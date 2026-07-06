import BitFoundation
import Foundation

/// Decides whether an outbound directed packet should carry a v2 source
/// route. Pure gating logic so BLEService's hot send path stays a thin wire.
enum BLESourceRouteOriginationPolicy {
    /// Why a packet kept flood/direct-write behavior instead of routing.
    /// The `rawValue` doubles as the greppable `[ROUTE]` log reason.
    enum FloodReason: String {
        case relayedNotOriginator = "not originator"
        case broadcast = "broadcast recipient"
        case noTTLHeadroom = "link-local ttl"
        case recipientDirect = "recipient direct"
        case routeSuppressed = "route suppressed→flood"
        case noPath = "no v2 path"
    }

    /// The routing decision for an originated packet.
    enum Decision: Equatable {
        /// Keep flood/direct-write behavior unchanged; carries the reason.
        case flood(FloodReason)
        /// Originate a v2 source route over these intermediate hops.
        case route([Data])
    }

    /// Returns whether to originate a v2 source route (with its hops) or keep
    /// flood/direct-write, with the reason for the latter.
    ///
    /// Routes are only originated when every gate passes:
    /// - we authored the packet (relays must not rewrite and re-sign someone
    ///   else's packet; route-following for in-flight routed packets lives in
    ///   `BLERouteForwardingPolicy`),
    /// - the packet is directed at a single peer (not broadcast),
    /// - the packet has TTL headroom to traverse hops (link-local TTL-0
    ///   packets like REQUEST_SYNC never route),
    /// - the recipient is not directly connected (a direct write already
    ///   delivers in one hop),
    /// - routing to the recipient is not suppressed by a recent unconfirmed
    ///   routed send, and
    /// - the topology yields a complete path.
    static func decide(
        for packet: BitchatPacket,
        to recipient: PeerID,
        localPeerIDData: Data,
        isRecipientConnected: (PeerID) -> Bool,
        shouldAttemptRoute: (PeerID) -> Bool,
        computeRoute: (PeerID) -> [Data]?
    ) -> Decision {
        guard packet.senderID == localPeerIDData else { return .flood(.relayedNotOriginator) }
        guard let recipientData = packet.recipientID,
              recipientData.count == 8,
              !recipientData.allSatisfy({ $0 == 0xFF }) else { return .flood(.broadcast) }
        guard packet.ttl > 1 else { return .flood(.noTTLHeadroom) }
        guard !isRecipientConnected(recipient) else { return .flood(.recipientDirect) }
        guard shouldAttemptRoute(recipient) else { return .flood(.routeSuppressed) }
        guard let route = computeRoute(recipient), !route.isEmpty else { return .flood(.noPath) }
        return .route(route)
    }
}
