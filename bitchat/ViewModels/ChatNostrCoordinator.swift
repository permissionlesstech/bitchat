import BitFoundation
import BitLogger
import Foundation
import SwiftUI
import Tor

/// The narrow surface `ChatNostrCoordinator` needs from its owner.
///
/// Follows the `ChatDeliveryContext` exemplar: the coordinator depends on the
/// minimal context it actually uses instead of holding a back-reference to the
/// whole `ChatViewModel`. This keeps the coordinator independently testable
/// (see `ChatNostrCoordinatorContextTests`) and makes its true dependencies
/// explicit. The surface is intentionally large — it documents the
/// coordinator's real coupling to channel/subscription state, the inbound
/// Nostr event pipeline, geohash presence, and the ack transports.
@MainActor
protocol ChatNostrContext: AnyObject {
    // MARK: Channel & subscription state
    var activeChannel: ChannelID { get set }
    var currentGeohash: String? { get set }
    var geoSubscriptionID: String? { get set }
    var geoDmSubscriptionID: String? { get set }
    /// Geohash sampling subscriptions: subscription ID -> geohash.
    var geoSamplingSubs: [String: String] { get set }
    /// Per-geohash notification cooldown: geohash -> last notify time.
    var lastGeoNotificationAt: [String: Date] { get set }
    var nostrRelayManager: NostrRelayManager? { get }

    // MARK: Public timeline & pipeline
    var messages: [BitchatMessage] { get }
    func resetPublicMessagePipeline()
    func updatePublicMessagePipelineChannel(_ channel: ChannelID)
    func refreshVisibleMessages(from channel: ChannelID?)
    func addPublicSystemMessage(_ content: String)
    func drainPendingGeohashSystemMessages() -> [String]
    func appendGeohashMessageIfAbsent(_ message: BitchatMessage, toGeohash geohash: String) -> Bool
    func synchronizePublicConversationStore(forGeohash geohash: String)

    // MARK: Inbound public messages
    func handlePublicMessage(_ message: BitchatMessage)
    func checkForMentions(_ message: BitchatMessage)
    func sendHapticFeedback(for message: BitchatMessage)
    func parseMentions(from content: String) -> [String]

    // MARK: Inbound private (geohash DM) payloads
    var selectedPrivateChatPeer: PeerID? { get }
    var nostrKeyMapping: [PeerID: String] { get set }
    func handlePrivateMessage(
        _ payload: NoisePayload,
        senderPubkey: String,
        convKey: PeerID,
        id: NostrIdentity,
        messageTimestamp: Date
    )
    func handleDelivered(_ payload: NoisePayload, senderPubkey: String, convKey: PeerID)
    func handleReadReceipt(_ payload: NoisePayload, senderPubkey: String, convKey: PeerID)
    func startPrivateChat(with peerID: PeerID)

    // MARK: Nostr identity & blocking (shared with `ChatPrivateConversationContext`)
    func deriveNostrIdentity(forGeohash geohash: String) throws -> NostrIdentity
    func currentNostrIdentity() -> NostrIdentity?
    func isNostrBlocked(pubkeyHexLowercased: String) -> Bool
    func displayNameForNostrPubkey(_ pubkeyHex: String) -> String

    // MARK: Event dedup
    func hasProcessedNostrEvent(_ eventID: String) -> Bool
    func recordProcessedNostrEvent(_ eventID: String)
    func clearProcessedNostrEvents()

    // MARK: Geo participants & presence
    var geoNicknames: [String: String] { get }
    var teleportedGeoCount: Int { get }
    func startGeoParticipantRefreshTimer()
    func stopGeoParticipantRefreshTimer()
    func setActiveParticipantGeohash(_ geohash: String?)
    func recordGeoParticipant(pubkeyHex: String)
    func recordGeoParticipant(pubkeyHex: String, geohash: String)
    func geoParticipantCount(for geohash: String) -> Int
    func setGeoNickname(_ nickname: String, forPubkey pubkeyHex: String)
    func markGeoTeleported(_ pubkeyHexLowercased: String)
    func clearGeoTeleported(_ pubkeyHexLowercased: String)
    func clearTeleportedGeo()
    func clearGeoNicknames()
    func visibleGeohashPeople() -> [GeoPerson]

    // MARK: Location channels
    var isTeleported: Bool { get }
    /// True when regional channels are known and the geohash is not one of them.
    func isGeohashOutsideRegionalChannels(_ geohash: String) -> Bool

    // MARK: Routing & acknowledgements (shared with `ChatPrivateConversationContext`)
    func routeFavoriteNotification(to peerID: PeerID, isFavorite: Bool)
    func sendGeohashDeliveryAck(for messageID: String, toRecipientHex recipientHex: String, from identity: NostrIdentity)
    func sendGeohashReadReceipt(_ messageID: String, toRecipientHex recipientHex: String, from identity: NostrIdentity)
}

extension ChatViewModel: ChatNostrContext {
    // `activeChannel`, `selectedPrivateChatPeer`, `nostrKeyMapping`,
    // `messages`, `geoNicknames`, the Nostr identity/blocking members, and the
    // routing/ack members are shared requirements with `ChatDeliveryContext` /
    // `ChatPrivateConversationContext`; their witnesses already exist. The
    // members below flatten nested service accesses into intent-named calls.

    func resetPublicMessagePipeline() {
        publicMessagePipeline.reset()
    }

    func updatePublicMessagePipelineChannel(_ channel: ChannelID) {
        publicMessagePipeline.updateActiveChannel(channel)
    }

    func drainPendingGeohashSystemMessages() -> [String] {
        timelineStore.drainPendingGeohashSystemMessages()
    }

    func appendGeohashMessageIfAbsent(_ message: BitchatMessage, toGeohash geohash: String) -> Bool {
        timelineStore.appendIfAbsent(message, toGeohash: geohash)
    }

    func hasProcessedNostrEvent(_ eventID: String) -> Bool {
        deduplicationService.hasProcessedNostrEvent(eventID)
    }

    func recordProcessedNostrEvent(_ eventID: String) {
        deduplicationService.recordNostrEvent(eventID)
    }

    func clearProcessedNostrEvents() {
        deduplicationService.clearNostrCaches()
    }

    var teleportedGeoCount: Int {
        locationPresenceStore.teleportedGeo.count
    }

    func startGeoParticipantRefreshTimer() {
        participantTracker.startRefreshTimer()
    }

    func stopGeoParticipantRefreshTimer() {
        participantTracker.stopRefreshTimer()
    }

    func setActiveParticipantGeohash(_ geohash: String?) {
        participantTracker.setActiveGeohash(geohash)
    }

    func recordGeoParticipant(pubkeyHex: String) {
        participantTracker.recordParticipant(pubkeyHex: pubkeyHex)
    }

    func recordGeoParticipant(pubkeyHex: String, geohash: String) {
        participantTracker.recordParticipant(pubkeyHex: pubkeyHex, geohash: geohash)
    }

    func geoParticipantCount(for geohash: String) -> Int {
        participantTracker.participantCount(for: geohash)
    }

    func setGeoNickname(_ nickname: String, forPubkey pubkeyHex: String) {
        locationPresenceStore.setNickname(nickname, for: pubkeyHex)
    }

    func markGeoTeleported(_ pubkeyHexLowercased: String) {
        locationPresenceStore.markTeleported(pubkeyHexLowercased)
    }

    func clearGeoTeleported(_ pubkeyHexLowercased: String) {
        locationPresenceStore.clearTeleported(pubkeyHexLowercased)
    }

    func clearTeleportedGeo() {
        locationPresenceStore.clearTeleportedGeo()
    }

    func clearGeoNicknames() {
        locationPresenceStore.clearGeoNicknames()
    }

    var isTeleported: Bool {
        locationManager.teleported
    }

    func isGeohashOutsideRegionalChannels(_ geohash: String) -> Bool {
        let channels = locationManager.availableChannels
        return !channels.isEmpty && !channels.contains { $0.geohash == geohash }
    }
}

final class ChatNostrCoordinator {
    private weak var context: (any ChatNostrContext)?
    private var recentGeoSamplingEventIDs = Set<String>()
    private var recentGeoSamplingEventIDOrder: [String] = []

    init(context: any ChatNostrContext) {
        self.context = context
    }

    @MainActor
    func resubscribeCurrentGeohash() {
        guard let context else { return }
        guard case .location(let channel) = context.activeChannel else { return }
        guard let subID = context.geoSubscriptionID else {
            switchLocationChannel(to: context.activeChannel)
            return
        }

        context.startGeoParticipantRefreshTimer()
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

        if let dmSub = context.geoDmSubscriptionID {
            NostrRelayManager.shared.unsubscribe(id: dmSub)
            context.geoDmSubscriptionID = nil
        }

        if let identity = try? context.deriveNostrIdentity(forGeohash: channel.geohash) {
            let dmSub = "geo-dm-\(channel.geohash)"
            context.geoDmSubscriptionID = dmSub
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
        guard let context else { return }
        guard event.isValidSignature() else { return }
        guard (event.kind == NostrProtocol.EventKind.ephemeralEvent.rawValue
            || event.kind == NostrProtocol.EventKind.geohashPresence.rawValue),
              !context.hasProcessedNostrEvent(event.id)
        else {
            return
        }

        context.recordProcessedNostrEvent(event.id)

        if let gh = context.currentGeohash,
           let myGeoIdentity = try? context.deriveNostrIdentity(forGeohash: gh),
           myGeoIdentity.publicKeyHex.lowercased() == event.pubkey.lowercased() {
            let eventTime = Date(timeIntervalSince1970: TimeInterval(event.created_at))
            if Date().timeIntervalSince(eventTime) < 15 {
                return
            }
        }

        if let nickTag = event.tags.first(where: { $0.first == "n" }), nickTag.count >= 2 {
            let nick = nickTag[1].trimmed
            context.setGeoNickname(nick, forPubkey: event.pubkey)
        }

        context.nostrKeyMapping[PeerID(nostr_: event.pubkey)] = event.pubkey
        context.nostrKeyMapping[PeerID(nostr: event.pubkey)] = event.pubkey
        context.recordGeoParticipant(pubkeyHex: event.pubkey)

        if event.kind == NostrProtocol.EventKind.geohashPresence.rawValue {
            return
        }

        let hasTeleportTag = event.tags.contains { tag in
            tag.count >= 2 && tag[0].lowercased() == "t" && tag[1].lowercased() == "teleport"
        }

        if hasTeleportTag {
            let key = event.pubkey.lowercased()
            let isSelf: Bool = {
                if let gh = context.currentGeohash,
                   let myIdentity = try? context.deriveNostrIdentity(forGeohash: gh) {
                    return myIdentity.publicKeyHex.lowercased() == key
                }
                return false
            }()
            if !isSelf {
                Task { @MainActor [weak context] in
                    context?.markGeoTeleported(key)
                }
            }
        }

        let senderName = context.displayNameForNostrPubkey(event.pubkey)
        let content = event.content.trimmed
        let rawTs = Date(timeIntervalSince1970: TimeInterval(event.created_at))
        let timestamp = min(rawTs, Date())
        let mentions = context.parseMentions(from: content)
        let message = BitchatMessage(
            id: event.id,
            sender: senderName,
            content: content,
            timestamp: timestamp,
            isRelay: false,
            senderPeerID: PeerID(nostr: event.pubkey),
            mentions: mentions.isEmpty ? nil : mentions
        )

        Task { @MainActor [weak context] in
            guard let context else { return }
            let isBlocked = context.isNostrBlocked(pubkeyHexLowercased: event.pubkey.lowercased())
            context.handlePublicMessage(message)
            if !isBlocked {
                context.checkForMentions(message)
                context.sendHapticFeedback(for: message)
            }
        }
    }

    @MainActor
    func subscribeGiftWrap(_ giftWrap: NostrEvent, id: NostrIdentity) {
        guard let context else { return }
        guard giftWrap.isValidSignature() else { return }
        guard !context.hasProcessedNostrEvent(giftWrap.id) else { return }
        context.recordProcessedNostrEvent(giftWrap.id)

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
        context.nostrKeyMapping[convKey] = senderPubkey

        switch noisePayload.type {
        case .privateMessage:
            context.handlePrivateMessage(
                noisePayload,
                senderPubkey: senderPubkey,
                convKey: convKey,
                id: id,
                messageTimestamp: messageTimestamp
            )
        case .delivered:
            context.handleDelivered(noisePayload, senderPubkey: senderPubkey, convKey: convKey)
        case .readReceipt:
            context.handleReadReceipt(noisePayload, senderPubkey: senderPubkey, convKey: convKey)
        case .verifyChallenge, .verifyResponse:
            break
        }
    }

    @MainActor
    func switchLocationChannel(to channel: ChannelID) {
        guard let context else { return }
        context.resetPublicMessagePipeline()
        context.activeChannel = channel
        context.updatePublicMessagePipelineChannel(channel)

        context.clearProcessedNostrEvents()
        switch channel {
        case .mesh:
            context.refreshVisibleMessages(from: .mesh)
            let emptyMesh = context.messages.filter { $0.content.trimmed.isEmpty }.count
            if emptyMesh > 0 {
                SecureLogger.debug("RenderGuard: mesh timeline contains \(emptyMesh) empty messages", category: .session)
            }
            context.stopGeoParticipantRefreshTimer()
            context.setActiveParticipantGeohash(nil)
            context.clearTeleportedGeo()

        case .location:
            context.refreshVisibleMessages(from: channel)
        }

        if case .location = channel {
            for content in context.drainPendingGeohashSystemMessages() {
                context.addPublicSystemMessage(content)
            }
        }

        if let sub = context.geoSubscriptionID {
            NostrRelayManager.shared.unsubscribe(id: sub)
            context.geoSubscriptionID = nil
        }
        if let dmSub = context.geoDmSubscriptionID {
            NostrRelayManager.shared.unsubscribe(id: dmSub)
            context.geoDmSubscriptionID = nil
        }
        context.currentGeohash = nil
        context.setActiveParticipantGeohash(nil)
        context.clearGeoNicknames()

        guard case .location(let channel) = channel else { return }
        context.currentGeohash = channel.geohash
        context.setActiveParticipantGeohash(channel.geohash)

        if let identity = try? context.deriveNostrIdentity(forGeohash: channel.geohash) {
            context.recordGeoParticipant(pubkeyHex: identity.publicKeyHex)
            let key = identity.publicKeyHex.lowercased()
            if context.isTeleported && context.isGeohashOutsideRegionalChannels(channel.geohash) {
                context.markGeoTeleported(key)
                SecureLogger.info(
                    "GeoTeleport: channel switch mark self teleported key=\(key.prefix(8))… total=\(context.teleportedGeoCount)",
                    category: .session
                )
            } else {
                context.clearGeoTeleported(key)
            }
        }

        let subID = "geo-\(channel.geohash)"
        context.geoSubscriptionID = subID
        context.startGeoParticipantRefreshTimer()
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
        guard let context else { return }
        guard event.isValidSignature() else { return }
        guard (event.kind == NostrProtocol.EventKind.ephemeralEvent.rawValue
            || event.kind == NostrProtocol.EventKind.geohashPresence.rawValue)
        else {
            return
        }

        if context.hasProcessedNostrEvent(event.id) { return }
        context.recordProcessedNostrEvent(event.id)

        SecureLogger.debug(
            "GeoTeleport: recv pub=\(event.pubkey.prefix(8))… tagCount=\(event.tags.count)",
            category: .session
        )

        if context.isNostrBlocked(pubkeyHexLowercased: event.pubkey) {
            return
        }

        let hasTeleportTag = event.tags.contains { tag in
            tag.count >= 2 && tag[0].lowercased() == "t" && tag[1].lowercased() == "teleport"
        }

        let isSelf: Bool = {
            if let gh = context.currentGeohash,
               let my = try? context.deriveNostrIdentity(forGeohash: gh) {
                return my.publicKeyHex.lowercased() == event.pubkey.lowercased()
            }
            return false
        }()

        if hasTeleportTag, !isSelf {
            let key = event.pubkey.lowercased()
            Task { @MainActor [weak context] in
                guard let context else { return }
                context.markGeoTeleported(key)
                SecureLogger.info(
                    "GeoTeleport: mark peer teleported key=\(key.prefix(8))… total=\(context.teleportedGeoCount)",
                    category: .session
                )
            }
        }

        context.recordGeoParticipant(pubkeyHex: event.pubkey)

        if isSelf {
            let eventTime = Date(timeIntervalSince1970: TimeInterval(event.created_at))
            if Date().timeIntervalSince(eventTime) < 15 {
                return
            }
        }

        if let nickTag = event.tags.first(where: { $0.first == "n" }), nickTag.count >= 2 {
            context.setGeoNickname(nickTag[1].trimmed, forPubkey: event.pubkey)
        }

        context.nostrKeyMapping[PeerID(nostr_: event.pubkey)] = event.pubkey
        context.nostrKeyMapping[PeerID(nostr: event.pubkey)] = event.pubkey

        if event.kind == NostrProtocol.EventKind.geohashPresence.rawValue {
            return
        }

        let senderName = context.displayNameForNostrPubkey(event.pubkey)
        let content = event.content

        if let teleTag = event.tags.first(where: { $0.first == "t" }),
           teleTag.count >= 2,
           teleTag[1] == "teleport",
           content.trimmed.isEmpty {
            return
        }

        let rawTs = Date(timeIntervalSince1970: TimeInterval(event.created_at))
        let mentions = context.parseMentions(from: content)
        let message = BitchatMessage(
            id: event.id,
            sender: senderName,
            content: content,
            timestamp: min(rawTs, Date()),
            isRelay: false,
            senderPeerID: PeerID(nostr: event.pubkey),
            mentions: mentions.isEmpty ? nil : mentions
        )

        Task { @MainActor [weak context] in
            guard let context else { return }
            context.handlePublicMessage(message)
            context.checkForMentions(message)
            context.sendHapticFeedback(for: message)
        }
    }

    @MainActor
    func subscribeToGeoChat(_ channel: GeohashChannel) {
        guard let context else { return }
        guard let identity = try? context.deriveNostrIdentity(forGeohash: channel.geohash) else { return }

        let dmSub = "geo-dm-\(channel.geohash)"
        context.geoDmSubscriptionID = dmSub
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
        guard let context else { return }
        guard giftWrap.isValidSignature() else { return }
        if context.hasProcessedNostrEvent(giftWrap.id) {
            return
        }
        context.recordProcessedNostrEvent(giftWrap.id)

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
        context.nostrKeyMapping[convKey] = senderPubkey

        switch payload.type {
        case .privateMessage:
            let messageTimestamp = Date(timeIntervalSince1970: TimeInterval(rumorTs))
            context.handlePrivateMessage(
                payload,
                senderPubkey: senderPubkey,
                convKey: convKey,
                id: id,
                messageTimestamp: messageTimestamp
            )
        case .delivered:
            context.handleDelivered(payload, senderPubkey: senderPubkey, convKey: convKey)
        case .readReceipt:
            context.handleReadReceipt(payload, senderPubkey: senderPubkey, convKey: convKey)
        case .verifyChallenge, .verifyResponse:
            break
        }
    }

    @MainActor
    func sendGeohash(context geoContext: ChatViewModel.GeoOutgoingContext) {
        guard let context else { return }
        let channel = geoContext.channel
        let event = geoContext.event
        let identity = geoContext.identity

        let targetRelays = GeoRelayDirectory.shared.closestRelays(
            toGeohash: channel.geohash,
            count: TransportConfig.nostrGeoRelayCount
        )

        if targetRelays.isEmpty {
            SecureLogger.warning("Geo: no geohash relays available for \(channel.geohash); not sending", category: .session)
        } else {
            NostrRelayManager.shared.sendEvent(event, to: targetRelays)
        }

        context.recordGeoParticipant(pubkeyHex: identity.publicKeyHex)
        context.nostrKeyMapping[PeerID(nostr: identity.publicKeyHex)] = identity.publicKeyHex
        SecureLogger.debug(
            "GeoTeleport: sent geo message pub=\(identity.publicKeyHex.prefix(8))… teleported=\(geoContext.teleported)",
            category: .session
        )

        if geoContext.teleported && context.isGeohashOutsideRegionalChannels(channel.geohash) {
            let key = identity.publicKeyHex.lowercased()
            context.markGeoTeleported(key)
            SecureLogger.info(
                "GeoTeleport: mark self teleported key=\(key.prefix(8))… total=\(context.teleportedGeoCount)",
                category: .session
            )
        }

        context.recordProcessedNostrEvent(event.id)
    }

    @MainActor
    func beginGeohashSampling(for geohashes: [String]) {
        guard let context else { return }
        if !TorManager.shared.isForeground() {
            endGeohashSampling()
            return
        }

        let desired = Set(geohashes)
        let current = Set(context.geoSamplingSubs.values)
        let toAdd = desired.subtracting(current)
        let toRemove = current.subtracting(desired)

        for (subID, gh) in context.geoSamplingSubs where toRemove.contains(gh) {
            NostrRelayManager.shared.unsubscribe(id: subID)
            context.geoSamplingSubs.removeValue(forKey: subID)
        }

        for gh in toAdd {
            subscribe(gh)
        }
    }

    @MainActor
    func subscribe(_ gh: String) {
        guard let context else { return }
        let subID = "geo-sample-\(gh)"
        context.geoSamplingSubs[subID] = gh
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
        guard let context else { return }
        guard (event.kind == NostrProtocol.EventKind.ephemeralEvent.rawValue
            || event.kind == NostrProtocol.EventKind.geohashPresence.rawValue)
        else {
            return
        }
        guard event.isValidSignature() else { return }
        guard shouldProcessGeoSamplingEvent(event.id) else { return }

        let existingCount = context.geoParticipantCount(for: gh)
        context.recordGeoParticipant(pubkeyHex: event.pubkey, geohash: gh)

        guard let content = event.content.trimmedOrNilIfEmpty else { return }
        if context.isNostrBlocked(pubkeyHexLowercased: event.pubkey.lowercased()) { return }
        if let my = try? context.deriveNostrIdentity(forGeohash: gh),
           my.publicKeyHex.lowercased() == event.pubkey.lowercased() {
            return
        }
        guard existingCount == 0 else { return }

        let eventTime = Date(timeIntervalSince1970: TimeInterval(event.created_at))
        if Date().timeIntervalSince(eventTime) > 30 { return }

        #if os(iOS)
        guard UIApplication.shared.applicationState == .active else { return }
        if case .location(let channel) = context.activeChannel, channel.geohash == gh { return }
        #elseif os(macOS)
        guard NSApplication.shared.isActive else { return }
        if case .location(let channel) = context.activeChannel, channel.geohash == gh { return }
        #endif

        cooldownPerGeohash(gh, content: content, event: event)
    }

    @MainActor
    func cooldownPerGeohash(_ gh: String, content: String, event: NostrEvent) {
        guard let context else { return }
        let now = Date()
        let last = context.lastGeoNotificationAt[gh] ?? .distantPast
        if now.timeIntervalSince(last) < TransportConfig.uiGeoNotifyCooldownSeconds { return }

        let preview: String = {
            let maxLen = TransportConfig.uiGeoNotifySnippetMaxLen
            if content.count <= maxLen { return content }
            let idx = content.index(content.startIndex, offsetBy: maxLen)
            return String(content[..<idx]) + "…"
        }()

        Task { @MainActor [weak context] in
            guard let context else { return }
            context.lastGeoNotificationAt[gh] = now
            let senderSuffix = String(event.pubkey.suffix(4))
            let nick = context.geoNicknames[event.pubkey.lowercased()]
            let senderName = (nick?.isEmpty == false ? nick! : "anon") + "#" + senderSuffix

            let rawTs = Date(timeIntervalSince1970: TimeInterval(event.created_at))
            let ts = min(rawTs, Date())
            let mentions = context.parseMentions(from: content)
            let message = BitchatMessage(
                id: event.id,
                sender: senderName,
                content: content,
                timestamp: ts,
                isRelay: false,
                senderPeerID: PeerID(nostr: event.pubkey),
                mentions: mentions.isEmpty ? nil : mentions
            )
            if context.appendGeohashMessageIfAbsent(message, toGeohash: gh) {
                context.synchronizePublicConversationStore(forGeohash: gh)
                NotificationService.shared.sendGeohashActivityNotification(geohash: gh, bodyPreview: preview)
            }
        }
    }

    @MainActor
    func endGeohashSampling() {
        guard let context else { return }
        for subID in context.geoSamplingSubs.keys {
            NostrRelayManager.shared.unsubscribe(id: subID)
        }
        context.geoSamplingSubs.removeAll()
        clearGeoSamplingEventDedup()
    }

    private func shouldProcessGeoSamplingEvent(_ eventID: String) -> Bool {
        guard !eventID.isEmpty else { return true }
        guard recentGeoSamplingEventIDs.insert(eventID).inserted else {
            return false
        }
        recentGeoSamplingEventIDOrder.append(eventID)

        let cap = TransportConfig.geoSamplingEventLRUCap
        if recentGeoSamplingEventIDOrder.count > cap {
            let removeCount = recentGeoSamplingEventIDOrder.count - cap
            for staleID in recentGeoSamplingEventIDOrder.prefix(removeCount) {
                recentGeoSamplingEventIDs.remove(staleID)
            }
            recentGeoSamplingEventIDOrder.removeFirst(removeCount)
        }
        return true
    }

    private func clearGeoSamplingEventDedup() {
        recentGeoSamplingEventIDs.removeAll()
        recentGeoSamplingEventIDOrder.removeAll()
    }

    @MainActor
    func setupNostrMessageHandling() {
        guard let context else { return }
        guard let currentIdentity = context.currentNostrIdentity() else {
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

        context.nostrRelayManager?.subscribe(filter: filter, id: "chat-messages") { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleNostrMessage(event)
            }
        }
    }

    @MainActor
    func handleNostrMessage(_ giftWrap: NostrEvent) {
        guard let context else { return }
        guard giftWrap.isValidSignature() else { return }
        if context.hasProcessedNostrEvent(giftWrap.id) { return }
        context.recordProcessedNostrEvent(giftWrap.id)

        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.processNostrMessage(giftWrap)
        }
    }

    func processNostrMessage(_ giftWrap: NostrEvent) async {
        guard giftWrap.isValidSignature() else { return }
        guard let context else { return }
        let currentIdentity: NostrIdentity? = await MainActor.run {
            context.currentNostrIdentity()
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
                        context.nostrKeyMapping[targetPeerID] = senderPubkey

                        switch payload.type {
                        case .privateMessage:
                            context.handlePrivateMessage(
                                payload,
                                senderPubkey: senderPubkey,
                                convKey: targetPeerID,
                                id: currentIdentity,
                                messageTimestamp: messageTimestamp
                            )
                        case .delivered:
                            context.handleDelivered(payload, senderPubkey: senderPubkey, convKey: targetPeerID)
                        case .readReceipt:
                            context.handleReadReceipt(payload, senderPubkey: senderPubkey, convKey: targetPeerID)
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
        guard let context else { return }
        if let _ = key {
            if let identity = context.currentNostrIdentity() {
                context.sendGeohashDeliveryAck(for: message.id, toRecipientHex: senderPubkey, from: identity)
            }
        } else if let identity = context.currentNostrIdentity() {
            context.sendGeohashDeliveryAck(for: message.id, toRecipientHex: senderPubkey, from: identity)
            SecureLogger.debug(
                "Sent DELIVERED ack directly to Nostr pub=\(senderPubkey.prefix(8))… for mid=\(message.id.prefix(8))…",
                category: .session
            )
        }

        if !wasReadBefore && context.selectedPrivateChatPeer == message.senderPeerID {
            if let _ = key {
                if let identity = context.currentNostrIdentity() {
                    context.sendGeohashReadReceipt(message.id, toRecipientHex: senderPubkey, from: identity)
                }
            } else if let identity = context.currentNostrIdentity() {
                context.sendGeohashReadReceipt(message.id, toRecipientHex: senderPubkey, from: identity)
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
        guard let context else { return }
        guard let relationship = FavoritesPersistenceService.shared.getFavoriteStatus(for: noisePublicKey),
              relationship.peerNostrPublicKey != nil else {
            SecureLogger.warning("⚠️ Cannot send favorite notification - no Nostr key for peer", category: .session)
            return
        }

        let peerID = PeerID(hexData: noisePublicKey)
        context.routeFavoriteNotification(to: peerID, isFavorite: isFavorite)
    }

    @MainActor
    func nostrPubkeyForDisplayName(_ name: String) -> String? {
        guard let context else { return nil }
        for person in context.visibleGeohashPeople() where person.displayName == name {
            return person.id
        }
        for (pub, nick) in context.geoNicknames where nick == name {
            return pub
        }
        return nil
    }

    @MainActor
    func startGeohashDM(withPubkeyHex hex: String) {
        guard let context else { return }
        let convKey = PeerID(nostr_: hex)
        context.nostrKeyMapping[convKey] = hex
        context.startPrivateChat(with: convKey)
    }

    @MainActor
    func fullNostrHex(forSenderPeerID senderID: PeerID) -> String? {
        guard let context else { return nil }
        return context.nostrKeyMapping[senderID]
    }

    @MainActor
    func geohashDisplayName(for convKey: PeerID) -> String {
        guard let context else { return convKey.bare }
        guard let full = context.nostrKeyMapping[convKey] else {
            return convKey.bare
        }
        return context.displayNameForNostrPubkey(full)
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
        guard let packetData = Base64URLCoding.decode(encoded),
              packetData.count <= maxBytes
        else {
            return nil
        }
        return BitchatPacket.from(packetData)
    }
}
