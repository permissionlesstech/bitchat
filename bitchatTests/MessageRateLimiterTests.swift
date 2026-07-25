//
// MessageRateLimiterTests.swift
// bitchatTests
//
// Tests for the public-intake token buckets, including the NIP-13
// proof-of-work relaxation of the per-sender bucket.
//

import Foundation
import Testing
@testable import bitchat

struct MessageRateLimiterTests {

    private func makeLimiter(
        senderCapacity: Double = 2,
        contentCapacity: Double = 100
    ) -> MessageRateLimiter {
        MessageRateLimiter(
            senderCapacity: senderCapacity,
            senderRefillPerSec: 0.0001,
            contentCapacity: contentCapacity,
            contentRefillPerSec: 0.0001
        )
    }

    @Test func senderBucketBlocksAfterCapacity() {
        var limiter = makeLimiter()
        let now = Date()

        let first = limiter.allow(senderKey: "s", contentKey: "c1", now: now)
        let second = limiter.allow(senderKey: "s", contentKey: "c2", now: now)
        let third = limiter.allow(senderKey: "s", contentKey: "c3", now: now)
        let otherSender = limiter.allow(senderKey: "other", contentKey: "c4", now: now)

        #expect(first)
        #expect(second)
        #expect(!third)
        #expect(otherSender)
    }

    @Test func validPoWBypassesExhaustedSenderBucket() {
        var limiter = makeLimiter()
        let now = Date()

        // Exhaust the sender bucket with plain (no-PoW) messages.
        let first = limiter.allow(senderKey: "s", contentKey: "c1", now: now)
        let second = limiter.allow(senderKey: "s", contentKey: "c2", now: now)
        let exhausted = limiter.allow(senderKey: "s", contentKey: "c3", now: now)

        // A message carrying sufficient validated PoW still passes, and so
        // does more-than-sufficient PoW; plain messages stay blocked.
        let powExact = limiter.allow(
            senderKey: "s",
            contentKey: "c4",
            powBits: NostrPoW.rateLimitBypassBits,
            now: now
        )
        let powHigh = limiter.allow(senderKey: "s", contentKey: "c5", powBits: 20, now: now)
        let plainAgain = limiter.allow(senderKey: "s", contentKey: "c6", now: now)

        #expect(first)
        #expect(second)
        #expect(!exhausted)
        #expect(powExact)
        #expect(powHigh)
        #expect(!plainAgain)
    }

    @Test func lowPoWDoesNotBypassSenderBucket() {
        var limiter = makeLimiter(senderCapacity: 1)
        let now = Date()

        let first = limiter.allow(senderKey: "s", contentKey: "c1", now: now)
        let lowPow = limiter.allow(
            senderKey: "s",
            contentKey: "c2",
            powBits: NostrPoW.rateLimitBypassBits - 1,
            now: now
        )
        let zeroPow = limiter.allow(senderKey: "s", contentKey: "c3", powBits: 0, now: now)

        #expect(first)
        #expect(!lowPow)
        #expect(!zeroPow)
    }

    @Test func powDoesNotBypassContentFloodBucket() {
        var limiter = makeLimiter(senderCapacity: 100, contentCapacity: 1)
        let now = Date()

        let first = limiter.allow(senderKey: "a", contentKey: "same", now: now)
        // Identical content spammed with PoW is still throttled by the
        // content bucket: PoW only relaxes the per-sender limit.
        let powSameContent = limiter.allow(senderKey: "b", contentKey: "same", powBits: 20, now: now)
        let powNewContent = limiter.allow(senderKey: "b", contentKey: "different", powBits: 20, now: now)

        #expect(first)
        #expect(!powSameContent)
        #expect(powNewContent)
    }

    @Test func powBypassDoesNotDrainSenderBucket() {
        var limiter = makeLimiter(senderCapacity: 1)
        let now = Date()

        // PoW messages don't consume sender tokens, so a subsequent plain
        // message still has its full budget.
        let powFirst = limiter.allow(senderKey: "s", contentKey: "c1", powBits: 20, now: now)
        let powSecond = limiter.allow(senderKey: "s", contentKey: "c2", powBits: 20, now: now)
        let plain = limiter.allow(senderKey: "s", contentKey: "c3", now: now)
        let plainExhausted = limiter.allow(senderKey: "s", contentKey: "c4", now: now)

        #expect(powFirst)
        #expect(powSecond)
        #expect(plain)
        #expect(!plainExhausted)
    }

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

        let first = limiter.allow(senderKey: "sender", contentKey: "content-0", now: now)
        var rejected = true
        for index in 1...100 {
            if limiter.allow(senderKey: "sender", contentKey: "content-\(index)", now: now) {
                rejected = false
            }
        }

        #expect(first)
        #expect(rejected)
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
            _ = limiter.allow(
                senderKey: "sender-\(index)",
                contentKey: "content-\(index)",
                now: now.addingTimeInterval(TimeInterval(index))
            )
        }

        #expect(limiter.bucketCountsForTesting.sender == maxEntries)
        #expect(limiter.bucketCountsForTesting.content == maxEntries)
    }

    @Test("PoW bypass still creates content buckets under the cap")
    func powBypassCreatesBoundedContentBuckets() {
        let maxEntries = 3
        var limiter = MessageRateLimiter(
            senderCapacity: 1,
            senderRefillPerSec: 0,
            contentCapacity: 100,
            contentRefillPerSec: 0,
            maxSenderBuckets: maxEntries,
            maxContentBuckets: maxEntries,
            bucketIdleTTL: 60
        )
        let now = Date()

        var allAllowed = true
        for index in 0..<10 {
            let allowed = limiter.allow(
                senderKey: "sender",
                contentKey: "content-\(index)",
                powBits: NostrPoW.rateLimitBypassBits,
                now: now.addingTimeInterval(TimeInterval(index))
            )
            if !allowed { allAllowed = false }
        }

        #expect(allAllowed)
        #expect(limiter.bucketCountsForTesting.sender == 0)
        #expect(limiter.bucketCountsForTesting.content == maxEntries)
    }
}
