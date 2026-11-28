//
// BlossomMediaService.swift
// bitchat
//
// BUD-01/BUD-02 Blossom media upload and SHA-256-verified image download
// routed fail-closed through TorURLSession when Tor is enabled.
// Strips all EXIF/GPS metadata on upload and validates container dimensions
// + cryptographic SHA-256 digest before rendering any remote image.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import BitLogger
import Foundation
import ImageIO
import Tor
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#else
import AppKit
#endif

enum BlossomMediaError: Error, LocalizedError, Equatable {
    case torNotReady
    case networkDisabled
    case invalidServerURL
    case invalidImage
    case payloadTooLarge
    case uploadFailed(Int)
    case invalidResponse
    case hashMismatch

    var errorDescription: String? {
        switch self {
        case .torNotReady:
            return "Tor is still connecting"
        case .networkDisabled:
            return "Network access is currently disabled"
        case .invalidServerURL:
            return "Invalid Blossom server URL"
        case .invalidImage:
            return "Could not process image"
        case .payloadTooLarge:
            return "Media exceeds size limit"
        case .uploadFailed(let status):
            return "Upload failed (HTTP \(status))"
        case .invalidResponse:
            return "Invalid Blossom server response"
        case .hashMismatch:
            return "Downloaded media failed SHA-256 integrity check"
        }
    }
}

struct BlossomMediaDependencies {
    var awaitTorReady: @Sendable () async -> Bool
    var isNetworkActivationAllowed: @MainActor () -> Bool
    var performRequest: @Sendable (URLRequest, Int) async throws -> (Data, Int)
    var now: () -> Date

    static let live = BlossomMediaDependencies(
        awaitTorReady: {
            guard NetworkActivationService.persistedTorPreference() else { return true }
            return await TorManager.shared.awaitReady()
        },
        isNetworkActivationAllowed: {
            NetworkActivationService.shared.activationAllowed
        },
        performRequest: { request, maxBytes in
            let session = await MainActor.run { TorURLSession.shared.session }
            let (bytes, response) = try await session.bytes(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            var buffer = Data()
            for try await byte in bytes {
                if buffer.count >= maxBytes {
                    throw BlossomMediaError.payloadTooLarge
                }
                buffer.append(byte)
            }
            return (buffer, statusCode)
        },
        now: Date.init
    )
}

@MainActor
final class BlossomMediaService {
    static let shared = BlossomMediaService()

    nonisolated static let defaultServerURLString = "https://blossom.primal.net"
    nonisolated static let serverURLKey = "bitchat.blossom.serverURL"
    nonisolated static let maxUploadDimension: CGFloat = 1_024
    nonisolated static let maxUploadBytes = 512 * 1024
    nonisolated static let maxDownloadBytes = 4 * 1024 * 1024
    private static let authExpirySeconds: TimeInterval = 5 * 60

    private final class VerifiedImageCache: @unchecked Sendable {
        private let lock = NSLock()
        private var generation: UInt64 = 0
        private let cache: NSCache<NSString, ImageDownsampler.PlatformImage> = {
            let c = NSCache<NSString, ImageDownsampler.PlatformImage>()
            c.countLimit = 32
            c.totalCostLimit = 24 * 1024 * 1024
            return c
        }()

        func lookup(_ key: String) -> (image: ImageDownsampler.PlatformImage?, generation: UInt64) {
            lock.lock()
            defer { lock.unlock() }
            return (cache.object(forKey: key as NSString), generation)
        }

        func store(_ image: ImageDownsampler.PlatformImage, for key: String, cost: Int, expectedGeneration: UInt64) {
            lock.lock()
            defer { lock.unlock() }
            guard generation == expectedGeneration else { return }
            cache.setObject(image, forKey: key as NSString, cost: cost)
        }

        func reset() {
            lock.lock()
            defer { lock.unlock() }
            generation &+= 1
            cache.removeAllObjects()
        }
    }

    private let cache = VerifiedImageCache()
    private let defaults: UserDefaults
    private let dependencies: BlossomMediaDependencies

    init(
        defaults: UserDefaults = .standard,
        dependencies: BlossomMediaDependencies = .live
    ) {
        self.defaults = defaults
        self.dependencies = dependencies
    }

    var serverURLString: String {
        get {
            defaults.string(forKey: Self.serverURLKey)?.trimmedOrNilIfEmpty ?? Self.defaultServerURLString
        }
        set {
            let trimmed = newValue.trimmed
            if trimmed.isEmpty {
                defaults.removeObject(forKey: Self.serverURLKey)
            } else {
                defaults.set(trimmed, forKey: Self.serverURLKey)
            }
        }
    }

    func cachedImage(for sha256Hex: String) -> ImageDownsampler.PlatformImage? {
        cache.lookup(sha256Hex.lowercased()).image
    }

    /// Strips all EXIF/GPS metadata by re-rendering a clean JPEG bitmap capped
    /// to `maxUploadDimension` and `maxUploadBytes`.
    nonisolated static func stripMetadataAndCompressJPEG(
        from imageData: Data,
        maxDimension: CGFloat = maxUploadDimension
    ) -> (jpegData: Data, width: Int, height: Int)? {
        guard !imageData.isEmpty, imageData.count <= 16 * 1024 * 1024 else { return nil }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(imageData as CFData, options),
              ImageContainerValidator.validateDimensions(
                of: source,
                maxDimensionPixels: ImageUtils.maxSourceDimensionPixels,
                maxTotalPixels: ImageUtils.maxSourceTotalPixels
              ) == nil else {
            return nil
        }

        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(ceil(maxDimension)))
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return nil
        }

        var quality: CGFloat = 0.80
        while quality >= 0.30 {
            if let encoded = encodeCleanJPEG(cgImage: cgImage, quality: quality),
               encoded.count <= maxUploadBytes {
                return (encoded, cgImage.width, cgImage.height)
            }
            quality -= 0.12
        }
        return nil
    }

    nonisolated private static func encodeCleanJPEG(cgImage: CGImage, quality: CGFloat) -> Data? {
        let mutable = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutable,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        // Only write compression quality — no EXIF, GPS, TIFF, or MakerNote dictionaries.
        let properties = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, cgImage, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutable as Data
    }

    /// Uploads EXIF-stripped JPEG bytes to the configured Blossom server using
    /// a signed BUD-02 kind-24242 auth header over Tor (fail-closed when Tor is on).
    func uploadImage(
        rawData: Data,
        senderIdentity: NostrIdentity
    ) async throws -> NostrProtocol.MediaAttachment {
        guard dependencies.isNetworkActivationAllowed() else {
            throw BlossomMediaError.networkDisabled
        }
        guard await dependencies.awaitTorReady() else {
            throw BlossomMediaError.torNotReady
        }
        guard let baseURL = NostrProtocol.validatedRemoteHTTPSURL(serverURLString) else {
            throw BlossomMediaError.invalidServerURL
        }
        guard let processed = await Task.detached(priority: .userInitiated, operation: {
            Self.stripMetadataAndCompressJPEG(from: rawData)
        }).value else {
            throw BlossomMediaError.invalidImage
        }

        let sha256Hex = processed.jpegData.sha256Fingerprint()
        let now = dependencies.now()
        let authEvent = try NostrProtocol.createBlossomUploadAuthEvent(
            sha256Hex: sha256Hex,
            expiration: now.addingTimeInterval(Self.authExpirySeconds),
            senderIdentity: senderIdentity,
            createdAt: now
        )
        let authJSON = try authEvent.jsonString()
        let authHeader = "Nostr " + Data(authJSON.utf8).base64EncodedString()

        let uploadURL = baseURL.appendingPathComponent("upload")
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.httpBody = processed.jpegData
        request.timeoutInterval = 30
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")

        let (responseData, statusCode) = try await dependencies.performRequest(request, 64 * 1024)
        guard (200...299).contains(statusCode) else {
            throw BlossomMediaError.uploadFailed(statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let returnedURLString = json["url"] as? String,
              let returnedURL = NostrProtocol.validatedRemoteHTTPSURL(returnedURLString) else {
            throw BlossomMediaError.invalidResponse
        }
        let returnedHash = (json["sha256"] as? String)?.lowercased() ?? sha256Hex
        guard returnedHash == sha256Hex else {
            throw BlossomMediaError.hashMismatch
        }
        return NostrProtocol.MediaAttachment(
            url: returnedURL,
            mimeType: "image/jpeg",
            sha256Hex: sha256Hex,
            sizeBytes: processed.jpegData.count,
            dimensions: "\(processed.width)x\(processed.height)"
        )
    }

    /// Downloads a remote Blossom image over Tor (when enabled), verifies its
    /// exact SHA-256 digest against `attachment.sha256Hex`, validates image
    /// dimensions, and caches the downsampled result in RAM.
    func fetchVerifiedImage(for attachment: NostrProtocol.MediaAttachment) async throws -> ImageDownsampler.PlatformImage {
        let key = attachment.sha256Hex.lowercased()
        let lookup = cache.lookup(key)
        if let cached = lookup.image {
            return cached
        }
        let generation = lookup.generation

        guard dependencies.isNetworkActivationAllowed() else {
            throw BlossomMediaError.networkDisabled
        }
        guard await dependencies.awaitTorReady() else {
            throw BlossomMediaError.torNotReady
        }
        guard NostrProtocol.validatedRemoteHTTPSURL(attachment.url.absoluteString) != nil else {
            throw BlossomMediaError.invalidServerURL
        }

        var request = URLRequest(url: attachment.url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30

        let (data, statusCode) = try await dependencies.performRequest(request, Self.maxDownloadBytes)
        guard (200...299).contains(statusCode) else {
            throw BlossomMediaError.uploadFailed(statusCode)
        }
        guard data.sha256Fingerprint() == key else {
            throw BlossomMediaError.hashMismatch
        }

        guard let decoded = await Task.detached(priority: .userInitiated, operation: {
            Self.decodeDownsampledCGImage(from: data, maxPixelSize: ImageDownsampler.inlineMaxPixelSize)
        }).value else {
            throw BlossomMediaError.invalidImage
        }
        let image: ImageDownsampler.PlatformImage
        #if os(iOS)
        image = UIImage(cgImage: decoded.cgImage)
        #else
        image = NSImage(
            cgImage: decoded.cgImage,
            size: NSSize(width: decoded.cgImage.width, height: decoded.cgImage.height)
        )
        #endif
        cache.store(image, for: key, cost: decoded.cost, expectedGeneration: generation)
        return image
    }

    nonisolated private static func decodeDownsampledCGImage(
        from data: Data,
        maxPixelSize: Int
    ) -> (cgImage: CGImage, cost: Int)? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              ImageContainerValidator.validateDimensions(of: source) == nil else {
            return nil
        }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return nil
        }
        let cost = max(1, cgImage.width * cgImage.height * 4)
        return (cgImage, cost)
    }

    /// Panic-wipe hook: clears cached decrypted/verified remote images and
    /// resets any custom Blossom server preference.
    func resetForPanic() {
        cache.reset()
        defaults.removeObject(forKey: Self.serverURLKey)
    }
}
