//
// GeohashCoverage.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Human-readable size of a geohash cell, shared by the location channels sheet and
/// the globe picker.
enum GeohashCoverage {
    /// Approximate max cell dimension at the equator, e.g. "~4.9 km" or "~3.0 mi".
    static func string(forPrecision len: Int, locale: Locale = .current) -> String {
        // Values sourced from common geohash dimension tables.
        let maxMeters: Double = {
            switch len {
            case 2: return 1_250_000
            case 3: return 156_000
            case 4: return 39_100
            case 5: return 4_890
            case 6: return 1_220
            case 7: return 153
            case 8: return 38.2
            case 9: return 4.77
            case 10: return 1.19
            default:
                if len <= 1 { return 5_000_000 }
                // For >10, scale down conservatively by ~1/4 each char
                let over = len - 10
                return 1.19 * pow(0.25, Double(over))
            }
        }()

        if usesMetric(locale) {
            return "~\(formatDistance(maxMeters / 1000.0)) km"
        } else {
            return "~\(formatDistance(maxMeters / 1609.344)) mi"
        }
    }

    /// Channel level a geohash of this length belongs to.
    static func level(forLength length: Int) -> GeohashChannelLevel {
        switch length {
        case ...2: return .region
        case 3...4: return .province
        case 5: return .city
        case 6: return .neighborhood
        case 7: return .block
        default: return .building
        }
    }

    static func usesMetric(_ locale: Locale = .current) -> Bool {
        if #available(iOS 16.0, macOS 13.0, *) {
            return locale.measurementSystem == .metric
        } else {
            return locale.usesMetricSystem
        }
    }

    private static func formatDistance(_ value: Double) -> String {
        if value >= 100 { return String(format: "%.0f", value.rounded()) }
        return String(format: "%.1f", value)
    }
}
