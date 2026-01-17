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
}
