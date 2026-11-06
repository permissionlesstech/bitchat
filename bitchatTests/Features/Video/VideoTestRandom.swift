//
// VideoTestRandom.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Deterministic SplitMix64 source so the video loss simulations replay
/// identically on every run.
final class VideoTestRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in `range` (lower bound inclusive, upper bound exclusive).
    func int(_ range: Range<Int>) -> Int {
        var generator = self
        return Int.random(in: range, using: &generator)
    }

    func double() -> Double {
        var generator = self
        return Double.random(in: 0..<1, using: &generator)
    }

    func bytes(_ count: Int) -> Data {
        var data = Data(count: count)
        for index in 0..<count {
            data[index] = UInt8(truncatingIfNeeded: next())
        }
        return data
    }

    func shuffled<T>(_ values: [T]) -> [T] {
        var generator = self
        return values.shuffled(using: &generator)
    }
}
