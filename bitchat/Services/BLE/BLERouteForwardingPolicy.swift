import BitFoundation
import Foundation

struct BLERouteForwardingPlan {
    let shouldSuppressFloodRelay: Bool
    let forwardPacket: BitchatPacket?
    let nextHop: PeerID?

    static let allowFloodRelay = BLERouteForwardingPlan(
        shouldSuppressFloodRelay: false,
        forwardPacket: nil,
        nextHop: nil
    )

    static let suppressFloodRelay = BLERouteForwardingPlan(
        shouldSuppressFloodRelay: true,
        forwardPacket: nil,
        nextHop: nil
    )

    static func forward(_ packet: BitchatPacket, to nextHop: PeerID) -> BLERouteForwardingPlan {
        BLERouteForwardingPlan(
            shouldSuppressFloodRelay: true,
            forwardPacket: packet,
            nextHop: nextHop
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
        if PeerID(hexData: packet.recipientID) == localPeerID {
            return .suppressFloodRelay
        }

        guard let route = packet.route, !route.isEmpty else {
            return .allowFloodRelay
        }

        guard packet.ttl > 1 else {
            return .suppressFloodRelay
        }

        guard let localRoutingData else {
            return .allowFloodRelay
        }

        guard let localIndex = route.firstIndex(of: localRoutingData) else {
            return forward(packet, toRouteData: route[0], routingPeer: routingPeer, isPeerConnected: isPeerConnected)
        }

        if localIndex == route.count - 1 {
            guard let destinationPeer = PeerID(hexData: packet.recipientID),
                  isPeerConnected(destinationPeer) else {
                return .allowFloodRelay
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
            return .allowFloodRelay
        }

        return .forward(relayed(packet), to: nextPeer)
    }

    private static func relayed(_ packet: BitchatPacket) -> BitchatPacket {
        var relayPacket = packet
        relayPacket.ttl = packet.ttl - 1
        return relayPacket
    }
}
