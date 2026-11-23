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
    /// keeps every peer color readable in dark mode without losing hue distinction.
    static func adjustForDarkMode(hue: Double, saturation: Double, brightness: Double) -> (saturation: Double, brightness: Double) {
        let normalizedHue = hue - floor(hue)
        guard normalizedHue >= 0.58 && normalizedHue <= 0.85 else {
            return (saturation, brightness)
        }
        // Smooth bell curve peaking around deep blue/purple (~0.70).
        let center = 0.70
        let halfWidth = 0.15
        let weight = max(0.0, 1.0 - abs(normalizedHue - center) / halfWidth)
        let adjustedSaturation = min(saturation, 0.58 + (1.0 - weight) * 0.14)
        let adjustedBrightness = max(brightness, 0.88 + weight * 0.08)
        return (min(1.0, max(0.0, adjustedSaturation)), min(1.0, max(0.0, adjustedBrightness)))
    }
}

extension Color {
    private static var peerColorCache: [String: Color] = [:]
    
    init(peerSeed: String, isDark: Bool) {
        let cacheKey = peerSeed + (isDark ? "|dark" : "|light")
        if let cached = Self.peerColorCache[cacheKey] {
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
        Self.peerColorCache[cacheKey] = c
        self = c
    }
}
