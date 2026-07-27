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
    func markAsRead_sendsReadReceiptViaRouter() async {
        let transport = MockTransport()
        let router = MessageRouter(transports: [transport])
        let (manager, store) = Self.makeManager(transport: transport)
        manager.messageRouter = router

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
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(transport.sentReadReceipts.count == 1)
        #expect(manager.sentReadReceipts.contains("pm-2"))
        #expect(!manager.unreadMessages.contains(peerID))
    }

    @Test @MainActor
    func markAsRead_withoutRouterFallsBackToTransport() async {
        let transport = MockTransport()
        let (manager, store) = Self.makeManager(transport: transport)
        let peerID = PeerID(str: "00000000000000CC")

        store.append(
            BitchatMessage(
                id: "pm-fallback",
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

        manager.markAsRead(from: peerID)

        #expect(transport.sentReadReceipts.count == 1)
        #expect(transport.sentReadReceipts.first?.receipt.originalMessageID == "pm-fallback")
    }

    @Test @MainActor
    func markAsRead_calledTwiceSynchronously_routesOneReceiptPerMessage() async {
        // Regression: opening a chat runs two read scans in the same
        // synchronous MainActor stretch (beginPrivateChatSession and
        // markPrivateMessagesAsRead). The receipt must be claimed before the
        // routing task gets a chance to run, or both scans route a copy.
        let transport = MockTransport()
        let router = MessageRouter(transports: [transport])
        let (manager, store) = Self.makeManager(transport: transport)
        manager.messageRouter = router

        let peerID = PeerID(str: "00000000000000DE")
        transport.reachablePeers.insert(peerID)

        store.append(
            BitchatMessage(
                id: "pm-double",
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
        manager.markAsRead(from: peerID)
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(transport.sentReadReceipts.count == 1)
        #expect(manager.sentReadReceipts.contains("pm-double"))
    }

    @Test @MainActor
    func markAsRead_failedRouteReleasesClaimForRetry() async {
        // No reachable transport: the receipt is not sent, and the eager
        // claim must be released so a later read scan retries.
        let transport = MockTransport()
        let router = MessageRouter(transports: [transport])
        let (manager, store) = Self.makeManager(transport: transport)
        manager.messageRouter = router

        let peerID = PeerID(str: "00000000000000DF")

        store.append(
            BitchatMessage(
                id: "pm-unroutable",
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
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(transport.sentReadReceipts.isEmpty)
        #expect(!manager.sentReadReceipts.contains("pm-unroutable"))
    }

    @Test @MainActor
    func consolidateMessages_mergesStableNoiseKeyHistoryAndMarksUnread() async {
        let transport = MockTransport()
        let (manager, store) = Self.makeManager(transport: transport)
        let identityManager = MockIdentityManager(MockKeychain())
        let idBridge = NostrIdentityBridge(keychain: MockKeychainHelper())
        let unifiedPeerService = UnifiedPeerService(meshService: transport, idBridge: idBridge, identityManager: identityManager)
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

        let hadUnread = manager.consolidateMessages(for: peerID, peerNickname: "Alice", persistedReadReceipts: [])

        #expect(hadUnread)
        #expect(manager.privateChats[stablePeerID] == nil)
        #expect(manager.privateChats[peerID]?.count == 1)
        #expect(manager.privateChats[peerID]?.first?.senderPeerID == peerID)
        #expect(manager.unreadMessages.contains(peerID))
    }

    @Test @MainActor
    func consolidateMessages_movesTemporaryGeoDMHistoryByNickname() async {
        let transport = MockTransport()
        let (manager, store) = Self.makeManager(transport: transport)
        let peerID = PeerID(str: "0011223344556677")
        let tempPeerID = PeerID(nostr_: "0000000000000000000000000000000000000000000000000000000000000042")

        store.append(
            BitchatMessage(
                id: "geo-msg",
                sender: "Alice",
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

        let hadUnread = manager.consolidateMessages(for: peerID, peerNickname: "alice", persistedReadReceipts: [])

        #expect(hadUnread)
        #expect(manager.privateChats[tempPeerID] == nil)
        #expect(manager.privateChats[peerID]?.count == 1)
        #expect(manager.privateChats[peerID]?.first?.senderPeerID == peerID)
        #expect(manager.unreadMessages.contains(peerID))
        #expect(!manager.unreadMessages.contains(tempPeerID))
    }

    @Test @MainActor
    func syncReadReceiptsForSentMessages_onlyCopiesDeliveredAndRead() async {
        let transport = MockTransport()
        let (manager, store) = Self.makeManager(transport: transport)
        let peerID = PeerID(str: "00000000000000DD")

        let seeded = [
            BitchatMessage(
                id: "sent-read",
                sender: "Me",
                content: "One",
                timestamp: Date(),
                isRelay: false,
                isPrivate: true,
                recipientNickname: "Peer",
                senderPeerID: transport.myPeerID,
                deliveryStatus: .read(by: "Peer", at: Date())
            ),
            BitchatMessage(
                id: "sent-delivered",
                sender: "Me",
                content: "Two",
                timestamp: Date(),
                isRelay: false,
                isPrivate: true,
                recipientNickname: "Peer",
                senderPeerID: transport.myPeerID,
                deliveryStatus: .delivered(to: "Peer", at: Date())
            ),
            BitchatMessage(
                id: "sent-failed",
                sender: "Me",
                content: "Three",
                timestamp: Date(),
                isRelay: false,
                isPrivate: true,
                recipientNickname: "Peer",
                senderPeerID: transport.myPeerID,
                deliveryStatus: .failed(reason: "nope")
            )
        ]
        for message in seeded {
            store.append(message, to: .directPeer(peerID))
        }

        var externalReceipts = Set<String>()
        manager.syncReadReceiptsForSentMessages(peerID: peerID, nickname: "Me", externalReceipts: &externalReceipts)

        #expect(externalReceipts == Set(["sent-read", "sent-delivered"]))
        #expect(manager.sentReadReceipts == Set(["sent-read", "sent-delivered"]))
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
