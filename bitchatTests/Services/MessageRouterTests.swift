//
// MessageRouterTests.swift
// bitchatTests
//
// Tests for MessageRouter transport selection and outbox behavior.
//

import Testing
import Foundation
@testable import bitchat

struct MessageRouterTests {

    @Test @MainActor
    func sendPrivate_usesConnectedTransport() async {
        let peerID = PeerID(str: "0000000000000001")
        let transportA = MockTransport()
        let transportB = MockTransport()
        transportB.connectedPeers.insert(peerID)
        transportB.reachablePeers.insert(peerID)

        let router = MessageRouter(transports: [transportA, transportB])
        router.sendPrivate("Hello", to: peerID, recipientNickname: "Peer", messageID: "m1")

        #expect(transportA.sentPrivateMessages.isEmpty)
        #expect(transportB.sentPrivateMessages.count == 1)
    }

    @Test @MainActor
    func sendPrivate_queuesWhenNotConnected() async {
        let peerID = PeerID(str: "0000000000000002")
        let transport = MockTransport()
        // Peer is reachable (retention window) but NOT connected
        transport.reachablePeers.insert(peerID)

        let router = MessageRouter(transports: [transport])
        router.sendPrivate("Queued", to: peerID, recipientNickname: "Peer", messageID: "m2")

        // Should NOT send — peer is only reachable, not connected
        #expect(transport.sentPrivateMessages.isEmpty)
    }

    @Test @MainActor
    func sendPrivate_queuesThenFlushesOnReconnect() async {
        let peerID = PeerID(str: "0000000000000003")
        let transport = MockTransport()

        let router = MessageRouter(transports: [transport])
        router.sendPrivate("Queued", to: peerID, recipientNickname: "Peer", messageID: "m3")

        #expect(transport.sentPrivateMessages.isEmpty)

        // Peer connects — flush sends the queued message
        transport.connectedPeers.insert(peerID)
        transport.reachablePeers.insert(peerID)
        router.flushOutbox(for: peerID)

        #expect(transport.sentPrivateMessages.count == 1)

        // Flushing again should not re-send (within resend cooldown)
        router.flushOutbox(for: peerID)
        #expect(transport.sentPrivateMessages.count == 1)

        // Message stays in outbox until delivery is confirmed
        #expect(router.pendingPeerIDs.count == 1)

        // Confirm delivery removes from outbox
        router.confirmDelivery(messageID: "m3")
        #expect(router.pendingPeerIDs.isEmpty)
    }

    @Test @MainActor
    func sendPrivate_preservesOrderingWithPendingMessages() async {
        let peerID = PeerID(str: "0000000000000006")
        let transport = MockTransport()

        let router = MessageRouter(transports: [transport])

        // Queue M1 while peer is offline
        router.sendPrivate("M1", to: peerID, recipientNickname: "Peer", messageID: "m1")
        #expect(transport.sentPrivateMessages.isEmpty)

        // Peer comes online, but we send M2 before flush runs
        transport.connectedPeers.insert(peerID)
        transport.reachablePeers.insert(peerID)
        router.sendPrivate("M2", to: peerID, recipientNickname: "Peer", messageID: "m2")

        // Both should have been sent (M1 pending triggers flush which sends M1 and M2)
        #expect(transport.sentPrivateMessages.count == 2)
        #expect(transport.sentPrivateMessages[0].content == "M1", "M1 should be sent before M2")
        #expect(transport.sentPrivateMessages[1].content == "M2", "M2 should be sent after M1")
    }

    @Test @MainActor
    func pendingPeerIDs_reflectsOutboxState() async {
        let peer1 = PeerID(str: "0000000000000007")
        let peer2 = PeerID(str: "0000000000000008")
        let transport = MockTransport()

        let router = MessageRouter(transports: [transport])
        #expect(router.pendingPeerIDs.isEmpty)

        // Queue messages for two offline peers
        router.sendPrivate("Hello", to: peer1, recipientNickname: "P1", messageID: "m1")
        router.sendPrivate("Hello", to: peer2, recipientNickname: "P2", messageID: "m2")

        #expect(router.pendingPeerIDs.count == 2)

        // Connect peer1, flush, then confirm delivery
        transport.connectedPeers.insert(peer1)
        router.flushOutbox(for: peer1)
        router.confirmDelivery(messageID: "m1")

        #expect(router.pendingPeerIDs.count == 1)
        #expect(router.pendingPeerIDs.first == peer2)
    }

    @Test @MainActor
    func flushAllOutbox_sendsToAllConnectedPeers() async {
        let peer1 = PeerID(str: "0000000000000009")
        let peer2 = PeerID(str: "000000000000000a")
        let transport = MockTransport()

        let router = MessageRouter(transports: [transport])

        // Queue messages while both peers are offline
        router.sendPrivate("M1", to: peer1, recipientNickname: "P1", messageID: "m1")
        router.sendPrivate("M2", to: peer2, recipientNickname: "P2", messageID: "m2")

        #expect(transport.sentPrivateMessages.isEmpty)

        // Both peers reconnect
        transport.connectedPeers.insert(peer1)
        transport.connectedPeers.insert(peer2)
        router.flushAllOutbox()

        #expect(transport.sentPrivateMessages.count == 2)

        // Messages stay in outbox until confirmed
        #expect(router.pendingPeerIDs.count == 2)
        router.confirmDelivery(messageID: "m1")
        router.confirmDelivery(messageID: "m2")
        #expect(router.pendingPeerIDs.isEmpty)
    }

    @Test @MainActor
    func resetSendState_allowsResendOnReconnect() async {
        let peerID = PeerID(str: "000000000000000b")
        let transport = MockTransport()

        let router = MessageRouter(transports: [transport])

        // Queue and flush while connected
        transport.connectedPeers.insert(peerID)
        router.sendPrivate("Hello", to: peerID, recipientNickname: "Peer", messageID: "m1")
        #expect(transport.sentPrivateMessages.count == 1)

        // Immediate re-flush should NOT resend (within cooldown)
        router.flushOutbox(for: peerID)
        #expect(transport.sentPrivateMessages.count == 1)

        // Simulate reconnect: reset send state then flush
        router.resetSendState(for: peerID)
        router.flushOutbox(for: peerID)

        // Message should be resent
        #expect(transport.sentPrivateMessages.count == 2)
        #expect(transport.sentPrivateMessages[1].content == "Hello")
    }

    @Test @MainActor
    func sendReadReceipt_usesReachableTransport() async {
        let peerID = PeerID(str: "0000000000000004")
        let transport = MockTransport()
        transport.reachablePeers.insert(peerID)

        let router = MessageRouter(transports: [transport])
        let receipt = ReadReceipt(originalMessageID: "m4", readerID: transport.myPeerID, readerNickname: "Me")
        router.sendReadReceipt(receipt, to: peerID)

        #expect(transport.sentReadReceipts.count == 1)
    }

    @Test @MainActor
    func sendFavoriteNotification_usesConnectedOrReachable() async {
        let peerID = PeerID(str: "0000000000000005")
        let transport = MockTransport()
        transport.reachablePeers.insert(peerID)

        let router = MessageRouter(transports: [transport])
        router.sendFavoriteNotification(to: peerID, isFavorite: true)

        #expect(transport.sentFavoriteNotifications.count == 1)
    }
}
