//
// LiveVideoQualityTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
@testable import bitchat

struct LiveVideoQualityTests {
    @Test func presetsMatchTheSpecification() {
        #expect(LiveVideoQuality.low.width == 144 && LiveVideoQuality.low.height == 192)
        #expect(LiveVideoQuality.low.fps == 8 && LiveVideoQuality.low.totalBitrate == 30_000)
        #expect(LiveVideoQuality.low.fec.blockWindowMs == 600)
        #expect(LiveVideoQuality.medium.fec.maxSourceShards == 16)
        #expect(LiveVideoQuality.high.videoBitrate == 360_000)
        #expect(LiveVideoQuality.high.fec.maxSourceShards == 32)
        #expect(!LiveVideoQuality.clip.isLivePreset)
        #expect(LiveVideoQuality.allCases.allSatisfy { $0.width % 16 == 0 && $0.height % 16 == 0 })
        #expect(LiveVideoQuality.fromName("MEDIUM") == .medium)
        #expect(LiveVideoQuality.fromName("bogus") == .low)
        #expect(LiveVideoQuality.fromName(nil) == .low)
        #expect(LiveVideoLimits.maxVideoFileBytes == 102_400)
    }

    @Test func parityCountAppliesTheFloorAndCap() {
        let policy = LiveVideoFecPolicy(parityRatio: 0.2, keyframeParityRatio: 0.4)
        #expect(policy.parityCount(sourceCount: 1, containsKeyframe: false) == 1)
        #expect(policy.parityCount(sourceCount: 3, containsKeyframe: false) == 1)
        // Two parity shards from four sources up.
        #expect(policy.parityCount(sourceCount: 4, containsKeyframe: false) == 2)
        #expect(policy.parityCount(sourceCount: 12, containsKeyframe: false) == 3)
        #expect(policy.parityCount(sourceCount: 12, containsKeyframe: true) == 5)
        #expect(LiveVideoFecPolicy(parityRatio: 1, keyframeParityRatio: 1)
            .parityCount(sourceCount: 32, containsKeyframe: true) == 16)
        #expect(LiveVideoQuality.clip.fec.parityCount(sourceCount: 8, containsKeyframe: true) == 0)
    }

    @Test func clipPresetSendsNoParity() {
        let packetizer = VideoStreamPacketizer(
            streamID: Data(count: 8),
            config: LiveVideoConfig(videoCodec: .h264AnnexB, width: 240, height: 320, fps: 12,
                                    bitrateKbps: 26, audioCodec: .none),
            fec: LiveVideoQuality.clip.fec
        )
        _ = packetizer.add(LiveMediaUnit(track: .video, ptsMs: 0, keyframe: true, data: Data(repeating: 1, count: 2_000)),
                           nowMs: 0)
        _ = packetizer.finish(durationMs: 100, nowMs: 100)
        #expect(packetizer.parityPackets == 0)
    }
}
