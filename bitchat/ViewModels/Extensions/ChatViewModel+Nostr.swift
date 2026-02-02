//
// ChatViewModel+Nostr.swift
// bitchat
//
// Geohash and Nostr logic for ChatViewModel
//

import Foundation
import Combine
import BitLogger
import SwiftUI
import Tor

extension ChatViewModel {

    // MARK: - Geohash Subscription

    // Resubscribe to the active geohash channel without clearing timeline
    @MainActor
    func resubscribeCurrentGeohash() {
        guard case .location(let ch) = activeChannel else { return }
        guard let subID = geoSubscriptionID else {
            // No existing subscription; set it up
            switchLocationChannel(to: activeChannel)
            return
        }
        // Ensure participant decay timer is running
        participantTracker.startRefreshTimer()
        // Unsubscribe + resubscribe
        NostrRelayManager.shared.unsubscribe(id: subID)
        let filter = NostrFilter.geohashEphemeral(
            ch.geohash,
            since: Date().addingTimeInterval(-TransportConfig.nostrGeohashInitialLookbackSeconds),
            limit: TransportConfig.nostrGeohashInitialLimit
        )
        let subRelays = GeoRelayDirectory.shared.closestRelays(
            toGeohash: ch.geohash,
            count: TransportConfig.nostrGeoRelayCount
        )
        NostrRelayManager.shared.subscribe(filter: filter, id: subID, relayUrls: subRelays) { [weak self] event in
            self?.subscribeNostrEvent(event)
        }
        // Resubscribe geohash DMs for this identity
        if let dmSub = geoDmSubscriptionID {
            NostrRelayManager.shared.unsubscribe(id: dmSub); geoDmSubscriptionID = nil
        }
        
        if let id = try? idBridge.deriveIdentity(forGeohash: ch.geohash) {
            let dmSub = "geo-dm-\(ch.geohash)"
            geoDmSubscriptionID = dmSub
            let dmFilter = NostrFilter.giftWrapsFor(pubkey: id.publicKeyHex, since: Date().addingTimeInterval(-TransportConfig.nostrDMSubscribeLookbackSeconds))
            NostrRelayManager.shared.subscribe(filter: dmFilter, id: dmSub) { [weak self] giftWrap in
                self?.subscribeGiftWrap(giftWrap, id: id)
            }
        }
    }
    
    func subscribeNostrEvent(_ event: NostrEvent) {
        guard event.isValidSignature() else { return }
        guard (event.kind == NostrProtocol.EventKind.ephemeralEvent.rawValue || 
               event.kind == NostrProtocol.EventKind.geohashPresence.rawValue),
              !deduplicationService.hasProcessedNostrEvent(event.id)
        else {
            return
        }

        deduplicationService.recordNostrEvent(event.id)
        
        if let gh = currentGeohash,
           let myGeoIdentity = try? idBridge.deriveIdentity(forGeohash: gh),
           myGeoIdentity.publicKeyHex.lowercased() == event.pubkey.lowercased() {
            // Skip very recent self-echo from relay, but allow older events (e.g., after app restart)
            let eventTime = Date(timeIntervalSince1970: TimeInterval(event.created_at))
            if Date().timeIntervalSince(eventTime) < 15 {
                return
            }
        }
        
        if let nickTag = event.tags.first(where: { $0.first == "n" }), nickTag.count >= 2 {
            let nick = nickTag[1].trimmingCharacters(in: .whitespacesAndNewlines)
            geoNicknames[event.pubkey.lowercased()] = nick
        }
        
        // Store mapping for geohash sender IDs used in messages (ensures consistent colors)
        nostrKeyMapping[PeerID(nostr_: event.pubkey)] = event.pubkey
        nostrKeyMapping[PeerID(nostr: event.pubkey)] = event.pubkey

        // Update participants last-seen for this pubkey
        participantTracker.recordParticipant(pubkeyHex: event.pubkey)
        
        // If presence heartbeat (Kind 20001), stop here - no content to display
        if event.kind == NostrProtocol.EventKind.geohashPresence.rawValue {
            return
        }
        
        // Track teleported tag (only our format ["t","teleport"]) for icon state
        let hasTeleportTag = event.tags.contains(where: { tag in
            tag.count >= 2 && tag[0].lowercased() == "t" && tag[1].lowercased() == "teleport"
        })
        
        if hasTeleportTag {
            let key = event.pubkey.lowercased()
            // Do not mark our own key from historical events; rely on manager.teleported for self
            let isSelf: Bool = {
                if let gh = currentGeohash, let my = try? idBridge.deriveIdentity(forGeohash: gh) {
                    return my.publicKeyHex.lowercased() == key
                }
                return false
            }()
            if !isSelf {
                Task { @MainActor in
                    teleportedGeo = teleportedGeo.union([key])
                }
            }
        }
        
        let senderName = displayNameForNostrPubkey(event.pubkey)
        let content = event.content.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Clamp future timestamps to now to avoid future-dated messages skewing order
        let rawTs = Date(timeIntervalSince1970: TimeInterval(event.created_at))
        let timestamp = min(rawTs, Date())
        let mentions = parseMentions(from: content)
        let msg = BitchatMessage(
            id: event.id,
            sender: senderName,
            content: content,
            timestamp: timestamp,
            isRelay: false,
            senderPeerID: PeerID(nostr: event.pubkey),
            mentions: mentions.isEmpty ? nil : mentions
        )
        Task { @MainActor in
            // BCH-01-012: Check blocking before any notifications
            // handlePublicMessage has its own blocking check but returns silently,
            // so we must also guard checkForMentions to prevent notification bypass
            let isBlocked = identityManager.isNostrBlocked(pubkeyHexLowercased: event.pubkey.lowercased())

            handlePublicMessage(msg)

            // Only check mentions and send haptic if sender is not blocked
            if !isBlocked {
                checkForMentions(msg)
                sendHapticFeedback(for: msg)
            }
        }
    }

    func subscribeGiftWrap(_ giftWrap: NostrEvent, id: NostrIdentity) {
        guard giftWrap.isValidSignature() else { return }
        guard !deduplicationService.hasProcessedNostrEvent(giftWrap.id) else { return }
        deduplicationService.recordNostrEvent(giftWrap.id)
        
        guard let (content, senderPubkey, rumorTs) = try? NostrProtocol.decryptPrivateMessage(giftWrap: giftWrap, recipientIdentity: id),
              let packet = Self.decodeEmbeddedBitChatPacket(from: content),
              packet.type == MessageType.noiseEncrypted.rawValue,
              let noisePayload = NoisePayload.decode(packet.payload)
        else {
            return
        }
        
        let messageTimestamp = Date(timeIntervalSince1970: TimeInterval(rumorTs))
        let convKey = PeerID(nostr_: senderPubkey)
        nostrKeyMapping[convKey] = senderPubkey
        
        switch noisePayload.type {
        case .privateMessage:
            handlePrivateMessage(noisePayload, senderPubkey: senderPubkey, convKey: convKey, id: id, messageTimestamp: messageTimestamp)
        case .delivered:
            handleDelivered(noisePayload, senderPubkey: senderPubkey, convKey: convKey)
        case .readReceipt:
            handleReadReceipt(noisePayload, senderPubkey: senderPubkey, convKey: convKey)
        case .verifyChallenge, .verifyResponse:
            // QR verification payloads over Nostr are not supported; ignore in geohash DMs
            break
        }
    }

    // MARK: - Geohash Channel Handling

    @MainActor
    func switchLocationChannel(to channel: ChannelID) {
        // Reset pending public batches to avoid cross-channel bleed
        publicMessagePipeline.reset()
        
        activeChannel = channel
        publicMessagePipeline.updateActiveChannel(channel)
        
        // Reset deduplication set and optionally hydrate timeline for mesh
        deduplicationService.clearNostrCaches()
        switch channel {
        case .mesh:
            refreshVisibleMessages(from: .mesh)
            // Debug: log if any empty messages are present
            let emptyMesh = messages.filter { $0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
            if emptyMesh > 0 {
                SecureLogger.debug("RenderGuard: mesh timeline contains \(emptyMesh) empty messages", category: .session)
            }
            participantTracker.stopRefreshTimer()
            participantTracker.setActiveGeohash(nil)
            teleportedGeo.removeAll()
        case .location:
            refreshVisibleMessages(from: channel)
        }
        // If switching to a location channel, flush any pending geohash-only system messages
        if case .location = channel {
            for content in timelineStore.drainPendingGeohashSystemMessages() {
                addPublicSystemMessage(content)
            }
        }
        // Unsubscribe previous
        if let sub = geoSubscriptionID {
            NostrRelayManager.shared.unsubscribe(id: sub)
            geoSubscriptionID = nil
        }
        if let dmSub = geoDmSubscriptionID {
            NostrRelayManager.shared.unsubscribe(id: dmSub)
            geoDmSubscriptionID = nil
        }
        currentGeohash = nil
        participantTracker.setActiveGeohash(nil)
        // Reset nickname cache for geochat participants
        geoNicknames.removeAll()

        guard case .location(let ch) = channel else { return }
        currentGeohash = ch.geohash
        participantTracker.setActiveGeohash(ch.geohash)
        
        // Ensure self appears immediately in the people list; mark teleported state only when truly teleported
        if let id = try? idBridge.deriveIdentity(forGeohash: ch.geohash) {
            participantTracker.recordParticipant(pubkeyHex: id.publicKeyHex)
            let hasRegional = !LocationChannelManager.shared.availableChannels.isEmpty
            let inRegional = LocationChannelManager.shared.availableChannels.contains { $0.geohash == ch.geohash }
            let key = id.publicKeyHex.lowercased()
            if LocationChannelManager.shared.teleported && hasRegional && !inRegional {
                teleportedGeo = teleportedGeo.union([key])
                SecureLogger.info("GeoTeleport: channel switch mark self teleported key=\(key.prefix(8))… total=\(teleportedGeo.count)", category: .session)
            } else {
                teleportedGeo.remove(key)
            }
        }
        
        let subID = "geo-\(ch.geohash)"
        geoSubscriptionID = subID
        participantTracker.startRefreshTimer()
        let ts = Date().addingTimeInterval(-TransportConfig.nostrGeohashInitialLookbackSeconds)
        let filter = NostrFilter.geohashEphemeral(ch.geohash, since: ts, limit: TransportConfig.nostrGeohashInitialLimit)
        let subRelays = GeoRelayDirectory.shared.closestRelays(toGeohash: ch.geohash, count: 5)
        NostrRelayManager.shared.subscribe(filter: filter, id: subID, relayUrls: subRelays) { [weak self] event in
            self?.handleNostrEvent(event)
        }

        subscribeToGeoChat(ch)
    }
    
    func handleNostrEvent(_ event: NostrEvent) {
        guard event.isValidSignature() else { return }
        // Only handle ephemeral kind 20000 or presence kind 20001 with matching tag
        guard (event.kind == NostrProtocol.EventKind.ephemeralEvent.rawValue ||
               event.kind == NostrProtocol.EventKind.geohashPresence.rawValue) else { return }
        
        // Deduplicate
        if deduplicationService.hasProcessedNostrEvent(event.id) { return }
        deduplicationService.recordNostrEvent(event.id)
        
        // Log incoming tags for diagnostics
        let tagSummary = event.tags.map { "[" + $0.joined(separator: ",") + "]" }.joined(separator: ",")
        SecureLogger.debug("GeoTeleport: recv pub=\(event.pubkey.prefix(8))… tags=\(tagSummary)", category: .session)
        
        // If this pubkey is blocked, skip mapping, participants, and timeline
        if identityManager.isNostrBlocked(pubkeyHexLowercased: event.pubkey) {
            return
        }
        
        // Track teleport tag for participants – only our format ["t", "teleport"]
        let hasTeleportTag: Bool = event.tags.contains { tag in
            tag.count >= 2 && tag[0].lowercased() == "t" && tag[1].lowercased() == "teleport"
        }
        
        let isSelf: Bool = {
            if let gh = currentGeohash, let my = try? idBridge.deriveIdentity(forGeohash: gh) {
                return my.publicKeyHex.lowercased() == event.pubkey.lowercased()
            }
            return false
        }()

        if hasTeleportTag {
            // Avoid marking our own key from historical events; rely on manager.teleported for self
            if !isSelf {
                let key = event.pubkey.lowercased()
                Task { @MainActor in
                    teleportedGeo = teleportedGeo.union([key])
                    SecureLogger.info("GeoTeleport: mark peer teleported key=\(key.prefix(8))… total=\(teleportedGeo.count)", category: .session)
                }
            }
        }
        
        // Update participants last-seen for this pubkey
        participantTracker.recordParticipant(pubkeyHex: event.pubkey)

        // Skip only very recent self-echo from relay; include older self events for hydration
        if isSelf {
            let eventTime = Date(timeIntervalSince1970: TimeInterval(event.created_at))
            if Date().timeIntervalSince(eventTime) < 15 {
                return
            }
        }
        
        // Cache nickname from tag if present
        if let nickTag = event.tags.first(where: { $0.first == "n" }), nickTag.count >= 2 {
            let nick = nickTag[1].trimmingCharacters(in: .whitespacesAndNewlines)
            geoNicknames[event.pubkey.lowercased()] = nick
        }
        
        // Store mapping for geohash DM initiation
        nostrKeyMapping[PeerID(nostr_: event.pubkey)] = event.pubkey
        nostrKeyMapping[PeerID(nostr: event.pubkey)] = event.pubkey
        
        // If presence heartbeat (Kind 20001), stop here - no content to display
        if event.kind == NostrProtocol.EventKind.geohashPresence.rawValue {
            return
        }
        
        let senderName = displayNameForNostrPubkey(event.pubkey)
        let content = event.content
        
        // If this is a teleport presence event (no content), don't add to timeline
        if let teleTag = event.tags.first(where: { $0.first == "t" }), teleTag.count >= 2, (teleTag[1] == "teleport"),
           content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }
        
        // Clamp future timestamps
        let rawTs = Date(timeIntervalSince1970: TimeInterval(event.created_at))
        let mentions = parseMentions(from: content)
        let msg = BitchatMessage(
            id: event.id,
            sender: senderName,
            content: content,
            timestamp: min(rawTs, Date()),
            isRelay: false,
            senderPeerID: PeerID(nostr: event.pubkey),
            mentions: mentions.isEmpty ? nil : mentions
        )
        
        Task { @MainActor in
            handlePublicMessage(msg)
            checkForMentions(msg)
            sendHapticFeedback(for: msg)
        }
    }
    
    @MainActor
    func subscribeToGeoChat(_ ch: GeohashChannel) {
        guard let id = try? idBridge.deriveIdentity(forGeohash: ch.geohash) else { return }
        
        let dmSub = "geo-dm-\(ch.geohash)"
        geoDmSubscriptionID = dmSub
        // pared back logging: subscribe debug only
        // Log GeoDM subscribe only when Tor is ready to avoid early noise
        if TorManager.shared.isReady {
            SecureLogger.debug("GeoDM: subscribing DMs pub=\(id.publicKeyHex.prefix(8))… sub=\(dmSub)", category: .session)
        }
        let dmFilter = NostrFilter.giftWrapsFor(pubkey: id.publicKeyHex, since: Date().addingTimeInterval(-TransportConfig.nostrDMSubscribeLookbackSeconds))
        NostrRelayManager.shared.subscribe(filter: dmFilter, id: dmSub) { [weak self] giftWrap in
            self?.handleGiftWrap(giftWrap, id: id)
        }
    }
    
    func handleGiftWrap(_ giftWrap: NostrEvent, id: NostrIdentity) {
        guard giftWrap.isValidSignature() else { return }
        if deduplicationService.hasProcessedNostrEvent(giftWrap.id) {
            return
        }
        deduplicationService.recordNostrEvent(giftWrap.id)
        
        // Decrypt with per-geohash identity
        guard let (content, senderPubkey, rumorTs) = try? NostrProtocol.decryptPrivateMessage(giftWrap: giftWrap, recipientIdentity: id) else {
            SecureLogger.warning("GeoDM: failed decrypt giftWrap id=\(giftWrap.id.prefix(8))…", category: .session)
            return
        }
        
        SecureLogger.debug("GeoDM: decrypted gift-wrap id=\(giftWrap.id.prefix(16))... from=\(senderPubkey.prefix(8))...", category: .session)
        
        guard let packet = Self.decodeEmbeddedBitChatPacket(from: content),
              packet.type == MessageType.noiseEncrypted.rawValue,
              let payload = NoisePayload.decode(packet.payload)
        else {
            return
        }
        
        let convKey = PeerID(nostr_: senderPubkey)
        nostrKeyMapping[convKey] = senderPubkey
        
        switch payload.type {
        case .privateMessage:
            let messageTimestamp = Date(timeIntervalSince1970: TimeInterval(rumorTs))
            handlePrivateMessage(payload, senderPubkey: senderPubkey, convKey: convKey, id: id, messageTimestamp: messageTimestamp)
        case .delivered:
            handleDelivered(payload, senderPubkey: senderPubkey, convKey: convKey)
        case .readReceipt:
            handleReadReceipt(payload, senderPubkey: senderPubkey, convKey: convKey)
        
        // Explicitly list other cases so we get compile-time check if a new case is added in the future
        case .verifyChallenge, .verifyResponse:
            break
        }
    }

    @MainActor
    func sendGeohash(context: GeoOutgoingContext) {
        let ch = context.channel
        let event = context.event
        let identity = context.identity

        let targetRelays = GeoRelayDirectory.shared.closestRelays(
            toGeohash: ch.geohash,
            count: TransportConfig.nostrGeoRelayCount
        )

        if targetRelays.isEmpty {
            SecureLogger.warning("Geo: no geohash relays available for \(ch.geohash); not sending", category: .session)
        } else {
            NostrRelayManager.shared.sendEvent(event, to: targetRelays)
        }

        // Track ourselves as active participant
        participantTracker.recordParticipant(pubkeyHex: identity.publicKeyHex)
        nostrKeyMapping[PeerID(nostr: identity.publicKeyHex)] = identity.publicKeyHex
        SecureLogger.debug("GeoTeleport: sent geo message pub=\(identity.publicKeyHex.prefix(8))… teleported=\(context.teleported)", category: .session)

        // If we tagged this as teleported, also mark our pubkey in teleportedGeo for UI
        // Only when not in our regional set (and regional list is known)
        let hasRegional = !LocationChannelManager.shared.availableChannels.isEmpty
        let inRegional = LocationChannelManager.shared.availableChannels.contains { $0.geohash == ch.geohash }

        if context.teleported && hasRegional && !inRegional {
            let key = identity.publicKeyHex.lowercased()
            teleportedGeo = teleportedGeo.union([key])
            SecureLogger.info("GeoTeleport: mark self teleported key=\(key.prefix(8))… total=\(teleportedGeo.count)", category: .session)
        }

        deduplicationService.recordNostrEvent(event.id)
    }

    // MARK: - Sampling

    /// Begin sampling multiple geohashes (used by channel sheet) without changing active channel.
    @MainActor
    func beginGeohashSampling(for geohashes: [String]) {
        // Disable sampling when app is backgrounded (Tor is stopped there)
        if !TorManager.shared.isForeground() {
            endGeohashSampling()
            return
        }
        // Determine which to add and which to remove
        let desired = Set(geohashes)
        let current = Set(geoSamplingSubs.values)
        let toAdd = desired.subtracting(current)
        let toRemove = current.subtracting(desired)

        for (subID, gh) in geoSamplingSubs where toRemove.contains(gh) {
            NostrRelayManager.shared.unsubscribe(id: subID)
            geoSamplingSubs.removeValue(forKey: subID)
        }

        for gh in toAdd {
            subscribe(gh)
        }
    }
    
    @MainActor
    func subscribe(_ gh: String) {
        let subID = "geo-sample-\(gh)"
        geoSamplingSubs[subID] = gh
        let filter = NostrFilter.geohashEphemeral(
            gh,
            since: Date().addingTimeInterval(-TransportConfig.nostrGeohashSampleLookbackSeconds),
            limit: TransportConfig.nostrGeohashSampleLimit
        )
        let subRelays = GeoRelayDirectory.shared.closestRelays(toGeohash: gh, count: 5)
        NostrRelayManager.shared.subscribe(filter: filter, id: subID, relayUrls: subRelays) { [weak self] event in
            self?.subscribeNostrEvent(event, gh: gh)
        }
    }
    
    func subscribeNostrEvent(_ event: NostrEvent, gh: String) {
        guard event.isValidSignature() else { return }
        guard (event.kind == NostrProtocol.EventKind.ephemeralEvent.rawValue ||
               event.kind == NostrProtocol.EventKind.geohashPresence.rawValue) else { return }

        // Compute current participant count (5-minute window) BEFORE updating with this event
        let existingCount = participantTracker.participantCount(for: gh)

        // Update participants for this specific geohash
        participantTracker.recordParticipant(pubkeyHex: event.pubkey, geohash: gh)
        
        // Notify only on rising-edge: previously zero people, now someone sends a chat
        let content = event.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        
        // Respect geohash blocks
        if identityManager.isNostrBlocked(pubkeyHexLowercased: event.pubkey.lowercased()) { return }
        
        // Skip self identity for this geohash
        if let my = try? idBridge.deriveIdentity(forGeohash: gh), my.publicKeyHex.lowercased() == event.pubkey.lowercased() { return }
        
        // Only trigger when there were zero participants in this geohash recently
        guard existingCount == 0 else { return }
        
        // Avoid notifications for old sampled events when launching or (re)subscribing
        let eventTime = Date(timeIntervalSince1970: TimeInterval(event.created_at))
        if Date().timeIntervalSince(eventTime) > 30 { return }
        
        // Foreground-only notifications: app must be active, and not already viewing this geohash
        #if os(iOS)
        guard UIApplication.shared.applicationState == .active else { return }
        if case .location(let ch) = activeChannel, ch.geohash == gh { return }
        #elseif os(macOS)
        guard NSApplication.shared.isActive else { return }
        if case .location(let ch) = activeChannel, ch.geohash == gh { return }
        #endif
        
        cooldownPerGeohash(gh, content: content, event: event)
    }
    
    func cooldownPerGeohash(_ gh: String, content: String, event: NostrEvent) {
        let now = Date()
        let last = lastGeoNotificationAt[gh] ?? .distantPast
        if now.timeIntervalSince(last) < TransportConfig.uiGeoNotifyCooldownSeconds { return }
        
        // Compose a short preview
        let preview: String = {
            let maxLen = TransportConfig.uiGeoNotifySnippetMaxLen
            if content.count <= maxLen { return content }
            let idx = content.index(content.startIndex, offsetBy: maxLen)
            return String(content[..<idx]) + "…"
        }()

        Task { @MainActor in
            lastGeoNotificationAt[gh] = now
            // Pre-populate the target geohash timeline so the triggering message appears when user opens it
            let senderSuffix = String(event.pubkey.suffix(4))
            let nick = geoNicknames[event.pubkey.lowercased()]
            let senderName = (nick?.isEmpty == false ? nick! : "anon") + "#" + senderSuffix
            
            // Clamp future timestamps
            let rawTs = Date(timeIntervalSince1970: TimeInterval(event.created_at))
            let ts = min(rawTs, Date())
            let mentions = self.parseMentions(from: content)
            let msg = BitchatMessage(
                id: event.id,
                sender: senderName,
                content: content,
                timestamp: ts,
                isRelay: false,
                senderPeerID: PeerID(nostr: event.pubkey),
                mentions: mentions.isEmpty ? nil : mentions
            )
            if timelineStore.appendIfAbsent(msg, toGeohash: gh) {
                NotificationService.shared.sendGeohashActivityNotification(geohash: gh, bodyPreview: preview)
            }
        }
    }

    /// Stop sampling all extra geohashes.
    @MainActor
    func endGeohashSampling() {
        for subID in geoSamplingSubs.keys { NostrRelayManager.shared.unsubscribe(id: subID) }
        geoSamplingSubs.removeAll()
    }

    // MARK: - Nostr DM Handling

    func setupNostrMessageHandling() {
        guard let currentIdentity = try? idBridge.getCurrentNostrIdentity() else {
            SecureLogger.warning("⚠️ No Nostr identity available for message handling", category: .session)
            return
        }
        
        SecureLogger.debug("🔑 Setting up Nostr subscription for pubkey: \(currentIdentity.publicKeyHex.prefix(16))...", category: .session)
        
        // Subscribe to Nostr messages
        let filter = NostrFilter.giftWrapsFor(
            pubkey: currentIdentity.publicKeyHex,
            since: Date().addingTimeInterval(-TransportConfig.nostrDMSubscribeLookbackSeconds)  // Last 24 hours
        )
        
        nostrRelayManager?.subscribe(filter: filter, id: "chat-messages") { [weak self] event in
            self?.handleNostrMessage(event)
        }
    }
    
    func handleNostrMessage(_ giftWrap: NostrEvent) {
        // Deduplicate messages by ID
        if deduplicationService.hasProcessedNostrEvent(giftWrap.id) { return }
        deduplicationService.recordNostrEvent(giftWrap.id)
        
        // Ensure we're on a background queue for decryption
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.processNostrMessage(giftWrap)
        }
    }
    
    func processNostrMessage(_ giftWrap: NostrEvent) async {
        guard giftWrap.isValidSignature() else { return }
        guard let currentIdentity = try? idBridge.getCurrentNostrIdentity() else { return }
        
        do {
            let (content, senderPubkey, rumorTimestamp) = try NostrProtocol.decryptPrivateMessage(
                giftWrap: giftWrap,
                recipientIdentity: currentIdentity
            )
            
            // Handle verification payloads first
            if content.hasPrefix("verify:") {
                // Ignore verification payloads arriving via Nostr path for now
                // Verification should ideally happen over mesh for security binding
                return
            }
            
            // Check if it's a BitChat packet embedded in the content (bitchat1:...)
            if content.hasPrefix("bitchat1:") {
                guard let packet = Self.decodeEmbeddedBitChatPacket(from: content) else {
                    SecureLogger.error("Failed to decode embedded BitChat packet from Nostr DM", category: .session)
                    return
                }
                
                // Map sender by Nostr pubkey to Noise key when possible
                let actualSenderNoiseKey = findNoiseKey(for: senderPubkey)
                
                // Stable target ID if we know Noise key; otherwise temporary Nostr-based peer
                let targetPeerID = PeerID(str: actualSenderNoiseKey?.hexEncodedString()) ?? PeerID(nostr_: senderPubkey)
                
                if packet.type == MessageType.noiseEncrypted.rawValue,
                   let payload = NoisePayload.decode(packet.payload) {
                    let messageTimestamp = Date(timeIntervalSince1970: TimeInterval(rumorTimestamp))
                    // Store Nostr mapping
                    await MainActor.run {
                        nostrKeyMapping[targetPeerID] = senderPubkey
                        
                        // Handle packet types
                        switch payload.type {
                        case .privateMessage:
                            handlePrivateMessage(payload, senderPubkey: senderPubkey, convKey: targetPeerID, id: currentIdentity, messageTimestamp: messageTimestamp)
                        case .delivered:
                            handleDelivered(payload, senderPubkey: senderPubkey, convKey: targetPeerID)
                        case .readReceipt:
                            handleReadReceipt(payload, senderPubkey: senderPubkey, convKey: targetPeerID)
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

    func findNoiseKey(for nostrPubkey: String) -> Data? {
        // Check favorites for this Nostr key
        let favorites = FavoritesPersistenceService.shared.favorites.values
        var npubToMatch = nostrPubkey
        
        // Convert hex to npub if needed for comparison
        if !nostrPubkey.hasPrefix("npub") {
            if let pubkeyData = Data(hexString: nostrPubkey),
               let encoded = try? Bech32.encode(hrp: "npub", data: pubkeyData) {
                npubToMatch = encoded
            } else {
                SecureLogger.warning("⚠️ Invalid hex public key format or encoding failed: \(nostrPubkey.prefix(16))...", category: .session)
            }
        }
        
        for relationship in favorites {
            // Search through favorites for matching Nostr pubkey
            if let storedNostrKey = relationship.peerNostrPublicKey {
                // Compare against stored key (could be hex or npub)
                if storedNostrKey == npubToMatch {
                    // SecureLogger.debug("✅ Found Noise key for Nostr sender (npub match)", category: .session)
                    return relationship.peerNoisePublicKey
                }
                
                // Also try comparing raw hex if stored key is hex
                if !storedNostrKey.hasPrefix("npub") && storedNostrKey == nostrPubkey {
                    SecureLogger.debug("✅ Found Noise key for Nostr sender (hex match)", category: .session)
                    return relationship.peerNoisePublicKey
                }
            }
        }
        
        SecureLogger.debug("⚠️ No matching Noise key found for Nostr pubkey: \(nostrPubkey.prefix(16))... (tried npub: \(npubToMatch.prefix(16))...)", category: .session)
        return nil
    }

    func sendDeliveryAckViaNostrEmbedded(_ message: BitchatMessage, wasReadBefore: Bool, senderPubkey: String, key: Data?) {
        // If we have a Noise key, try to route securely if possible, otherwise fallback to direct
        if let _ = key {
             // Ideally we would use MessageRouter here, but for simplicity in this direct callback:
             // check if we have an identity
             if let id = try? idBridge.getCurrentNostrIdentity() {
                 let nt = NostrTransport(keychain: keychain, idBridge: idBridge)
                 nt.senderPeerID = meshService.myPeerID
                 nt.sendDeliveryAckGeohash(for: message.id, toRecipientHex: senderPubkey, from: id)
             }
        } else if let id = try? idBridge.getCurrentNostrIdentity() {
            // Fallback: no Noise mapping yet — send directly to sender's Nostr pubkey
            let nt = NostrTransport(keychain: keychain, idBridge: idBridge)
            nt.senderPeerID = meshService.myPeerID
            nt.sendDeliveryAckGeohash(for: message.id, toRecipientHex: senderPubkey, from: id)
            SecureLogger.debug("Sent DELIVERED ack directly to Nostr pub=\(senderPubkey.prefix(8))… for mid=\(message.id.prefix(8))…", category: .session)
        }
        
        // Same for READ receipt if viewing
        if !wasReadBefore && selectedPrivateChatPeer == message.senderPeerID {
             if let _ = key {
                 if let id = try? idBridge.getCurrentNostrIdentity() {
                     let nt = NostrTransport(keychain: keychain, idBridge: idBridge)
                     nt.senderPeerID = meshService.myPeerID
                     nt.sendReadReceiptGeohash(message.id, toRecipientHex: senderPubkey, from: id)
                 }
             } else if let id = try? idBridge.getCurrentNostrIdentity() {
                 let nt = NostrTransport(keychain: keychain, idBridge: idBridge)
                 nt.senderPeerID = meshService.myPeerID
                 nt.sendReadReceiptGeohash(message.id, toRecipientHex: senderPubkey, from: id)
                 SecureLogger.debug("Viewing chat; sent READ ack directly to Nostr pub=\(senderPubkey.prefix(8))… for mid=\(message.id.prefix(8))…", category: .session)
             }
        }
    }

    func handleFavoriteNotification(content: String, from nostrPubkey: String) {
        // Try to find Noise key associated with this Nostr pubkey
        guard let senderNoiseKey = findNoiseKey(for: nostrPubkey) else { return }
        
        let isFavorite = content.contains("FAVORITE:TRUE")
        let senderNickname = content.components(separatedBy: "|").last ?? "Unknown"
        
        // Update favorite status
        if isFavorite {
            FavoritesPersistenceService.shared.addFavorite(
                peerNoisePublicKey: senderNoiseKey,
                peerNostrPublicKey: nostrPubkey,
                peerNickname: senderNickname
            )
        } else {
            // Only remove if we don't have it set locally
            // Logic handled by persistence service usually, here we just update remote state
            // Actually for now we just process the notification
        }
        
        // Extract Nostr public key if included
        var extractedNostrPubkey: String? = nil
        if let range = content.range(of: "NPUB:") {
            let suffix = content[range.upperBound...]
            let parts = suffix.components(separatedBy: "|")
            if let key = parts.first {
                extractedNostrPubkey = String(key)
            }
        } else if content.contains(":") {
             // Fallback: simple format FAVORITE:TRUE:npub...
             let parts = content.components(separatedBy: ":")
             if parts.count >= 3 {
                 extractedNostrPubkey = String(parts[2])
             }
        }
        
        SecureLogger.info("📝 Received favorite notification from \(senderNickname): \(isFavorite)", category: .session)
        
        // If they favorited us and provided their Nostr key, ensure it's stored
        if isFavorite && extractedNostrPubkey != nil {
            SecureLogger.info("💾 Storing Nostr key association for \(senderNickname): \(extractedNostrPubkey!.prefix(16))...", category: .session)
             FavoritesPersistenceService.shared.addFavorite(
                peerNoisePublicKey: senderNoiseKey,
                peerNostrPublicKey: extractedNostrPubkey,
                peerNickname: senderNickname
            )
        }
        
        // Show notification
        NotificationService.shared.sendLocalNotification(
            title: isFavorite ? "New Favorite" : "Favorite Removed",
            body: "\(senderNickname) \(isFavorite ? "favorited" : "unfavorited") you",
            identifier: "fav-\(UUID().uuidString)"
        )
    }

    func sendFavoriteNotificationViaNostr(noisePublicKey: Data, isFavorite: Bool) {
        // Find peer Nostr key
        guard let relationship = FavoritesPersistenceService.shared.getFavoriteStatus(for: noisePublicKey),
              relationship.peerNostrPublicKey != nil else {
            SecureLogger.warning("⚠️ Cannot send favorite notification - no Nostr key for peer", category: .session)
            return
        }
        
        let peerID = PeerID(hexData: noisePublicKey)
        
        // Route via message router
        messageRouter.sendFavoriteNotification(to: peerID, isFavorite: isFavorite)
    }

    private static func decodeEmbeddedBitChatPacket(from content: String) -> BitchatPacket? {
        guard content.hasPrefix("bitchat1:") else { return nil }
        let encoded = String(content.dropFirst("bitchat1:".count))
        let maxBytes = FileTransferLimits.maxFramedFileBytes
        // Base64url length upper bound for maxBytes (padded length; unpadded is <= this).
        let maxEncoded = ((maxBytes + 2) / 3) * 4
        guard encoded.count <= maxEncoded else { return nil }
        guard let packetData = Self.base64URLDecode(encoded),
              packetData.count <= maxBytes
        else { return nil }
        return BitchatPacket.from(packetData)
    }

    // MARK: - Geohash Nickname Resolution (for /block in geohash)

    func nostrPubkeyForDisplayName(_ name: String) -> String? {
        // Look up current visible geohash participants for an exact displayName match
        for p in visibleGeohashPeople() {
            if p.displayName == name {
                return p.id
            }
        }
        // Also check nickname cache directly
        for (pub, nick) in geoNicknames {
            if nick == name { return pub }
        }
        return nil
    }
    
    func startGeohashDM(withPubkeyHex hex: String) {
        let convKey = PeerID(nostr_: hex)
        nostrKeyMapping[convKey] = hex
        startPrivateChat(with: convKey)
    }
    
    func fullNostrHex(forSenderPeerID senderID: PeerID) -> String? {
        return nostrKeyMapping[senderID]
    }
    
    func geohashDisplayName(for convKey: PeerID) -> String {
        guard let full = nostrKeyMapping[convKey] else {
            return convKey.bare
        }
        return displayNameForNostrPubkey(full)
    }
}
