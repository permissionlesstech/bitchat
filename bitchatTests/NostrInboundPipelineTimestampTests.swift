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

    @Test("Outer gift wraps inside the 48h-plus-skew window are accepted")
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
}

struct NostrEnvelopeTimestampRandomizationTests {
    @Test("Envelope timestamps stay in [now-maxPast, now] and never go future")
    func samplesPastOnlyWindow() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let maxPast: TimeInterval = 172_800
        for _ in 0..<200 {
            let ts = NostrProtocol.randomizedEnvelopeTimestamp(now: now, maxPast: maxPast)
            #expect(ts <= now)
            #expect(ts >= now.addingTimeInterval(-maxPast))
        }
        // Zero past collapses to exactly now.
        #expect(NostrProtocol.randomizedEnvelopeTimestamp(now: now, maxPast: 0) == now)
        // Negative past is treated as zero.
        #expect(NostrProtocol.randomizedEnvelopeTimestamp(now: now, maxPast: -10) == now)
    }
}
