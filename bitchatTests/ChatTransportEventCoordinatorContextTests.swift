//
// ChatTransportEventCoordinatorContextTests.swift
// bitchatTests
//
// Exercises `ChatTransportEventCoordinator` against a mock
// `ChatTransportEventContext` — proving the coordinator works without a
// `ChatViewModel`, following the `ChatDeliveryCoordinatorContextTests` /
// `ChatPrivateConversationCoordinatorContextTests` exemplars.
//
// Scope note: the coordinator hops every event onto the main actor via an
// internal `Task`; tests drain those tasks with `Task.yield()`. All flows are
// mockable — no singletons are involved at this layer.
//

import Testing
import Foundation
import BitFoundation
@testable import bitchat

// MARK: - Mock Context

/// Lightweight stand-in for `ChatTransportEventContext` proving that
/// `ChatTransportEventCoordinator` is testable without a `ChatViewModel`.
@MainActor
private final class MockChatTransportEventContext: ChatTransportEventContext {
    // Connection & chat state
    var isConnected = false
    var nickname = "me"
    var myPeerID = PeerID(str: "0011223344556677")
    var privateChats: [PeerID: [BitchatMessage]] = [:]

    func privateMessages(for peerID: PeerID) -> [BitchatMessage] {
        privateChats[peerID] ?? []
    }
    var unreadPrivateMessages: Set<PeerID> = []
    var selectedPrivateChatPeer: PeerID?
    private(set) var unmarkedReadReceiptBatches: [[String]] = []
    private(set) var notifyUIChangedCount = 0

    // Conversation store intents (mirror `ConversationStore` semantics)
    @discardableResult
    func appendPrivateMessage(_ message: BitchatMessage, to peerID: PeerID) -> Bool {
        var chat = privateChats[peerID] ?? []
        guard !chat.contains(where: { $0.id == message.id }) else { return false }
        let index = chat.firstIndex(where: { $0.timestamp > message.timestamp }) ?? chat.count
        chat.insert(message, at: index)
        privateChats[peerID] = chat
        return true
    }

    func removePrivateChat(_ peerID: PeerID) {
        privateChats.removeValue(forKey: peerID)
        unreadPrivateMessages.remove(peerID)
    }

    func markPrivateChatUnread(_ peerID: PeerID) {
        unreadPrivateMessages.insert(peerID)
    }

    func markPrivateChatRead(_ peerID: PeerID) {
        unreadPrivateMessages.remove(peerID)
    }

    func unmarkReadReceiptsSent(_ ids: [String]) {
        unmarkedReadReceiptBatches.append(ids)
    }

    func notifyUIChanged() {
        notifyUIChangedCount += 1
    }

    // Inbound message handling
    var blockedMessageIDs: Set<String> = []
    private(set) var handledPrivateMessages: [BitchatMessage] = []
    private(set) var handledPublicMessages: [BitchatMessage] = []
    private(set) var mentionCheckedMessageIDs: [String] = []
    private(set) var hapticMessageIDs: [String] = []

    func isMessageBlocked(_ message: BitchatMessage) -> Bool {
        blockedMessageIDs.contains(message.id)
    }

    func handlePrivateMessage(_ message: BitchatMessage) {
        handledPrivateMessages.append(message)
    }

    func handlePublicMessage(_ message: BitchatMessage) {
        handledPublicMessages.append(message)
    }

    func checkForMentions(_ message: BitchatMessage) {
        mentionCheckedMessageIDs.append(message.id)
    }

    func sendHapticFeedback(for message: BitchatMessage) {
        hapticMessageIDs.append(message.id)
    }

    func parseMentions(from content: String) -> [String] {
        content.contains("@me") ? ["me"] : []
    }

    // Peer identity & sessions
    var blockedPeers: Set<PeerID> = []
    var peersByID: [PeerID: BitchatPeer] = [:]
    var noiseSessionKeysByPeerID: [PeerID: Data] = [:]
    private(set) var stablePeerIDCache: [PeerID: PeerID] = [:]
    private(set) var registeredEphemeralSessions: [PeerID] = []
    private(set) var removedEphemeralSessions: [PeerID] = []

    func isPeerBlocked(_ peerID: PeerID) -> Bool { blockedPeers.contains(peerID) }
    func unifiedPeer(for peerID: PeerID) -> BitchatPeer? { peersByID[peerID] }
    func resolveNickname(for peerID: PeerID) -> String { "anon\(peerID.id.prefix(4))" }
    func registerEphemeralSession(peerID: PeerID) { registeredEphemeralSessions.append(peerID) }
    func removeEphemeralSession(peerID: PeerID) { removedEphemeralSessions.append(peerID) }
    func noiseSessionPublicKeyData(for peerID: PeerID) -> Data? { noiseSessionKeysByPeerID[peerID] }
    func cacheStablePeerID(_ stablePeerID: PeerID, for shortPeerID: PeerID) {
        stablePeerIDCache[shortPeerID] = stablePeerID
    }
    func cachedStablePeerID(for shortPeerID: PeerID) -> PeerID? { stablePeerIDCache[shortPeerID] }

    // Routing & acknowledgements
    private(set) var flushedOutboxPeerIDs: [PeerID] = []
    private(set) var courierRetryPeerIDs: [PeerID] = []
    private(set) var meshDeliveryAcks: [(messageID: String, peerID: PeerID)] = []

    private(set) var flushedSkippingMessageIDs: [Set<String>] = []
    func flushRouterOutbox(forAliases peerIDAliases: [PeerID], skippingMessageIDs: Set<String>) {
        flushedOutboxPeerIDs.append(contentsOf: peerIDAliases)
        flushedSkippingMessageIDs.append(skippingMessageIDs)
    }
    func retryCourierDeposits(via peerID: PeerID) { courierRetryPeerIDs.append(peerID) }
    func sendMeshDeliveryAck(for messageID: String, to peerID: PeerID) {
        meshDeliveryAcks.append((messageID, peerID))
    }

    // Delivery status
    var applyMessageDeliveryStatusResult = true
    var deliveryStatusesByMessageID: [String: DeliveryStatus] = [:]
    private(set) var appliedDeliveryStatuses: [
        (messageID: String, status: DeliveryStatus, peerIDAliases: Set<PeerID>)
    ] = []

    @discardableResult
    func applyAcknowledgedMessageDeliveryStatus(
        _ messageID: String,
        status: DeliveryStatus,
        from peerIDAliases: Set<PeerID>
    ) -> Bool {
        appliedDeliveryStatuses.append((messageID, status, peerIDAliases))
        return applyMessageDeliveryStatusResult
    }

    func deliveryStatus(for messageID: String) -> DeliveryStatus? {
        deliveryStatusesByMessageID[messageID]
    }

    // Verification payloads
    private(set) var verifyChallengePayloads: [(peerID: PeerID, payload: Data)] = []
    private(set) var verifyResponsePayloads: [(peerID: PeerID, payload: Data)] = []

    func handleVerifyChallengePayload(from peerID: PeerID, payload: Data) {
        verifyChallengePayloads.append((peerID, payload))
    }

    func handleVerifyResponsePayload(from peerID: PeerID, payload: Data) {
        verifyResponsePayloads.append((peerID, payload))
    }

    // Group payloads
    private(set) var groupInvitePayloads: [(peerID: PeerID, payload: Data)] = []
    private(set) var groupKeyUpdatePayloads: [(peerID: PeerID, payload: Data)] = []

    func handleGroupInvitePayload(from peerID: PeerID, payload: Data) {
        groupInvitePayloads.append((peerID, payload))
    }

    func handleGroupKeyUpdatePayload(from peerID: PeerID, payload: Data) {
        groupKeyUpdatePayloads.append((peerID, payload))
    }

    private(set) var vouchPayloads: [(peerID: PeerID, payload: Data)] = []

    func handleVouchPayload(from peerID: PeerID, payload: Data) {
        vouchPayloads.append((peerID, payload))
    }

    // Live voice payloads
    private(set) var voiceFramePayloads: [(peerID: PeerID, payload: Data, timestamp: Date)] = []

    func handleVoiceFramePayload(from peerID: PeerID, payload: Data, timestamp: Date) {
        voiceFramePayloads.append((peerID, payload, timestamp))
    }
}

// MARK: - Helpers

/// Lets the coordinator's internal `Task { @MainActor … }` hops run.
@MainActor
private func drainMainActorTasks() async {
    for _ in 0..<10 { await Task.yield() }
}

private func makeMessage(
    id: String,
    sender: String = "alice",
    content: String = "hello",
    isPrivate: Bool = false,
    senderPeerID: PeerID? = nil
) -> BitchatMessage {
    BitchatMessage(
        id: id,
        sender: sender,
        content: content,
        timestamp: Date(),
        isRelay: false,
        isPrivate: isPrivate,
        recipientNickname: isPrivate ? "me" : nil,
        senderPeerID: senderPeerID
    )
}

// MARK: - Coordinator Tests Against Mock Context

/// Exercises `ChatTransportEventCoordinator` against
/// `MockChatTransportEventContext` with no `ChatViewModel`.
struct ChatTransportEventCoordinatorContextTests {

    @Test @MainActor
    func didReceiveMessage_routesPrivateAndPublic_skipsBlockedAndEmpty() async {
        let context = MockChatTransportEventContext()
        let coordinator = ChatTransportEventCoordinator(context: context)
        let peerID = PeerID(str: "1122334455667788")

        // Blocked messages are dropped before any handling.
        context.blockedMessageIDs = ["blocked", "blocked-private"]
        coordinator.didReceiveMessage(makeMessage(id: "blocked"))
        coordinator.didReceiveMessage(makeMessage(
            id: "blocked-private",
            isPrivate: true,
            senderPeerID: peerID
        ))
        // Empty public content is dropped too.
        coordinator.didReceiveMessage(makeMessage(id: "empty", content: "   "))
        await drainMainActorTasks()
        #expect(context.handledPublicMessages.isEmpty)
        #expect(context.handledPrivateMessages.isEmpty)
        #expect(context.mentionCheckedMessageIDs.isEmpty)
        #expect(context.meshDeliveryAcks.isEmpty)

        // Private goes to the private handler, public to the public handler;
        // both get mention checks and haptics. Stable-media ACK authorization
        // belongs to BLEFileTransferHandler after its durable commit and this
        // synchronous acceptance result, not to the generic UI coordinator.
        let stableMediaID = "media-\(String(repeating: "a", count: 32))"
        coordinator.didReceiveMessage(makeMessage(
            id: stableMediaID,
            isPrivate: true,
            senderPeerID: peerID
        ))
        coordinator.didReceiveMessage(makeMessage(
            id: "legacy-media",
            isPrivate: true,
            senderPeerID: peerID
        ))
        coordinator.didReceiveMessage(makeMessage(id: "pm-missing-sender", isPrivate: true))
        coordinator.didReceiveMessage(makeMessage(id: "pub"))
        await drainMainActorTasks()
        #expect(context.handledPrivateMessages.map(\.id) == [
            stableMediaID,
            "legacy-media",
            "pm-missing-sender"
        ])
        #expect(context.handledPublicMessages.map(\.id) == ["pub"])
        #expect(context.mentionCheckedMessageIDs == [
            stableMediaID,
            "legacy-media",
            "pm-missing-sender",
            "pub"
        ])
        #expect(context.hapticMessageIDs == [
            stableMediaID,
            "legacy-media",
            "pm-missing-sender",
            "pub"
        ])
        #expect(context.meshDeliveryAcks.isEmpty)
    }

    @Test @MainActor
    func synchronousMessageDeliveryReportsAcceptanceForAckGating() {
        let context = MockChatTransportEventContext()
        let coordinator = ChatTransportEventCoordinator(context: context)
        let peerID = PeerID(str: "1122334455667788")
        let blocked = makeMessage(
            id: "blocked-private-media",
            isPrivate: true,
            senderPeerID: peerID
        )
        context.blockedMessageIDs = [blocked.id]

        #expect(coordinator.didReceiveMessageSynchronously(blocked) == false)
        #expect(context.handledPrivateMessages.isEmpty)

        let accepted = makeMessage(
            id: "accepted-private-media",
            isPrivate: true,
            senderPeerID: peerID
        )
        #expect(coordinator.didReceiveMessageSynchronously(accepted) == true)
        #expect(context.handledPrivateMessages.map(\.id) == [accepted.id])
    }

    @Test @MainActor
    func didReceivePublicMessage_trimsContentAndParsesMentions() async {
        let context = MockChatTransportEventContext()
        let coordinator = ChatTransportEventCoordinator(context: context)
        let peerID = PeerID(str: "aabbccdd00112233")

        coordinator.didReceivePublicMessage(
            from: peerID,
            nickname: "alice",
            content: "  hi @me  ",
            timestamp: Date(),
            messageID: "m1"
        )
        await drainMainActorTasks()

        #expect(context.handledPublicMessages.count == 1)
        let message = context.handledPublicMessages[0]
        #expect(message.content == "hi @me")
        #expect(message.mentions == ["me"])
        #expect(message.senderPeerID == peerID)
        #expect(context.hapticMessageIDs == ["m1"])
    }

    @Test @MainActor
    func didConnectAndDisconnect_manageSessionsStableIDsAndReadReceipts() async {
        let context = MockChatTransportEventContext()
        let coordinator = ChatTransportEventCoordinator(context: context)
        let peerID = PeerID(str: "1122334455667788")
        let noiseKey = Data(repeating: 0xAB, count: 32)
        context.peersByID[peerID] = BitchatPeer(peerID: peerID, noisePublicKey: noiseKey, nickname: "alice")

        coordinator.didConnectToPeer(peerID)
        await drainMainActorTasks()
        #expect(context.isConnected)
        #expect(context.registeredEphemeralSessions == [peerID])
        #expect(context.stablePeerIDCache[peerID] == PeerID(hexData: noiseKey))
        // Both queues: the short id, then the stable 64-hex key that offline-
        // composed mail is queued under (#1408). Order matters only in that the
        // short-id flush is not delayed behind the stable-key resolution.
        #expect(context.flushedOutboxPeerIDs == [peerID, PeerID(hexData: noiseKey)])
        #expect(context.notifyUIChangedCount == 1)

        // Their messages' read receipts are un-marked on disconnect so READ
        // acks can be re-sent after reconnect; our own messages are not.
        context.privateChats[peerID] = [
            makeMessage(id: "theirs-1", isPrivate: true, senderPeerID: peerID),
            makeMessage(id: "mine-1", sender: "me", isPrivate: true, senderPeerID: context.myPeerID),
            makeMessage(id: "theirs-2", isPrivate: true, senderPeerID: peerID)
        ]
        coordinator.didDisconnectFromPeer(peerID)
        await drainMainActorTasks()
        #expect(context.removedEphemeralSessions == [peerID])
        #expect(context.unmarkedReadReceiptBatches == [["theirs-1", "theirs-2"]])
        #expect(context.notifyUIChangedCount == 2)
    }

    @Test @MainActor
    func synchronousConnectAndDisconnect_applyBeforeReturning() {
        let context = MockChatTransportEventContext()
        let coordinator = ChatTransportEventCoordinator(context: context)
        let peerID = PeerID(str: "2233445566778899")
        let incoming = makeMessage(
            id: "incoming-receipt",
            isPrivate: true,
            senderPeerID: peerID
        )
        context.privateChats[peerID] = [incoming]

        coordinator.didConnectToPeerSynchronously(peerID)

        #expect(context.isConnected)
        #expect(context.registeredEphemeralSessions == [peerID])
        #expect(context.flushedOutboxPeerIDs == [peerID])
        #expect(context.courierRetryPeerIDs == [peerID])

        coordinator.didDisconnectFromPeerSynchronously(peerID)

        #expect(context.removedEphemeralSessions == [peerID])
        #expect(context.unmarkedReadReceiptBatches == [[incoming.id]])
        #expect(context.notifyUIChangedCount == 2)
    }

    @Test @MainActor
    func didDisconnect_whileViewingChat_migratesConversationToStablePeerID() async {
        let context = MockChatTransportEventContext()
        let coordinator = ChatTransportEventCoordinator(context: context)
        let peerID = PeerID(str: "1122334455667788")
        let noiseKey = Data(repeating: 0xCD, count: 32)
        let stablePeerID = PeerID(hexData: noiseKey)

        // No cached stable ID: it must be derived from the Noise session key.
        context.noiseSessionKeysByPeerID[peerID] = noiseKey
        context.selectedPrivateChatPeer = peerID
        context.unreadPrivateMessages = [peerID]
        context.privateChats[peerID] = [
            makeMessage(id: "m1", isPrivate: true, senderPeerID: peerID),
            makeMessage(id: "mine", sender: "me", isPrivate: true, senderPeerID: context.myPeerID)
        ]

        coordinator.didDisconnectFromPeer(peerID)
        await drainMainActorTasks()

        #expect(context.privateChats[peerID] == nil)
        #expect(context.privateChats[stablePeerID]?.map(\.id) == ["m1", "mine"])
        // Sender IDs migrate to the stable peer ID, except our own.
        #expect(context.privateChats[stablePeerID]?.first?.senderPeerID == stablePeerID)
        #expect(context.privateChats[stablePeerID]?.last?.senderPeerID == context.myPeerID)
        #expect(context.selectedPrivateChatPeer == stablePeerID)
        #expect(context.unreadPrivateMessages == [stablePeerID])
        #expect(context.stablePeerIDCache[peerID] == stablePeerID)
    }

    @Test @MainActor
    func noisePayloads_driveDeliveryStatusAcksAndVerification() async {
        let context = MockChatTransportEventContext()
        let coordinator = ChatTransportEventCoordinator(context: context)
        let peerID = PeerID(str: "99aabbccddeeff00")
        let noiseKey = Data(repeating: 0x44, count: 32)
        context.peersByID[peerID] = BitchatPeer(peerID: peerID, noisePublicKey: noiseKey, nickname: "alice")
        let stablePeerID = PeerID(hexData: noiseKey)
        let staleStablePeerID = PeerID(hexData: Data(repeating: 0x55, count: 32))
        context.cacheStablePeerID(staleStablePeerID, for: peerID)
        context.noiseSessionKeysByPeerID[peerID] = noiseKey

        // Inbound private message: decoded, handled, and delivery-acked.
        let packet = PrivateMessagePacket(messageID: "pm-1", content: "hi there")
        coordinator.didReceiveNoisePayload(
            from: peerID,
            type: .privateMessage,
            payload: packet.encode() ?? Data(),
            timestamp: Date()
        )
        await drainMainActorTasks()
        #expect(context.handledPrivateMessages.map(\.id) == ["pm-1"])
        #expect(context.handledPrivateMessages.first?.sender == "alice")
        #expect(context.meshDeliveryAcks.count == 1)
        #expect(context.meshDeliveryAcks.first?.messageID == "pm-1")

        // Delivered / read acks resolve the display name from the unified peer.
        coordinator.didReceiveNoisePayload(from: peerID, type: .delivered, payload: Data("m-1".utf8), timestamp: Date())
        coordinator.didReceiveNoisePayload(from: peerID, type: .readReceipt, payload: Data("m-2".utf8), timestamp: Date())
        await drainMainActorTasks()
        #expect(context.appliedDeliveryStatuses.count == 2)
        #expect(context.appliedDeliveryStatuses[0].messageID == "m-1")
        #expect(context.appliedDeliveryStatuses[0].peerIDAliases == [peerID, stablePeerID])
        #expect(!context.appliedDeliveryStatuses[0].peerIDAliases.contains(staleStablePeerID))
        if case .delivered(let to, _) = context.appliedDeliveryStatuses[0].status {
            #expect(to == "alice")
        } else {
            Issue.record("expected .delivered status")
        }
        if case .read(let by, _) = context.appliedDeliveryStatuses[1].status {
            #expect(by == "alice")
        } else {
            Issue.record("expected .read status")
        }

        // Verification payloads are forwarded untouched.
        coordinator.didReceiveNoisePayload(from: peerID, type: .verifyChallenge, payload: Data([0x01]), timestamp: Date())
        coordinator.didReceiveNoisePayload(from: peerID, type: .verifyResponse, payload: Data([0x02]), timestamp: Date())
        await drainMainActorTasks()
        #expect(context.verifyChallengePayloads.count == 1)
        #expect(context.verifyResponsePayloads.count == 1)

        // Blocked peers' private messages are dropped (no handling, no ack).
        context.blockedPeers = [peerID]
        coordinator.didReceiveNoisePayload(
            from: peerID,
            type: .privateMessage,
            payload: packet.encode() ?? Data(),
            timestamp: Date()
        )
        await drainMainActorTasks()
        #expect(context.handledPrivateMessages.count == 1)
        #expect(context.meshDeliveryAcks.count == 1)
    }

    /// #1408: a DM composed while the recipient was an offline favorite is
    /// queued in the router outbox under the peer's STABLE 64-hex Noise key.
    /// `flushOutbox` is keyed by exactly the id it is handed, so flushing only
    /// the short 16-hex id on connect never reaches that queue — the mail waits
    /// for an app relaunch, a favorite-status change, or the 24h TTL.
    ///
    /// Reconnect must flush both.
    @Test @MainActor
    func didConnectToPeer_flushesTheStableKeyOutboxAsWellAsTheShortID() {
        let context = MockChatTransportEventContext()
        let coordinator = ChatTransportEventCoordinator(context: context)

        let shortPeerID = PeerID(str: "1122334455667788")
        let noiseKey = Data((0..<32).map { UInt8(0xB0 &+ $0) })
        let stablePeerID = PeerID(hexData: noiseKey)
        #expect(stablePeerID != shortPeerID)

        // The peer is known by its Noise key, as it is after a handshake.
        context.peersByID[shortPeerID] = BitchatPeer(
            peerID: shortPeerID,
            noisePublicKey: noiseKey,
            nickname: "alice"
        )

        coordinator.didConnectToPeerSynchronously(shortPeerID)

        // Both queues are drained, and the stable key is the one that carries
        // the offline-composed mail.
        #expect(context.flushedOutboxPeerIDs.contains(shortPeerID))
        #expect(
            context.flushedOutboxPeerIDs.contains(stablePeerID),
            "offline-queued mail under the stable key was never flushed"
        )
    }

    /// The stable key must still resolve when unified-peer state has not been
    /// populated yet at connect time — otherwise the flush silently no-ops in
    /// exactly the case it is for. It resolves from the live Noise session key,
    /// never from the cache alone.
    @Test @MainActor
    func didConnectToPeer_resolvesTheStableKeyWithoutUnifiedPeerState() {
        let shortPeerID = PeerID(str: "1122334455667788")
        let noiseKey = Data((0..<32).map { UInt8(0xC0 &+ $0) })
        let stablePeerID = PeerID(hexData: noiseKey)

        // Cache only, with no live evidence for this link. Short BLE IDs are
        // recycled, so the entry may belong to a previous owner of this ID —
        // flushing it would drain a stranger's queue and skip the right one.
        let viaCache = MockChatTransportEventContext()
        viaCache.cacheStablePeerID(stablePeerID, for: shortPeerID)
        ChatTransportEventCoordinator(context: viaCache)
            .didConnectToPeerSynchronously(shortPeerID)
        #expect(
            viaCache.flushedOutboxPeerIDs == [shortPeerID],
            "a cache entry with no live corroboration named the stable peer"
        )

        // Noise session key only.
        let viaSession = MockChatTransportEventContext()
        viaSession.noiseSessionKeysByPeerID[shortPeerID] = noiseKey
        ChatTransportEventCoordinator(context: viaSession)
            .didConnectToPeerSynchronously(shortPeerID)
        #expect(viaSession.flushedOutboxPeerIDs.contains(stablePeerID))

        // Nothing resolvable: the short-id flush still happens, and no bogus
        // second flush is issued.
        let unresolvable = MockChatTransportEventContext()
        ChatTransportEventCoordinator(context: unresolvable)
            .didConnectToPeerSynchronously(shortPeerID)
        #expect(unresolvable.flushedOutboxPeerIDs == [shortPeerID])
    }

    /// Both keys must be handed to the router in a *single* call. Two
    /// sequential single-key flushes would drain the short-ID queue first, so
    /// mail composed moments ago could be delivered ahead of the older mail
    /// that has been waiting under the stable key. Only the merged call lets
    /// the router order the two queues by timestamp.
    @Test @MainActor
    func didConnectToPeer_flushesBothKeysInOneMergedCall() {
        let context = MockChatTransportEventContext()
        let shortPeerID = PeerID(str: "1122334455667788")
        let noiseKey = Data((0..<32).map { UInt8(0xD0 &+ $0) })
        let stablePeerID = PeerID(hexData: noiseKey)

        context.peersByID[shortPeerID] = BitchatPeer(
            peerID: shortPeerID,
            noisePublicKey: noiseKey,
            nickname: "alice"
        )

        ChatTransportEventCoordinator(context: context)
            .didConnectToPeerSynchronously(shortPeerID)

        #expect(
            context.flushedSkippingMessageIDs.count == 1,
            "the two keys must be merged into one flush, not drained in sequence"
        )
        #expect(context.flushedOutboxPeerIDs == [shortPeerID, stablePeerID])
        // Connect has no preceding retry pass, so nothing may be skipped.
        #expect(context.flushedSkippingMessageIDs == [[]])
    }

    /// Short BLE IDs are ephemeral and get recycled. A cache entry left by a
    /// previous owner of the same short ID must lose to the identity of the
    /// link we just brought up, or the flush drains — and transmits under —
    /// the wrong peer's queue.
    @Test @MainActor
    func didConnectToPeer_prefersTheLiveSessionKeyOverAStaleCacheEntry() {
        let context = MockChatTransportEventContext()
        let shortPeerID = PeerID(str: "1122334455667788")

        let staleKey = Data(repeating: 0xAA, count: 32)
        let liveKey = Data(repeating: 0xBB, count: 32)
        context.cacheStablePeerID(PeerID(hexData: staleKey), for: shortPeerID)
        context.noiseSessionKeysByPeerID[shortPeerID] = liveKey

        ChatTransportEventCoordinator(context: context)
            .didConnectToPeerSynchronously(shortPeerID)

        #expect(context.flushedOutboxPeerIDs == [shortPeerID, PeerID(hexData: liveKey)])
        #expect(
            !context.flushedOutboxPeerIDs.contains(PeerID(hexData: staleKey)),
            "a recycled short ID flushed the previous owner's outbox"
        )
    }
}
