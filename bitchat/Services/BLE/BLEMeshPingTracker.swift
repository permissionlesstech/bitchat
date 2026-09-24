import BitFoundation
import Foundation

struct BLEMeshPingProbe {
    let peerID: PeerID
    let sentAt: Date
    let lifecycleGeneration: UInt64
    let completion: @MainActor (MeshPingResult?) -> Void
    let timeout: DispatchWorkItem
}

/// Engine-confined /ping diagnostics state: outstanding probes keyed by
/// their unguessable nonce, plus the inbound response budget.
///
/// The budget is keyed by the ingress link (the directly connected peer
/// that delivered the packet), never the packet-claimed sender: pings are
/// unsigned, so the claimed sender is attacker-controlled and rotating it
/// would reset the budget, turning a directed unencrypted probe into an
/// amplification primitive.
///
/// Pure state — the transport owns packet I/O, timers, and main-actor
/// completion delivery around it.
struct BLEMeshPingTracker {
    private var pendingProbes: [Data: BLEMeshPingProbe] = [:]
    private var responseLimiter = SyncResponseRateLimiter(
        maxResponses: TransportConfig.meshPingInboundMaxPerLink,
        window: TransportConfig.meshPingInboundWindowSeconds
    )

    mutating func register(_ probe: BLEMeshPingProbe, nonce: Data) {
        pendingProbes[nonce] = probe
    }

    /// Resolves a pong against its outstanding probe. The echoed nonce plus
    /// the sender check bind the reply to the probed peer.
    mutating func resolve(nonce: Data, from peerID: PeerID) -> BLEMeshPingProbe? {
        guard pendingProbes[nonce]?.peerID == peerID else { return nil }
        return pendingProbes.removeValue(forKey: nonce)
    }

    /// Removes a timed-out probe so its completion can fire once with nil.
    mutating func expire(nonce: Data) -> BLEMeshPingProbe? {
        pendingProbes.removeValue(forKey: nonce)
    }

    /// Whether an inbound ping delivered by this link is within budget.
    mutating func shouldRespond(toLink linkPeerID: PeerID, now: Date) -> Bool {
        responseLimiter.shouldRespond(to: linkPeerID, now: now)
    }

    /// Drops all probes and restores a fresh response budget (panic wipe).
    /// Returns the orphaned timeout work items for the caller to cancel.
    mutating func reset() -> [DispatchWorkItem] {
        let timeouts = pendingProbes.values.map(\.timeout)
        pendingProbes.removeAll()
        responseLimiter = SyncResponseRateLimiter(
            maxResponses: TransportConfig.meshPingInboundMaxPerLink,
            window: TransportConfig.meshPingInboundWindowSeconds
        )
        return timeouts
    }
}
