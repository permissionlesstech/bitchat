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
        states[centralID] = State(
            lastAnnounceTime: now,
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
