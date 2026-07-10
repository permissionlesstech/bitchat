//
// ChatLifecycleCoordinatorContextTests.swift
// bitchatTests
//
// Exercises `ChatLifecycleCoordinator` against a mock `ChatLifecycleContext`
// — proving the coordinator works without a `ChatViewModel`, following the
// `ChatDeliveryCoordinatorContextTests` /
// `ChatPrivateConversationCoordinatorContextTests` exemplars.
//
// Scope note: the geohash-screenshot branch publishes via
// `NostrRelayManager.shared` / `GeoRelayDirectory.shared`; that stays covered
// by the full view-model tests. The GeoDM read pass, the favorites-backed
// mesh/Nostr read-receipt branch (favorites are injected through the
// context), message merging, screenshot notices, and lifecycle persistence
// flows are covered here.
//

import Testing
import Foundation
import BitFoundation
@testable import bitchat

// MARK: - Mock Context

/// Lightweight stand-in for `ChatLifecycleContext` proving that
/// `ChatLifecycleCoordinator` is testable without a `ChatViewModel`.
@MainActor
private final class MockChatLifecycleContext: ChatLifecycleContext {
    // Chat & receipt state
    var messages: [BitchatMessage] = []
    var privateChats: [PeerID: [BitchatMessage]] = [:]

    func privateMessages(for peerID: PeerID) -> [BitchatMessage] {
        privateChats[peerID] ?? []
    }
    var unreadPrivateMessages: Set<PeerID> = []
    var selectedPrivateChatPeer: PeerID?
    var sentReadReceipts: Set<String> = []
    var nickname = "me"
    var myPeerID = PeerID(str: "0011223344556677")
    var activeChannel: ChannelID = .mesh
    var nostrKeyMapping: [PeerID: String] = [:]
    private(set) var ownerLevelReadPasses: [PeerID] = []
    private(set) var managerReadMarks: [PeerID] = []
    private(set) var systemMessages: [String] = []

    // Conversation store intents
    @discardableResult
    func appendPrivateMessage(_ message: BitchatMessage, to peerID: PeerID) -> Bool {
        var chat = privateChats[peerID] ?? []
        guard !chat.contains(where: { $0.id == message.id }) else { return false }
        let index = chat.firstIndex(where: { $0.timestamp > message.timestamp }) ?? chat.count
        chat.insert(message, at: index)
        privateChats[peerID] = chat
        return true
    }

    func markPrivateChatRead(_ peerID: PeerID) {
        unreadPrivateMessages.remove(peerID)
    }

    @discardableResult
    func markReadReceiptSent(_ messageID: String) -> Bool {
        sentReadReceipts.insert(messageID).inserted
    }

    func markPrivateMessagesAsRead(from peerID: PeerID) {
        ownerLevelReadPasses.append(peerID)
    }

    func markChatAsRead(from peerID: PeerID) {
        managerReadMarks.append(peerID)
    }

    // Scheduled work runs synchronously so tests never poll wall-clock queues.
    private(set) var scheduledDelays: [TimeInterval] = []
    func scheduleOnMainAfter(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        scheduledDelays.append(delay)
        work()
    }

    func addSystemMessage(_ content: String) { systemMessages.append(content) }

    // Peers & sessions
    var nicknamesByPeerID: [PeerID: String] = [:]
    var peersByID: [PeerID: BitchatPeer] = [:]
    var noiseSessionStates: [PeerID: LazyHandshakeState] = [:]
    private(set) var stopMeshServicesCount = 0
    private(set) var refreshBluetoothStateCount = 0

    func peerNickname(for peerID: PeerID) -> String? { nicknamesByPeerID[peerID] }
    func unifiedPeer(for peerID: PeerID) -> BitchatPeer? { peersByID[peerID] }
    func noiseSessionState(for peerID: PeerID) -> LazyHandshakeState {
        noiseSessionStates[peerID] ?? .none
    }
    func stopMeshServices() { stopMeshServicesCount += 1 }
    func refreshBluetoothState() { refreshBluetoothStateCount += 1 }

    // Routing & receipts
    private(set) var routedPrivateMessages: [(content: String, peerID: PeerID, recipientNickname: String)] = []
    private(set) var routedReadReceipts: [(messageID: String, peerID: PeerID)] = []
    private(set) var meshBroadcasts: [String] = []
    private(set) var geoReadReceipts: [(messageID: String, recipientHex: String)] = []

    func routePrivateMessage(_ content: String, to peerID: PeerID, recipientNickname: String, messageID: String) {
        routedPrivateMessages.append((content, peerID, recipientNickname))
    }

    var routeReadReceiptResult = true
    func routeReadReceipt(_ receipt: ReadReceipt, to peerID: PeerID) -> Bool {
        routedReadReceipts.append((receipt.originalMessageID, peerID))
        return routeReadReceiptResult
    }

    func sendMeshMessage(_ content: String, mentions: [String], messageID: String, timestamp: Date) {
        meshBroadcasts.append(content)
    }

    func sendGeohashReadReceipt(_ messageID: String, toRecipientHex recipientHex: String, from identity: NostrIdentity) {
        geoReadReceipts.append((messageID, recipientHex))
    }

    // Nostr & geohash
    var isTeleported = false
    private(set) var recordedGeoParticipants: [String] = []

    func deriveNostrIdentity(forGeohash geohash: String) throws -> NostrIdentity { Self.dummyIdentity }
    func recordGeoParticipant(pubkeyHex: String) { recordedGeoParticipants.append(pubkeyHex) }

    // Favorites
    var favoriteRelationshipsByNoiseKey: [Data: FavoritesPersistenceService.FavoriteRelationship] = [:]

    func favoriteRelationship(forNoiseKey noiseKey: Data) -> FavoritesPersistenceService.FavoriteRelationship? {
        favoriteRelationshipsByNoiseKey[noiseKey]
    }

    // Identity persistence
    private(set) var forceSaveIdentityCount = 0
    private(set) var verifyIdentityKeyExistsCount = 0

    func forceSaveIdentity() { forceSaveIdentityCount += 1 }

    @discardableResult
    func verifyIdentityKeyExists() -> Bool {
        verifyIdentityKeyExistsCount += 1
        return true
    }

    static let dummyIdentity = NostrIdentity(
        privateKey: Data(repeating: 0x11, count: 32),
        publicKey: Data(repeating: 0x22, count: 32),
        npub: "npub1mock",
        createdAt: Date(timeIntervalSince1970: 0)
    )
}

// MARK: - Helpers

private func makeFavoriteRelationship(
    noiseKey: Data,
    nostrPublicKey: String? = nil,
    nickname: String = "alice",
    isFavorite: Bool = false,
    theyFavoritedUs: Bool = false
) -> FavoritesPersistenceService.FavoriteRelationship {
    FavoritesPersistenceService.FavoriteRelationship(
        peerNoisePublicKey: noiseKey,
        peerNostrPublicKey: nostrPublicKey,
        peerNickname: nickname,
        isFavorite: isFavorite,
        theyFavoritedUs: theyFavoritedUs,
        favoritedAt: Date(timeIntervalSince1970: 0),
        lastUpdated: Date(timeIntervalSince1970: 0)
    )
}

@MainActor
private func makePrivateMessage(
    id: String,
    sender: String = "alice",
    timestamp: Date = Date(),
    senderPeerID: PeerID? = nil,
    isRelay: Bool = false,
    deliveryStatus: DeliveryStatus? = nil
) -> BitchatMessage {
    BitchatMessage(
        id: id,
        sender: sender,
        content: "hello",
        timestamp: timestamp,
        isRelay: isRelay,
        isPrivate: true,
        recipientNickname: "me",
        senderPeerID: senderPeerID,
        deliveryStatus: deliveryStatus
    )
}

// MARK: - Coordinator Tests Against Mock Context

/// Exercises `ChatLifecycleCoordinator` against `MockChatLifecycleContext`
/// with no `ChatViewModel`.
struct ChatLifecycleCoordinatorContextTests {

    @Test @MainActor
    func getPrivateChatMessages_mergesEphemeralAndStableKeepingBestStatus() async {
        let context = MockChatLifecycleContext()
        let coordinator = ChatLifecycleCoordinator(context: context)
        let peerID = PeerID(str: "1122334455667788")
        let noiseKey = Data(repeating: 0xAB, count: 32)
        let stablePeerID = PeerID(hexData: noiseKey)
        context.peersByID[peerID] = BitchatPeer(peerID: peerID, noisePublicKey: noiseKey, nickname: "alice")

        let t1 = Date(timeIntervalSince1970: 1)
        let t2 = Date(timeIntervalSince1970: 2)
        // Same message under both keys: the read copy must win over sent.
        context.privateChats[peerID] = [
            makePrivateMessage(id: "m1", timestamp: t1, deliveryStatus: .sent),
            makePrivateMessage(id: "m2", timestamp: t2)
        ]
        context.privateChats[stablePeerID] = [
            makePrivateMessage(id: "m1", timestamp: t1, deliveryStatus: .read(by: "alice", at: t2))
        ]

        let merged = coordinator.getPrivateChatMessages(for: peerID)
        #expect(merged.map(\.id) == ["m1", "m2"])
        if case .read? = merged.first?.deliveryStatus {
        } else {
            Issue.record("expected the .read copy of m1 to win the merge")
        }

        // getMessages(for: nil) falls back to the public timeline.
        context.messages = [makePrivateMessage(id: "pub")]
        #expect(coordinator.getMessages(for: nil).map(\.id) == ["pub"])
    }

    @Test @MainActor
    func markPrivateMessagesAsRead_geoDM_sendsReadReceiptsOnce() async {
        let context = MockChatLifecycleContext()
        let coordinator = ChatLifecycleCoordinator(context: context)
        let convKey = PeerID(nostr_: "feedface00112233")
        let recipientHex = "feedface00112233"
        context.activeChannel = .location(GeohashChannel(level: .city, geohash: "u4pruy"))
        context.nostrKeyMapping[convKey] = recipientHex
        context.sentReadReceipts = ["already-acked"]
        context.privateChats[convKey] = [
            makePrivateMessage(id: "m1", senderPeerID: convKey),
            makePrivateMessage(id: "already-acked", senderPeerID: convKey),
            makePrivateMessage(id: "relay", senderPeerID: convKey, isRelay: true),
            makePrivateMessage(id: "mine", sender: "me", senderPeerID: context.myPeerID)
        ]

        coordinator.markPrivateMessagesAsRead(from: convKey)

        #expect(context.managerReadMarks == [convKey])
        // Only the peer's own un-acked, non-relay message gets a READ.
        #expect(context.geoReadReceipts.map(\.messageID) == ["m1"])
        #expect(context.geoReadReceipts.first?.recipientHex == recipientHex)
        #expect(context.sentReadReceipts.contains("m1"))

        // Second pass: nothing new to send.
        coordinator.markPrivateMessagesAsRead(from: convKey)
        #expect(context.geoReadReceipts.count == 1)
    }

    @Test @MainActor
    func handleScreenshotCaptured_privateChat_appendsNoticeAndRoutesWhenEstablished() async {
        let context = MockChatLifecycleContext()
        let coordinator = ChatLifecycleCoordinator(context: context)
        let peerID = PeerID(str: "1122334455667788")
        context.selectedPrivateChatPeer = peerID
        context.nicknamesByPeerID[peerID] = "alice"

        // No established session: local notice only, no network send.
        coordinator.handleScreenshotCaptured()
        #expect(context.routedPrivateMessages.isEmpty)
        #expect(context.privateChats[peerID]?.map(\.content) == ["you took a screenshot"])
        #expect(context.privateChats[peerID]?.first?.sender == "system")

        // Established session: the peer is notified too.
        context.noiseSessionStates[peerID] = .established
        coordinator.handleScreenshotCaptured()
        #expect(context.routedPrivateMessages.count == 1)
        #expect(context.routedPrivateMessages.first?.content == "* me took a screenshot *")
        #expect(context.routedPrivateMessages.first?.recipientNickname == "alice")
        #expect(context.privateChats[peerID]?.count == 2)
        // The public-channel system message is not used for private chats.
        #expect(context.systemMessages.isEmpty)
        #expect(context.meshBroadcasts.isEmpty)
    }

    @Test @MainActor
    func handleScreenshotCaptured_meshChannel_broadcastsAndConfirmsLocally() async {
        let context = MockChatLifecycleContext()
        let coordinator = ChatLifecycleCoordinator(context: context)

        coordinator.handleScreenshotCaptured()

        #expect(context.meshBroadcasts == ["* me took a screenshot *"])
        #expect(context.systemMessages == ["you took a screenshot"])
        #expect(context.privateChats.isEmpty)
    }

    @Test @MainActor
    func lifecycleEvents_persistIdentityAndScheduleReadPasses() async {
        let context = MockChatLifecycleContext()
        let coordinator = ChatLifecycleCoordinator(context: context)

        coordinator.applicationWillTerminate()
        #expect(context.stopMeshServicesCount == 1)
        #expect(context.forceSaveIdentityCount == 1)
        #expect(context.verifyIdentityKeyExistsCount == 1)

        // Becoming active with no open chat only refreshes Bluetooth state.
        coordinator.handleDidBecomeActive()
        #expect(context.refreshBluetoothStateCount == 1)
        #expect(context.managerReadMarks.isEmpty)

        // With an open chat the read pass runs immediately (manager-level) and
        // a delayed owner-level pass is scheduled.
        let peerID = PeerID(nostr_: "feedface00112233")
        context.selectedPrivateChatPeer = peerID
        coordinator.handleDidBecomeActive()
        #expect(context.refreshBluetoothStateCount == 2)
        #expect(context.managerReadMarks == [peerID])

        // The mock executes scheduled work synchronously, so the delayed
        // owner-level pass has already run - no wall-clock polling.
        #expect(context.scheduledDelays == [TransportConfig.uiAnimationMediumSeconds])
        #expect(context.ownerLevelReadPasses == [peerID])
    }
    @Test @MainActor
    func markPrivateMessagesAsRead_routesReceiptsForFavoritesAndNonFavorites() {
        let context = MockChatLifecycleContext()
        let coordinator = ChatLifecycleCoordinator(context: context)
        let noiseKey = Data(repeating: 0xAB, count: 32)
        let peerID = PeerID(hexData: noiseKey)
        context.favoriteRelationshipsByNoiseKey[noiseKey] = makeFavoriteRelationship(
            noiseKey: noiseKey,
            nostrPublicKey: "npub1alice"
        )
        context.privateChats[peerID] = [
            makePrivateMessage(id: "in-1", senderPeerID: peerID),
            makePrivateMessage(id: "in-relay", senderPeerID: peerID, isRelay: true)
        ]

        coordinator.markPrivateMessagesAsRead(from: peerID)

        // Favorite with a Nostr key: READ receipts routed for non-relay
        // inbound messages and recorded as sent.
        #expect(context.managerReadMarks == [peerID])
        #expect(context.routedReadReceipts.map(\.messageID) == ["in-1"])
        #expect(context.routedReadReceipts.map(\.peerID) == [peerID])
        #expect(context.sentReadReceipts.contains("in-1"))

        // No favorite relationship: receipts still route — the router picks
        // whatever transport can reach the peer (mesh included). Gating on a
        // stored Nostr key silently starved mesh-connected non-favorites.
        let otherKey = Data(repeating: 0xCD, count: 32)
        let otherPeer = PeerID(hexData: otherKey)
        context.privateChats[otherPeer] = [makePrivateMessage(id: "in-2", senderPeerID: otherPeer)]
        coordinator.markPrivateMessagesAsRead(from: otherPeer)
        #expect(context.routedReadReceipts.map(\.messageID) == ["in-1", "in-2"])
        #expect(context.sentReadReceipts.contains("in-2"))
    }

}
