//
// LiveVideoQuality.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Sender presets. Dimensions are portrait and multiples of 16 so every
/// hardware H.264 encoder accepts them without cropping. Low targets multi-hop
/// Bluetooth (roughly the airtime of a live voice burst); Medium suits one or
/// two BLE hops; High assumes a Wi-Fi link.
enum LiveVideoQuality: String, CaseIterable {
    case low
    case medium
    case high
    /// Recorded clips: sized so `LiveVideoLimits.maxClipDurationMs` fits one file transfer.
    case clip

    var width: Int {
        switch self {
        case .low: return 144
        case .medium, .clip: return 240
        case .high: return 480
        }
    }

    var height: Int {
        switch self {
        case .low: return 192
        case .medium, .clip: return 320
        case .high: return 640
        }
    }

    var fps: Int {
        switch self {
        case .low: return 8
        case .medium, .clip: return 12
        case .high: return 24
        }
    }

    /// Video bitrate in bits per second.
    var videoBitrate: Int {
        switch self {
        case .low: return 18_000
        case .medium: return 56_000
        case .high: return 360_000
        case .clip: return 26_000
        }
    }

    /// Audio bitrate in bits per second.
    var audioBitrate: Int {
        switch self {
        case .low, .clip: return 12_000
        case .medium: return 16_000
        case .high: return 24_000
        }
    }

    var keyframeIntervalSeconds: Int { 2 }

    var fec: LiveVideoFecPolicy {
        switch self {
        case .low:
            return LiveVideoFecPolicy(parityRatio: 0.2, keyframeParityRatio: 0.4, blockWindowMs: 600)
        case .medium:
            return LiveVideoFecPolicy(parityRatio: 0.2, keyframeParityRatio: 0.35, maxSourceShards: 16)
        case .high:
            return LiveVideoFecPolicy(parityRatio: 0.15, keyframeParityRatio: 0.3, maxSourceShards: 32)
        case .clip:
            return LiveVideoFecPolicy(parityRatio: 0, keyframeParityRatio: 0)
        }
    }

    var isLivePreset: Bool { self != .clip }

    var totalBitrate: Int { videoBitrate + audioBitrate }

    /// Case-insensitive lookup by name; unknown or nil falls back to `.low`.
    static func fromName(_ value: String?) -> LiveVideoQuality {
        guard let value else { return .low }
        return LiveVideoQuality(rawValue: value.lowercased()) ?? .low
    }
}

enum LiveVideoLimits {
    /// Largest video file that fits one mesh file transfer: 256 fragments of
    /// at most ~450 B, less the file TLVs, packet header, signature and Noise framing.
    static let maxVideoFileBytes = 100 * 1_024
    static let maxClipDurationMs: Int64 = 20_000
    static let maxTranscodeSourceMs: Int64 = 60_000
}
