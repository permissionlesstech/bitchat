//
// PrivateChatManagerTests.swift
// bitchatTests
//
// Tests for PrivateChatManager read receipt and selection behavior.
//

import Testing
import Foundation
@testable import bitchat

struct PrivateChatManagerTests {

    @Test @MainActor
    func startChat_setsSelectedAndClearsUnread() async {
        let transport = MockTransport()
        let manager = PrivateChatManager(meshService: transport)
        let peerID = PeerID(str: "00000000000000AA")

        manager.privateChats[peerID] = [
            BitchatMessage(
                id: "pm-1",
                sender: "Peer",
                content: "Hi",
                timestamp: Date(),
                isRelay: false,
                isPrivate: true,
                recipientNickname: "Me",
                senderPeerID: peerID
            )
        ]
        manager.unreadMessages.insert(peerID)

        manager.startChat(with: peerID)

        #expect(manager.selectedPeer == peerID)
        #expect(!manager.unreadMessages.contains(peerID))
        #expect(manager.privateChats[peerID] != nil)
    }

    @Test @MainActor
    func markAsRead_sendsReadReceiptViaRouter() async {
        let transport = MockTransport()
        let router = MessageRouter(transports: [transport])
        let manager = PrivateChatManager(meshService: transport)
        manager.messageRouter = router

        let peerID = PeerID(str: "00000000000000BB")
        transport.reachablePeers.insert(peerID)

        manager.privateChats[peerID] = [
            BitchatMessage(
                id: "pm-2",
                sender: "Peer",
                content: "Hi",
                timestamp: Date(),
                isRelay: false,
                isPrivate: true,
                recipientNickname: "Me",
                senderPeerID: peerID
            )
        ]
        manager.unreadMessages.insert(peerID)

        manager.markAsRead(from: peerID)
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(transport.sentReadReceipts.count == 1)
        #expect(manager.sentReadReceipts.contains("pm-2"))
        #expect(!manager.unreadMessages.contains(peerID))
    }

    @Test @MainActor
    func markAsRead_withoutRouterFallsBackToTransport() async {
        let transport = MockTransport()
        let manager = PrivateChatManager(meshService: transport)
        let peerID = PeerID(str: "00000000000000CC")

        manager.privateChats[peerID] = [
            BitchatMessage(
                id: "pm-fallback",
                sender: "Peer",
                content: "Hi",
                timestamp: Date(),
                isRelay: false,
                isPrivate: true,
                recipientNickname: "Me",
                senderPeerID: peerID
            )
        ]

        manager.markAsRead(from: peerID)

        #expect(transport.sentReadReceipts.count == 1)
        #expect(transport.sentReadReceipts.first?.receipt.originalMessageID == "pm-fallback")
    }

    @Test @MainActor
    func consolidateMessages_mergesStableNoiseKeyHistoryAndMarksUnread() async {
        let transport = MockTransport()
        let manager = PrivateChatManager(meshService: transport)
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

        manager.privateChats[stablePeerID] = [
            BitchatMessage(
                id: "stable-msg",
                sender: "Alice",
                content: "Hello from stable",
                timestamp: Date(),
                isRelay: false,
                isPrivate: true,
                recipientNickname: "Me",
                senderPeerID: stablePeerID
            )
        ]
        manager.unreadMessages.insert(stablePeerID)

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
        let manager = PrivateChatManager(meshService: transport)
        let peerID = PeerID(str: "0011223344556677")
        let tempPeerID = PeerID(nostr_: "0000000000000000000000000000000000000000000000000000000000000042")

        manager.privateChats[tempPeerID] = [
            BitchatMessage(
                id: "geo-msg",
                sender: "Alice",
                content: "Geo hello",
                timestamp: Date(),
                isRelay: false,
                isPrivate: true,
                recipientNickname: "Me",
                senderPeerID: tempPeerID
            )
        ]
        manager.unreadMessages.insert(tempPeerID)

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
        let manager = PrivateChatManager(meshService: transport)
        let peerID = PeerID(str: "00000000000000DD")

        manager.privateChats[peerID] = [
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

        var externalReceipts = Set<String>()
        manager.syncReadReceiptsForSentMessages(peerID: peerID, nickname: "Me", externalReceipts: &externalReceipts)

        #expect(externalReceipts == Set(["sent-read", "sent-delivered"]))
        #expect(manager.sentReadReceipts == Set(["sent-read", "sent-delivered"]))
    }

    @Test @MainActor
    func sanitizeChat_sortsChronologicallyAndKeepsLatestDuplicate() async {
        let transport = MockTransport()
        let manager = PrivateChatManager(meshService: transport)
        let peerID = PeerID(str: "00000000000000EE")
        let base = Date(timeIntervalSince1970: 10)

        manager.privateChats[peerID] = [
            BitchatMessage(
                id: "same",
                sender: "Peer",
                content: "Older",
                timestamp: base.addingTimeInterval(10),
                isRelay: false,
                isPrivate: true,
                recipientNickname: "Me",
                senderPeerID: peerID
            ),
            BitchatMessage(
                id: "first",
                sender: "Peer",
                content: "First",
                timestamp: base,
                isRelay: false,
                isPrivate: true,
                recipientNickname: "Me",
                senderPeerID: peerID
            ),
            BitchatMessage(
                id: "same",
                sender: "Peer",
                content: "Newest",
                timestamp: base.addingTimeInterval(20),
                isRelay: false,
                isPrivate: true,
                recipientNickname: "Me",
                senderPeerID: peerID
            )
        ]

        manager.sanitizeChat(for: peerID)

        #expect(manager.privateChats[peerID]?.map(\.id) == ["first", "same"])
        #expect(manager.privateChats[peerID]?.last?.content == "Newest")
    }
}
