//
// NostrInboundPipelineTimestampTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Testing
@testable import bitchat

struct NostrInboundPipelineTimestampTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let nowSeconds = 1_700_000_000
    private let skew = Int(TransportConfig.nostrDMMaxClockSkewSeconds)
    private let lookback = Int(TransportConfig.nostrDMSubscribeLookbackSeconds)
    private let giftWrapMaxAge = Int(TransportConfig.nostrGiftWrapMaxAgeSeconds)

    @Test("Rumor timestamps inside the lookback-plus-skew window are accepted")
    func acceptsPlausibleTimestamps() {
        #expect(NostrInboundPipeline.isPlausibleRumorTimestamp(nowSeconds, now: now))
        #expect(NostrInboundPipeline.isPlausibleRumorTimestamp(nowSeconds - lookback + 60, now: now))
        // A sender clock slightly ahead of the receiver is tolerated.
        #expect(NostrInboundPipeline.isPlausibleRumorTimestamp(nowSeconds + skew - 60, now: now))
    }

    @Test("Future-dated and stale rumor timestamps are rejected")
    func rejectsImplausibleTimestamps() {
        #expect(!NostrInboundPipeline.isPlausibleRumorTimestamp(nowSeconds + skew + 60, now: now))
        #expect(!NostrInboundPipeline.isPlausibleRumorTimestamp(nowSeconds - lookback - skew - 60, now: now))
    }

    @Test("Outer gift wraps inside the randomization and delivery window are accepted")
    func acceptsPlausibleGiftWrapTimestamps() {
        #expect(NostrInboundPipeline.isAcceptableGiftWrapTimestamp(nowSeconds, now: now))
        // Android randomizes wraps up to 48h into the past.
        #expect(NostrInboundPipeline.isAcceptableGiftWrapTimestamp(nowSeconds - 172_800 + 60, now: now))
        #expect(NostrInboundPipeline.isAcceptableGiftWrapTimestamp(nowSeconds + skew - 60, now: now))
    }

    @Test("Far-future and over-age outer gift wraps are rejected")
    func rejectsImplausibleGiftWrapTimestamps() {
        #expect(!NostrInboundPipeline.isAcceptableGiftWrapTimestamp(nowSeconds + skew + 60, now: now))
        #expect(!NostrInboundPipeline.isAcceptableGiftWrapTimestamp(nowSeconds - giftWrapMaxAge - 60, now: now))
        // A wrap older than 24h but inside 48h+skew must still pass — that is
        // the Android→iOS delivery gap this gate exists to keep open.
        #expect(NostrInboundPipeline.isAcceptableGiftWrapTimestamp(nowSeconds - lookback - 3_600, now: now))
    }

    @Test("A wrap randomized 48h back remains deliverable after 23h offline")
    func acceptsQueuedGiftWrapWithFreshRumor() {
        // Fixed wire timestamps: created together 23h before receipt, with the
        // outer timestamp moved another 48h back. Do not derive the vector
        // from the policy constants: that would hide an undersized window.
        let rumorCreatedAt = 1_699_917_200
        let wrapCreatedAt = 1_699_744_400
        #expect(NostrInboundPipeline.isPlausibleRumorTimestamp(rumorCreatedAt, now: now))
        #expect(NostrInboundPipeline.isAcceptableGiftWrapTimestamp(wrapCreatedAt, now: now))
        let subscriptionSince = now.addingTimeInterval(-TransportConfig.nostrGiftWrapMaxAgeSeconds)
        #expect(Date(timeIntervalSince1970: TimeInterval(wrapCreatedAt)) >= subscriptionSince)
    }

    @Test("Delivery grace covers the inner boundary without extending rumor freshness")
    func preservesIndependentTimestampBoundaries() {
        // At this receive time, 24h plus 15min is the last valid inner rumor;
        // its maximally randomized wrap is exactly 72h plus 15min old.
        #expect(NostrInboundPipeline.isPlausibleRumorTimestamp(1_699_912_700, now: now))
        #expect(NostrInboundPipeline.isAcceptableGiftWrapTimestamp(1_699_739_900, now: now))
        #expect(!NostrInboundPipeline.isAcceptableGiftWrapTimestamp(1_699_739_899, now: now))
        // A freshly rewrapped envelope cannot revive an expired inner rumor.
        #expect(NostrInboundPipeline.isAcceptableGiftWrapTimestamp(nowSeconds, now: now))
        #expect(!NostrInboundPipeline.isPlausibleRumorTimestamp(1_699_912_699, now: now))
        #expect(!NostrInboundPipeline.isAcceptableGiftWrapTimestamp(1_700_000_901, now: now))
    }

}
