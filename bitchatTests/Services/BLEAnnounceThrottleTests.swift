import Foundation
import Testing
@testable import bitchat

struct BLEAnnounceThrottleTests {
    @Test
    func firstAnnounceIsAllowed() {
        let throttle = BLEAnnounceThrottle(normalMinimumInterval: 10, forcedMinimumInterval: 2)

        let shouldSend = throttle.shouldSend(force: false, now: Date(timeIntervalSince1970: 100))

        #expect(shouldSend)
    }

    @Test
    func regularAnnounceUsesNormalMinimumInterval() {
        let now = Date(timeIntervalSince1970: 100)
        let throttle = BLEAnnounceThrottle(normalMinimumInterval: 10, forcedMinimumInterval: 2)

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
        let throttle = BLEAnnounceThrottle(normalMinimumInterval: 10, forcedMinimumInterval: 2)

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
        let throttle = BLEAnnounceThrottle(normalMinimumInterval: 10, forcedMinimumInterval: 2)

        _ = throttle.shouldSend(force: false, now: now)

        #expect(throttle.elapsed(since: now.addingTimeInterval(3)) == 3)
    }

    @Test
    func concurrentRequestsAdmitOnlyOneAnnounce() {
        let now = Date(timeIntervalSince1970: 100)
        let throttle = BLEAnnounceThrottle(
            normalMinimumInterval: 10,
            forcedMinimumInterval: 2
        )
        let accepted = LockedCounter()

        DispatchQueue.concurrentPerform(iterations: 1_000) { _ in
            if throttle.shouldSend(force: false, now: now) {
                accepted.increment()
            }
        }

        #expect(accepted.value == 1)
        #expect(throttle.elapsed(since: now.addingTimeInterval(3)) == 3)
    }

    @Test
    func resetForgetsThrottleDebtSoARotationAnnounceIsNeverSwallowed() {
        let throttle = BLEAnnounceThrottle(
            normalMinimumInterval: 1,
            forcedMinimumInterval: 1
        )
        let now = Date()
        #expect(throttle.shouldSend(force: true, now: now))
        // A panic inside the forced window would be throttled...
        #expect(!throttle.shouldSend(force: true, now: now.addingTimeInterval(0.2)))
        // ...so the rotation resets the debt and announces immediately.
        throttle.reset()
        #expect(throttle.shouldSend(force: true, now: now.addingTimeInterval(0.3)))
    }

    @Test
    func broadcastCountIsMonotonicAndSurvivesReset() {
        let throttle = BLEAnnounceThrottle(normalMinimumInterval: 10, forcedMinimumInterval: 2)
        #expect(throttle.broadcastCount == 0)

        throttle.noteBroadcast(claimingNeighbors: [])
        throttle.noteBroadcast(claimingNeighbors: [])
        #expect(throttle.broadcastCount == 2)

        // A panic reset must never make "nothing broadcast since this
        // snapshot" true for a snapshot taken before it.
        throttle.reset()
        #expect(throttle.broadcastCount == 2)
    }

    @Test
    func lastBroadcastOmitsOnlyNeighborsItDidNotClaim() {
        let throttle = BLEAnnounceThrottle()
        let alice = Data(repeating: 0xA1, count: 8)
        let bob = Data(repeating: 0xB0, count: 8)
        // Nothing broadcast yet: no neighbour is claimed.
        #expect(throttle.lastBroadcastOmits(alice))

        throttle.noteBroadcast(claimingNeighbors: [alice])
        #expect(!throttle.lastBroadcastOmits(alice))
        #expect(throttle.lastBroadcastOmits(bob))

        // Each broadcast replaces the claim.
        throttle.noteBroadcast(claimingNeighbors: [bob])
        #expect(throttle.lastBroadcastOmits(alice))
        #expect(!throttle.lastBroadcastOmits(bob))

        // A rotated identity has claimed no neighbours.
        throttle.reset()
        #expect(throttle.lastBroadcastOmits(bob))
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}
