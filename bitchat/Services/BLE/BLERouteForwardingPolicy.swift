import BitFoundation
import Foundation

struct BLERouteForwardingPlan {
    let shouldSuppressFloodRelay: Bool
    let forwardPacket: BitchatPacket?
    let nextHop: PeerID?
    let isSourceRouteFallback: Bool

    init(
        shouldSuppressFloodRelay: Bool,
        forwardPacket: BitchatPacket?,
        nextHop: PeerID?,
        isSourceRouteFallback: Bool = false
    ) {
        self.shouldSuppressFloodRelay = shouldSuppressFloodRelay
        self.forwardPacket = forwardPacket
        self.nextHop = nextHop
        self.isSourceRouteFallback = isSourceRouteFallback
    }

    static let allowFloodRelay = BLERouteForwardingPlan(
        shouldSuppressFloodRelay: false,
        forwardPacket: nil,
        nextHop: nil,
        isSourceRouteFallback: false
    )

    static let fallbackToFloodRelay = BLERouteForwardingPlan(
        shouldSuppressFloodRelay: false,
        forwardPacket: nil,
        nextHop: nil,
        isSourceRouteFallback: true
    )

    static let suppressFloodRelay = BLERouteForwardingPlan(
        shouldSuppressFloodRelay: true,
        forwardPacket: nil,
        nextHop: nil,
        isSourceRouteFallback: false
    )

    static func forward(_ packet: BitchatPacket, to nextHop: PeerID) -> BLERouteForwardingPlan {
        BLERouteForwardingPlan(
            shouldSuppressFloodRelay: true,
            forwardPacket: packet,
            nextHop: nextHop,
            isSourceRouteFallback: false
        )
    }
}

struct BLERouteForwardingPolicy {
    static func plan(
        for packet: BitchatPacket,
        localPeerID: PeerID,
        localRoutingData: Data?,
        routingPeer: (Data) -> PeerID?,
        isPeerConnected: (PeerID) -> Bool
    ) -> BLERouteForwardingPlan {
        // REQUEST_SYNC is link-local: never forward it, on the flood path or
        // the source-routed path. A crafted request with a route and TTL
        // headroom must not be able to fan a full-store replay out to the next
        // hop. Suppressing here also short-circuits the flood relay.
        if packet.type == MessageType.requestSync.rawValue {
            return .suppressFloodRelay
        }

        if PeerID(hexData: packet.recipientID) == localPeerID {
            return .suppressFloodRelay
        }

        guard let route = packet.route, !route.isEmpty else {
            return .allowFloodRelay
        }

        // Guard against routing loops caused by duplicate hops in the route list.
        if Set(route).count < route.count {
            return .suppressFloodRelay
        }

        guard packet.ttl > 1 else {
            return .suppressFloodRelay
        }

        guard let localRoutingData else {
            return .fallbackToFloodRelay
        }

        guard let localIndex = route.firstIndex(of: localRoutingData) else {
            return forward(packet, toRouteData: route[0], routingPeer: routingPeer, isPeerConnected: isPeerConnected)
        }

        if localIndex == route.count - 1 {
            guard let destinationPeer = PeerID(hexData: packet.recipientID),
                  isPeerConnected(destinationPeer) else {
                return .fallbackToFloodRelay
            }
            return .forward(relayed(packet), to: destinationPeer)
        }

        return forward(
            packet,
            toRouteData: route[localIndex + 1],
            routingPeer: routingPeer,
            isPeerConnected: isPeerConnected
        )
    }

    private static func forward(
        _ packet: BitchatPacket,
        toRouteData routeData: Data,
        routingPeer: (Data) -> PeerID?,
        isPeerConnected: (PeerID) -> Bool
    ) -> BLERouteForwardingPlan {
        guard let nextPeer = routingPeer(routeData),
              isPeerConnected(nextPeer) else {
            return .fallbackToFloodRelay
        }

        return .forward(relayed(packet), to: nextPeer)
    }

    private static func relayed(_ packet: BitchatPacket) -> BitchatPacket {
        var relayPacket = packet
        relayPacket.ttl = packet.ttl - 1
        return relayPacket
    }
}
