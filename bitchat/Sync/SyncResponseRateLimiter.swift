import BitFoundation
import Foundation

/// Sliding-window limiter for REQUEST_SYNC responses.
///
/// A single sync response can replay the entire gossip store, so a peer that
/// requests in a tight loop must not be able to drain the airtime and battery
/// of everyone in radio range. Legitimate peers send at most a few requests
/// per maintenance tick (one per type schedule, plus the initial sync).
struct SyncResponseRateLimiter {
    private let maxResponses: Int
    private let window: TimeInterval
    private var history: [PeerID: [Date]] = [:]

    init(maxResponses: Int, window: TimeInterval) {
        self.maxResponses = max(1, maxResponses)
        self.window = max(0, window)
    }

    /// Returns true (and records the response) if the peer is under its
    /// response budget for the current window.
    mutating func shouldRespond(to peerID: PeerID, now: Date) -> Bool {
        let cutoff = now.addingTimeInterval(-window)
        var recent = (history[peerID] ?? []).filter { $0 >= cutoff }
        guard recent.count < maxResponses else {
            history[peerID] = recent
            return false
        }
        recent.append(now)
        history[peerID] = recent
        return true
    }

    /// Drops history outside the window so departed peers don't accumulate.
    mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-window)
        history = history.compactMapValues { dates in
            let recent = dates.filter { $0 >= cutoff }
            return recent.isEmpty ? nil : recent
        }
    }
}
