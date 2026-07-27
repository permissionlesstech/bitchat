import Foundation
import Testing
@testable import bitchat

struct BLEPeerPublishCoalescerTests {
    @Test
    func firstRequestPublishesImmediately() {
        var coalescer = BLEPeerPublishCoalescer(minimumInterval: 0.1)

        #expect(coalescer.requestPublish(now: Date(timeIntervalSince1970: 100)) == .publishNow)
    }

    @Test
    func rapidRequestSchedulesAfterRemainingInterval() {
        let now = Date(timeIntervalSince1970: 100)
        var coalescer = BLEPeerPublishCoalescer(minimumInterval: 0.1)

        _ = coalescer.requestPublish(now: now)

        if case .schedule(let delay) = coalescer.requestPublish(now: now.addingTimeInterval(0.04)) {
            #expect(abs(delay - 0.06) < 0.001)
        } else {
            Issue.record("Expected a scheduled publish")
        }
    }

    @Test
    func requestSkipsWhilePublishIsAlreadyPending() {
        let now = Date(timeIntervalSince1970: 100)
        var coalescer = BLEPeerPublishCoalescer(minimumInterval: 0.1)

        _ = coalescer.requestPublish(now: now)
        _ = coalescer.requestPublish(now: now.addingTimeInterval(0.04))

        #expect(coalescer.requestPublish(now: now.addingTimeInterval(0.05)) == .skip)
    }

    @Test
    func elapsedRequestPublishesImmediatelyEvenWithPendingPublish() {
        let now = Date(timeIntervalSince1970: 100)
        var coalescer = BLEPeerPublishCoalescer(minimumInterval: 0.1)

        _ = coalescer.requestPublish(now: now)
        _ = coalescer.requestPublish(now: now.addingTimeInterval(0.04))

        #expect(coalescer.requestPublish(now: now.addingTimeInterval(0.11)) == .publishNow)
    }

    @Test
    func scheduledPublishFiredClearsPendingState() {
        let now = Date(timeIntervalSince1970: 100)
        var coalescer = BLEPeerPublishCoalescer(minimumInterval: 0.1)

        _ = coalescer.requestPublish(now: now)
        _ = coalescer.requestPublish(now: now.addingTimeInterval(0.04))
        coalescer.scheduledPublishFired(now: now.addingTimeInterval(0.1))

        if case .schedule(let delay) = coalescer.requestPublish(now: now.addingTimeInterval(0.15)) {
            #expect(abs(delay - 0.05) < 0.001)
        } else {
            Issue.record("Expected a scheduled publish")
        }
    }
}
