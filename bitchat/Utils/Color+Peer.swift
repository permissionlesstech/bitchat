//
// Color+Peer.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

enum PeerColorContrast {
    /// Blue and purple hues (210°–306°) have low perceived luminance at standard HSB
    /// brightness on dark/black backgrounds. Lifting brightness and easing saturation
    /// keeps every peer color readable (>= 4.5:1 WCAG AA on black) in dark mode while
    /// preserving ring-dependent separation for overflow palette entries.
    static func adjustForDarkMode(
        hue: Double,
        saturation: Double,
        brightness: Double,
        ring: Int = 0
    ) -> (saturation: Double, brightness: Double) {
        let normalizedHue = hue - floor(hue)
        guard normalizedHue >= 0.58 && normalizedHue <= 0.85 else {
            return (saturation, brightness)
        }
        // Smooth bell curve peaking around deep blue/purple (~0.70).
        let center = 0.70
        let halfWidth = 0.15
        let weight = max(0.0, 1.0 - abs(normalizedHue - center) / halfWidth)
        let ringStep = Double(max(0, ring))
        let maxSat = max(0.25, 0.50 + (1.0 - weight) * 0.10 - ringStep * 0.12)
        let minBri = min(1.0, 0.92 + weight * 0.06)
        let adjustedSaturation = min(saturation, maxSat)
        let adjustedBrightness = max(brightness, minBri)
        return (min(1.0, max(0.0, adjustedSaturation)), min(1.0, max(0.0, adjustedBrightness)))
    }
}

extension Color {
    private static let maxPeerColorCacheEntries = 512

    private final class PeerColorCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: Color] = [:]
        private var generation: UInt64 = 0

        func lookup(_ key: String) -> (color: Color?, generation: UInt64) {
            lock.lock()
            defer { lock.unlock() }
            return (entries[key], generation)
        }

        func store(_ color: Color, for key: String, expectedGeneration: UInt64) {
            lock.lock()
            defer { lock.unlock() }
            guard generation == expectedGeneration else { return }
            if entries.count >= Color.maxPeerColorCacheEntries {
                entries.removeAll(keepingCapacity: true)
            }
            entries[key] = color
        }

        func reset() {
            lock.lock()
            defer { lock.unlock() }
            generation &+= 1
            entries.removeAll(keepingCapacity: false)
        }
    }

    private static let peerColorCache = PeerColorCache()

    /// Panic-wipe hook: drops cached peer color seeds (nicknames, Noise keys,
    /// Nostr pubkeys) from memory and fences any concurrent lookup.
    static func clearPeerColorCache() {
        peerColorCache.reset()
    }

    init(peerSeed: String, isDark: Bool) {
        let cacheKey = peerSeed + (isDark ? "|dark" : "|light")
        let lookup = Self.peerColorCache.lookup(cacheKey)
        if let cached = lookup.color {
            self = cached
            return
        }
        let h = peerSeed.djb2()
        var hue = Double(h % 1000) / 1000.0
        let orange = 30.0 / 360.0
        if abs(hue - orange) < TransportConfig.uiColorHueAvoidanceDelta {
            hue = fmod(hue + TransportConfig.uiColorHueOffset, 1.0)
        }
        let sRand = Double((h >> 17) & 0x3FF) / 1023.0
        let bRand = Double((h >> 27) & 0x3FF) / 1023.0
        let sBase: Double = isDark ? 0.80 : 0.70
        let sRange: Double = 0.20
        let bBase: Double = isDark ? 0.75 : 0.45
        let bRange: Double = isDark ? 0.16 : 0.14
        var saturation = min(1.0, max(0.50, sBase + (sRand - 0.5) * sRange))
        var brightness = min(1.0, max(0.35, bBase + (bRand - 0.5) * bRange))
        if isDark {
            let adjusted = PeerColorContrast.adjustForDarkMode(hue: hue, saturation: saturation, brightness: brightness)
            saturation = adjusted.saturation
            brightness = adjusted.brightness
        }
        let c = Color(hue: hue, saturation: saturation, brightness: brightness)
        Self.peerColorCache.store(c, for: cacheKey, expectedGeneration: lookup.generation)
        self = c
    }
}
