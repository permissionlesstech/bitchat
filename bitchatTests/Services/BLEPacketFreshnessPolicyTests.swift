import Foundation
import Testing
@testable import bitchat

struct BLEPacketFreshnessPolicyTests {
    @Test
    func nilRecipientCountsAsBroadcast() {
        #expect(BLEPacketFreshnessPolicy.isBroadcastRecipient(nil))
    }

    @Test
    func allOnesEightByteRecipientCountsAsBroadcast() {
        #expect(BLEPacketFreshnessPolicy.isBroadcastRecipient(Data(repeating: 0xFF, count: 8)))
    }

    @Test
    func directedRecipientIsNotBroadcast() {
        #expect(!BLEPacketFreshnessPolicy.isBroadcastRecipient(Data([0, 1, 2, 3, 4, 5, 6, 7])))
    }

    @Test
    func recentPacketIsNotStale() {
        let now = Date(timeIntervalSince1970: 1000)
        let timestamp = UInt64((now.timeIntervalSince1970 - 100) * 1000)

        #expect(!BLEPacketFreshnessPolicy.isStale(timestampMilliseconds: timestamp, now: now))
    }

    @Test
    func oldPacketIsStale() {
        let now = Date(timeIntervalSince1970: 1000)
        let timestamp = UInt64((now.timeIntervalSince1970 - 901) * 1000)

        #expect(BLEPacketFreshnessPolicy.isStale(timestampMilliseconds: timestamp, now: now))
    }

    @Test
    func futurePacketAgeIsZero() {
        let now = Date(timeIntervalSince1970: 1000)
        let timestamp = UInt64((now.timeIntervalSince1970 + 10) * 1000)

        #expect(BLEPacketFreshnessPolicy.ageSeconds(timestampMilliseconds: timestamp, now: now) == 0)
    }
}
