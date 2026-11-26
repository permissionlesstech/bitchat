//
// LiveVideoCongestionControllerTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
@testable import bitchat

struct LiveVideoCongestionControllerTests {
    @Test func growingQueueBacksOffThenRecoversGradually() {
        let controller = LiveVideoCongestionController(maxBitrate: 60_000)
        _ = controller.onBacklog(20, nowMs: 0)
        #expect(controller.bitrate == 48_000)
        // Rate-limited: a second high sample inside a second does not compound.
        _ = controller.onBacklog(20, nowMs: 500)
        #expect(controller.bitrate == 48_000)
        _ = controller.onBacklog(20, nowMs: 1_000)
        #expect(controller.bitrate == 38_400)

        // Calm queue: nothing for two seconds, then one step per second, capped at the preset.
        var now: Int64 = 2_000
        _ = controller.onBacklog(0, nowMs: now)
        #expect(controller.bitrate == 38_400)
        for _ in 0..<20 {
            now += 1_000
            _ = controller.onBacklog(0, nowMs: now)
        }
        #expect(controller.bitrate == 60_000)
    }

    @Test func deepQueueSkipsVideoAndResumesWithAKeyframe() {
        let controller = LiveVideoCongestionController(maxBitrate: 60_000)
        let deep = controller.onBacklog(80, nowMs: 0)
        #expect(deep.skipVideo)
        #expect(!deep.requestKeyframe)
        #expect(controller.onBacklog(30, nowMs: 250).skipVideo)
        let drained = controller.onBacklog(2, nowMs: 500)
        #expect(!drained.skipVideo)
        #expect(drained.requestKeyframe)
        #expect(!controller.onBacklog(2, nowMs: 750).requestKeyframe)
        #expect(controller.skipEpisodes == 1)
        #expect(!controller.skipping)
    }

    @Test func bitrateNeverDropsBelowTheFloor() {
        let controller = LiveVideoCongestionController(maxBitrate: 20_000)
        var now: Int64 = 0
        for _ in 0..<30 {
            _ = controller.onBacklog(100, nowMs: now)
            now += 250
        }
        #expect(controller.bitrate == 6_000)
    }

    @Test func midQueueResetsTheCalmTimer() {
        let controller = LiveVideoCongestionController(maxBitrate: 60_000, minBitrate: 10_000)
        _ = controller.onBacklog(20, nowMs: 0)
        #expect(controller.bitrate == 48_000)
        _ = controller.onBacklog(0, nowMs: 1_000)
        _ = controller.onBacklog(10, nowMs: 2_500) // between low and high water
        _ = controller.onBacklog(0, nowMs: 3_000)
        #expect(controller.bitrate == 48_000)
        _ = controller.onBacklog(0, nowMs: 5_000)
        #expect(controller.bitrate == 53_000)
    }
}
