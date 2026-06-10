//
// MessageRateLimiterTests.swift
// bitchatTests
//
// Ensures public-message rate limiter state remains bounded for attacker-derived keys.
//

import Foundation
import Testing
@testable import bitchat

struct MessageRateLimiterTests {
    @Test("Content buckets do not grow when sender is rate limited")
    func contentBucketsDoNotGrowAfterSenderLimit() {
        var limiter = MessageRateLimiter(
            senderCapacity: 1,
            senderRefillPerSec: 0,
            contentCapacity: 1,
            contentRefillPerSec: 0,
            maxSenderBuckets: 10,
            maxContentBuckets: 10,
            bucketIdleTTL: 60
        )
        let now = Date()

        #expect(limiter.allow(senderKey: "sender", contentKey: "content-0", now: now))
        for index in 1...100 {
            #expect(!limiter.allow(senderKey: "sender", contentKey: "content-\(index)", now: now))
        }

        #expect(limiter.bucketCountsForTesting.sender == 1)
        #expect(limiter.bucketCountsForTesting.content == 1)
    }

    @Test("Bucket maps evict entries at configured caps")
    func bucketMapsEvictAtConfiguredCaps() {
        let maxEntries = 3
        var limiter = MessageRateLimiter(
            senderCapacity: 1,
            senderRefillPerSec: 0,
            contentCapacity: 1,
            contentRefillPerSec: 0,
            maxSenderBuckets: maxEntries,
            maxContentBuckets: maxEntries,
            bucketIdleTTL: 60
        )
        let now = Date()

        for index in 0..<25 {
            #expect(limiter.allow(senderKey: "sender-\(index)", contentKey: "content-\(index)", now: now.addingTimeInterval(TimeInterval(index))))
        }

        #expect(limiter.bucketCountsForTesting.sender == maxEntries)
        #expect(limiter.bucketCountsForTesting.content == maxEntries)
    }
}
