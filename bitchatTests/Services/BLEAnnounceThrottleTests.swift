import Foundation
import Testing
@testable import bitchat

struct BLEAnnounceThrottleTests {
    @Test
    func firstAnnounceIsAllowed() {
        var throttle = BLEAnnounceThrottle(normalMinimumInterval: 10, forcedMinimumInterval: 2)

        let shouldSend = throttle.shouldSend(force: false, now: Date(timeIntervalSince1970: 100))

        #expect(shouldSend)
    }

    @Test
    func regularAnnounceUsesNormalMinimumInterval() {
        let now = Date(timeIntervalSince1970: 100)
        var throttle = BLEAnnounceThrottle(normalMinimumInterval: 10, forcedMinimumInterval: 2)

        let first = throttle.shouldSend(force: false, now: now)
        let suppressed = throttle.shouldSend(force: false, now: now.addingTimeInterval(9.9))
        let afterInterval = throttle.shouldSend(force: false, now: now.addingTimeInterval(10))

        #expect(first)
        #expect(!suppressed)
        #expect(afterInterval)
    }

    @Test
    func forcedAnnounceUsesShorterMinimumInterval() {
        let now = Date(timeIntervalSince1970: 100)
        var throttle = BLEAnnounceThrottle(normalMinimumInterval: 10, forcedMinimumInterval: 2)

        let first = throttle.shouldSend(force: false, now: now)
        let suppressed = throttle.shouldSend(force: true, now: now.addingTimeInterval(1.9))
        let afterInterval = throttle.shouldSend(force: true, now: now.addingTimeInterval(2))

        #expect(first)
        #expect(!suppressed)
        #expect(afterInterval)
    }

    @Test
    func elapsedReportsTimeSinceAcceptedSend() {
        let now = Date(timeIntervalSince1970: 100)
        var throttle = BLEAnnounceThrottle(normalMinimumInterval: 10, forcedMinimumInterval: 2)

        _ = throttle.shouldSend(force: false, now: now)

        #expect(throttle.elapsed(since: now.addingTimeInterval(3)) == 3)
    }
}
