import Foundation

enum BLESubscriptionAnnounceDecision: Equatable {
    case allowed
    case rateLimited(backoffSeconds: TimeInterval, attemptCount: Int, suppressAnnounce: Bool)
}

struct BLESubscriptionAnnounceLimiter {
    private struct State {
        var lastAnnounceTime: Date
        var attemptCount: Int
        var currentBackoffSeconds: TimeInterval
    }

    private var states: [String: State] = [:]

    var trackedCentralCount: Int {
        states.count
    }

    mutating func removeAll() {
        states.removeAll()
    }

    mutating func decision(for centralID: String, now: Date) -> BLESubscriptionAnnounceDecision {
        pruneStaleEntries(now: now)

        guard let existing = states[centralID] else {
            recordAllowedAttempt(for: centralID, now: now)
            return .allowed
        }

        let timeSinceLastAnnounce = now.timeIntervalSince(existing.lastAnnounceTime)
        guard timeSinceLastAnnounce < existing.currentBackoffSeconds else {
            recordAllowedAttempt(for: centralID, now: now)
            return .allowed
        }

        let newAttemptCount = existing.attemptCount + 1
        let newBackoff = min(
            existing.currentBackoffSeconds * TransportConfig.bleSubscriptionRateLimitBackoffFactor,
            TransportConfig.bleSubscriptionRateLimitMaxBackoffSeconds
        )
        // `lastAnnounceTime` deliberately keeps the time of the last *allowed*
        // announce. It is the reference for both the backoff and
        // `pruneStaleEntries`, so refreshing it on a rejection restarts the
        // tracking window on every attempt — a central resubscribing faster
        // than the maximum backoff could then never reach the window and
        // stayed suppressed for as long as it kept trying.
        states[centralID] = State(
            lastAnnounceTime: existing.lastAnnounceTime,
            attemptCount: newAttemptCount,
            currentBackoffSeconds: newBackoff
        )

        return .rateLimited(
            backoffSeconds: existing.currentBackoffSeconds,
            attemptCount: existing.attemptCount,
            suppressAnnounce: newAttemptCount >= TransportConfig.bleSubscriptionRateLimitMaxAttempts
        )
    }

    private mutating func recordAllowedAttempt(for centralID: String, now: Date) {
        states[centralID] = State(
            lastAnnounceTime: now,
            attemptCount: 1,
            currentBackoffSeconds: TransportConfig.bleSubscriptionRateLimitMinSeconds
        )
    }

    private mutating func pruneStaleEntries(now: Date) {
        let windowSeconds = TransportConfig.bleSubscriptionRateLimitWindowSeconds
        states = states.filter { _, state in
            now.timeIntervalSince(state.lastAnnounceTime) < windowSeconds
        }
    }
}
