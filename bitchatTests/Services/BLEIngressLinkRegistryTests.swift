import Foundation
import Testing
import BitFoundation
@testable import bitchat

struct BLEIngressLinkRegistryTests {
    @Test
    func recordIfNewSuppressesDuplicateWithinLifetime() {
        var registry = BLEIngressLinkRegistry()
        let packet = makePacket(sender: PeerID(str: "1122334455667788"), timestamp: 1)
        let peer = PeerID(str: "1122334455667788")
        let now = Date()

        let firstRecord = registry.recordIfNew(packet, link: .central("central-a"), peerID: peer, now: now, lifetime: 3.0)
        let duplicateRecord = registry.recordIfNew(packet, link: .peripheral("peripheral-b"), peerID: peer, now: now.addingTimeInterval(1.0), lifetime: 3.0)

        #expect(firstRecord)
        #expect(!duplicateRecord)
        #expect(registry.link(for: packet) == .central("central-a"))
        #expect(registry.peerID(for: packet) == peer)
    }

    @Test
    func recordIfNewAllowsExpiredDuplicateAndUpdatesLink() {
        var registry = BLEIngressLinkRegistry()
        let packet = makePacket(sender: PeerID(str: "1122334455667788"), timestamp: 1)
        let peer = PeerID(str: "1122334455667788")
        let now = Date()

        let firstRecord = registry.recordIfNew(packet, link: .central("central-a"), peerID: peer, now: now, lifetime: 3.0)
        let expiredRecord = registry.recordIfNew(packet, link: .peripheral("peripheral-b"), peerID: peer, now: now.addingTimeInterval(4.0), lifetime: 3.0)

        #expect(firstRecord)
        #expect(expiredRecord)
        #expect(registry.link(for: packet) == .peripheral("peripheral-b"))
        #expect(registry.peerID(for: packet) == peer)
    }

    @Test
    func pruneRemovesExpiredIngressLinks() {
        var registry = BLEIngressLinkRegistry()
        let packet = makePacket(sender: PeerID(str: "1122334455667788"), timestamp: 1)
        let peer = PeerID(str: "1122334455667788")
        let now = Date()

        let firstRecord = registry.recordIfNew(packet, link: .central("central-a"), peerID: peer, now: now, lifetime: 3.0)
        #expect(firstRecord)
        registry.prune(before: now.addingTimeInterval(4.0))

        #expect(registry.isEmpty)
        #expect(registry.link(for: packet) == nil)
        #expect(registry.peerID(for: packet) == nil)
    }

    @Test
    func packetContextRejectsSelfLoopback() {
        let localPeer = PeerID(str: "1122334455667788")
        let packet = makePacket(sender: localPeer, timestamp: 1)

        let result = BLEIngressLinkRegistry.packetContext(
            for: packet,
            claimedSenderID: localPeer,
            boundPeerID: nil,
            localPeerID: localPeer,
            directAnnounceTTL: 7
        )

        #expect(result == .failure(.selfLoopback(packetType: MessageType.message.rawValue)))
    }

    @Test
    func packetContextAllowsRelayedSenderOnBoundLink() throws {
        let localPeer = PeerID(str: "0011223344556677")
        let boundPeer = PeerID(str: "1122334455667788")
        let relayedSender = PeerID(str: "8899aabbccddeeff")
        let packet = makePacket(sender: relayedSender, timestamp: 1)

        let context = try #require(trySuccess(BLEIngressLinkRegistry.packetContext(
            for: packet,
            claimedSenderID: relayedSender,
            boundPeerID: boundPeer,
            localPeerID: localPeer,
            directAnnounceTTL: 7
        )))

        #expect(context.receivedFromPeerID == boundPeer)
        #expect(context.validationPeerID == relayedSender)
    }

    @Test
    func packetContextRejectsDirectAnnounceMismatchOnBoundLink() {
        let localPeer = PeerID(str: "0011223344556677")
        let boundPeer = PeerID(str: "1122334455667788")
        let claimedPeer = PeerID(str: "8899aabbccddeeff")
        let packet = makeAnnouncePacket(sender: claimedPeer, ttl: 7)

        let result = BLEIngressLinkRegistry.packetContext(
            for: packet,
            claimedSenderID: claimedPeer,
            boundPeerID: boundPeer,
            localPeerID: localPeer,
            directAnnounceTTL: 7
        )

        #expect(result == .failure(.directSenderMismatch(boundPeerID: boundPeer, claimedSenderID: claimedPeer)))
    }

    @Test
    func packetContextUsesBoundPeerForRSRValidation() throws {
        let localPeer = PeerID(str: "0011223344556677")
        let boundPeer = PeerID(str: "1122334455667788")
        let relayedSender = PeerID(str: "8899aabbccddeeff")
        var packet = makePacket(sender: relayedSender, timestamp: 1)
        packet.isRSR = true

        let context = try #require(trySuccess(BLEIngressLinkRegistry.packetContext(
            for: packet,
            claimedSenderID: relayedSender,
            boundPeerID: boundPeer,
            localPeerID: localPeer,
            directAnnounceTTL: 7
        )))

        #expect(context.receivedFromPeerID == boundPeer)
        #expect(context.validationPeerID == boundPeer)
    }

    @Test
    func packetContextAllowsSelfAuthoredRSRWithTTLZeroFromBoundPeer() throws {
        let localPeer = PeerID(str: "0011223344556677")
        let boundPeer = PeerID(str: "1122334455667788")
        var packet = makePacket(sender: localPeer, timestamp: 1)
        packet.isRSR = true
        packet.ttl = 0

        let context = try #require(trySuccess(BLEIngressLinkRegistry.packetContext(
            for: packet,
            claimedSenderID: localPeer,
            boundPeerID: boundPeer,
            localPeerID: localPeer,
            directAnnounceTTL: 7
        )))

        #expect(context.receivedFromPeerID == boundPeer)
        #expect(context.validationPeerID == boundPeer)
    }
}

private func makePacket(sender: PeerID, timestamp: UInt64) -> BitchatPacket {
    BitchatPacket(
        type: MessageType.message.rawValue,
        senderID: Data(hexString: sender.id) ?? Data(),
        recipientID: nil,
        timestamp: timestamp,
        payload: Data("hello".utf8),
        signature: nil,
        ttl: 3
    )
}

private func makeAnnouncePacket(sender: PeerID, ttl: UInt8) -> BitchatPacket {
    BitchatPacket(
        type: MessageType.announce.rawValue,
        senderID: Data(hexString: sender.id) ?? Data(),
        recipientID: nil,
        timestamp: 1,
        payload: Data(),
        signature: nil,
        ttl: ttl
    )
}

private func trySuccess(_ result: Result<BLEIngressPacketContext, BLEIngressRejection>) -> BLEIngressPacketContext? {
    guard case .success(let context) = result else {
        return nil
    }
    return context
}
