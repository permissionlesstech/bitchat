import BitFoundation
import BitLogger
import Foundation
import SwiftUI
import Tor

final class ChatNostrCoordinator {
    private unowned let viewModel: ChatViewModel

    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
    }

    @MainActor
    func resubscribeCurrentGeohash() {
        guard case .location(let channel) = viewModel.activeChannel else { return }
        guard let subID = viewModel.geoSubscriptionID else {
            switchLocationChannel(to: viewModel.activeChannel)
            return
        }

        viewModel.participantTracker.startRefreshTimer()
        NostrRelayManager.shared.unsubscribe(id: subID)
        let filter = NostrFilter.geohashEphemeral(
            channel.geohash,
            since: Date().addingTimeInterval(-TransportConfig.nostrGeohashInitialLookbackSeconds),
            limit: TransportConfig.nostrGeohashInitialLimit
        )
        let subRelays = GeoRelayDirectory.shared.closestRelays(
            toGeohash: channel.geohash,
            count: TransportConfig.nostrGeoRelayCount
        )
        NostrRelayManager.shared.subscribe(filter: filter, id: subID, relayUrls: subRelays) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.subscribeNostrEvent(event)
            }
        }

        if let dmSub = viewModel.geoDmSubscriptionID {
            NostrRelayManager.shared.unsubscribe(id: dmSub)
            viewModel.geoDmSubscriptionID = nil
        }

        if let identity = try? viewModel.idBridge.deriveIdentity(forGeohash: channel.geohash) {
            let dmSub = "geo-dm-\(channel.geohash)"
            viewModel.geoDmSubscriptionID = dmSub
            let dmFilter = NostrFilter.giftWrapsFor(
                pubkey: identity.publicKeyHex,
                since: Date().addingTimeInterval(-TransportConfig.nostrDMSubscribeLookbackSeconds)
            )
            NostrRelayManager.shared.subscribe(filter: dmFilter, id: dmSub) { [weak self] giftWrap in
                Task { @MainActor [weak self] in
                    self?.subscribeGiftWrap(giftWrap, id: identity)
                }
            }
        }
    }

    @MainActor
    func subscribeNostrEvent(_ event: NostrEvent) {
        guard event.isValidSignature() else { return }
        guard (event.kind == NostrProtocol.EventKind.ephemeralEvent.rawValue
            || event.kind == NostrProtocol.EventKind.geohashPresence.rawValue),
              !viewModel.deduplicationService.hasProcessedNostrEvent(event.id)
        else {
            return
        }

        viewModel.deduplicationService.recordNostrEvent(event.id)

        if let gh = viewModel.currentGeohash,
           let myGeoIdentity = try? viewModel.idBridge.deriveIdentity(forGeohash: gh),
           myGeoIdentity.publicKeyHex.lowercased() == event.pubkey.lowercased() {
            let eventTime = Date(timeIntervalSince1970: TimeInterval(event.created_at))
            if Date().timeIntervalSince(eventTime) < 15 {
                return
            }
        }

        if let nickTag = event.tags.first(where: { $0.first == "n" }), nickTag.count >= 2 {
            let nick = nickTag[1].trimmed
            viewModel.locationPresenceStore.setNickname(nick, for: event.pubkey)
        }

        viewModel.nostrKeyMapping[PeerID(nostr_: event.pubkey)] = event.pubkey
        viewModel.nostrKeyMapping[PeerID(nostr: event.pubkey)] = event.pubkey
        viewModel.participantTracker.recordParticipant(pubkeyHex: event.pubkey)

        if event.kind == NostrProtocol.EventKind.geohashPresence.rawValue {
            return
        }

        let hasTeleportTag = event.tags.contains { tag in
            tag.count >= 2 && tag[0].lowercased() == "t" && tag[1].lowercased() == "teleport"
        }

        if hasTeleportTag {
            let key = event.pubkey.lowercased()
            let isSelf: Bool = {
                if let gh = viewModel.currentGeohash,
                   let myIdentity = try? viewModel.idBridge.deriveIdentity(forGeohash: gh) {
                    return myIdentity.publicKeyHex.lowercased() == key
                }
                return false
            }()
            if !isSelf {
                Task { @MainActor [weak viewModel] in
                    viewModel?.locationPresenceStore.markTeleported(key)
                }
            }
        }

        let senderName = viewModel.displayNameForNostrPubkey(event.pubkey)
        let content = event.content.trimmed
        let rawTs = Date(timeIntervalSince1970: TimeInterval(event.created_at))
        let timestamp = min(rawTs, Date())
        let mentions = viewModel.parseMentions(from: content)
        let message = BitchatMessage(
            id: event.id,
            sender: senderName,
            content: content,
            timestamp: timestamp,
            isRelay: false,
            senderPeerID: PeerID(nostr: event.pubkey),
            mentions: mentions.isEmpty ? nil : mentions
        )

        Task { @MainActor [weak viewModel] in
            guard let viewModel else { return }
            let isBlocked = viewModel.identityManager.isNostrBlocked(pubkeyHexLowercased: event.pubkey.lowercased())
            viewModel.handlePublicMessage(message)
            if !isBlocked {
                viewModel.checkForMentions(message)
                viewModel.sendHapticFeedback(for: message)
            }
        }
    }

    @MainActor
    func subscribeGiftWrap(_ giftWrap: NostrEvent, id: NostrIdentity) {
        guard giftWrap.isValidSignature() else { return }
        guard !viewModel.deduplicationService.hasProcessedNostrEvent(giftWrap.id) else { return }
        viewModel.deduplicationService.recordNostrEvent(giftWrap.id)

        guard let (content, senderPubkey, rumorTs) = try? NostrProtocol.decryptPrivateMessage(
            giftWrap: giftWrap,
            recipientIdentity: id
        ),
        let packet = Self.decodeEmbeddedBitChatPacket(from: content),
        packet.type == MessageType.noiseEncrypted.rawValue,
        let noisePayload = NoisePayload.decode(packet.payload)
        else {
            return
        }

        let messageTimestamp = Date(timeIntervalSince1970: TimeInterval(rumorTs))
        let convKey = PeerID(nostr_: senderPubkey)
        viewModel.nostrKeyMapping[convKey] = senderPubkey

        switch noisePayload.type {
        case .privateMessage:
            viewModel.handlePrivateMessage(
                noisePayload,
                senderPubkey: senderPubkey,
                convKey: convKey,
                id: id,
                messageTimestamp: messageTimestamp
            )
        case .delivered:
            viewModel.handleDelivered(noisePayload, senderPubkey: senderPubkey, convKey: convKey)
        case .readReceipt:
            viewModel.handleReadReceipt(noisePayload, senderPubkey: senderPubkey, convKey: convKey)
        case .verifyChallenge, .verifyResponse:
            break
        }
    }

    @MainActor
    func switchLocationChannel(to channel: ChannelID) {
        viewModel.publicMessagePipeline.reset()
        viewModel.activeChannel = channel
        viewModel.publicMessagePipeline.updateActiveChannel(channel)

        viewModel.deduplicationService.clearNostrCaches()
        switch channel {
        case .mesh:
            viewModel.refreshVisibleMessages(from: .mesh)
            let emptyMesh = viewModel.messages.filter { $0.content.trimmed.isEmpty }.count
            if emptyMesh > 0 {
                SecureLogger.debug("RenderGuard: mesh timeline contains \(emptyMesh) empty messages", category: .session)
            }
            viewModel.participantTracker.stopRefreshTimer()
            viewModel.participantTracker.setActiveGeohash(nil)
            viewModel.locationPresenceStore.clearTeleportedGeo()

        case .location:
            viewModel.refreshVisibleMessages(from: channel)
        }

        if case .location = channel {
            for content in viewModel.timelineStore.drainPendingGeohashSystemMessages() {
                viewModel.addPublicSystemMessage(content)
            }
        }

        if let sub = viewModel.geoSubscriptionID {
            NostrRelayManager.shared.unsubscribe(id: sub)
            viewModel.geoSubscriptionID = nil
        }
        if let dmSub = viewModel.geoDmSubscriptionID {
            NostrRelayManager.shared.unsubscribe(id: dmSub)
            viewModel.geoDmSubscriptionID = nil
        }
        viewModel.currentGeohash = nil
        viewModel.participantTracker.setActiveGeohash(nil)
        viewModel.locationPresenceStore.clearGeoNicknames()

        guard case .location(let channel) = channel else { return }
        viewModel.currentGeohash = channel.geohash
        viewModel.participantTracker.setActiveGeohash(channel.geohash)

        if let identity = try? viewModel.idBridge.deriveIdentity(forGeohash: channel.geohash) {
            viewModel.participantTracker.recordParticipant(pubkeyHex: identity.publicKeyHex)
            let hasRegional = !viewModel.locationManager.availableChannels.isEmpty
            let inRegional = viewModel.locationManager.availableChannels.contains { $0.geohash == channel.geohash }
            let key = identity.publicKeyHex.lowercased()
            if viewModel.locationManager.teleported && hasRegional && !inRegional {
                viewModel.locationPresenceStore.markTeleported(key)
                SecureLogger.info(
                    "GeoTeleport: channel switch mark self teleported key=\(key.prefix(8))… total=\(viewModel.locationPresenceStore.teleportedGeo.count)",
                    category: .session
                )
            } else {
                viewModel.locationPresenceStore.clearTeleported(key)
            }
        }

        let subID = "geo-\(channel.geohash)"
        viewModel.geoSubscriptionID = subID
        viewModel.participantTracker.startRefreshTimer()
        let ts = Date().addingTimeInterval(-TransportConfig.nostrGeohashInitialLookbackSeconds)
        let filter = NostrFilter.geohashEphemeral(channel.geohash, since: ts, limit: TransportConfig.nostrGeohashInitialLimit)
        let subRelays = GeoRelayDirectory.shared.closestRelays(toGeohash: channel.geohash, count: 5)
        NostrRelayManager.shared.subscribe(filter: filter, id: subID, relayUrls: subRelays) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleNostrEvent(event)
            }
        }

        subscribeToGeoChat(channel)
    }

    @MainActor
    func handleNostrEvent(_ event: NostrEvent) {
        guard event.isValidSignature() else { return }
        guard (event.kind == NostrProtocol.EventKind.ephemeralEvent.rawValue
            || event.kind == NostrProtocol.EventKind.geohashPresence.rawValue)
        else {
            return
        }

        if viewModel.deduplicationService.hasProcessedNostrEvent(event.id) { return }
        viewModel.deduplicationService.recordNostrEvent(event.id)

        let tagSummary = event.tags.map { "[" + $0.joined(separator: ",") + "]" }.joined(separator: ",")
        SecureLogger.debug("GeoTeleport: recv pub=\(event.pubkey.prefix(8))… tags=\(tagSummary)", category: .session)

        if viewModel.identityManager.isNostrBlocked(pubkeyHexLowercased: event.pubkey) {
            return
        }

        let hasTeleportTag = event.tags.contains { tag in
            tag.count >= 2 && tag[0].lowercased() == "t" && tag[1].lowercased() == "teleport"
        }

        let isSelf: Bool = {
            if let gh = viewModel.currentGeohash,
               let my = try? viewModel.idBridge.deriveIdentity(forGeohash: gh) {
                return my.publicKeyHex.lowercased() == event.pubkey.lowercased()
            }
            return false
        }()

        if hasTeleportTag, !isSelf {
            let key = event.pubkey.lowercased()
            Task { @MainActor [weak viewModel] in
                guard let viewModel else { return }
                viewModel.locationPresenceStore.markTeleported(key)
                SecureLogger.info(
                    "GeoTeleport: mark peer teleported key=\(key.prefix(8))… total=\(viewModel.locationPresenceStore.teleportedGeo.count)",
                    category: .session
                )
            }
        }

        viewModel.participantTracker.recordParticipant(pubkeyHex: event.pubkey)

        if isSelf {
            let eventTime = Date(timeIntervalSince1970: TimeInterval(event.created_at))
            if Date().timeIntervalSince(eventTime) < 15 {
                return
            }
        }

        if let nickTag = event.tags.first(where: { $0.first == "n" }), nickTag.count >= 2 {
            viewModel.locationPresenceStore.setNickname(nickTag[1].trimmed, for: event.pubkey)
        }

        viewModel.nostrKeyMapping[PeerID(nostr_: event.pubkey)] = event.pubkey
        viewModel.nostrKeyMapping[PeerID(nostr: event.pubkey)] = event.pubkey

        if event.kind == NostrProtocol.EventKind.geohashPresence.rawValue {
            return
        }

        let senderName = viewModel.displayNameForNostrPubkey(event.pubkey)
        let content = event.content

        if let teleTag = event.tags.first(where: { $0.first == "t" }),
           teleTag.count >= 2,
           teleTag[1] == "teleport",
           content.trimmed.isEmpty {
            return
        }

        let rawTs = Date(timeIntervalSince1970: TimeInterval(event.created_at))
        let mentions = viewModel.parseMentions(from: content)
        let message = BitchatMessage(
            id: event.id,
            sender: senderName,
            content: content,
            timestamp: min(rawTs, Date()),
            isRelay: false,
            senderPeerID: PeerID(nostr: event.pubkey),
            mentions: mentions.isEmpty ? nil : mentions
        )

        Task { @MainActor [weak viewModel] in
            guard let viewModel else { return }
            viewModel.handlePublicMessage(message)
            viewModel.checkForMentions(message)
            viewModel.sendHapticFeedback(for: message)
        }
    }

    @MainActor
    func subscribeToGeoChat(_ channel: GeohashChannel) {
        guard let identity = try? viewModel.idBridge.deriveIdentity(forGeohash: channel.geohash) else { return }

        let dmSub = "geo-dm-\(channel.geohash)"
        viewModel.geoDmSubscriptionID = dmSub
        if TorManager.shared.isReady {
            SecureLogger.debug("GeoDM: subscribing DMs pub=\(identity.publicKeyHex.prefix(8))… sub=\(dmSub)", category: .session)
        }
        let dmFilter = NostrFilter.giftWrapsFor(
            pubkey: identity.publicKeyHex,
            since: Date().addingTimeInterval(-TransportConfig.nostrDMSubscribeLookbackSeconds)
        )
        NostrRelayManager.shared.subscribe(filter: dmFilter, id: dmSub) { [weak self] giftWrap in
            Task { @MainActor [weak self] in
                self?.handleGiftWrap(giftWrap, id: identity)
            }
        }
    }

    @MainActor
    func handleGiftWrap(_ giftWrap: NostrEvent, id: NostrIdentity) {
        guard giftWrap.isValidSignature() else { return }
        if viewModel.deduplicationService.hasProcessedNostrEvent(giftWrap.id) {
            return
        }
        viewModel.deduplicationService.recordNostrEvent(giftWrap.id)

        guard let (content, senderPubkey, rumorTs) = try? NostrProtocol.decryptPrivateMessage(
            giftWrap: giftWrap,
            recipientIdentity: id
        ) else {
            SecureLogger.warning("GeoDM: failed decrypt giftWrap id=\(giftWrap.id.prefix(8))…", category: .session)
            return
        }

        SecureLogger.debug(
            "GeoDM: decrypted gift-wrap id=\(giftWrap.id.prefix(16))... from=\(senderPubkey.prefix(8))...",
            category: .session
        )

        guard let packet = Self.decodeEmbeddedBitChatPacket(from: content),
              packet.type == MessageType.noiseEncrypted.rawValue,
              let payload = NoisePayload.decode(packet.payload)
        else {
            return
        }

        let convKey = PeerID(nostr_: senderPubkey)
        viewModel.nostrKeyMapping[convKey] = senderPubkey

        switch payload.type {
        case .privateMessage:
            let messageTimestamp = Date(timeIntervalSince1970: TimeInterval(rumorTs))
            viewModel.handlePrivateMessage(
                payload,
                senderPubkey: senderPubkey,
                convKey: convKey,
                id: id,
                messageTimestamp: messageTimestamp
            )
        case .delivered:
            viewModel.handleDelivered(payload, senderPubkey: senderPubkey, convKey: convKey)
        case .readReceipt:
            viewModel.handleReadReceipt(payload, senderPubkey: senderPubkey, convKey: convKey)
        case .verifyChallenge, .verifyResponse:
            break
        }
    }

    @MainActor
    func sendGeohash(context: ChatViewModel.GeoOutgoingContext) {
        let channel = context.channel
        let event = context.event
        let identity = context.identity

        let targetRelays = GeoRelayDirectory.shared.closestRelays(
            toGeohash: channel.geohash,
            count: TransportConfig.nostrGeoRelayCount
        )

        if targetRelays.isEmpty {
            SecureLogger.warning("Geo: no geohash relays available for \(channel.geohash); not sending", category: .session)
        } else {
            NostrRelayManager.shared.sendEvent(event, to: targetRelays)
        }

        viewModel.participantTracker.recordParticipant(pubkeyHex: identity.publicKeyHex)
        viewModel.nostrKeyMapping[PeerID(nostr: identity.publicKeyHex)] = identity.publicKeyHex
        SecureLogger.debug(
            "GeoTeleport: sent geo message pub=\(identity.publicKeyHex.prefix(8))… teleported=\(context.teleported)",
            category: .session
        )

        let hasRegional = !viewModel.locationManager.availableChannels.isEmpty
        let inRegional = viewModel.locationManager.availableChannels.contains { $0.geohash == channel.geohash }
        if context.teleported && hasRegional && !inRegional {
            let key = identity.publicKeyHex.lowercased()
            viewModel.locationPresenceStore.markTeleported(key)
            SecureLogger.info(
                "GeoTeleport: mark self teleported key=\(key.prefix(8))… total=\(viewModel.locationPresenceStore.teleportedGeo.count)",
                category: .session
            )
        }

        viewModel.deduplicationService.recordNostrEvent(event.id)
    }

    @MainActor
    func beginGeohashSampling(for geohashes: [String]) {
        if !TorManager.shared.isForeground() {
            endGeohashSampling()
            return
        }

        let desired = Set(geohashes)
        let current = Set(viewModel.geoSamplingSubs.values)
        let toAdd = desired.subtracting(current)
        let toRemove = current.subtracting(desired)

        for (subID, gh) in viewModel.geoSamplingSubs where toRemove.contains(gh) {
            NostrRelayManager.shared.unsubscribe(id: subID)
            viewModel.geoSamplingSubs.removeValue(forKey: subID)
        }

        for gh in toAdd {
            subscribe(gh)
        }
    }

    @MainActor
    func subscribe(_ gh: String) {
        let subID = "geo-sample-\(gh)"
        viewModel.geoSamplingSubs[subID] = gh
        let filter = NostrFilter.geohashEphemeral(
            gh,
            since: Date().addingTimeInterval(-TransportConfig.nostrGeohashSampleLookbackSeconds),
            limit: TransportConfig.nostrGeohashSampleLimit
        )
        let subRelays = GeoRelayDirectory.shared.closestRelays(toGeohash: gh, count: 5)
        NostrRelayManager.shared.subscribe(filter: filter, id: subID, relayUrls: subRelays) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.subscribeNostrEvent(event, gh: gh)
            }
        }
    }

    @MainActor
    func subscribeNostrEvent(_ event: NostrEvent, gh: String) {
        guard event.isValidSignature() else { return }
        guard (event.kind == NostrProtocol.EventKind.ephemeralEvent.rawValue
            || event.kind == NostrProtocol.EventKind.geohashPresence.rawValue)
        else {
            return
        }

        let existingCount = viewModel.participantTracker.participantCount(for: gh)
        viewModel.participantTracker.recordParticipant(pubkeyHex: event.pubkey, geohash: gh)

        guard let content = event.content.trimmedOrNilIfEmpty else { return }
        if viewModel.identityManager.isNostrBlocked(pubkeyHexLowercased: event.pubkey.lowercased()) { return }
        if let my = try? viewModel.idBridge.deriveIdentity(forGeohash: gh),
           my.publicKeyHex.lowercased() == event.pubkey.lowercased() {
            return
        }
        guard existingCount == 0 else { return }

        let eventTime = Date(timeIntervalSince1970: TimeInterval(event.created_at))
        if Date().timeIntervalSince(eventTime) > 30 { return }

        #if os(iOS)
        guard UIApplication.shared.applicationState == .active else { return }
        if case .location(let channel) = viewModel.activeChannel, channel.geohash == gh { return }
        #elseif os(macOS)
        guard NSApplication.shared.isActive else { return }
        if case .location(let channel) = viewModel.activeChannel, channel.geohash == gh { return }
        #endif

        cooldownPerGeohash(gh, content: content, event: event)
    }

    @MainActor
    func cooldownPerGeohash(_ gh: String, content: String, event: NostrEvent) {
        let now = Date()
        let last = viewModel.lastGeoNotificationAt[gh] ?? .distantPast
        if now.timeIntervalSince(last) < TransportConfig.uiGeoNotifyCooldownSeconds { return }

        let preview: String = {
            let maxLen = TransportConfig.uiGeoNotifySnippetMaxLen
            if content.count <= maxLen { return content }
            let idx = content.index(content.startIndex, offsetBy: maxLen)
            return String(content[..<idx]) + "…"
        }()

        Task { @MainActor [weak viewModel] in
            guard let viewModel else { return }
            viewModel.lastGeoNotificationAt[gh] = now
            let senderSuffix = String(event.pubkey.suffix(4))
            let nick = viewModel.geoNicknames[event.pubkey.lowercased()]
            let senderName = (nick?.isEmpty == false ? nick! : "anon") + "#" + senderSuffix

            let rawTs = Date(timeIntervalSince1970: TimeInterval(event.created_at))
            let ts = min(rawTs, Date())
            let mentions = viewModel.parseMentions(from: content)
            let message = BitchatMessage(
                id: event.id,
                sender: senderName,
                content: content,
                timestamp: ts,
                isRelay: false,
                senderPeerID: PeerID(nostr: event.pubkey),
                mentions: mentions.isEmpty ? nil : mentions
            )
            if viewModel.timelineStore.appendIfAbsent(message, toGeohash: gh) {
                viewModel.synchronizePublicConversationStore(forGeohash: gh)
                NotificationService.shared.sendGeohashActivityNotification(geohash: gh, bodyPreview: preview)
            }
        }
    }

    @MainActor
    func endGeohashSampling() {
        for subID in viewModel.geoSamplingSubs.keys {
            NostrRelayManager.shared.unsubscribe(id: subID)
        }
        viewModel.geoSamplingSubs.removeAll()
    }

    @MainActor
    func setupNostrMessageHandling() {
        guard let currentIdentity = try? viewModel.idBridge.getCurrentNostrIdentity() else {
            SecureLogger.warning("⚠️ No Nostr identity available for message handling", category: .session)
            return
        }

        SecureLogger.debug(
            "🔑 Setting up Nostr subscription for pubkey: \(currentIdentity.publicKeyHex.prefix(16))...",
            category: .session
        )

        let filter = NostrFilter.giftWrapsFor(
            pubkey: currentIdentity.publicKeyHex,
            since: Date().addingTimeInterval(-TransportConfig.nostrDMSubscribeLookbackSeconds)
        )

        viewModel.nostrRelayManager?.subscribe(filter: filter, id: "chat-messages") { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleNostrMessage(event)
            }
        }
    }

    @MainActor
    func handleNostrMessage(_ giftWrap: NostrEvent) {
        if viewModel.deduplicationService.hasProcessedNostrEvent(giftWrap.id) { return }
        viewModel.deduplicationService.recordNostrEvent(giftWrap.id)

        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.processNostrMessage(giftWrap)
        }
    }

    func processNostrMessage(_ giftWrap: NostrEvent) async {
        guard giftWrap.isValidSignature() else { return }
        let currentIdentity: NostrIdentity? = await MainActor.run {
            try? viewModel.idBridge.getCurrentNostrIdentity()
        }
        guard let currentIdentity else { return }

        do {
            let (content, senderPubkey, rumorTimestamp) = try NostrProtocol.decryptPrivateMessage(
                giftWrap: giftWrap,
                recipientIdentity: currentIdentity
            )

            if content.hasPrefix("verify:") {
                return
            }

            if content.hasPrefix("bitchat1:") {
                let packet: BitchatPacket? = await MainActor.run {
                    Self.decodeEmbeddedBitChatPacket(from: content)
                }
                guard let packet else {
                    SecureLogger.error("Failed to decode embedded BitChat packet from Nostr DM", category: .session)
                    return
                }

                let actualSenderNoiseKey: Data? = await MainActor.run {
                    self.findNoiseKey(for: senderPubkey)
                }
                let targetPeerID = PeerID(str: actualSenderNoiseKey?.hexEncodedString()) ?? PeerID(nostr_: senderPubkey)

                if packet.type == MessageType.noiseEncrypted.rawValue,
                   let payload = NoisePayload.decode(packet.payload) {
                    let messageTimestamp = Date(timeIntervalSince1970: TimeInterval(rumorTimestamp))
                    await MainActor.run {
                        viewModel.nostrKeyMapping[targetPeerID] = senderPubkey

                        switch payload.type {
                        case .privateMessage:
                            viewModel.handlePrivateMessage(
                                payload,
                                senderPubkey: senderPubkey,
                                convKey: targetPeerID,
                                id: currentIdentity,
                                messageTimestamp: messageTimestamp
                            )
                        case .delivered:
                            viewModel.handleDelivered(payload, senderPubkey: senderPubkey, convKey: targetPeerID)
                        case .readReceipt:
                            viewModel.handleReadReceipt(payload, senderPubkey: senderPubkey, convKey: targetPeerID)
                        case .verifyChallenge, .verifyResponse:
                            break
                        }
                    }
                }
            } else {
                SecureLogger.debug("Ignoring non-embedded Nostr DM content", category: .session)
            }
        } catch {
            SecureLogger.error("Failed to decrypt Nostr message: \(error)", category: .session)
        }
    }

    @MainActor
    func findNoiseKey(for nostrPubkey: String) -> Data? {
        let favorites = FavoritesPersistenceService.shared.favorites.values
        var npubToMatch = nostrPubkey

        if !nostrPubkey.hasPrefix("npub") {
            if let pubkeyData = Data(hexString: nostrPubkey),
               let encoded = try? Bech32.encode(hrp: "npub", data: pubkeyData) {
                npubToMatch = encoded
            } else {
                SecureLogger.warning(
                    "⚠️ Invalid hex public key format or encoding failed: \(nostrPubkey.prefix(16))...",
                    category: .session
                )
            }
        }

        for relationship in favorites {
            if let storedNostrKey = relationship.peerNostrPublicKey {
                if storedNostrKey == npubToMatch {
                    return relationship.peerNoisePublicKey
                }
                if !storedNostrKey.hasPrefix("npub") && storedNostrKey == nostrPubkey {
                    SecureLogger.debug("✅ Found Noise key for Nostr sender (hex match)", category: .session)
                    return relationship.peerNoisePublicKey
                }
            }
        }

        SecureLogger.debug(
            "⚠️ No matching Noise key found for Nostr pubkey: \(nostrPubkey.prefix(16))... (tried npub: \(npubToMatch.prefix(16))...)",
            category: .session
        )
        return nil
    }

    @MainActor
    func sendDeliveryAckViaNostrEmbedded(
        _ message: BitchatMessage,
        wasReadBefore: Bool,
        senderPubkey: String,
        key: Data?
    ) {
        if let _ = key {
            if let identity = try? viewModel.idBridge.getCurrentNostrIdentity() {
                let transport = NostrTransport(keychain: viewModel.keychain, idBridge: viewModel.idBridge)
                transport.senderPeerID = viewModel.meshService.myPeerID
                transport.sendDeliveryAckGeohash(for: message.id, toRecipientHex: senderPubkey, from: identity)
            }
        } else if let identity = try? viewModel.idBridge.getCurrentNostrIdentity() {
            let transport = NostrTransport(keychain: viewModel.keychain, idBridge: viewModel.idBridge)
            transport.senderPeerID = viewModel.meshService.myPeerID
            transport.sendDeliveryAckGeohash(for: message.id, toRecipientHex: senderPubkey, from: identity)
            SecureLogger.debug(
                "Sent DELIVERED ack directly to Nostr pub=\(senderPubkey.prefix(8))… for mid=\(message.id.prefix(8))…",
                category: .session
            )
        }

        if !wasReadBefore && viewModel.selectedPrivateChatPeer == message.senderPeerID {
            if let _ = key {
                if let identity = try? viewModel.idBridge.getCurrentNostrIdentity() {
                    let transport = NostrTransport(keychain: viewModel.keychain, idBridge: viewModel.idBridge)
                    transport.senderPeerID = viewModel.meshService.myPeerID
                    transport.sendReadReceiptGeohash(message.id, toRecipientHex: senderPubkey, from: identity)
                }
            } else if let identity = try? viewModel.idBridge.getCurrentNostrIdentity() {
                let transport = NostrTransport(keychain: viewModel.keychain, idBridge: viewModel.idBridge)
                transport.senderPeerID = viewModel.meshService.myPeerID
                transport.sendReadReceiptGeohash(message.id, toRecipientHex: senderPubkey, from: identity)
                SecureLogger.debug(
                    "Viewing chat; sent READ ack directly to Nostr pub=\(senderPubkey.prefix(8))… for mid=\(message.id.prefix(8))…",
                    category: .session
                )
            }
        }
    }

    @MainActor
    func handleFavoriteNotification(content: String, from nostrPubkey: String) {
        guard let senderNoiseKey = findNoiseKey(for: nostrPubkey) else { return }

        let isFavorite = content.contains("FAVORITE:TRUE")
        let senderNickname = content.components(separatedBy: "|").last ?? "Unknown"

        if isFavorite {
            FavoritesPersistenceService.shared.addFavorite(
                peerNoisePublicKey: senderNoiseKey,
                peerNostrPublicKey: nostrPubkey,
                peerNickname: senderNickname
            )
        }

        var extractedNostrPubkey: String?
        if let range = content.range(of: "NPUB:") {
            let suffix = content[range.upperBound...]
            let parts = suffix.components(separatedBy: "|")
            if let key = parts.first {
                extractedNostrPubkey = String(key)
            }
        } else if content.contains(":") {
            let parts = content.components(separatedBy: ":")
            if parts.count >= 3 {
                extractedNostrPubkey = String(parts[2])
            }
        }

        SecureLogger.info("📝 Received favorite notification from \(senderNickname): \(isFavorite)", category: .session)

        if isFavorite && extractedNostrPubkey != nil {
            SecureLogger.info(
                "💾 Storing Nostr key association for \(senderNickname): \(extractedNostrPubkey!.prefix(16))...",
                category: .session
            )
            FavoritesPersistenceService.shared.addFavorite(
                peerNoisePublicKey: senderNoiseKey,
                peerNostrPublicKey: extractedNostrPubkey,
                peerNickname: senderNickname
            )
        }

        NotificationService.shared.sendLocalNotification(
            title: isFavorite ? "New Favorite" : "Favorite Removed",
            body: "\(senderNickname) \(isFavorite ? "favorited" : "unfavorited") you",
            identifier: "fav-\(UUID().uuidString)"
        )
    }

    @MainActor
    func sendFavoriteNotificationViaNostr(noisePublicKey: Data, isFavorite: Bool) {
        guard let relationship = FavoritesPersistenceService.shared.getFavoriteStatus(for: noisePublicKey),
              relationship.peerNostrPublicKey != nil else {
            SecureLogger.warning("⚠️ Cannot send favorite notification - no Nostr key for peer", category: .session)
            return
        }

        let peerID = PeerID(hexData: noisePublicKey)
        viewModel.messageRouter.sendFavoriteNotification(to: peerID, isFavorite: isFavorite)
    }

    @MainActor
    func nostrPubkeyForDisplayName(_ name: String) -> String? {
        for person in viewModel.visibleGeohashPeople() where person.displayName == name {
            return person.id
        }
        for (pub, nick) in viewModel.geoNicknames where nick == name {
            return pub
        }
        return nil
    }

    @MainActor
    func startGeohashDM(withPubkeyHex hex: String) {
        let convKey = PeerID(nostr_: hex)
        viewModel.nostrKeyMapping[convKey] = hex
        viewModel.startPrivateChat(with: convKey)
    }

    @MainActor
    func fullNostrHex(forSenderPeerID senderID: PeerID) -> String? {
        viewModel.nostrKeyMapping[senderID]
    }

    @MainActor
    func geohashDisplayName(for convKey: PeerID) -> String {
        guard let full = viewModel.nostrKeyMapping[convKey] else {
            return convKey.bare
        }
        return viewModel.displayNameForNostrPubkey(full)
    }
}

private extension ChatNostrCoordinator {
    @MainActor
    static func decodeEmbeddedBitChatPacket(from content: String) -> BitchatPacket? {
        guard content.hasPrefix("bitchat1:") else { return nil }
        let encoded = String(content.dropFirst("bitchat1:".count))
        let maxBytes = FileTransferLimits.maxFramedFileBytes
        let maxEncoded = ((maxBytes + 2) / 3) * 4
        guard encoded.count <= maxEncoded else { return nil }
        guard let packetData = ChatViewModel.base64URLDecode(encoded),
              packetData.count <= maxBytes
        else {
            return nil
        }
        return BitchatPacket.from(packetData)
    }
}
