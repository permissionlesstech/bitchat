//
// PrivateChatManagerTests.swift
// bitchatTests
//
// Tests for PrivateChatManager read receipt and selection behavior.
// Message storage lives in the single-writer ConversationStore; the
// manager's privateChats/unreadMessages are derived views over it.
//

import Testing
import Foundation
import BitFoundation
@testable import bitchat

struct PrivateChatManagerTests {

    @MainActor
    private static func makeManager(transport: MockTransport) -> (PrivateChatManager, ConversationStore) {
        let store = ConversationStore()
        let manager = PrivateChatManager(meshService: transport, conversationStore: store)
        return (manager, store)
    }

    @Test @MainActor
    func startChat_setsSelectedAndClearsUnread() async {
        let transport = MockTransport()
        let (manager, store) = Self.makeManager(transport: transport)
        let peerID = PeerID(str: "00000000000000AA")

        store.append(
            BitchatMessage(
                id: "pm-1",
                sender: "Peer",
                content: "Hi",
                timestamp: Date(),
                isRelay: false,
                isPrivate: true,
                recipientNickname: "Me",
                senderPeerID: peerID
            ),
            to: .directPeer(peerID)
        )
        store.markUnread(.directPeer(peerID))

        manager.startChat(with: peerID)

        #expect(manager.selectedPeer == peerID)
        #expect(!manager.unreadMessages.contains(peerID))
        #expect(manager.privateChats[peerID] != nil)
    }

    @Test @MainActor
    func markAsRead_clearsUnreadWithoutSendingDuplicateReceipts() async {
        // Read-receipt routing is owned solely by ChatLifecycleCoordinator;
        // PrivateChatManager only clears the unread badge so opening a chat
        // never emits duplicate receipts from two independent tracking sets.
        let transport = MockTransport()
        let (manager, store) = Self.makeManager(transport: transport)

        let peerID = PeerID(str: "00000000000000BB")
        transport.reachablePeers.insert(peerID)

        store.append(
            BitchatMessage(
                id: "pm-2",
                sender: "Peer",
                content: "Hi",
                timestamp: Date(),
                isRelay: false,
                isPrivate: true,
                recipientNickname: "Me",
                senderPeerID: peerID
            ),
            to: .directPeer(peerID)
        )
        store.markUnread(.directPeer(peerID))

        manager.markAsRead(from: peerID)

        #expect(transport.sentReadReceipts.isEmpty)
        #expect(!manager.unreadMessages.contains(peerID))
    }

    @Test @MainActor
    func consolidateMessages_mergesStableNoiseKeyHistoryAndMarksUnread() async {
        let transport = MockTransport()
        let (manager, store) = Self.makeManager(transport: transport)
        let identityManager = MockIdentityManager(MockKeychain())
        let unifiedPeerService = UnifiedPeerService(meshService: transport, identityManager: identityManager)
        manager.unifiedPeerService = unifiedPeerService

        let peerID = PeerID(str: "0123456789abcdef")
        let noiseKey = Data((0..<32).map(UInt8.init))
        let stablePeerID = PeerID(hexData: noiseKey)

        transport.updatePeerSnapshots([
            TransportPeerSnapshot(
                peerID: peerID,
                nickname: "Alice",
                isConnected: true,
                noisePublicKey: noiseKey,
                lastSeen: Date()
            )
        ])
        try? await Task.sleep(nanoseconds: 50_000_000)

        store.append(
            BitchatMessage(
                id: "stable-msg",
                sender: "Alice",
                content: "Hello from stable",
                timestamp: Date(),
                isRelay: false,
                isPrivate: true,
                recipientNickname: "Me",
                senderPeerID: stablePeerID
            ),
            to: .directPeer(stablePeerID)
        )
        store.markUnread(.directPeer(stablePeerID))

        let hadUnread = manager.consolidateMessages(for: peerID, persistedReadReceipts: [])

        #expect(hadUnread)
        #expect(manager.privateChats[stablePeerID] == nil)
        #expect(manager.privateChats[peerID]?.count == 1)
        #expect(manager.privateChats[peerID]?.first?.senderPeerID == peerID)
        #expect(manager.unreadMessages.contains(peerID))
    }

    @Test @MainActor
    func consolidateMessages_stableKeyHistoryKeepsMyRowsMine() async throws {
        // A row sent locally while the peer was offline sits in the stable-key
        // chat. Folding that chat must not re-attribute it to the peer.
        let transport = MockTransport()
        transport.myPeerID = PeerID(str: "a1b2c3d4e5f60718")
        let (manager, store) = Self.makeManager(transport: transport)
        let identityManager = MockIdentityManager(MockKeychain())
        let unifiedPeerService = UnifiedPeerService(meshService: transport, identityManager: identityManager)
        manager.unifiedPeerService = unifiedPeerService

        let peerID = PeerID(str: "0123456789abcdef")
        let noiseKey = Data((0..<32).map(UInt8.init))
        let stablePeerID = PeerID(hexData: noiseKey)
        transport.updatePeerSnapshots([
            TransportPeerSnapshot(peerID: peerID, nickname: "Alice", isConnected: true, noisePublicKey: noiseKey, lastSeen: Date())
        ])
        let peerResolved = await TestHelpers.waitUntil(
            { unifiedPeerService.getPeer(by: peerID)?.noisePublicKey == noiseKey },
            timeout: TestConstants.settleTimeout
        )
        try #require(peerResolved)

        for (id, sender) in [("mine", transport.myPeerID), ("theirs", stablePeerID)] {
            store.append(
                BitchatMessage(id: id, sender: "Alice", content: id, timestamp: Date(), isRelay: false,
                               isPrivate: true, recipientNickname: "Alice", senderPeerID: sender),
                to: .directPeer(stablePeerID)
            )
        }

        _ = manager.consolidateMessages(for: peerID, persistedReadReceipts: [])

        let joined = manager.privateChats[peerID] ?? []
        #expect(joined.first { $0.id == "mine" }?.senderPeerID == transport.myPeerID)
        #expect(joined.first { $0.id == "theirs" }?.senderPeerID == peerID)
    }

    @Test @MainActor
    func consolidateMessages_keepsGeoDMHistoryAndUnreadWithItsSender() async {
        let transport = MockTransport()
        let (manager, store) = Self.makeManager(transport: transport)
        let peerID = PeerID(str: "0011223344556677")
        let tempPeerID = PeerID(nostr_: "0000000000000000000000000000000000000000000000000000000000000042")

        transport.peerNicknames[peerID] = "anon#0042"

        store.append(
            BitchatMessage(
                id: "geo-msg",
                sender: "anon#0042",
                content: "Geo hello",
                timestamp: Date(),
                isRelay: false,
                isPrivate: true,
                recipientNickname: "Me",
                senderPeerID: tempPeerID
            ),
            to: .directPeer(tempPeerID)
        )
        store.markUnread(.directPeer(tempPeerID))

        let hadUnread = manager.consolidateMessages(for: peerID, persistedReadReceipts: [])

        #expect(!hadUnread)
        #expect(manager.privateChats[peerID] == nil)
        #expect(manager.privateChats[tempPeerID]?.count == 1)
        #expect(manager.privateChats[tempPeerID]?.first?.senderPeerID == tempPeerID)
        #expect(!manager.unreadMessages.contains(peerID))
        #expect(manager.unreadMessages.contains(tempPeerID))
    }

    @Test @MainActor
    func consolidateMessages_leavesMyGeoDMThreadOutOfANamesakesChat() async {
        // My geo DMs carry my plain nickname (sendGeohashDM), so a thread of
        // my rows matches any mesh peer who shares that nickname, though my
        // rows say nothing about who the thread is with. Folded into the
        // namesake's chat, my thread with a geohash stranger would send a
        // reply typed there to the namesake.
        let transport = MockTransport()
        transport.myPeerID = PeerID(str: "a1b2c3d4e5f60718")
        let (manager, store) = Self.makeManager(transport: transport)
        let namesakePeerID = PeerID(str: "0011223344556677")
        let tempPeerID = PeerID(nostr_: String(repeating: "42", count: 32))

        store.append(
            BitchatMessage(
                id: "my-geo-dm",
                sender: "alice",
                content: "hi from the geohash",
                timestamp: Date(),
                isRelay: false,
                isPrivate: true,
                recipientNickname: "alice",
                senderPeerID: transport.myPeerID,
                deliveryStatus: .delivered(to: "alice", at: Date())
            ),
            to: .directPeer(tempPeerID)
        )

        _ = manager.consolidateMessages(for: namesakePeerID, persistedReadReceipts: [])

        // The thread stays where it is, my row still mine...
        #expect(manager.privateChats[tempPeerID]?.map(\.id) == ["my-geo-dm"])
        #expect(manager.privateChats[tempPeerID]?.first?.senderPeerID == transport.myPeerID)
        // ...and no thread with the namesake appears.
        #expect(manager.privateChats[namesakePeerID] == nil)

        // Opening the namesake's chat sends no read receipts.
        manager.markAsRead(from: namesakePeerID)
        #expect(transport.sentReadReceipts.isEmpty)
    }

    @Test @MainActor
    func consolidateMessages_keepsBothGeoDMThreadsWithoutIdentityProof() async {
        // Matching display names do not identify either geohash thread as
        // belonging to this mesh peer.
        let transport = MockTransport()
        transport.myPeerID = PeerID(str: "a1b2c3d4e5f60718")
        let (manager, store) = Self.makeManager(transport: transport)
        let peerID = PeerID(str: "0011223344556677")
        let myThread = PeerID(nostr_: String(repeating: "42", count: 32))
        let theirThread = PeerID(nostr_: String(repeating: "43", count: 32))

        store.append(
            BitchatMessage(
                id: "my-geo-dm",
                sender: "alice",
                content: "hi from the geohash",
                timestamp: Date(),
                isRelay: false,
                isPrivate: true,
                recipientNickname: "alice",
                senderPeerID: transport.myPeerID,
                deliveryStatus: .sent
            ),
            to: .directPeer(myThread)
        )
        store.append(
            BitchatMessage(
                id: "their-geo-dm",
                sender: "alice",
                content: "hi from them",
                timestamp: Date(),
                isRelay: false,
                isPrivate: true,
                recipientNickname: "alice",
                senderPeerID: theirThread
            ),
            to: .directPeer(theirThread)
        )
        store.markUnread(.directPeer(theirThread))

        let hadUnread = manager.consolidateMessages(for: peerID, persistedReadReceipts: [])

        #expect(!hadUnread)
        #expect(manager.privateChats[theirThread]?.map(\.id) == ["their-geo-dm"])
        #expect(manager.privateChats[theirThread]?.first?.senderPeerID == theirThread)
        #expect(manager.privateChats[peerID] == nil)
        #expect(manager.unreadMessages.contains(theirThread))
        #expect(!manager.unreadMessages.contains(peerID))
        #expect(manager.privateChats[myThread]?.map(\.id) == ["my-geo-dm"])
    }

    @Test @MainActor
    func consolidateMessages_leavesAThreadWithMyRepliesOutOfANamesakesChat() async {
        // One row of mine is enough, not a thread of only mine: their rows
        // and my replies all read "alice", so the nickname check alone would
        // fold the thread, my replies with it.
        let transport = MockTransport()
        transport.myPeerID = PeerID(str: "a1b2c3d4e5f60718")
        let (manager, store) = Self.makeManager(transport: transport)
        let namesakePeerID = PeerID(str: "0011223344556677")
        let thread = PeerID(nostr_: String(repeating: "44", count: 32))

        store.append(
            BitchatMessage(
                id: "their-geo-dm",
                sender: "alice",
                content: "hi from them",
                timestamp: Date().addingTimeInterval(-60),
                isRelay: false,
                isPrivate: true,
                recipientNickname: "alice",
                senderPeerID: thread
            ),
            to: .directPeer(thread)
        )
        store.append(
            BitchatMessage(
                id: "my-reply",
                sender: "alice",
                content: "hi back",
                timestamp: Date(),
                isRelay: false,
                isPrivate: true,
                recipientNickname: "alice",
                senderPeerID: transport.myPeerID,
                deliveryStatus: .sent
            ),
            to: .directPeer(thread)
        )

        _ = manager.consolidateMessages(for: namesakePeerID, persistedReadReceipts: [])

        #expect(manager.privateChats[thread]?.map(\.id) == ["their-geo-dm", "my-reply"])
        #expect(manager.privateChats[namesakePeerID] == nil)
    }

    /// The store replaces `sanitizeChat`: inserts keep chronological order,
    /// duplicate IDs are rejected on append, and `upsertByID` replaces the
    /// stored message with the latest copy in place.
    @Test @MainActor
    func store_keepsChronologicalOrderAndDedupsByID() async {
        let transport = MockTransport()
        let (manager, store) = Self.makeManager(transport: transport)
        let peerID = PeerID(str: "00000000000000EE")
        let base = Date(timeIntervalSince1970: 10)

        func message(_ id: String, _ content: String, offset: TimeInterval) -> BitchatMessage {
            BitchatMessage(
                id: id,
                sender: "Peer",
                content: content,
                timestamp: base.addingTimeInterval(offset),
                isRelay: false,
                isPrivate: true,
                recipientNickname: "Me",
                senderPeerID: peerID
            )
        }

        #expect(store.append(message("same", "Older", offset: 10), to: .directPeer(peerID)))
        // Out-of-order arrival is inserted in timestamp order.
        #expect(store.append(message("first", "First", offset: 0), to: .directPeer(peerID)))
        // Duplicate ID is rejected on append…
        #expect(!store.append(message("same", "Newest", offset: 20), to: .directPeer(peerID)))
        // …and replaced in place by upsert.
        store.upsertByID(message("same", "Newest", offset: 20), in: .directPeer(peerID))

        #expect(manager.privateChats[peerID]?.map(\.id) == ["first", "same"])
        #expect(manager.privateChats[peerID]?.last?.content == "Newest")
    }
}
