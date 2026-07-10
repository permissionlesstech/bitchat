import BitFoundation
import Foundation

/// Decides whether an outbound directed packet should carry a v2 source
/// route. Pure gating logic so BLEService's hot send path stays a thin wire.
enum BLESourceRouteOriginationPolicy {
    /// Returns the intermediate-hop route to attach, or nil to keep the
    /// current flood/direct-write behavior unchanged.
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
    static func route(
        for packet: BitchatPacket,
        to recipient: PeerID,
        localPeerIDData: Data,
        isRecipientConnected: (PeerID) -> Bool,
        shouldAttemptRoute: (PeerID) -> Bool,
        computeRoute: (PeerID) -> [Data]?
    ) -> [Data]? {
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
