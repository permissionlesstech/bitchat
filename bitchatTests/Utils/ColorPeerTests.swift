//
// ColorPeerTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import SwiftUI
@testable import bitchat

struct ColorPeerTests {

    // MARK: - Consistency Tests

    @Test func peerColor_sameSeedProducesSameColor() {
        let color1 = Color(peerSeed: "alice", isDark: false)
        let color2 = Color(peerSeed: "alice", isDark: false)

        // Since the cache is static, both should produce the same color
        // We can't directly compare Color objects, but we can verify they produce consistent hashes
        #expect(color1.description == color2.description, "Same seed should produce same color")
    }

    @Test func peerColor_differentSeedsProduceDifferentColors() {
        let color1 = Color(peerSeed: "alice", isDark: false)
        let color2 = Color(peerSeed: "bob", isDark: false)

        // Different seeds should produce different colors
        #expect(color1.description != color2.description, "Different seeds should produce different colors")
    }

    @Test func peerColor_darkModeDifferent() {
        let lightColor = Color(peerSeed: "alice", isDark: false)
        let darkColor = Color(peerSeed: "alice", isDark: true)

        // Same seed but different dark mode should produce different colors
        #expect(lightColor.description != darkColor.description, "Light and dark mode should produce different colors")
    }

    // MARK: - Caching Tests

    @Test func peerColor_cacheWorks() {
        // Generate color twice with same parameters
        let color1 = Color(peerSeed: "testuser", isDark: false)
        let color2 = Color(peerSeed: "testuser", isDark: false)

        // Both should be identical (from cache)
        #expect(color1.description == color2.description, "Cache should return same color object")
    }

    @Test func peerColor_cacheDistinguishesDarkMode() {
        // Generate colors for same seed but different dark mode
        let lightColor1 = Color(peerSeed: "user", isDark: false)
        let darkColor1 = Color(peerSeed: "user", isDark: true)
        let lightColor2 = Color(peerSeed: "user", isDark: false)
        let darkColor2 = Color(peerSeed: "user", isDark: true)

        // Cache should distinguish between light and dark
        #expect(lightColor1.description == lightColor2.description, "Light colors should match from cache")
        #expect(darkColor1.description == darkColor2.description, "Dark colors should match from cache")
        #expect(lightColor1.description != darkColor1.description, "Light and dark should differ")
    }

    // MARK: - Orange Avoidance Tests

    @Test func peerColor_avoidsOrangeHue() {
        // Test seeds that might hash to orange-ish hues
        // Orange is at 30/360 = 0.0833...
        // Avoidance delta is 0.05, so range is roughly 0.033 to 0.133

        let testSeeds = [
            "orangish1",
            "orangish2",
            "orangish3",
            "test30",
            "test35"
        ]

        for seed in testSeeds {
            _ = Color(peerSeed: seed, isDark: false)
            // If the hue was too close to orange, it should have been offset
            // We can't easily extract the hue from SwiftUI Color, but we can verify it doesn't crash
        }
    }

    // MARK: - Hash Distribution Tests

    @Test func peerColor_differentHashBits() {
        // Test that different parts of the hash affect the color
        let color1 = Color(peerSeed: "aaa", isDark: false)
        let color2 = Color(peerSeed: "bbb", isDark: false)
        let color3 = Color(peerSeed: "ccc", isDark: false)

        // All three should be different
        #expect(color1.description != color2.description)
        #expect(color2.description != color3.description)
        #expect(color1.description != color3.description)
    }

    // MARK: - Real World Scenarios

    @Test func peerColor_nostrPublicKeys() {
        // Test with realistic Nostr-like public key hashes
        let pubkey1 = "npub1abc123def456..."
        let pubkey2 = "npub1xyz789ghi012..."

        let color1 = Color(peerSeed: pubkey1, isDark: false)
        let color2 = Color(peerSeed: pubkey2, isDark: false)

        #expect(color1.description != color2.description, "Different pubkeys should produce different colors")
    }

    @Test func peerColor_shortSeeds() {
        // Test with short seeds
        let color1 = Color(peerSeed: "a", isDark: false)
        let color2 = Color(peerSeed: "b", isDark: false)

        #expect(color1.description != color2.description, "Even short seeds should produce different colors")
    }

    @Test func peerColor_longSeeds() {
        // Test with very long seeds
        let longSeed1 = String(repeating: "a", count: 100)
        let longSeed2 = String(repeating: "b", count: 100)

        let color1 = Color(peerSeed: longSeed1, isDark: false)
        let color2 = Color(peerSeed: longSeed2, isDark: false)

        #expect(color1.description != color2.description, "Long seeds should produce different colors")
    }

    @Test func peerColor_emptyStringSeed() {
        // Edge case: empty string
        let color = Color(peerSeed: "", isDark: false)

        // Should not crash and should produce a valid color
        #expect(color.description.isEmpty == false, "Empty seed should produce valid color")
    }

    @Test func peerColor_unicodeSeeds() {
        let color1 = Color(peerSeed: "alice", isDark: false)
        let color2 = Color(peerSeed: "alicé", isDark: false)

        #expect(color1.description != color2.description, "Unicode differences should affect color")
    }

    // MARK: - Determinism Tests

    @Test func peerColor_isDeterministic() {
        // Run multiple times to ensure determinism
        let seeds = ["alice", "bob", "charlie", "dave", "eve"]

        for seed in seeds {
            let colors = (0..<10).map { _ in
                Color(peerSeed: seed, isDark: false).description
            }

            // All 10 should be identical
            let uniqueColors = Set(colors)
            #expect(uniqueColors.count == 1, "Color generation for '\(seed)' should be deterministic")
        }
    }

    @Test func peerColor_caseMatters() {
        let color1 = Color(peerSeed: "Alice", isDark: false)
        let color2 = Color(peerSeed: "alice", isDark: false)
        let color3 = Color(peerSeed: "ALICE", isDark: false)

        // All three should be different (case-sensitive)
        #expect(color1.description != color2.description, "Alice != alice")
        #expect(color2.description != color3.description, "alice != ALICE")
        #expect(color1.description != color3.description, "Alice != ALICE")
    }

    // MARK: - Boundary Value Tests

    @Test func peerColor_numberSeeds() {
        let color1 = Color(peerSeed: "1", isDark: false)
        let color2 = Color(peerSeed: "2", isDark: false)
        let color3 = Color(peerSeed: "99999", isDark: false)

        #expect(color1.description != color2.description)
        #expect(color2.description != color3.description)
    }

    @Test func peerColor_specialCharacterSeeds() {
        let color1 = Color(peerSeed: "user@host", isDark: false)
        let color2 = Color(peerSeed: "user#1234", isDark: false)
        let color3 = Color(peerSeed: "user!special", isDark: false)

        #expect(color1.description != color2.description)
        #expect(color2.description != color3.description)
    }
}
