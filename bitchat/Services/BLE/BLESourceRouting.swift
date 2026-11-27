import BitFoundation
import Foundation

// MARK: - Source-Route Origination

/// Decides whether an outbound directed packet should carry a v2 source route.
enum BLESourceRouteOriginationPolicy {
    static func route(
        for packet: BitchatPacket,
        to recipient: PeerID,
        localPeerIDData: Data,
        isRecipientConnected: (PeerID) -> Bool,
        shouldAttemptRoute: (PeerID) -> Bool,
        computeRoute: (PeerID) -> [Data]?
    ) -> [Data]? {
        guard packet.route == nil,
              packet.type != MessageType.fragment.rawValue else { return nil }
        guard packet.senderID == localPeerIDData else { return nil }
        guard let recipientData = packet.recipientID,
              recipientData.count == 8,
              !recipientData.allSatisfy({ $0 == 0xFF }) else { return nil }
        guard packet.ttl > 1 else { return nil }
        guard !isRecipientConnected(recipient) else { return nil }
        guard shouldAttemptRoute(recipient) else { return nil }
        guard let route = computeRoute(recipient), !route.isEmpty else { return nil }
        return route
    }
}

// MARK: - Source-Route Failure Suppression

/// Tracks whether source-routed sends to a recipient appear to be working,
/// falling back to flooding when a routed send goes unconfirmed.
struct BLESourceRouteFailureCache {
    struct Config {
        var confirmationWindowSeconds: TimeInterval = TransportConfig.bleSourceRouteConfirmationWindowSeconds
        var suppressionSeconds: TimeInterval = TransportConfig.bleSourceRouteSuppressionSeconds
    }

    private struct State {
        var pendingSince: Date?
        var suppressedUntil: Date?
    }

    private let config: Config
    private var states: [PeerID: State] = [:]

    init(config: Config = Config()) {
        self.config = config
    }

    mutating func shouldAttemptRoute(to recipient: PeerID, now: Date = Date()) -> Bool {
        guard var state = states[recipient] else { return true }

        if let until = state.suppressedUntil {
            guard now >= until else { return false }
            state.suppressedUntil = nil
        }

        if let pending = state.pendingSince,
           now.timeIntervalSince(pending) > config.confirmationWindowSeconds {
            state.pendingSince = nil
            state.suppressedUntil = now.addingTimeInterval(config.suppressionSeconds)
            states[recipient] = state
            return false
        }

        states[recipient] = state
        return true
    }

    mutating func noteRoutedSend(to recipient: PeerID, now: Date = Date()) {
        var state = states[recipient] ?? State()
        if state.pendingSince == nil {
            state.pendingSince = now
        }
        states[recipient] = state
    }

    mutating func noteInboundActivity(from peer: PeerID) {
        guard var state = states[peer] else { return }
        state.pendingSince = nil
        if state.suppressedUntil == nil {
            states.removeValue(forKey: peer)
        } else {
            states[peer] = state
        }
    }

    mutating func prune(now: Date = Date()) {
        let pendingRetention = config.confirmationWindowSeconds + config.suppressionSeconds
        states = states.filter { _, state in
            if let until = state.suppressedUntil, now < until { return true }
            if let pending = state.pendingSince,
               now.timeIntervalSince(pending) <= pendingRetention {
                return true
            }
            return false
        }
    }
}

// MARK: - Source-Route Forwarding

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
        if packet.type == MessageType.requestSync.rawValue {
            return .suppressFloodRelay
        }

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
