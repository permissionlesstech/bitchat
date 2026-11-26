//
// LiveVideoCongestionController.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Sender-side congestion control for a broadcast stream with no receiver feedback.
///
/// The signal is the depth of the busiest outbound queue: on a mesh the first
/// hop is the usual bottleneck, and a growing queue is pure added latency. The
/// controller backs the encoder off multiplicatively, probes back up
/// additively once the queue stays short, and when the queue is far behind it
/// skips video until it drains, then restarts from a keyframe so the stream
/// stays live instead of drifting seconds behind.
///
/// Not thread-safe — confine to one queue. Callers supply time.
final class LiveVideoCongestionController {
    struct Decision: Equatable {
        let bitrate: Int
        let skipVideo: Bool
        let requestKeyframe: Bool
    }

    private static let decreaseIntervalMs: Int64 = 1_000
    private static let increaseIntervalMs: Int64 = 1_000
    private static let calmBeforeIncreaseMs: Int64 = 2_000

    private let maxBitrate: Int
    private let minBitrate: Int
    private let highWater: Int
    private let skipWater: Int
    private let lowWater: Int

    private(set) var bitrate: Int
    private(set) var skipping = false
    private(set) var skipEpisodes = 0

    private var lastDecreaseMs = Int64.min / 2
    private var lastIncreaseMs = Int64.min / 2
    private var calmSinceMs: Int64?

    /// `minBitrate` defaults to 30% of `maxBitrate`.
    init(
        maxBitrate: Int,
        minBitrate: Int? = nil,
        highWater: Int = 16,
        skipWater: Int = 48,
        lowWater: Int = 4
    ) {
        self.maxBitrate = maxBitrate
        self.minBitrate = minBitrate ?? maxBitrate * 3 / 10
        self.highWater = highWater
        self.skipWater = skipWater
        self.lowWater = lowWater
        self.bitrate = maxBitrate
    }

    func onBacklog(_ backlog: Int, nowMs: Int64) -> Decision {
        var keyframe = false
        if backlog >= skipWater {
            if !skipping { skipEpisodes += 1 }
            skipping = true
            calmSinceMs = nil
            decrease(nowMs: nowMs, factor: 0.6, force: true)
        } else if backlog >= highWater {
            calmSinceMs = nil
            decrease(nowMs: nowMs, factor: 0.8, force: false)
        } else if backlog <= lowWater {
            if skipping {
                skipping = false
                keyframe = true
            }
            let since = calmSinceMs ?? nowMs
            calmSinceMs = since
            if nowMs - since >= Self.calmBeforeIncreaseMs
                && nowMs - lastIncreaseMs >= Self.increaseIntervalMs {
                bitrate = min(maxBitrate, bitrate + maxBitrate / 12)
                lastIncreaseMs = nowMs
            }
        } else {
            calmSinceMs = nil
        }
        return Decision(bitrate: bitrate, skipVideo: skipping, requestKeyframe: keyframe)
    }

    private func decrease(nowMs: Int64, factor: Double, force: Bool) {
        if !force && nowMs - lastDecreaseMs < Self.decreaseIntervalMs { return }
        bitrate = max(minBitrate, Int(Double(bitrate) * factor))
        lastDecreaseMs = nowMs
    }
}
