import Foundation
import Testing
@testable import bitchat

@Suite("BLE subscription announce limiter tests")
struct BLESubscriptionAnnounceLimiterTests {
    @Test("first subscription is allowed and repeated subscriptions are rate limited")
    func repeatedSubscriptionsAreRateLimited() {
        var limiter = BLESubscriptionAnnounceLimiter()
        let centralID = "central-a"
        let now = Date(timeIntervalSince1970: 100)

        #expect(limiter.decision(for: centralID, now: now) == .allowed)
        #expect(limiter.trackedCentralCount == 1)

        let second = limiter.decision(for: centralID, now: now.addingTimeInterval(0.1))
        #expect(second == .rateLimited(
            backoffSeconds: TransportConfig.bleSubscriptionRateLimitMinSeconds,
            attemptCount: 1,
            suppressAnnounce: false
        ))
    }

    @Test("rapid subscription attempts eventually suppress announces")
    func rapidAttemptsSuppressAnnouncesAtThreshold() {
        var limiter = BLESubscriptionAnnounceLimiter()
        let centralID = "central-a"
        let now = Date(timeIntervalSince1970: 100)

        #expect(limiter.decision(for: centralID, now: now) == .allowed)

        var decision = BLESubscriptionAnnounceDecision.allowed
        for attempt in 2...TransportConfig.bleSubscriptionRateLimitMaxAttempts {
            decision = limiter.decision(
                for: centralID,
                now: now.addingTimeInterval(Double(attempt) * 0.01)
            )
        }

        if case let .rateLimited(_, _, suppressAnnounce) = decision {
            #expect(suppressAnnounce)
        } else {
            Issue.record("Expected rate-limited decision at suppression threshold")
        }
    }

    @Test("stale limiter entries are pruned on the next decision")
    func staleEntriesArePruned() {
        var limiter = BLESubscriptionAnnounceLimiter()
        let staleCentralID = "central-a"
        let freshCentralID = "central-b"
        let now = Date(timeIntervalSince1970: 100)

        #expect(limiter.decision(for: staleCentralID, now: now) == .allowed)
        #expect(limiter.trackedCentralCount == 1)

        let afterWindow = now.addingTimeInterval(TransportConfig.bleSubscriptionRateLimitWindowSeconds + 1)
        #expect(limiter.decision(for: freshCentralID, now: afterWindow) == .allowed)
        #expect(limiter.trackedCentralCount == 1)
    }

    @Test("a central that keeps resubscribing recovers once the backoff elapses")
    func flappingCentralRecoversAfterBackoff() {
        // A legitimate central whose BLE link flaps resubscribes faster than the
        // maximum backoff. Every rejection used to refresh `lastAnnounceTime`,
        // which is the reference for both the backoff and `pruneStaleEntries`,
        // so the elapsed time never grew: the central stayed suppressed for as
        // long as it kept trying. It must instead be re-admitted once the
        // capped backoff has passed since its last *allowed* announce.
        var limiter = BLESubscriptionAnnounceLimiter()
        let centralID = "central-flapping"
        let start = Date(timeIntervalSince1970: 1_000)

        #expect(limiter.decision(for: centralID, now: start) == .allowed)

        let maxBackoff = TransportConfig.bleSubscriptionRateLimitMaxBackoffSeconds
        var admittedAt: Double?
        for step in stride(from: 1.0, through: maxBackoff * 2, by: 1.0) {
            if limiter.decision(for: centralID, now: start.addingTimeInterval(step)) == .allowed {
                admittedAt = step
                break
            }
        }

        #expect(admittedAt != nil, "a central that keeps trying must eventually be re-admitted")
        if let admittedAt {
            #expect(admittedAt >= maxBackoff, "re-admitted early at +\(admittedAt)s")
        }
    }

    @Test("a hammering central is still held off for the whole backoff")
    func flappingCentralIsNotAdmittedEarly() {
        // The counterpart: relaxing the reference timestamp must not let a
        // hammering central back in before the capped backoff has elapsed.
        var limiter = BLESubscriptionAnnounceLimiter()
        let centralID = "central-flapping"
        let start = Date(timeIntervalSince1970: 2_000)
        let maxBackoff = TransportConfig.bleSubscriptionRateLimitMaxBackoffSeconds

        #expect(limiter.decision(for: centralID, now: start) == .allowed)

        for step in stride(from: 1.0, to: maxBackoff, by: 1.0) {
            let decision = limiter.decision(for: centralID, now: start.addingTimeInterval(step))
            #expect(decision != .allowed, "admitted early at +\(step)s")
        }
    }
}
