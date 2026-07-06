import BitFoundation
import Foundation
import Testing
@testable import bitchat

@Suite("BLE route forwarding policy tests")
struct BLERouteForwardingPolicyTests {
    @Test("local recipient suppresses flood relay")
    func localRecipientSuppressesFloodRelay() {
        let local = peer("1111111111111111")
        let remote = peer("2222222222222222")
        let packet = makePacket(sender: remote, recipient: local)

        let plan = forwardingPlan(packet, local: local)

        #expect(plan.shouldSuppressFloodRelay)
        #expect(plan.forwardPacket == nil)
        #expect(plan.nextHop == nil)
    }

    @Test("unrouted packets are left for flood relay")
    func unroutedPacketAllowsFloodRelay() {
        let local = peer("1111111111111111")
        let remote = peer("2222222222222222")
        let packet = makePacket(sender: remote, recipient: peer("3333333333333333"), route: nil)

        let plan = forwardingPlan(packet, local: local)

        #expect(!plan.shouldSuppressFloodRelay)
        #expect(plan.forwardPacket == nil)
        #expect(plan.nextHop == nil)
    }

    @Test("origin forwards routed packet to first hop")
    func originForwardsToFirstHop() {
        let local = peer("1111111111111111")
        let firstHop = peer("2222222222222222")
        let destination = peer("3333333333333333")
        let packet = makePacket(sender: local, recipient: destination, ttl: 6, route: [routeData(firstHop)])

        let plan = forwardingPlan(packet, local: local, connected: [firstHop])

        #expect(plan.shouldSuppressFloodRelay)
        #expect(plan.nextHop == firstHop)
        #expect(plan.forwardPacket?.ttl == 5)
    }

    @Test("origin leaves packet for flood relay when first hop is unavailable")
    func originAllowsFloodWhenFirstHopUnavailable() {
        let local = peer("1111111111111111")
        let firstHop = peer("2222222222222222")
        let destination = peer("3333333333333333")
        let packet = makePacket(sender: local, recipient: destination, route: [routeData(firstHop)])

        let plan = forwardingPlan(packet, local: local, connected: [])

        #expect(!plan.shouldSuppressFloodRelay)
        #expect(plan.forwardPacket == nil)
        #expect(plan.nextHop == nil)
    }

    @Test("intermediate forwards routed packet to next route hop")
    func intermediateForwardsToNextHop() {
        let previous = peer("1111111111111111")
        let local = peer("2222222222222222")
        let nextHop = peer("3333333333333333")
        let destination = peer("4444444444444444")
        let packet = makePacket(
            sender: previous,
            recipient: destination,
            ttl: 4,
            route: [routeData(local), routeData(nextHop)]
        )

        let plan = forwardingPlan(packet, local: local, connected: [nextHop])

        #expect(plan.shouldSuppressFloodRelay)
        #expect(plan.nextHop == nextHop)
        #expect(plan.forwardPacket?.ttl == 3)
    }

    @Test("last intermediate forwards routed packet to destination")
    func lastIntermediateForwardsToDestination() {
        let previous = peer("1111111111111111")
        let local = peer("2222222222222222")
        let destination = peer("3333333333333333")
        let packet = makePacket(
            sender: previous,
            recipient: destination,
            ttl: 4,
            route: [routeData(local)]
        )

        let plan = forwardingPlan(packet, local: local, connected: [destination])

        #expect(plan.shouldSuppressFloodRelay)
        #expect(plan.nextHop == destination)
        #expect(plan.forwardPacket?.ttl == 3)
    }

    @Test("expired routed packets suppress further relay")
    func expiredRoutedPacketSuppressesRelay() {
        let local = peer("1111111111111111")
        let firstHop = peer("2222222222222222")
        let destination = peer("3333333333333333")
        let packet = makePacket(sender: local, recipient: destination, ttl: 1, route: [routeData(firstHop)])

        let plan = forwardingPlan(packet, local: local, connected: [firstHop])

        #expect(plan.shouldSuppressFloodRelay)
        #expect(plan.forwardPacket == nil)
        #expect(plan.nextHop == nil)
    }

    @Test("REQUEST_SYNC is never route-forwarded even with a route and TTL headroom")
    func requestSyncNeverRouteForwarded() {
        let previous = peer("1111111111111111")
        let local = peer("2222222222222222")
        let nextHop = peer("3333333333333333")
        let destination = peer("4444444444444444")
        var packet = makePacket(
            sender: previous,
            recipient: destination,
            ttl: 7,
            route: [routeData(local), routeData(nextHop)]
        )
        packet = BitchatPacket(
            type: MessageType.requestSync.rawValue,
            senderID: packet.senderID,
            recipientID: packet.recipientID,
            timestamp: packet.timestamp,
            payload: packet.payload,
            signature: nil,
            ttl: packet.ttl,
            route: packet.route
        )

        let plan = forwardingPlan(packet, local: local, connected: [nextHop])

        #expect(plan.shouldSuppressFloodRelay)
        #expect(plan.forwardPacket == nil)
        #expect(plan.nextHop == nil)
    }

    private func forwardingPlan(
        _ packet: BitchatPacket,
        local: PeerID,
        connected: Set<PeerID> = []
    ) -> BLERouteForwardingPlan {
        BLERouteForwardingPolicy.plan(
            for: packet,
            localPeerID: local,
            localRoutingData: local.routingData,
            routingPeer: PeerID.init(routingData:),
            isPeerConnected: { connected.contains($0) }
        )
    }

    private func makePacket(
        sender: PeerID,
        recipient: PeerID?,
        ttl: UInt8 = 7,
        route: [Data]? = []
    ) -> BitchatPacket {
        BitchatPacket(
            type: MessageType.noiseEncrypted.rawValue,
            senderID: routeData(sender),
            recipientID: recipient.map { routeData($0) },
            timestamp: 1,
            payload: Data([0x01, 0x02]),
            signature: nil,
            ttl: ttl,
            route: route
        )
    }

    private func peer(_ id: String) -> PeerID {
        PeerID(str: id)
    }

    private func routeData(_ peerID: PeerID) -> Data {
        peerID.routingData ?? Data()
    }
}
