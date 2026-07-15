//
// ChatOutgoingCoordinatorContextTests.swift
// bitchatTests
//
// Exercises `ChatOutgoingCoordinator` against a mock `ChatOutgoingContext` —
// proving the coordinator works without a `ChatViewModel`, following the
// `ChatDeliveryCoordinatorContextTests` exemplar.
//
// Scope note: the geohash path builds and signs a real Nostr event via
// `NostrProtocol.createEphemeralGeohashEvent` (pure crypto, no shared state);
// everything else flows through the mock context.
//

import Testing
import Foundation
import BitFoundation
@testable import bitchat

// MARK: - Mock Context

/// Lightweight stand-in for `ChatOutgoingContext` proving that
/// `ChatOutgoingCoordinator` is testable without a `ChatViewModel`.
@MainActor
private final class MockChatOutgoingContext: ChatOutgoingContext {
    // Identity & channel state
    var nickname = "me"
    var myPeerID = PeerID(str: "0011223344556677")
    var activeChannel: ChannelID = .mesh
    var selectedPrivateChatPeer: PeerID?
    var isTeleported = false

    // Commands & private messages
    var selectedPeerAfterUpdate: PeerID??
    private(set) var handledCommands: [String] = []
    private(set) var updatePrivateChatPeerIfNeededCount = 0
    private(set) var sentPrivateMessages: [(content: String, peerID: PeerID)] = []

    func handleCommand(_ command: String) { handledCommands.append(command) }

    func updatePrivateChatPeerIfNeeded() {
        updatePrivateChatPeerIfNeededCount += 1
        if let selectedPeerAfterUpdate {
            selectedPrivateChatPeer = selectedPeerAfterUpdate
        }
    }

    func sendPrivateMessage(_ content: String, to peerID: PeerID) {
        sentPrivateMessages.append((content, peerID))
    }

    // Public timeline (local echo)
    private(set) var appendedPublicMessages: [(message: BitchatMessage, conversationID: ConversationID)] = []
    private(set) var systemMessages: [String] = []

    func parseMentions(from content: String) -> [String] {
        content.contains("@bob") ? ["bob"] : []
    }

    @discardableResult
    func appendPublicMessage(_ message: BitchatMessage, to conversationID: ConversationID) -> Bool {
        appendedPublicMessages.append((message, conversationID))
        return true
    }

    func addSystemMessage(_ content: String) { systemMessages.append(content) }

    // Content dedup
    private(set) var recordedContentKeys: [(key: String, timestamp: Date)] = []

    func normalizedContentKey(_ content: String) -> String { "key:\(content)" }
    func recordContentKey(_ key: String, timestamp: Date) {
        recordedContentKeys.append((key, timestamp))
    }

    // Outbound routing
    private(set) var recordedActivityKeys: [String] = []
    private(set) var sentMeshMessages: [(content: String, mentions: [String], messageID: String, timestamp: Date)] = []
    private(set) var sentGeohashContexts: [ChatViewModel.GeoOutgoingContext] = []

    func recordPublicActivity(forChannelKey key: String) { recordedActivityKeys.append(key) }

    func sendMeshMessage(_ content: String, mentions: [String], messageID: String, timestamp: Date) {
        sentMeshMessages.append((content, mentions, messageID, timestamp))
    }

    func sendGeohash(context: ChatViewModel.GeoOutgoingContext) {
        sentGeohashContexts.append(context)
    }

    private(set) var bridgedMessages: [(content: String, senderPeerID: PeerID, timestamp: Date)] = []
    func bridgeOutgoingPublicMessage(_ content: String, senderPeerID: PeerID, timestamp: Date) {
        bridgedMessages.append((content, senderPeerID, timestamp))
    }

    // Geohash identity
    struct IdentityUnavailable: Error {}
    var deriveNostrIdentityError: Error?
    static let dummyIdentity = NostrIdentity(
        privateKey: Data(repeating: 0x11, count: 32),
        publicKey: Data(repeating: 0x22, count: 32),
        npub: "npub1mock",
        createdAt: Date(timeIntervalSince1970: 0)
    )

    func deriveNostrIdentity(forGeohash geohash: String) throws -> NostrIdentity {
        if let deriveNostrIdentityError { throw deriveNostrIdentityError }
        return Self.dummyIdentity
    }
}

// MARK: - Helpers

/// Lets the coordinator's internal `Task { @MainActor … }` hops run.
@MainActor
private func drainMainActorTasks() async {
    for _ in 0..<10 { await Task.yield() }
}

// MARK: - Coordinator Tests Against Mock Context

/// Exercises `ChatOutgoingCoordinator` against `MockChatOutgoingContext` with
/// no `ChatViewModel`.
struct ChatOutgoingCoordinatorContextTests {

    @Test @MainActor
    func sendMessage_routesSlashCommandsAndDropsEmptyContent() async {
        let context = MockChatOutgoingContext()
        let coordinator = ChatOutgoingCoordinator(context: context)

        coordinator.sendMessage("   ")
        coordinator.sendMessage("/who all")
        await drainMainActorTasks()

        #expect(context.handledCommands == ["/who all"])
        #expect(context.appendedPublicMessages.isEmpty)
        #expect(context.sentMeshMessages.isEmpty)
    }

    @Test @MainActor
    func sendMessage_inPrivateChat_reResolvesPeerBeforeSending() async {
        let context = MockChatOutgoingContext()
        let coordinator = ChatOutgoingCoordinator(context: context)
        let shortPeer = PeerID(str: "1111111111111111")
        let stablePeer = PeerID(str: String(repeating: "ab", count: 32))

        // The selected peer is refreshed (short → stable) before sending.
        context.selectedPrivateChatPeer = shortPeer
        context.selectedPeerAfterUpdate = stablePeer
        coordinator.sendMessage("hi there")
        #expect(context.updatePrivateChatPeerIfNeededCount == 1)
        #expect(context.sentPrivateMessages.map(\.peerID) == [stablePeer])
        #expect(context.sentPrivateMessages.map(\.content) == ["hi there"])

        // If the refresh clears the selection, nothing is sent.
        context.selectedPeerAfterUpdate = PeerID??.some(nil)
        coordinator.sendMessage("dropped")
        await drainMainActorTasks()
        #expect(context.sentPrivateMessages.count == 1)
        #expect(context.appendedPublicMessages.isEmpty)
    }

    @Test @MainActor
    func sendMessage_onMesh_appendsLocalEchoRecordsActivityAndSends() async {
        let context = MockChatOutgoingContext()
        let coordinator = ChatOutgoingCoordinator(context: context)

        coordinator.sendMessage("  hello @bob  ")
        await drainMainActorTasks()

        // Local echo uses the trimmed content, own nickname/peer ID, mentions.
        #expect(context.appendedPublicMessages.count == 1)
        let echo = context.appendedPublicMessages[0]
        #expect(echo.message.content == "hello @bob")
        #expect(echo.message.sender == "me")
        #expect(echo.message.senderPeerID == context.myPeerID)
        #expect(echo.message.mentions == ["bob"])
        #expect(echo.conversationID == .mesh)
        #expect(context.recordedContentKeys.map(\.key) == ["key:hello @bob"])

        // The mesh send carries the original (untrimmed) content and reuses
        // the echo's message ID and timestamp; activity is stamped for "mesh".
        #expect(context.recordedActivityKeys == ["mesh"])
        #expect(context.sentMeshMessages.count == 1)
        let sent = context.sentMeshMessages[0]
        #expect(sent.content == "  hello @bob  ")
        #expect(sent.mentions == ["bob"])
        #expect(sent.messageID == echo.message.id)
        #expect(sent.timestamp == echo.message.timestamp)
    }

    @Test @MainActor
    func sendMessage_onLocationChannel_sendsGeohashEventOrFailsWithSystemMessage() async {
        let context = MockChatOutgoingContext()
        let coordinator = ChatOutgoingCoordinator(context: context)
        let channel = GeohashChannel(level: .city, geohash: "u4pruydq")
        context.activeChannel = .location(channel)
        context.isTeleported = true

        coordinator.sendMessage("hello geo")
        // Geohash sends mine a NIP-13 nonce tag off-main before echoing and
        // sending; await the send task, then drain the main queue.
        await coordinator.geohashMiningTask?.value
        await drainMainActorTasks()

        // Local echo carries the geohash sender suffix (#last-4-of-pubkey) and
        // the signed event's ID; the send context targets the same channel.
        #expect(context.appendedPublicMessages.count == 1)
        let echo = context.appendedPublicMessages[0].message
        #expect(context.appendedPublicMessages[0].conversationID == .geohash("u4pruydq"))
        #expect(echo.sender == "me#2222")
        #expect(context.recordedActivityKeys == ["geo:u4pruydq"])
        #expect(context.sentGeohashContexts.count == 1)
        let geoContext = context.sentGeohashContexts[0]
        #expect(geoContext.channel == channel)
        #expect(geoContext.teleported)
        #expect(geoContext.event.id == echo.id)

        // Identity derivation failure: system message, no echo, no send.
        context.deriveNostrIdentityError = MockChatOutgoingContext.IdentityUnavailable()
        coordinator.sendMessage("doomed")
        await drainMainActorTasks()
        #expect(context.systemMessages.count == 1)
        #expect(context.appendedPublicMessages.count == 1)
        #expect(context.sentGeohashContexts.count == 1)
    }

    @Test @MainActor
    func sendMessage_onLocationChannel_serializesRapidSendsInSendOrder() async {
        let context = MockChatOutgoingContext()
        let coordinator = ChatOutgoingCoordinator(context: context)
        let channel = GeohashChannel(level: .city, geohash: "u4pruydq")
        context.activeChannel = .location(channel)

        // Two back-to-back sends. The first carries much larger content, so
        // its NIP-13 mining hashes a bigger event per attempt and runs longer
        // than the second's. Without serialization the second (faster) task
        // could finish first and reorder both the local timeline and the
        // relayed events. The coordinator chains the mining tasks — each send
        // awaits the previous send's task before it echoes and relays — so the
        // visible order must always match the send order.
        let first = "first " + String(repeating: "x", count: 4000)
        let second = "second"
        coordinator.sendMessage(first)
        coordinator.sendMessage(second)

        // The stored task is the second send, which awaits the first.
        await coordinator.geohashMiningTask?.value
        await drainMainActorTasks()

        // Local echoes land in send order…
        #expect(context.appendedPublicMessages.map(\.message.content) == [first, second])
        // …and so do the relayed events (IDs match the echoes 1:1, in order).
        #expect(context.sentGeohashContexts.count == 2)
        #expect(context.sentGeohashContexts.map(\.event.id)
                == context.appendedPublicMessages.map(\.message.id))
    }
}
