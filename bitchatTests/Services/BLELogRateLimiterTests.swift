import Foundation
import Testing
@testable import bitchat

@Suite("BLE log rate limiter tests")
struct BLELogRateLimiterTests {
    @Test("repeated log keys are suppressed until the default interval elapses")
    func suppressesRepeatedKeysUntilIntervalElapses() {
        let limiter = BLELogRateLimiter(defaultMinimumInterval: 5)
        let now = Date(timeIntervalSince1970: 100)

        #expect(limiter.shouldLog(key: "ready:peer-a", now: now))
        #expect(!limiter.shouldLog(key: "ready:peer-a", now: now.addingTimeInterval(4.9)))
        #expect(limiter.shouldLog(key: "ready:peer-a", now: now.addingTimeInterval(5)))
    }

    @Test("different log keys are tracked independently")
    func tracksKeysIndependently() {
        let limiter = BLELogRateLimiter(defaultMinimumInterval: 5)
        let now = Date(timeIntervalSince1970: 100)

        #expect(limiter.shouldLog(key: "ready:peer-a", now: now))
        #expect(limiter.shouldLog(key: "ready:peer-b", now: now))
        #expect(!limiter.shouldLog(key: "ready:peer-a", now: now.addingTimeInterval(1)))
    }

    @Test("call sites can override the default interval")
    func supportsPerCallIntervals() {
        let limiter = BLELogRateLimiter(defaultMinimumInterval: 5)
        let now = Date(timeIntervalSince1970: 100)

        #expect(limiter.shouldLog(key: "self-loopback", now: now, minimumInterval: 30))
        #expect(!limiter.shouldLog(key: "self-loopback", now: now.addingTimeInterval(29), minimumInterval: 30))
        #expect(limiter.shouldLog(key: "self-loopback", now: now.addingTimeInterval(30), minimumInterval: 30))
    }
}
