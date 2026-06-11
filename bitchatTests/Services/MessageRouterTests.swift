//
// MessageRouterTests.swift
// bitchatTests
//
// Tests for MessageRouter transport selection and outbox behavior.
//

import Testing
import Foundation
import BitFoundation
@testable import bitchat

struct MessageRouterTests {

    @Test @MainActor
    func sendPrivate_usesReachableTransport() async {
        let peerID = PeerID(str: "0000000000000001")
        let transportA = MockTransport()
        let transportB = MockTransport()
        transportB.reachablePeers.insert(peerID)

        let router = MessageRouter(transports: [transportA, transportB])
        router.sendPrivate("Hello", to: peerID, recipientNickname: "Peer", messageID: "m1")

        #expect(transportA.sentPrivateMessages.isEmpty)
        #expect(transportB.sentPrivateMessages.count == 1)
    }

    @Test @MainActor
    func sendPrivate_queuesThenFlushesWhenReachable() async {
        let peerID = PeerID(str: "0000000000000002")
        let transport = MockTransport()

        let router = MessageRouter(transports: [transport])
        router.sendPrivate("Queued", to: peerID, recipientNickname: "Peer", messageID: "m2")

        #expect(transport.sentPrivateMessages.isEmpty)

        transport.reachablePeers.insert(peerID)
        router.flushOutbox(for: peerID)

        #expect(transport.sentPrivateMessages.count == 1)
    }

    @Test @MainActor
    func sendPrivate_prefersConnectedTransportOverEarlierReachableOne() async {
        let peerID = PeerID(str: "0000000000000005")
        let reachableOnly = MockTransport()
        reachableOnly.reachablePeers.insert(peerID)
        let connected = MockTransport()
        connected.connectedPeers.insert(peerID)
        connected.reachablePeers.insert(peerID)

        let router = MessageRouter(transports: [reachableOnly, connected])
        router.sendPrivate("Hello", to: peerID, recipientNickname: "Peer", messageID: "m5")

        #expect(reachableOnly.sentPrivateMessages.isEmpty)
        #expect(connected.sentPrivateMessages.count == 1)
    }

    @Test @MainActor
    func sendPrivate_reachableOnlySendRetainsUntilDeliveryAck() async {
        let peerID = PeerID(str: "0000000000000006")
        let transport = MockTransport()
        transport.reachablePeers.insert(peerID)

        let router = MessageRouter(transports: [transport])
        router.sendPrivate("Hello", to: peerID, recipientNickname: "Peer", messageID: "m6")
        #expect(transport.sentPrivateMessages.count == 1)

        // No ack yet: a flush retries over the weak signal.
        router.flushOutbox(for: peerID)
        #expect(transport.sentPrivateMessages.count == 2)

        // Ack clears the retained copy; later flushes stop resending.
        router.markDelivered("m6")
        router.flushOutbox(for: peerID)
        #expect(transport.sentPrivateMessages.count == 2)
    }

    @Test @MainActor
    func sendPrivate_connectedSendIsNotRetained() async {
        let peerID = PeerID(str: "0000000000000007")
        let transport = MockTransport()
        transport.connectedPeers.insert(peerID)
        transport.reachablePeers.insert(peerID)

        let router = MessageRouter(transports: [transport])
        router.sendPrivate("Hello", to: peerID, recipientNickname: "Peer", messageID: "m7")
        #expect(transport.sentPrivateMessages.count == 1)

        router.flushOutbox(for: peerID)
        #expect(transport.sentPrivateMessages.count == 1)
    }

    @Test @MainActor
    func flushOutbox_dropsUnackedMessageAfterAttemptCap() async {
        let peerID = PeerID(str: "0000000000000008")
        let transport = MockTransport()
        transport.reachablePeers.insert(peerID)

        let router = MessageRouter(transports: [transport])
        router.sendPrivate("Hello", to: peerID, recipientNickname: "Peer", messageID: "m8")

        for _ in 0..<10 {
            router.flushOutbox(for: peerID)
        }

        // Initial send plus capped resends; never unbounded.
        #expect(transport.sentPrivateMessages.count == 8)
    }

    @Test @MainActor
    func sendReadReceipt_usesReachableTransport() async {
        let peerID = PeerID(str: "0000000000000003")
        let transport = MockTransport()
        transport.reachablePeers.insert(peerID)

        let router = MessageRouter(transports: [transport])
        let receipt = ReadReceipt(originalMessageID: "m3", readerID: transport.myPeerID, readerNickname: "Me")
        router.sendReadReceipt(receipt, to: peerID)

        #expect(transport.sentReadReceipts.count == 1)
    }

    @Test @MainActor
    func sendFavoriteNotification_routesThroughOutboxAsPrivateMessage() async {
        let peerID = PeerID(str: "0000000000000004")
        let transport = MockTransport()
        transport.reachablePeers.insert(peerID)

        let router = MessageRouter(transports: [transport])
        router.sendFavoriteNotification(to: peerID, isFavorite: true)

        // Favorites now ride the outbox (sendPrivate) so they survive offline /
        // handshake gaps; the recipient parses the `[FAVORITED]` prefix.
        #expect(transport.sentPrivateMessages.count == 1)
        #expect(transport.sentPrivateMessages.first?.content.hasPrefix("[FAVORITED]") == true)
    }

    @Test @MainActor
    func sendFavoriteNotification_whileOffline_queuesAndFlushesOnReconnect() async {
        let peerID = PeerID(str: "0000000000000009")
        let transport = MockTransport()
        // Peer is neither connected nor reachable: the favorite must be retained.
        let router = MessageRouter(transports: [transport])
        router.sendFavoriteNotification(to: peerID, isFavorite: false)
        #expect(transport.sentPrivateMessages.isEmpty)

        // Peer comes back: the queued favorite flushes.
        transport.connectedPeers.insert(peerID)
        router.flushOutbox(for: peerID)
        #expect(transport.sentPrivateMessages.count == 1)
        #expect(transport.sentPrivateMessages.first?.content.hasPrefix("[UNFAVORITED]") == true)
    }
}
