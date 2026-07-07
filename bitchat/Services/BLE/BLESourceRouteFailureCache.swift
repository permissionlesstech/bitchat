import BitFoundation
import Foundation

/// Tracks whether source-routed sends to a recipient appear to be working.
///
/// A routed unicast rides exactly one path, so a broken hop silently loses the
/// packet where a flood would have healed around it. Rather than building a
/// retransmission machine (MessageRouter already retries at a higher layer),
/// this cache degrades: a routed send that sees no inbound traffic from the
/// recipient within the confirmation window marks the route as failed, and
/// subsequent sends fall back to flooding until the suppression TTL lapses.
struct BLESourceRouteFailureCache {
    struct Config {
        /// How long a routed send may go unconfirmed before it counts as a
        /// route failure.
        var confirmationWindowSeconds: TimeInterval = TransportConfig.bleSourceRouteConfirmationWindowSeconds
        /// How long to flood instead of routing after a failure.
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

    /// Whether the next directed send to `recipient` may carry a source
    /// route. Flips the recipient into suppression when the last routed send
    /// went unconfirmed past the confirmation window.
    mutating func shouldAttemptRoute(to recipient: PeerID, now: Date = Date()) -> Bool {
        guard var state = states[recipient] else { return true }

        if let until = state.suppressedUntil {
            guard now >= until else { return false }
            state.suppressedUntil = nil
        }

        if let pending = state.pendingSince,
           now.timeIntervalSince(pending) > config.confirmationWindowSeconds {
            // The routed send was never confirmed: treat the route as broken
            // and flood until the suppression window lapses.
            state.pendingSince = nil
            state.suppressedUntil = now.addingTimeInterval(config.suppressionSeconds)
            states[recipient] = state
            return false
        }

        states[recipient] = state
        return true
    }

    /// Records that a source-routed packet was sent to `recipient`. Keeps the
    /// earliest unconfirmed send so back-to-back packets share one deadline.
    mutating func noteRoutedSend(to recipient: PeerID, now: Date = Date()) {
        var state = states[recipient] ?? State()
        if state.pendingSince == nil {
            state.pendingSince = now
        }
        states[recipient] = state
    }

    /// Any inbound packet authored by `peer` confirms the pending routed send
    /// (delivery acks and replies arrive this way). Deliberately does not
    /// lift an active suppression: that traffic may have arrived via flood.
    mutating func noteInboundActivity(from peer: PeerID) {
        guard var state = states[peer] else { return }
        state.pendingSince = nil
        if state.suppressedUntil == nil {
            states.removeValue(forKey: peer)
        } else {
            states[peer] = state
        }
    }

    /// Drops entries that can no longer influence a routing decision. An
    /// expired-but-unconverted pending entry is kept for as long as the
    /// suppression it would trigger could still be active.
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
