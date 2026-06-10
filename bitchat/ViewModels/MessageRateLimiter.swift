//
// MessageRateLimiter.swift
// bitchat
//
// Handles per-sender and per-content token buckets for public message intake.
//

import Foundation

struct MessageRateLimiter {
    private struct TokenBucket {
        var capacity: Double
        var tokens: Double
        var refillPerSec: Double
        var lastRefill: Date

        mutating func allow(cost: Double = 1.0, now: Date = Date()) -> Bool {
            let dt = now.timeIntervalSince(lastRefill)
            if dt > 0 {
                tokens = min(capacity, tokens + dt * refillPerSec)
                lastRefill = now
            }
            if tokens >= cost {
                tokens -= cost
                return true
            }
            return false
        }

        func isIdle(since now: Date, idleTTL: TimeInterval) -> Bool {
            now.timeIntervalSince(lastRefill) >= idleTTL
        }
    }

    private var senderBuckets: [String: TokenBucket] = [:]
    private var contentBuckets: [String: TokenBucket] = [:]

    private let senderCapacity: Double
    private let senderRefill: Double
    private let contentCapacity: Double
    private let contentRefill: Double
    private let maxSenderBuckets: Int
    private let maxContentBuckets: Int
    private let bucketIdleTTL: TimeInterval

    init(
        senderCapacity: Double,
        senderRefillPerSec: Double,
        contentCapacity: Double,
        contentRefillPerSec: Double,
        maxSenderBuckets: Int = TransportConfig.uiSenderRateBucketMaxEntries,
        maxContentBuckets: Int = TransportConfig.uiContentRateBucketMaxEntries,
        bucketIdleTTL: TimeInterval = TransportConfig.uiRateBucketIdleTTL
    ) {
        self.senderCapacity = senderCapacity
        self.senderRefill = senderRefillPerSec
        self.contentCapacity = contentCapacity
        self.contentRefill = contentRefillPerSec
        self.maxSenderBuckets = max(1, maxSenderBuckets)
        self.maxContentBuckets = max(1, maxContentBuckets)
        self.bucketIdleTTL = bucketIdleTTL
    }

    mutating func allow(senderKey: String, contentKey: String, now: Date = Date()) -> Bool {
        var senderBucket = bucket(
            for: senderKey,
            in: &senderBuckets,
            capacity: senderCapacity,
            refillPerSec: senderRefill,
            maxBuckets: maxSenderBuckets,
            now: now
        )
        let senderAllowed = senderBucket.allow(now: now)
        senderBuckets[senderKey] = senderBucket
        guard senderAllowed else { return false }

        var contentBucket = bucket(
            for: contentKey,
            in: &contentBuckets,
            capacity: contentCapacity,
            refillPerSec: contentRefill,
            maxBuckets: maxContentBuckets,
            now: now
        )
        let contentAllowed = contentBucket.allow(now: now)
        contentBuckets[contentKey] = contentBucket

        return contentAllowed
    }

    mutating func reset() {
        senderBuckets.removeAll()
        contentBuckets.removeAll()
    }

    var bucketCountsForTesting: (sender: Int, content: Int) {
        (senderBuckets.count, contentBuckets.count)
    }

    private mutating func bucket(
        for key: String,
        in buckets: inout [String: TokenBucket],
        capacity: Double,
        refillPerSec: Double,
        maxBuckets: Int,
        now: Date
    ) -> TokenBucket {
        if let bucket = buckets[key] {
            return bucket
        }

        evictIfNeeded(from: &buckets, maxBuckets: maxBuckets, now: now)
        return TokenBucket(
            capacity: capacity,
            tokens: capacity,
            refillPerSec: refillPerSec,
            lastRefill: now
        )
    }

    private func evictIfNeeded(from buckets: inout [String: TokenBucket], maxBuckets: Int, now: Date) {
        guard buckets.count >= maxBuckets else { return }

        buckets = buckets.filter { !$0.value.isIdle(since: now, idleTTL: bucketIdleTTL) }
        guard buckets.count >= maxBuckets else { return }

        if let oldestKey = buckets.min(by: { $0.value.lastRefill < $1.value.lastRefill })?.key {
            buckets.removeValue(forKey: oldestKey)
        }
    }
}
