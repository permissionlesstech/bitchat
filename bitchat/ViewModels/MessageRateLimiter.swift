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

    /// - Parameter powBits: validated NIP-13 difficulty of the event
    ///   (`NostrPoW.validatedDifficulty`; 0 for mesh or no-PoW events).
    ///   At or above `NostrPoW.rateLimitBypassBits` the per-sender bucket is
    ///   skipped entirely — each such message paid for itself with work — but
    ///   the per-content flood bucket still applies.
    mutating func allow(senderKey: String, contentKey: String, powBits: Int = 0, now: Date = Date()) -> Bool {
        let senderAllowed: Bool
        if powBits >= NostrPoW.rateLimitBypassBits {
            senderAllowed = true
        } else {
            var senderBucket = Self.bucket(
                for: senderKey,
                in: &senderBuckets,
                capacity: senderCapacity,
                refillPerSec: senderRefill,
                maxBuckets: maxSenderBuckets,
                idleTTL: bucketIdleTTL,
                now: now
            )
            senderAllowed = senderBucket.allow(now: now)
            senderBuckets[senderKey] = senderBucket
        }

        // Rejected senders must not mint attacker-keyed content entries.
        guard senderAllowed else { return false }

        var contentBucket = Self.bucket(
            for: contentKey,
            in: &contentBuckets,
            capacity: contentCapacity,
            refillPerSec: contentRefill,
            maxBuckets: maxContentBuckets,
            idleTTL: bucketIdleTTL,
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

    // Static so we can take `inout` on a stored dictionary without overlapping
    // exclusive access through a mutating method on `self`.
    private static func bucket(
        for key: String,
        in buckets: inout [String: TokenBucket],
        capacity: Double,
        refillPerSec: Double,
        maxBuckets: Int,
        idleTTL: TimeInterval,
        now: Date
    ) -> TokenBucket {
        if let existing = buckets[key] {
            return existing
        }

        evictIfNeeded(from: &buckets, maxBuckets: maxBuckets, idleTTL: idleTTL, now: now)
        return TokenBucket(
            capacity: capacity,
            tokens: capacity,
            refillPerSec: refillPerSec,
            lastRefill: now
        )
    }

    private static func evictIfNeeded(
        from buckets: inout [String: TokenBucket],
        maxBuckets: Int,
        idleTTL: TimeInterval,
        now: Date
    ) {
        guard buckets.count >= maxBuckets else { return }

        buckets = buckets.filter { !$0.value.isIdle(since: now, idleTTL: idleTTL) }
        guard buckets.count >= maxBuckets else { return }

        if let oldestKey = buckets.min(by: { $0.value.lastRefill < $1.value.lastRefill })?.key {
            buckets.removeValue(forKey: oldestKey)
        }
    }
}
