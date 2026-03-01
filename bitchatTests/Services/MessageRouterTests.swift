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
    func flushOutbox_doesNotSetSentAtWhenTransportReturnsFalse() async {
        let peerID = PeerID(str: "000000000000000c")
        let transport = MockTransport()
        transport.connectedPeers.insert(peerID)
        transport.reachablePeers.insert(peerID)
        // Simulate BLE with no Noise session — transport queues internally
        transport.sendPrivateMessageResult = false

        let router = MessageRouter(transports: [transport])

        // Queue and flush — transport returns false
        router.sendPrivate("Hello", to: peerID, recipientNickname: "Peer", messageID: "m1")
        #expect(transport.sentPrivateMessages.count == 1, "Transport was called")
        #expect(router.pendingPeerIDs.count == 1, "Message stays in outbox")

        // Flush again — since sentAt was NOT set (transport returned false),
        // the message should be retried immediately (no cooldown)
        router.flushOutbox(for: peerID)
        #expect(transport.sentPrivateMessages.count == 2, "Message retried because sentAt was not set")

        // Now simulate Noise session established — transport returns true
        transport.sendPrivateMessageResult = true
        router.flushOutbox(for: peerID)
        #expect(transport.sentPrivateMessages.count == 3, "Message sent again")

        // Now message has sentAt set — cooldown should block immediate retry
        router.flushOutbox(for: peerID)
        #expect(transport.sentPrivateMessages.count == 3, "Cooldown blocks retry")
    }

    @Test @MainActor
    func sendPrivate_resetsCooldownForQueuedMessages() async {
        let peerID = PeerID(str: "000000000000000d")
        let transport = MockTransport()
        transport.connectedPeers.insert(peerID)
        transport.reachablePeers.insert(peerID)

        let router = MessageRouter(transports: [transport])

        // Send first message — sentAt is set (transport returns true by default)
        router.sendPrivate("M1", to: peerID, recipientNickname: "Peer", messageID: "m1")
        #expect(transport.sentPrivateMessages.count == 1)

        // Flushing again is blocked by cooldown
        router.flushOutbox(for: peerID)
        #expect(transport.sentPrivateMessages.count == 1)

        // User sends a second message — this should reset cooldown for M1
        // so both messages are sent in the same flush
        router.sendPrivate("M2", to: peerID, recipientNickname: "Peer", messageID: "m2")
        #expect(transport.sentPrivateMessages.count == 3, "Both M1 and M2 should be sent")
        #expect(transport.sentPrivateMessages[1].content == "M1", "M1 resent first")
        #expect(transport.sentPrivateMessages[2].content == "M2", "M2 sent second")
    }

    @Test @MainActor
    func flushAfterNoiseSession_sendsAllQueuedMessages() async {
        let peerID = PeerID(str: "000000000000000e")
        let transport = MockTransport()
        transport.connectedPeers.insert(peerID)
        // Simulate BLE before Noise handshake — transport queues internally
        transport.sendPrivateMessageResult = false

        let router = MessageRouter(transports: [transport])

        // Queue 3 messages while peer is connected but Noise isn't ready.
        // Each sendPrivate call triggers an internal flushOutbox which retries
        // all pending messages (sentAt stays nil because transport returns false).
        router.sendPrivate("M1", to: peerID, recipientNickname: "Peer", messageID: "m1")
        router.sendPrivate("M2", to: peerID, recipientNickname: "Peer", messageID: "m2")
        router.sendPrivate("M3", to: peerID, recipientNickname: "Peer", messageID: "m3")

        // All still pending (transport returned false every time)
        #expect(router.pendingPeerIDs.count == 1, "All still pending")
        let callsBeforeHandshake = transport.sentPrivateMessages.count

        // Simulate Noise handshake completing (didEstablishEncryptedSession path)
        transport.sendPrivateMessageResult = true
        router.resetSendState(for: peerID)
        router.flushOutbox(for: peerID)

        // All 3 messages should now be sent successfully
        let newCalls = transport.sentPrivateMessages.count - callsBeforeHandshake
        #expect(newCalls == 3, "All 3 sent after session established")

        // Verify order and content of the successful sends
        let successfulSends = transport.sentPrivateMessages.suffix(3)
        #expect(successfulSends[successfulSends.startIndex].content == "M1")
        #expect(successfulSends[successfulSends.startIndex + 1].content == "M2")
        #expect(successfulSends[successfulSends.startIndex + 2].content == "M3")

        // Confirm all deliveries
        router.confirmDelivery(messageID: "m1")
        router.confirmDelivery(messageID: "m2")
        router.confirmDelivery(messageID: "m3")
        #expect(router.pendingPeerIDs.isEmpty)
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
