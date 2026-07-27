//
// StickerPackService.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Combine
import Foundation
import ImageIO
import Tor

// MARK: - LOCAL STUB for StickerRefCodec validators
//
// `bitchat/Protocols/StickerRefCodec.swift` (owned by a parallel delegate) is
// expected to provide `StickerRef` plus `StickerRefCodec.isValidCoordinate /
// isValidShortcode / isValidSha256`. Until that file lands, the validator
// shapes are stubbed here so the services layer compiles and stays testable.
// A later pass should re-point these at the codec (or have the codec call
// these) — do NOT duplicate them further.
enum StickerRefValidation {
    /// Strictly `[0-9a-f]{64}` — safe to use as a file name after this passes.
    static func isValidSha256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit } && value == value.lowercased()
    }

    /// Nostr pubkey hex has the same shape as a sha256 hex string.
    static func isValidPubkeyHex(_ value: String) -> Bool { isValidSha256(value) }

    /// Shortcode: `[a-z0-9_-]{1,64}`.
    static func isValidShortcode(_ value: String) -> Bool {
        guard (1...64).contains(value.count) else { return false }
        return value.allSatisfy { c in
            c.isASCII && ((c.isLetter && c.isLowercase) || c.isNumber || c == "_" || c == "-")
        }
    }

    /// `d` identifier: printable ASCII except whitespace, 1...256 chars.
    static func isValidPackIdentifier(_ value: String) -> Bool {
        guard (1...256).contains(value.count) else { return false }
        return value.unicodeScalars.allSatisfy { (0x21...0x7E).contains($0.value) }
    }

    /// Pack coordinate: `30031:<author-pubkey-hex>:<d-identifier>`.
    static func isValidCoordinate(_ value: String) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "30031" else { return false }
        return isValidPubkeyHex(String(parts[1])) && isValidPackIdentifier(String(parts[2]))
    }
}

// MARK: - Models

struct StickerDimensions: Codable, Equatable, Sendable {
    let width: Int
    let height: Int
}

struct Sticker: Codable, Equatable, Sendable, Identifiable {
    let shortcode: String
    let url: URL
    /// Lowercase hex SHA-256 of the plaintext bytes (also present in `url.path`).
    let sha256: String
    /// One of image/webp, image/png, image/apng, image/gif.
    let mime: String
    let dim: StickerDimensions?
    let alt: String?
    let emoji: String?

    var id: String { shortcode }
}

struct StickerPack: Codable, Equatable, Sendable, Identifiable {
    /// `30031:<author-pubkey-hex>:<d-identifier>`.
    let coordinate: String
    let authorPubkey: String
    let identifier: String
    let title: String
    let description: String?
    let coverURL: URL?
    let createdAt: Date
    let stickers: [Sticker]

    var id: String { coordinate }
}

// MARK: - One-shot relay queries

/// One-shot, EOSE-bounded Nostr queries used by the sticker services.
///
/// Goes through `NostrRelayManager.shared`, so the global network-activation
/// gate and the manager's own Tor fail-closed queueing apply; `relayUrls: nil`
/// targets the built-in default relay set (damus/nos.lol/primal/offchain +
/// user-added), never the geo relays.
enum StickerRelayQuery {
    @MainActor
    static func oneShot(
        filter: NostrFilter,
        timeout: TimeInterval = 10
    ) async -> [NostrEvent] {
        await withCheckedContinuation { continuation in
            let query = StickerOneShotQuery(continuation: continuation)
            query.start(filter: filter, timeout: timeout)
        }
    }
}

@MainActor
private final class StickerOneShotQuery {
    private var events: [NostrEvent] = []
    private var continuation: CheckedContinuation<[NostrEvent], Never>?
    private var timeoutTask: Task<Void, Never>?

    init(continuation: CheckedContinuation<[NostrEvent], Never>) {
        self.continuation = continuation
    }

    func start(filter: NostrFilter, timeout: TimeInterval) {
        let id = "sticker-oneshot-\(UUID().uuidString)"
        NostrRelayManager.shared.subscribe(
            filter: filter,
            id: id,
            relayUrls: nil,
            handler: { [weak self] event in
                Task { @MainActor in self?.events.append(event) }
            },
            onEOSE: { [weak self] in
                Task { @MainActor in self?.finish(id: id) }
            }
        )
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self?.finish(id: id) // no-op if EOSE already finished
        }
    }

    private func finish(id: String) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        NostrRelayManager.shared.unsubscribe(id: id)
        continuation.resume(returning: events)
    }
}

// MARK: - Service

/// Resolves Sonar sticker packs (Nostr kind 30031, format
/// `sonar-sticker-pack-v1`) and downloads/caches sticker images.
///
/// Rendering never hits the network synchronously: pack metadata is cached in
/// memory (plus a small JSON sidecar) with a 24h TTL, and image bytes come
/// from `StickerCache` whenever possible. All internet access is Tor-aware and
/// fail-closed (see `makeTorDownloader`).
@MainActor
final class StickerPackService: ObservableObject {
    typealias RelayQuery = @Sendable (NostrFilter) async -> [NostrEvent]
    typealias Downloader = @Sendable (URL) async throws -> Data

    enum StickerPackError: Swift.Error, Equatable {
        case packNotFound
        case invalidCoordinate
        /// Network activation gate is closed (no permission/favorites/offline).
        case networkNotAllowed
        /// Tor preference is on but Tor failed to become ready. Fail-closed:
        /// the fetch is refused rather than leaked to clearnet.
        case torNotReady
        case downloadTooLarge
        case mimeMismatch
        case invalidImageData
    }

    nonisolated static let packEventKind = 30031
    nonisolated static let packFormatValue = "sonar-sticker-pack-v1"
    nonisolated static let maxStickersPerPack = 200
    nonisolated static let maxImageDimension = 4096
    nonisolated static let metadataTTL: TimeInterval = 24 * 60 * 60
    nonisolated static let allowedMimes: Set<String> = ["image/webp", "image/png", "image/apng", "image/gif"]

    static let shared = StickerPackService()

    /// Pack metadata keyed by coordinate, for synchronous render lookups.
    @Published private(set) var packs: [String: StickerPack] = [:]
    private var packFetchedAt: [String: Date] = [:]

    private let cache: StickerCache
    private let relayQuery: RelayQuery
    private let downloader: Downloader
    private let networkActivationAllowed: @Sendable () async -> Bool
    private let now: @Sendable () -> Date
    private let metadataURL: URL?

    init(
        cache: StickerCache = StickerCache(),
        relayQuery: @escaping RelayQuery = { filter in
            await StickerRelayQuery.oneShot(filter: filter)
        },
        downloader: @escaping Downloader = StickerPackService.makeTorDownloader(),
        networkActivationAllowed: @escaping @Sendable () async -> Bool = {
            await NetworkActivationService.shared.activationAllowed
        },
        metadataURL: URL? = try? StickerStoragePaths.stickersDirectory()
            .appendingPathComponent("pack-metadata.json", isDirectory: false),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.cache = cache
        self.relayQuery = relayQuery
        self.downloader = downloader
        self.networkActivationAllowed = networkActivationAllowed
        self.metadataURL = metadataURL
        self.now = now
        loadMetadata()
    }

    // MARK: - Pack event parsing (pure, spec-validating)

    /// Parses and fully validates a kind-30031 `sonar-sticker-pack-v1` event.
    /// Any spec violation rejects the whole pack (returns nil).
    nonisolated static func parsePackEvent(_ event: NostrEvent) -> StickerPack? {
        guard event.kind == packEventKind else { return nil }
        guard StickerRefValidation.isValidPubkeyHex(event.pubkey) else { return nil }
        guard event.tags.contains(where: {
            $0.count >= 2 && $0[0] == "pack_format" && $0[1] == packFormatValue
        }) else { return nil }

        guard let dTag = event.tags.first(where: { $0.count >= 2 && $0[0] == "d" }),
              StickerRefValidation.isValidPackIdentifier(dTag[1]) else { return nil }
        let identifier = dTag[1]

        guard let titleTag = event.tags.first(where: { $0.count >= 2 && $0[0] == "title" }),
              titleTag[1].utf8.count <= 256,
              !titleTag[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        let description = event.tags.first(where: { $0.count >= 2 && $0[0] == "description" })?[1]

        var coverURL: URL? = nil
        if let imageTag = event.tags.first(where: { $0.count >= 2 && $0[0] == "image" }) {
            guard let url = validatedHTTPSURL(imageTag[1]) else { return nil }
            coverURL = url
        }

        let stickerTags = event.tags.filter { $0.count >= 2 && $0[0] == "sticker" }
        guard (1...maxStickersPerPack).contains(stickerTags.count) else { return nil }

        var seenShortcodes = Set<String>()
        var seenHashes = Set<String>()
        var stickers: [Sticker] = []
        stickers.reserveCapacity(stickerTags.count)

        for tag in stickerTags {
            // ["sticker", shortcode, url, sha256, mime, dim?, alt?, emoji?]
            guard tag.count >= 5 else { return nil }
            let shortcode = tag[1]
            let hash = tag[3]
            let mime = tag[4]
            guard StickerRefValidation.isValidShortcode(shortcode) else { return nil }
            guard StickerRefValidation.isValidSha256(hash) else { return nil }
            guard allowedMimes.contains(mime) else { return nil }
            guard let url = validatedStickerURL(tag[2], sha256: hash) else { return nil }

            var dim: StickerDimensions? = nil
            if tag.count >= 6, !tag[5].isEmpty {
                guard let parsed = parseDimensions(tag[5]) else { return nil }
                dim = parsed
            }
            let alt = tag.count >= 7 ? tag[6] : nil
            let emoji = tag.count >= 8 ? tag[7] : nil

            guard seenShortcodes.insert(shortcode).inserted else { return nil }
            guard seenHashes.insert(hash).inserted else { return nil }
            stickers.append(Sticker(
                shortcode: shortcode, url: url, sha256: hash,
                mime: mime, dim: dim, alt: alt, emoji: emoji
            ))
        }

        return StickerPack(
            coordinate: "30031:\(event.pubkey):\(identifier)",
            authorPubkey: event.pubkey,
            identifier: identifier,
            title: titleTag[1],
            description: description,
            coverURL: coverURL,
            createdAt: Date(timeIntervalSince1970: TimeInterval(event.created_at)),
            stickers: stickers
        )
    }

    /// HTTPS-only, no embedded credentials.
    nonisolated static func validatedHTTPSURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              url.host != nil,
              url.user == nil, url.password == nil
        else { return nil }
        return url
    }

    /// Sticker asset URL: HTTPS-only and the path must contain the lowercase
    /// sha256 (binds the URL to the pinned hash).
    nonisolated static func validatedStickerURL(_ raw: String, sha256: String) -> URL? {
        guard let url = validatedHTTPSURL(raw),
              url.path.lowercased().contains(sha256)
        else { return nil }
        return url
    }

    /// `WxH` with both dimensions in 1...4096.
    nonisolated static func parseDimensions(_ raw: String) -> StickerDimensions? {
        let parts = raw.split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let w = Int(parts[0]), let h = Int(parts[1]),
              (1...maxImageDimension).contains(w),
              (1...maxImageDimension).contains(h)
        else { return nil }
        return StickerDimensions(width: w, height: h)
    }

    // MARK: - Pack fetching

    /// Fetches a pack by author + identifier, preferring the 24h metadata
    /// cache. Relay queries are one-shot (EOSE-bounded, ~10s timeout) on the
    /// built-in default relay set; the latest `created_at` wins.
    func fetchPack(authorPubkeyHex: String, identifier: String) async throws -> StickerPack {
        guard StickerRefValidation.isValidPubkeyHex(authorPubkeyHex),
              StickerRefValidation.isValidPackIdentifier(identifier)
        else { throw StickerPackError.invalidCoordinate }
        let coordinate = "30031:\(authorPubkeyHex):\(identifier)"

        if let cached = packs[coordinate],
           let fetchedAt = packFetchedAt[coordinate],
           now().timeIntervalSince(fetchedAt) < Self.metadataTTL {
            return cached
        }

        // NOTE: NostrFilter.tagFilters is fileprivate, so a server-side "#d"
        // filter cannot be expressed from this file. We query by kind+author
        // and filter the identifier client-side. A follow-up could add a
        // `NostrFilter.stickerPack(author:identifier:)` factory next to the
        // other factories in NostrRelayManager.swift.
        var filter = NostrFilter()
        filter.kinds = [Self.packEventKind]
        filter.authors = [authorPubkeyHex]
        filter.limit = 20

        let events = await relayQuery(filter)
        let candidates = events
            .compactMap(Self.parsePackEvent)
            .filter { $0.authorPubkey == authorPubkeyHex && $0.identifier == identifier }
        guard let latest = candidates.max(by: { $0.createdAt < $1.createdAt }) else {
            throw StickerPackError.packNotFound
        }

        packs[coordinate] = latest
        packFetchedAt[coordinate] = now()
        persistMetadata()
        return latest
    }

    /// Synchronous cache-only lookup for renderers — never queries the network.
    func cachedPack(forCoordinate coordinate: String) -> StickerPack? {
        packs[coordinate]
    }

    // MARK: - Image fetching

    /// Returns sticker bytes from the disk cache when present; otherwise
    /// downloads through the Tor-aware fail-closed pipeline (network-activation
    /// gate → streamed 4 MiB cap → MIME sniff vs declared → CGImageSource
    /// dimension check) and stores them in `StickerCache`, which re-verifies
    /// the sha256 and applies negative-cache backoff to failures.
    func imageData(for sticker: Sticker) async throws -> Data {
        if let data = await cache.data(for: sticker.sha256) { return data }
        return try await cache.fetch(
            sha256: sticker.sha256,
            url: sticker.url,
            mime: sticker.mime
        ) { [downloader, networkActivationAllowed] url in
            guard await networkActivationAllowed() else {
                throw StickerPackError.networkNotAllowed
            }
            let data = try await downloader(url)
            try Self.validateDownloadedImage(data, declaredMime: sticker.mime)
            return data
        }
    }

    /// Pack-edit attack guard: a ref is only trustworthy when the CURRENT pack
    /// still contains BOTH the shortcode and the pinned plaintext hash. When
    /// this is false the caller must render an "untrusted sticker" placeholder.
    nonisolated func validateStickerRef(
        packCoordinate: String,
        shortcode: String,
        plaintextSha256: String,
        against pack: StickerPack
    ) -> Bool {
        guard pack.coordinate == packCoordinate else { return false }
        return pack.stickers.contains {
            $0.shortcode == shortcode && $0.sha256 == plaintextSha256
        }
    }

    // MARK: - Download validation

    /// Size cap, MIME byte-sniff vs declared type (APNG sniffs as PNG — both
    /// carry the PNG signature), and CGImageSource dimension check (≤4096²).
    nonisolated static func validateDownloadedImage(_ data: Data, declaredMime: String) throws {
        guard !data.isEmpty, data.count <= StickerCache.maxStickerBytes else {
            throw StickerPackError.downloadTooLarge
        }
        let sniffOK: Bool
        switch declaredMime {
        case "image/webp": sniffOK = MimeType.webp.matches(data: data)
        case "image/png", "image/apng": sniffOK = MimeType.png.matches(data: data)
        case "image/gif": sniffOK = MimeType.gif.matches(data: data)
        default: sniffOK = false
        }
        guard sniffOK else { throw StickerPackError.mimeMismatch }

        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              CGImageSourceGetType(source) != nil,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width >= 1, height >= 1,
              width <= maxImageDimension, height <= maxImageDimension
        else { throw StickerPackError.invalidImageData }
    }

    /// Default downloader: all traffic through `TorURLSession.shared.session`,
    /// fail-closed on the Tor preference (mirrors GeoRelayDirectory): when Tor
    /// is wanted but not ready, the fetch is refused — never clearnet.
    /// Content-Length is not trusted; bytes are counted as they arrive.
    nonisolated static func makeTorDownloader() -> Downloader {
        { url in
            if NetworkActivationService.persistedTorPreference() {
                guard await TorManager.shared.awaitReady() else {
                    throw StickerPackError.torNotReady
                }
            }
            let session = TorURLSession.shared.session
            let (bytes, response) = try await session.bytes(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode)
            else { throw URLError(.badServerResponse) }
            var data = Data()
            for try await byte in bytes {
                guard data.count < StickerCache.maxStickerBytes else {
                    throw StickerPackError.downloadTooLarge
                }
                data.append(byte)
            }
            return data
        }
    }

    // MARK: - Metadata persistence (24h TTL, small JSON sidecar)

    private struct PersistedMetadata: Codable {
        var packs: [String: StickerPack]
        var fetchedAt: [String: Date]
    }

    private func persistMetadata() {
        guard let metadataURL,
              let data = try? JSONEncoder().encode(
                  PersistedMetadata(packs: packs, fetchedAt: packFetchedAt)
              ) else { return }
        try? data.write(to: metadataURL, options: .atomic)
    }

    private func loadMetadata() {
        guard let metadataURL,
              let data = try? Data(contentsOf: metadataURL),
              let decoded = try? JSONDecoder().decode(PersistedMetadata.self, from: data)
        else { return }
        let reference = now()
        for (coordinate, fetchedAt) in decoded.fetchedAt
        where reference.timeIntervalSince(fetchedAt) < Self.metadataTTL {
            guard let pack = decoded.packs[coordinate] else { continue }
            packs[coordinate] = pack
            packFetchedAt[coordinate] = fetchedAt
        }
    }
}
