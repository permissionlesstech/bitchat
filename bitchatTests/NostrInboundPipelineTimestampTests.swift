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
}
