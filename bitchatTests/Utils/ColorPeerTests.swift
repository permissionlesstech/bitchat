//
// ColorPeerTests.swift
// bitchatTests
//
// Tests for Color(peerSeed:isDark:) caching
//

import Testing
import SwiftUI
@testable import bitchat

struct ColorPeerTests {

    @Test func repeatedSeedHitsCacheInsteadOfRecomputing() {
        let seed = "cache-hit-\(UUID().uuidString)"

        let before = Color._peerColorComputeCountForTesting
        let first = Color(peerSeed: seed, isDark: true)
        let afterFirst = Color._peerColorComputeCountForTesting
        let second = Color(peerSeed: seed, isDark: true)
        let afterSecond = Color._peerColorComputeCountForTesting

        #expect(afterFirst == before + 1)
        #expect(afterSecond == afterFirst)
        #expect(first == second)
    }

    @Test func differentAppearanceForSameSeedIsNotCachedTogether() {
        let seed = "appearance-\(UUID().uuidString)"

        let before = Color._peerColorComputeCountForTesting
        _ = Color(peerSeed: seed, isDark: true)
        _ = Color(peerSeed: seed, isDark: false)
        let after = Color._peerColorComputeCountForTesting

        #expect(after == before + 2)
    }

    @Test func sameSeedProducesSameColor() {
        let seed = "deterministic-\(UUID().uuidString)"
        let a = Color(peerSeed: seed, isDark: false)
        let b = Color(peerSeed: seed, isDark: false)
        #expect(a == b)
    }
}
