//
// ChatNostrCoordinatorContextTests.swift
// bitchatTests
//
// Exercises the `ChatNostrCoordinator` facade and its components
// (`NostrInboundPipeline`, `GeohashSubscriptionManager`, `GeoPresenceTracker`)
// against a mock `ChatNostrContext` — proving the stack works without a
// `ChatViewModel`, following the `ChatDeliveryCoordinatorContextTests` /
// `ChatPrivateConversationCoordinatorContextTests` exemplars.
//

import Testing
import Foundation
import BitFoundation
@testable import bitchat

// MARK: - Mock Context

/// Lightweight stand-in for `ChatNostrContext` (and, via protocol
/// inheritance, the component contexts) proving that the Nostr stack is
/// testable without a `ChatViewModel`.
@MainActor
private final class MockChatNostrContext: ChatNostrContext {
    // Channel & subscription state
    var activeChannel: ChannelID = .mesh
    var currentGeohash: String?
    var geoSubscriptionID: String?
    var geoDmSubscriptionID: String?
    var geoSamplingSubs: [String: String] = [:]
    var lastGeoNotificationAt: [String: Date] = [:]
    var nostrRelayManager: NostrRelayManager? { nil }

    func setGeoChatSubscriptionID(_ id: String?) { geoSubscriptionID = id }
    func setGeoDmSubscriptionID(_ id: String?) { geoDmSubscriptionID = id }
    func addGeoSamplingSub(_ subID: String, forGeohash geohash: String) { geoSamplingSubs[subID] = geohash }
    func removeGeoSamplingSub(_ subID: String) { geoSamplingSubs.removeValue(forKey: subID) }

    func clearGeoSamplingSubs() -> [String] {
        defer { geoSamplingSubs.removeAll() }
        return Array(geoSamplingSubs.keys)
    }

    // Public timeline & pipeline
    var messages: [BitchatMessage] = []
    private(set) var pipelineFlushCount = 0
    private(set) var refreshedChannels: [ChannelID?] = []
    private(set) var publicSystemMessages: [String] = []
    var pendingGeohashSystemMessages: [String] = []
    private(set) var appendedGeohashMessages: [(message: BitchatMessage, geohash: String)] = []

    func flushPublicMessagePipeline() { pipelineFlushCount += 1 }
    func refreshVisibleMessages(from channel: ChannelID?) { refreshedChannels.append(channel) }
    func addPublicSystemMessage(_ content: String) { publicSystemMessages.append(content) }

    func drainPendingGeohashSystemMessages() -> [String] {
        defer { pendingGeohashSystemMessages.removeAll() }
        return pendingGeohashSystemMessages
    }

    func appendGeohashMessageIfAbsent(_ message: BitchatMessage, toGeohash geohash: String) -> Bool {
        guard !appendedGeohashMessages.contains(where: { $0.message.id == message.id && $0.geohash == geohash }) else {
            return false
        }
        appendedGeohashMessages.append((message, geohash))
        return true
    }

    // Inbound public messages
    private(set) var handledPublicMessages: [BitchatMessage] = []
    private(set) var mentionCheckedMessageIDs: [String] = []
    private(set) var hapticMessageIDs: [String] = []

    func handlePublicMessage(_ message: BitchatMessage, powBits: Int) { handledPublicMessages.append(message) }
    func checkForMentions(_ message: BitchatMessage) { mentionCheckedMessageIDs.append(message.id) }
    func sendHapticFeedback(for message: BitchatMessage) { hapticMessageIDs.append(message.id) }
    func parseMentions(from content: String) -> [String] { [] }

    // Inbound private (geohash DM) payloads
    var selectedPrivateChatPeer: PeerID?
    var nostrKeyMapping: [PeerID: String] = [:]
    func registerNostrKeyMapping(_ pubkey: String, for peerID: PeerID) { nostrKeyMapping[peerID] = pubkey }
    private(set) var handledPrivateMessages: [(payload: NoisePayload, senderPubkey: String, convKey: PeerID, timestamp: Date)] = []
    private(set) var handledDelivered: [(senderPubkey: String, convKey: PeerID)] = []
    private(set) var handledReadReceipts: [(senderPubkey: String, convKey: PeerID)] = []
    private(set) var startedPrivateChats: [PeerID] = []

    func handlePrivateMessage(
        _ payload: NoisePayload,
        senderPubkey: String,
        convKey: PeerID,
        id: NostrIdentity,
        messageTimestamp: Date
    ) {
        handledPrivateMessages.append((payload, senderPubkey, convKey, messageTimestamp))
    }

    func handleDelivered(_ payload: NoisePayload, senderPubkey: String, convKey: PeerID) {
        handledDelivered.append((senderPubkey, convKey))
    }

    func handleReadReceipt(_ payload: NoisePayload, senderPubkey: String, convKey: PeerID) {
        handledReadReceipts.append((senderPubkey, convKey))
    }

    func startPrivateChat(with peerID: PeerID) { startedPrivateChats.append(peerID) }

    // Nostr identity & blocking
    var geohashIdentities: [String: NostrIdentity] = [:]
    var nostrIdentity: NostrIdentity?
    var blockedNostrPubkeys: Set<String> = []
    var displayNamesByPubkey: [String: String] = [:]

    private struct NoIdentity: Error {}

    func deriveNostrIdentity(forGeohash geohash: String) throws -> NostrIdentity {
        guard let identity = geohashIdentities[geohash] else { throw NoIdentity() }
        return identity
    }

    func currentNostrIdentity() -> NostrIdentity? { nostrIdentity }

    func isNostrBlocked(pubkeyHexLowercased: String) -> Bool {
        blockedNostrPubkeys.contains(pubkeyHexLowercased.lowercased())
    }

    func displayNameForNostrPubkey(_ pubkeyHex: String) -> String {
        displayNamesByPubkey[pubkeyHex] ?? "anon"
    }

    // Event dedup
    private(set) var recordedNostrEventIDs: [String] = []
    private var processedNostrEventIDs: Set<String> = []
    private(set) var clearProcessedNostrEventsCount = 0

    func hasProcessedNostrEvent(_ eventID: String) -> Bool { processedNostrEventIDs.contains(eventID) }

    func recordProcessedNostrEvent(_ eventID: String) {
        processedNostrEventIDs.insert(eventID)
        recordedNostrEventIDs.append(eventID)
    }

    func clearProcessedNostrEvents() {
        processedNostrEventIDs.removeAll()
        clearProcessedNostrEventsCount += 1
    }

    // Geo participants & presence
    var geoNicknames: [String: String] = [:]
    private(set) var teleportedKeys: Set<String> = []
    var teleportedGeoCount: Int { teleportedKeys.count }
    private(set) var refreshTimerStartCount = 0
    private(set) var refreshTimerStopCount = 0
    private(set) var activeParticipantGeohashes: [String?] = []
    private(set) var recordedParticipants: [String] = []
    private(set) var recordedSampledParticipants: [(pubkeyHex: String, geohash: String)] = []
    private(set) var clearTeleportedGeoCount = 0
    private(set) var clearGeoNicknamesCount = 0
    var visiblePeople: [GeoPerson] = []

    func startGeoParticipantRefreshTimer() { refreshTimerStartCount += 1 }
    func stopGeoParticipantRefreshTimer() { refreshTimerStopCount += 1 }
    func setActiveParticipantGeohash(_ geohash: String?) { activeParticipantGeohashes.append(geohash) }
    func recordGeoParticipant(pubkeyHex: String) { recordedParticipants.append(pubkeyHex) }

    func recordGeoParticipant(pubkeyHex: String, geohash: String) {
        recordedSampledParticipants.append((pubkeyHex, geohash))
    }

    func geoParticipantCount(for geohash: String) -> Int {
        recordedSampledParticipants.filter { $0.geohash == geohash }.count
    }

    func setGeoNickname(_ nickname: String, forPubkey pubkeyHex: String) { geoNicknames[pubkeyHex.lowercased()] = nickname }
    func markGeoTeleported(_ pubkeyHexLowercased: String) { teleportedKeys.insert(pubkeyHexLowercased) }
    func clearGeoTeleported(_ pubkeyHexLowercased: String) { teleportedKeys.remove(pubkeyHexLowercased) }

    func clearTeleportedGeo() {
        teleportedKeys.removeAll()
        clearTeleportedGeoCount += 1
    }

    func clearGeoNicknames() {
        geoNicknames.removeAll()
        clearGeoNicknamesCount += 1
    }

    func visibleGeohashPeople() -> [GeoPerson] { visiblePeople }

    // Location channels
    var isTeleported = false
    var regionalGeohashes: Set<String> = []

    func isGeohashOutsideRegionalChannels(_ geohash: String) -> Bool {
        !regionalGeohashes.isEmpty && !regionalGeohashes.contains(geohash)
    }

    // Routing & acknowledgements
    private(set) var routedFavoriteNotifications: [(peerID: PeerID, isFavorite: Bool)] = []
    private(set) var geoDeliveryAcks: [(messageID: String, recipientHex: String)] = []
    private(set) var geoReadReceipts: [(messageID: String, recipientHex: String)] = []

    func routeFavoriteNotification(to peerID: PeerID, isFavorite: Bool) {
        routedFavoriteNotifications.append((peerID, isFavorite))
    }

    func sendGeohashDeliveryAck(for messageID: String, toRecipientHex recipientHex: String, from identity: NostrIdentity) {
        geoDeliveryAcks.append((messageID, recipientHex))
    }

    func sendGeohashReadReceipt(_ messageID: String, toRecipientHex recipientHex: String, from identity: NostrIdentity) {
        geoReadReceipts.append((messageID, recipientHex))
    }

    // Favorites & notifications
    var favoriteRelationshipsByNoiseKey: [Data: FavoritesPersistenceService.FavoriteRelationship] = [:]
    private(set) var geohashActivityNotifications: [(geohash: String, bodyPreview: String)] = []

    func favoriteRelationship(forNoiseKey noiseKey: Data) -> FavoritesPersistenceService.FavoriteRelationship? {
        favoriteRelationshipsByNoiseKey[noiseKey]
    }

    func allFavoriteRelationships() -> [FavoritesPersistenceService.FavoriteRelationship] {
        Array(favoriteRelationshipsByNoiseKey.values)
    }

    func notifyGeohashActivity(geohash: String, bodyPreview: String) {
        geohashActivityNotifications.append((geohash, bodyPreview))
    }
}

// MARK: - Helpers

/// Let the inner `Task { @MainActor in ... }` hops the coordinator schedules
/// run to completion.
@MainActor
private func drainMainQueue() async {
    for _ in 0..<5 {
        await Task.yield()
    }
}

// MARK: - Coordinator Tests Against Mock Context

/// Exercises `ChatNostrCoordinator` against `MockChatNostrContext` with no
/// `ChatViewModel`. Scoped to the inbound event pipeline (dedup, presence,
/// public-message ingest), gift-wrap DM ingest, key mapping, channel-switch
/// teardown, embedded ack flows, and — now that favorites and notifications
/// are injected through the context — the favorite-notification ingest and
/// the sampled-geohash notification cooldown. Flows that hit live singletons
/// (`NostrRelayManager.shared` subscriptions, `TorManager`) remain covered by
/// the full view-model tests.
struct ChatNostrCoordinatorContextTests {

    @Test @MainActor
    func handleNostrEvent_ingestsPublicMessageOnceAndDeduplicates() async throws {
        let context = MockChatNostrContext()
        let coordinator = ChatNostrCoordinator(context: context)

        let sender = try NostrIdentity.generate()
        let event = try NostrProtocol.createEphemeralGeohashEvent(
            content: "hello geohash",
            geohash: "u4pruyd",
            senderIdentity: sender,
            nickname: "alice"
        )
        context.displayNamesByPubkey[event.pubkey] = "alice#1234"

        coordinator.inbound.handleNostrEvent(event)
        await drainMainQueue()

        // Dedup recorded exactly once, presence and key mapping updated.
        #expect(context.recordedNostrEventIDs == [event.id])
        #expect(context.geoNicknames[event.pubkey.lowercased()] == "alice")
        #expect(context.recordedParticipants == [event.pubkey])
        #expect(context.nostrKeyMapping[PeerID(nostr: event.pubkey)] == event.pubkey)
        #expect(context.nostrKeyMapping[PeerID(nostr_: event.pubkey)] == event.pubkey)

        // The message reached the public ingest path with the resolved name.
        #expect(context.handledPublicMessages.map(\.id) == [event.id])
        #expect(context.handledPublicMessages.first?.sender == "alice#1234")
        #expect(context.handledPublicMessages.first?.content == "hello geohash")
        #expect(context.mentionCheckedMessageIDs == [event.id])
        #expect(context.hapticMessageIDs == [event.id])

        // A replay of the same event is dropped before any processing.
        coordinator.inbound.handleNostrEvent(event)
        await drainMainQueue()
        #expect(context.recordedNostrEventIDs == [event.id])
        #expect(context.handledPublicMessages.count == 1)
        #expect(context.recordedParticipants.count == 1)
    }

    @Test @MainActor
    func handleNostrEvent_marksTeleportedPeerWithoutIngestingEmptyContent() async throws {
        let context = MockChatNostrContext()
        let coordinator = ChatNostrCoordinator(context: context)

        let sender = try NostrIdentity.generate()
        let event = try NostrProtocol.createEphemeralGeohashEvent(
            content: "",
            geohash: "u4pruyd",
            senderIdentity: sender,
            teleported: true
        )

        coordinator.inbound.handleNostrEvent(event)
        await drainMainQueue()

        // Teleport detection fires even though the empty message is dropped.
        #expect(context.teleportedKeys == [event.pubkey.lowercased()])
        #expect(context.recordedParticipants == [event.pubkey])
        #expect(context.handledPublicMessages.isEmpty)
    }

    @Test @MainActor
    func handleNostrEvent_skipsBlockedSender() async throws {
        let context = MockChatNostrContext()
        let coordinator = ChatNostrCoordinator(context: context)

        let sender = try NostrIdentity.generate()
        let event = try NostrProtocol.createEphemeralGeohashEvent(
            content: "spam",
            geohash: "u4pruyd",
            senderIdentity: sender
        )
        context.blockedNostrPubkeys.insert(event.pubkey.lowercased())

        coordinator.inbound.handleNostrEvent(event)
        await drainMainQueue()

        // The event is still recorded for dedup but nothing else happens.
        #expect(context.recordedNostrEventIDs == [event.id])
        #expect(context.recordedParticipants.isEmpty)
        #expect(context.handledPublicMessages.isEmpty)
    }

    @Test @MainActor
    func handleGiftWrap_routesEmbeddedPrivateMessageAndDeduplicates() async throws {
        let context = MockChatNostrContext()
        let coordinator = ChatNostrCoordinator(context: context)

        let recipient = try NostrIdentity.generate()
        let sender = try NostrIdentity.generate()
        let embedded = try #require(NostrEmbeddedBitChat.encodePMForNostrNoRecipient(
            content: "psst",
            messageID: "gm-1",
            senderPeerID: PeerID(str: "aabbccddeeff0011")
        ))
        let giftWrap = try NostrProtocol.createPrivateMessage(
            content: embedded,
            recipientPubkey: recipient.publicKeyHex,
            senderIdentity: sender
        )

        coordinator.inbound.handleGiftWrap(giftWrap, id: recipient)

        let convKey = PeerID(nostr_: sender.publicKeyHex)
        #expect(context.recordedNostrEventIDs == [giftWrap.id])
        #expect(context.nostrKeyMapping[convKey] == sender.publicKeyHex)
        #expect(context.handledPrivateMessages.count == 1)
        #expect(context.handledPrivateMessages.first?.senderPubkey == sender.publicKeyHex)
        #expect(context.handledPrivateMessages.first?.convKey == convKey)

        // The embedded Noise payload survives the round trip intact.
        let payload = try #require(context.handledPrivateMessages.first?.payload)
        #expect(payload.type == .privateMessage)
        let pm = try #require(PrivateMessagePacket.decode(from: payload.data))
        #expect(pm.messageID == "gm-1")
        #expect(pm.content == "psst")

        // The same gift wrap is dropped on replay.
        coordinator.inbound.handleGiftWrap(giftWrap, id: recipient)
        #expect(context.recordedNostrEventIDs == [giftWrap.id])
        #expect(context.handledPrivateMessages.count == 1)
    }

    @Test @MainActor
    func processNostrMessage_invalidSignatureDoesNotPoisonDedup() async throws {
        let context = MockChatNostrContext()
        let coordinator = ChatNostrCoordinator(context: context)

        let recipient = try NostrIdentity.generate()
        let sender = try NostrIdentity.generate()
        let giftWrap = try NostrProtocol.createPrivateMessage(
            content: "verify:noop",
            recipientPubkey: recipient.publicKeyHex,
            senderIdentity: sender
        )
        var invalidGiftWrap = giftWrap
        invalidGiftWrap.sig = String(repeating: "0", count: 128)

        // A forged-signature copy is rejected WITHOUT entering the dedup set...
        await coordinator.inbound.processNostrMessage(invalidGiftWrap)
        #expect(context.recordedNostrEventIDs.isEmpty)

        // ...so the genuine event with the same ID still processes and records.
        await coordinator.inbound.processNostrMessage(giftWrap)
        #expect(context.recordedNostrEventIDs == [giftWrap.id])
    }

    @Test @MainActor
    func switchLocationChannel_toMesh_tearsDownGeohashState() async {
        let context = MockChatNostrContext()
        let coordinator = ChatNostrCoordinator(context: context)
        context.activeChannel = .mesh
        context.currentGeohash = "u4pruyd"
        context.geoNicknames = ["abcd": "alice"]

        coordinator.subscriptions.switchLocationChannel(to: .mesh)

        #expect(context.pipelineFlushCount == 1)
        #expect(context.activeChannel == .mesh)
        #expect(context.clearProcessedNostrEventsCount == 1)
        #expect(context.refreshedChannels == [.mesh])
        #expect(context.refreshTimerStopCount == 1)
        #expect(context.clearTeleportedGeoCount == 1)
        // Cleared once in the mesh branch, once in the shared teardown.
        #expect(context.activeParticipantGeohashes == [nil, nil])
        #expect(context.currentGeohash == nil)
        #expect(context.geoSubscriptionID == nil)
        #expect(context.geoDmSubscriptionID == nil)
        #expect(context.clearGeoNicknamesCount == 1)
        #expect(context.geoNicknames.isEmpty)
        // Mesh never starts a geohash subscription or refresh timer.
        #expect(context.refreshTimerStartCount == 0)
    }

    @Test @MainActor
    func sendDeliveryAckViaNostrEmbedded_sendsReadReceiptOnlyWhenViewingUnread() async throws {
        let context = MockChatNostrContext()
        let coordinator = ChatNostrCoordinator(context: context)
        context.nostrIdentity = try NostrIdentity.generate()
        let senderPubkey = "feedface00112233"
        let convKey = PeerID(nostr_: senderPubkey)

        let message = BitchatMessage(
            id: "mid-1",
            sender: "alice#1234",
            content: "hi",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "me",
            senderPeerID: convKey
        )

        // Not viewing the chat: delivery ack only.
        coordinator.sendDeliveryAckViaNostrEmbedded(message, wasReadBefore: false, senderPubkey: senderPubkey, key: nil)
        #expect(context.geoDeliveryAcks.map(\.messageID) == ["mid-1"])
        #expect(context.geoDeliveryAcks.first?.recipientHex == senderPubkey)
        #expect(context.geoReadReceipts.isEmpty)

        // Viewing the chat: delivery ack plus read receipt.
        context.selectedPrivateChatPeer = convKey
        coordinator.sendDeliveryAckViaNostrEmbedded(message, wasReadBefore: false, senderPubkey: senderPubkey, key: Data([0x01]))
        #expect(context.geoDeliveryAcks.count == 2)
        #expect(context.geoReadReceipts.map(\.messageID) == ["mid-1"])

        // Already read: no further read receipt.
        coordinator.sendDeliveryAckViaNostrEmbedded(message, wasReadBefore: true, senderPubkey: senderPubkey, key: nil)
        #expect(context.geoDeliveryAcks.count == 3)
        #expect(context.geoReadReceipts.count == 1)
    }

    @Test @MainActor
    func geohashDMKeyMappingHelpers_resolveAndStartChats() async {
        let context = MockChatNostrContext()
        let coordinator = ChatNostrCoordinator(context: context)
        let hex = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
        let convKey = PeerID(nostr_: hex)
        context.displayNamesByPubkey[hex] = "bob#eeff"

        coordinator.startGeohashDM(withPubkeyHex: hex)
        #expect(context.nostrKeyMapping[convKey] == hex)
        #expect(context.startedPrivateChats == [convKey])

        #expect(coordinator.fullNostrHex(forSenderPeerID: convKey) == hex)
        #expect(coordinator.geohashDisplayName(for: convKey) == "bob#eeff")

        // Unmapped conversation keys fall back to the bare peer ID.
        let unknown = PeerID(nostr_: "ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100")
        #expect(coordinator.geohashDisplayName(for: unknown) == unknown.bare)

        // Display-name lookup prefers visible people, then nicknames.
        context.visiblePeople = [GeoPerson(id: "aa11", displayName: "carol#aa11", lastSeen: Date())]
        context.geoNicknames = ["bb22": "dave"]
        #expect(coordinator.nostrPubkeyForDisplayName("carol#aa11") == "aa11")
        #expect(coordinator.nostrPubkeyForDisplayName("dave") == "bb22")
        #expect(coordinator.nostrPubkeyForDisplayName("nobody") == nil)
    }
}

// MARK: - GeoPresenceTracker Tests

/// Focused tests for seams the coordinator split made independently
/// testable: the sampling-event LRU dedup and the per-geohash notification
/// cooldown. The cooldown tests stop short of the live notification center by
/// pre-seeding the timeline append as a duplicate.
struct GeoPresenceTrackerTests {

    @Test @MainActor
    func samplingEventDedup_evictsOldestBeyondLRUCap() {
        let context = MockChatNostrContext()
        let tracker = GeoPresenceTracker(context: context)
        let cap = TransportConfig.geoSamplingEventLRUCap

        // Empty IDs are never deduplicated.
        #expect(tracker.shouldProcessGeoSamplingEvent(""))
        #expect(tracker.shouldProcessGeoSamplingEvent(""))

        // First sight passes; a replay is rejected.
        #expect(tracker.shouldProcessGeoSamplingEvent("ev-0"))
        #expect(!tracker.shouldProcessGeoSamplingEvent("ev-0"))

        // Fill one past the cap: the oldest entry is evicted and accepted
        // again, while a still-resident entry stays deduplicated.
        for i in 1...cap {
            #expect(tracker.shouldProcessGeoSamplingEvent("ev-\(i)"))
        }
        #expect(tracker.shouldProcessGeoSamplingEvent("ev-0"))
        #expect(!tracker.shouldProcessGeoSamplingEvent("ev-\(cap)"))

        // Clearing resets the dedup entirely.
        tracker.clearGeoSamplingEventDedup()
        #expect(tracker.shouldProcessGeoSamplingEvent("ev-\(cap)"))
    }

    @Test @MainActor
    func notificationCooldown_skipsWithinWindow() async throws {
        let context = MockChatNostrContext()
        let tracker = GeoPresenceTracker(context: context)
        let sender = try NostrIdentity.generate()
        let event = try NostrProtocol.createEphemeralGeohashEvent(
            content: "sampled activity",
            geohash: "9q8yy",
            senderIdentity: sender,
            nickname: "alice"
        )

        // Within the cooldown window nothing is appended or re-stamped.
        let recent = Date()
        context.lastGeoNotificationAt["9q8yy"] = recent
        tracker.cooldownPerGeohash("9q8yy", content: "sampled activity", event: event)
        await drainMainQueue()
        #expect(context.appendedGeohashMessages.isEmpty)
        #expect(context.lastGeoNotificationAt["9q8yy"] == recent)
    }

    @Test @MainActor
    func notificationCooldown_stampsGeohashOnceWindowElapses() async throws {
        let context = MockChatNostrContext()
        let tracker = GeoPresenceTracker(context: context)
        let sender = try NostrIdentity.generate()
        let event = try NostrProtocol.createEphemeralGeohashEvent(
            content: "sampled activity",
            geohash: "9q8yy",
            senderIdentity: sender,
            nickname: "alice"
        )

        // Pre-seed the same event ID so the timeline append reports a
        // duplicate and the flow never reaches the live notification center.
        let placeholder = BitchatMessage(
            id: event.id,
            sender: "seed",
            content: "seed",
            timestamp: Date(),
            isRelay: false
        )
        #expect(context.appendGeohashMessageIfAbsent(placeholder, toGeohash: "9q8yy"))

        // Cooldown elapsed: the geohash is re-stamped and the append is
        // attempted (and rejected as a duplicate, so no notification either).
        let stale = Date().addingTimeInterval(-TransportConfig.uiGeoNotifyCooldownSeconds - 1)
        context.lastGeoNotificationAt["9q8yy"] = stale
        tracker.cooldownPerGeohash("9q8yy", content: "sampled activity", event: event)
        await drainMainQueue()

        let stamped = try #require(context.lastGeoNotificationAt["9q8yy"])
        #expect(stamped > stale)
        #expect(context.appendedGeohashMessages.count == 1)
    }

    @Test @MainActor
    func geoPresence_sampledActivityNotificationRespectsPerGeohashCooldown() async throws {
        let context = MockChatNostrContext()
        let coordinator = ChatNostrCoordinator(context: context)
        let sender = try NostrIdentity.generate()
        context.geoNicknames[sender.publicKeyHex.lowercased()] = "alice"

        let first = try NostrProtocol.createEphemeralGeohashEvent(
            content: "hello geohash",
            geohash: "u4pruyd",
            senderIdentity: sender,
            nickname: "alice"
        )
        coordinator.presence.cooldownPerGeohash("u4pruyd", content: "hello geohash", event: first)
        await drainMainQueue()

        // Sampled message recorded in the store and notification posted.
        #expect(context.appendedGeohashMessages.map(\.message.id) == [first.id])
        #expect(context.appendedGeohashMessages.first?.message.sender == "alice#" + String(first.pubkey.suffix(4)))
        #expect(context.geohashActivityNotifications.count == 1)
        #expect(context.geohashActivityNotifications.first?.geohash == "u4pruyd")
        #expect(context.geohashActivityNotifications.first?.bodyPreview == "hello geohash")
        #expect(context.lastGeoNotificationAt["u4pruyd"] != nil)

        // A second sampled event inside the cooldown window is fully suppressed.
        let second = try NostrProtocol.createEphemeralGeohashEvent(
            content: "again",
            geohash: "u4pruyd",
            senderIdentity: sender,
            nickname: "alice"
        )
        coordinator.presence.cooldownPerGeohash("u4pruyd", content: "again", event: second)
        await drainMainQueue()
        #expect(context.geohashActivityNotifications.count == 1)
        #expect(context.appendedGeohashMessages.count == 1)

        // Long previews are truncated to the snippet cap with an ellipsis.
        let longContent = String(repeating: "x", count: TransportConfig.uiGeoNotifySnippetMaxLen + 20)
        let third = try NostrProtocol.createEphemeralGeohashEvent(
            content: longContent,
            geohash: "9q8yyk",
            senderIdentity: sender,
            nickname: "alice"
        )
        coordinator.presence.cooldownPerGeohash("9q8yyk", content: longContent, event: third)
        await drainMainQueue()
        #expect(
            context.geohashActivityNotifications.last?.bodyPreview
                == String(repeating: "x", count: TransportConfig.uiGeoNotifySnippetMaxLen) + "…"
        )
    }

}
