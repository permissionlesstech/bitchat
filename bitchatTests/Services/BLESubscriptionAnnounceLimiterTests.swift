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
}
