//
// VideoPosterLoader.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import AVFoundation
import CoreGraphics
import Foundation

/// Poster frame + duration for video bubbles, with a small in-memory cache so
/// scrolling a chat does not re-decode every clip.
enum VideoPosterLoader {
    private final class Entry {
        let poster: CGImage?
        let durationSeconds: Double

        init(poster: CGImage?, durationSeconds: Double) {
            self.poster = poster
            self.durationSeconds = durationSeconds
        }
    }

    /// Long edge of the generated poster, in pixels (bubbles are small).
    private static let maxPosterEdge: CGFloat = 480

    private static let cache: NSCache<NSURL, Entry> = {
        let cache = NSCache<NSURL, Entry>()
        cache.countLimit = 64
        return cache
    }()

    static func load(url: URL) async -> (poster: CGImage?, durationSeconds: Double) {
        if let cached = cache.object(forKey: url as NSURL) {
            return (cached.poster, cached.durationSeconds)
        }
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration)).map { $0.isNumeric ? $0.seconds : 0 } ?? 0

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPosterEdge, height: maxPosterEdge)
        // Any nearby frame will do; exact seeking would decode from the
        // previous keyframe for nothing.
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        let poster = try? await generator.image(at: .zero).image

        // Only cache what was readable, so a file still being written gets a
        // fresh attempt next time.
        if poster != nil || duration > 0 {
            cache.setObject(Entry(poster: poster, durationSeconds: duration), forKey: url as NSURL)
        }
        return (poster, duration)
    }

    static func evict(url: URL) {
        cache.removeObject(forKey: url as NSURL)
    }
}
