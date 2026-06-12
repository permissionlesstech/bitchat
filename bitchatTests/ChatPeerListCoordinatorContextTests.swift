//
// ChatPeerListCoordinatorContextTests.swift
// bitchatTests
//
// Exercises `ChatPeerListCoordinator` against a mock `ChatPeerListContext` —
// proving the coordinator works without a `ChatViewModel`, following the
// `ChatDeliveryCoordinatorContextTests` /
// `ChatTransportEventCoordinatorContextTests` exemplars.
//
// Scope note: the network-availability notification now posts through the
// injected `ChatPeerListContext` (`notifyNetworkAvailable(peerCount:)`), so
// its gating is covered here; the wall-clock timer-driven reset flows are
// covered by integration-level tests.
//

import Testing
import Foundation
import BitFoundation
@testable import bitchat

// MARK: - Mock Context

/// Lightweight stand-in for `ChatPeerListContext` proving that
/// `ChatPeerListCoordinator` is testable without a `ChatViewModel`.
@MainActor
private final class MockChatPeerListContext: ChatPeerListContext {
    // Connection & chat state
    var isConnected = false
    var privateChats: [PeerID: [BitchatMessage]] = [:]

    func privateMessages(for peerID: PeerID) -> [BitchatMessage] {
        privateChats[peerID] ?? []
    }
    var unreadPrivateMessages: Set<PeerID> = []
    var hasTrackedPrivateChatSelection = false
    private(set) var updatePrivateChatPeerIfNeededCount = 0
    private(set) var cleanupOldReadReceiptsCount = 0

    func markPrivateChatRead(_ peerID: PeerID) {
        unreadPrivateMessages.remove(peerID)
    }

    func updatePrivateChatPeerIfNeeded() {
        updatePrivateChatPeerIfNeededCount += 1
    }

    func cleanupOldReadReceipts() {
        cleanupOldReadReceiptsCount += 1
    }

    // Peers & sessions
    var unifiedPeers: [BitchatPeer] = []
    var connectedMeshPeers: Set<PeerID> = []
    var reachableMeshPeers: Set<PeerID> = []
    var activeMeshPeerCountValue = 0
    private(set) var registeredEphemeralSessions: [PeerID] = []
    private(set) var updateEncryptionStatusForPeersCount = 0

    func isPeerConnected(_ peerID: PeerID) -> Bool { connectedMeshPeers.contains(peerID) }
    func isPeerReachable(_ peerID: PeerID) -> Bool { reachableMeshPeers.contains(peerID) }
    func activeMeshPeerCount() -> Int { activeMeshPeerCountValue }
    func registerEphemeralSession(peerID: PeerID) { registeredEphemeralSessions.append(peerID) }
    func updateEncryptionStatusForPeers() { updateEncryptionStatusForPeersCount += 1 }

    // Notifications
    private(set) var networkAvailableNotifications: [Int] = []

    func notifyNetworkAvailable(peerCount: Int) {
        networkAvailableNotifications.append(peerCount)
    }
}

// MARK: - Helpers

/// Lets the coordinator's internal `Task { @MainActor … }` hops run.
@MainActor
private func drainMainActorTasks() async {
    for _ in 0..<10 { await Task.yield() }
}

private func makeMessage(id: String, senderPeerID: PeerID? = nil) -> BitchatMessage {
    BitchatMessage(
        id: id,
        sender: "alice",
        content: "hello",
        timestamp: Date(),
        isRelay: false,
        isPrivate: true,
        recipientNickname: "me",
        senderPeerID: senderPeerID
    )
}

// MARK: - Coordinator Tests Against Mock Context

/// Exercises `ChatPeerListCoordinator` against `MockChatPeerListContext` with
/// no `ChatViewModel`.
struct ChatPeerListCoordinatorContextTests {

    @Test @MainActor
    func didUpdatePeerList_updatesConnectionSessionsAndEncryptionStatus() async {
        let context = MockChatPeerListContext()
        let coordinator = ChatPeerListCoordinator(context: context)
        let peerA = PeerID(str: "0011223344556677")
        let peerB = PeerID(str: "8899aabbccddeeff")
        context.isConnected = true

        // Empty list: disconnected, read-receipt hygiene still runs, no sessions.
        coordinator.didUpdatePeerList([])
        await drainMainActorTasks()
        #expect(!context.isConnected)
        #expect(context.cleanupOldReadReceiptsCount == 1)
        #expect(context.registeredEphemeralSessions.isEmpty)
        #expect(context.updateEncryptionStatusForPeersCount == 1)

        // Non-empty list: connected, every peer gets an ephemeral session.
        coordinator.didUpdatePeerList([peerA, peerB])
        await drainMainActorTasks()
        #expect(context.isConnected)
        #expect(context.registeredEphemeralSessions == [peerA, peerB])
        #expect(context.updateEncryptionStatusForPeersCount == 2)
        #expect(context.cleanupOldReadReceiptsCount == 2)
    }

    @Test @MainActor
    func didUpdatePeerList_refreshesPrivateChatPeerOnlyWhenSelectionIsTracked() async {
        let context = MockChatPeerListContext()
        let coordinator = ChatPeerListCoordinator(context: context)
        let peerID = PeerID(str: "0011223344556677")

        coordinator.didUpdatePeerList([peerID])
        await drainMainActorTasks()
        #expect(context.updatePrivateChatPeerIfNeededCount == 0)

        context.hasTrackedPrivateChatSelection = true
        coordinator.didUpdatePeerList([peerID])
        await drainMainActorTasks()
        #expect(context.updatePrivateChatPeerIfNeededCount == 1)
    }

    @Test @MainActor
    func didUpdatePeerList_removesStaleUnreadPeerIDsButKeepsBackedConversations() async {
        let context = MockChatPeerListContext()
        let coordinator = ChatPeerListCoordinator(context: context)

        let currentPeer = PeerID(str: "0011223344556677")
        let staleShortPeer = PeerID(str: "8899aabbccddeeff")
        let geoDMWithMessages = PeerID(str: "nostr_" + String(repeating: "ab", count: 8))
        let geoDMWithoutMessages = PeerID(str: "nostr_" + String(repeating: "cd", count: 8))
        let noiseKeyWithMessages = PeerID(str: String(repeating: "ef", count: 32))

        context.unifiedPeers = [
            BitchatPeer(
                peerID: currentPeer,
                noisePublicKey: Data(repeating: 0x01, count: 32),
                nickname: "alice"
            ),
        ]
        context.unreadPrivateMessages = [
            currentPeer,
            staleShortPeer,
            geoDMWithMessages,
            geoDMWithoutMessages,
            noiseKeyWithMessages,
        ]
        context.privateChats = [
            geoDMWithMessages: [makeMessage(id: "geo-1")],
            noiseKeyWithMessages: [makeMessage(id: "noise-1")],
        ]

        coordinator.didUpdatePeerList([currentPeer])
        await drainMainActorTasks()

        // Stale IDs without a backing conversation are dropped; geo-DM and
        // Noise-key IDs with stored messages survive, as does the live peer.
        #expect(context.unreadPrivateMessages == [currentPeer, geoDMWithMessages, noiseKeyWithMessages])
        #expect(context.cleanupOldReadReceiptsCount == 1)
    }

    @Test @MainActor
    func didUpdatePeerList_notifiesNetworkAvailableOncePerCooldownForNewMeshPeers() async {
        let context = MockChatPeerListContext()
        let coordinator = ChatPeerListCoordinator(context: context)
        let peerA = PeerID(str: "0011223344556677")
        let peerB = PeerID(str: "8899aabbccddeeff")
        context.connectedMeshPeers = [peerA, peerB]

        // First sighting of a mesh-active peer notifies with the mesh peer count.
        coordinator.didUpdatePeerList([peerA])
        await drainMainActorTasks()
        #expect(context.networkAvailableNotifications == [1])

        // The same peer again is not new — no repeat notification.
        coordinator.didUpdatePeerList([peerA])
        await drainMainActorTasks()
        #expect(context.networkAvailableNotifications == [1])

        // A genuinely new peer inside the cooldown window stays silent too.
        coordinator.didUpdatePeerList([peerA, peerB])
        await drainMainActorTasks()
        #expect(context.networkAvailableNotifications == [1])
    }

    @Test @MainActor
    func didUpdatePeerList_peerJoiningExistingMeshDoesNotNotify() async {
        // Cooldown zero so this proves the empty-transition gate alone — a
        // new peer joining while already meshed must stay silent even with
        // the cooldown long expired (the sitting-idle re-notify bug).
        let context = MockChatPeerListContext()
        let coordinator = ChatPeerListCoordinator(context: context, notificationCooldownSeconds: 0)
        let peerA = PeerID(str: "0011223344556677")
        let peerB = PeerID(str: "8899aabbccddeeff")
        context.connectedMeshPeers = [peerA, peerB]

        coordinator.didUpdatePeerList([peerA])
        await drainMainActorTasks()
        #expect(context.networkAvailableNotifications == [1])

        // peerB arrives while peerA is still connected: no notification.
        coordinator.didUpdatePeerList([peerA, peerB])
        await drainMainActorTasks()
        #expect(context.networkAvailableNotifications == [1])

        // Repeat events while idle keep staying silent.
        coordinator.didUpdatePeerList([peerA, peerB])
        await drainMainActorTasks()
        #expect(context.networkAvailableNotifications == [1])
    }

    @Test @MainActor
    func didUpdatePeerList_briefMeshFlapDoesNotRenotify() async {
        let context = MockChatPeerListContext()
        let coordinator = ChatPeerListCoordinator(context: context, notificationCooldownSeconds: 0)
        let peerA = PeerID(str: "0011223344556677")
        context.connectedMeshPeers = [peerA]

        coordinator.didUpdatePeerList([peerA])
        await drainMainActorTasks()
        #expect(context.networkAvailableNotifications == [1])

        // Link flap: empty list, then the peer returns before the 30s empty
        // confirmation fires — silent.
        coordinator.didUpdatePeerList([])
        await drainMainActorTasks()
        coordinator.didUpdatePeerList([peerA])
        await drainMainActorTasks()
        #expect(context.networkAvailableNotifications == [1])
    }

    @Test @MainActor
    func didUpdatePeerList_meshInactivePeersNeverNotify() async {
        let context = MockChatPeerListContext()
        let coordinator = ChatPeerListCoordinator(context: context)
        let peerA = PeerID(str: "0011223344556677")

        // Peer present but neither connected nor reachable: no notification.
        coordinator.didUpdatePeerList([peerA])
        await drainMainActorTasks()
        #expect(context.networkAvailableNotifications.isEmpty)
    }
}
