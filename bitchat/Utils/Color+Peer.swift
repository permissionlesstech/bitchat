//
// Color+Peer.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

extension Color {
    private static var peerColorCache: [String: Color] = [:]
    
    init(peerSeed: String, isDark: Bool) {
        let cacheKey = peerSeed + (isDark ? "|dark" : "|light")
        if let cached = Self.peerColorCache[cacheKey] {
            self = cached
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
        let saturation = min(1.0, max(0.50, sBase + (sRand - 0.5) * sRange))
        let brightness = min(1.0, max(0.35, bBase + (bRand - 0.5) * bRange))
        let c = Color(hue: hue, saturation: saturation, brightness: brightness)
        Self.peerColorCache[cacheKey] = c
        self = c
    }
}
