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
    }

    private var senderBuckets: [String: TokenBucket] = [:]
    private var contentBuckets: [String: TokenBucket] = [:]

    private let senderCapacity: Double
    private let senderRefill: Double
    private let contentCapacity: Double
    private let contentRefill: Double

    init(
        senderCapacity: Double,
        senderRefillPerSec: Double,
        contentCapacity: Double,
        contentRefillPerSec: Double
    ) {
        self.senderCapacity = senderCapacity
        self.senderRefill = senderRefillPerSec
        self.contentCapacity = contentCapacity
        self.contentRefill = contentRefillPerSec
    }

    mutating func allow(senderKey: String, contentKey: String, now: Date = Date()) -> Bool {
        var senderBucket = senderBuckets[senderKey] ?? TokenBucket(
            capacity: senderCapacity,
            tokens: senderCapacity,
            refillPerSec: senderRefill,
            lastRefill: now
        )
        let senderAllowed = senderBucket.allow(now: now)
        senderBuckets[senderKey] = senderBucket

        var contentBucket = contentBuckets[contentKey] ?? TokenBucket(
            capacity: contentCapacity,
            tokens: contentCapacity,
            refillPerSec: contentRefill,
            lastRefill: now
        )
        let contentAllowed = contentBucket.allow(now: now)
        contentBuckets[contentKey] = contentBucket

        return senderAllowed && contentAllowed
    }

    mutating func reset() {
        senderBuckets.removeAll()
        contentBuckets.removeAll()
    }
}
