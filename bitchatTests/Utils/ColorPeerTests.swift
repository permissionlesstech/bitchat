//
// ColorPeerTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
@testable import bitchat

@Suite(.serialized)
struct ColorPeerTests {

    @Test func peerColor_resolvesRepresentativeSeeds() {
        let seeds = [
            "alice",
            "",
            "caf\u{00E9}",
            "a",
            String(repeating: "long-seed-", count: 12),
            "nostr:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        ]

        for seed in seeds {
            #expect(isUsableRGBA(resolvedRGBA(for: Color(peerSeed: seed, isDark: false))),
                    "Light peer color should resolve for seed '\(seed)'")
            #expect(isUsableRGBA(resolvedRGBA(for: Color(peerSeed: seed, isDark: true))),
                    "Dark peer color should resolve for seed '\(seed)'")
        }
    }

    @Test func peerColor_isDeterministicForSameSeedAndMode() {
        let firstLight = resolvedRGBA(for: Color(peerSeed: "alice", isDark: false))
        let secondLight = resolvedRGBA(for: Color(peerSeed: "alice", isDark: false))
        let firstDark = resolvedRGBA(for: Color(peerSeed: "alice", isDark: true))
        let secondDark = resolvedRGBA(for: Color(peerSeed: "alice", isDark: true))

        #expect(firstLight == secondLight)
        #expect(firstDark == secondDark)
    }

    @Test func peerColor_supportsLightAndDarkModes() {
        let light = resolvedRGBA(for: Color(peerSeed: "mode-check", isDark: false))
        let dark = resolvedRGBA(for: Color(peerSeed: "mode-check", isDark: true))

        #expect(isUsableRGBA(light))
        #expect(isUsableRGBA(dark))
    }
}

private struct RGBA: Equatable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    var values: [Double] {
        [red, green, blue, alpha]
    }
}

private func resolvedRGBA(for color: Color) -> RGBA? {
#if os(iOS)
    let platformColor = UIColor(color)
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    guard platformColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
        return nil
    }
    return RGBA(red: Double(red), green: Double(green), blue: Double(blue), alpha: Double(alpha))
#elseif os(macOS)
    let platformColor = NSColor(color)
    guard let rgbColor = platformColor.usingColorSpace(.deviceRGB) else {
        return nil
    }
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    rgbColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    return RGBA(red: Double(red), green: Double(green), blue: Double(blue), alpha: Double(alpha))
#else
    return nil
#endif
}

private func isUsableRGBA(_ components: RGBA?) -> Bool {
    guard let components else { return false }
    return components.values.allSatisfy { (0.0...1.0).contains($0) }
}
