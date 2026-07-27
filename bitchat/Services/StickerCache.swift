//
// StickerCache.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import CryptoKit

/// Shared on-disk locations for the Sonar sticker feature.
///
/// Everything lives under `Application Support/files/stickers/` — the same
/// `files` tree that `BLEIncomingFileStore.panicWipe` removes, so sticker
/// data is covered by panic wipe without any extra wiring.
enum StickerStoragePaths {
    static func filesDirectory(
        base: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let root = try base ?? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = root.appendingPathComponent("files", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func stickersDirectory(
        base: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let dir = try filesDirectory(base: base, fileManager: fileManager)
            .appendingPathComponent("stickers", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// Content-addressed disk cache for sticker image bytes.
///
/// Layout: `Application Support/files/stickers/<sha256>[.<ext>]`. The file name
/// is the lowercase hex SHA-256 of the plaintext (validated as strictly
/// `[0-9a-f]{64}` before any path join, so traversal is impossible), plus an
/// optional extension derived from the declared MIME type.
///
/// Last-access bookkeeping for LRU eviction lives in a small JSON sidecar
/// (`_index.json`) inside the same directory. Chosen over extended attributes
/// because xattrs do not survive some backup/restore and file-copy paths and
/// are awkward to inspect in tests; a sidecar keeps all cache state in one
/// directory that panic wipe already removes.
///
/// The negative cache (failed hash → next-retry timestamp, exponential backoff
/// from 30s capped at 30min) is intentionally in-memory only: a restart simply
/// resets backoff, which is acceptable for a cache.
actor StickerCache {
    enum Error: Swift.Error, Equatable {
        /// Hash string is not strictly `[0-9a-f]{64}` (includes traversal attempts).
        case invalidSHA256
        /// SHA-256 of the supplied bytes does not match the claimed hash.
        case hashMismatch
        /// Sticker bytes exceed the 4 MiB hard cap.
        case stickerTooLarge
        /// A previous fetch failed recently; backoff has not elapsed yet.
        case negativeCacheBackoff(retryAfter: Date)
    }

    static let maxStickerBytes = 4 * 1024 * 1024
    static let defaultMaxCacheBytes = 100 * 1024 * 1024
    static let negativeCacheInitialDelay: TimeInterval = 30
    static let negativeCacheMaxDelay: TimeInterval = 30 * 60

    typealias Downloader = @Sendable (URL) async throws -> Data

    private struct IndexEntry: Codable {
        var lastAccess: TimeInterval
        var fileExtension: String?
        var size: Int
    }

    private let stickersDirectory: URL
    private let indexURL: URL
    private let maxCacheBytes: Int
    private let fileManager: FileManager
    private let now: @Sendable () -> Date

    // No default value: assigned exactly once in init (a later mutation of a
    // defaulted property from the nonisolated init is an error in Swift 6 mode).
    private var index: [String: IndexEntry]
    private var inFlight: [String: Task<Data, Swift.Error>] = [:]
    private var failureCounts: [String: Int] = [:]
    private var negativeCache: [String: Date] = [:]
    private var lastIndexPersist: Date = .distantPast

    init(
        baseDirectory: URL? = nil,
        maxCacheBytes: Int = StickerCache.defaultMaxCacheBytes,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        let dir = (try? StickerStoragePaths.stickersDirectory(base: baseDirectory, fileManager: fileManager))
            ?? fileManager.temporaryDirectory
                .appendingPathComponent("bitchat-stickers-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        self.stickersDirectory = dir
        self.indexURL = dir.appendingPathComponent("_index.json", isDirectory: false)
        self.maxCacheBytes = maxCacheBytes
        self.fileManager = fileManager
        self.now = now
        // Load the LRU sidecar and drop entries whose file disappeared
        // (e.g. manual cleanup). Done inline: actor inits are nonisolated, so
        // isolated helper calls from here are an error in Swift 6 mode.
        var initialIndex: [String: IndexEntry] = [:]
        if let data = try? Data(contentsOf: self.indexURL),
           let decoded = try? JSONDecoder().decode([String: IndexEntry].self, from: data) {
            initialIndex = decoded
        }
        for (hash, entry) in initialIndex
        where !fileManager.fileExists(atPath: Self.fileURL(in: dir, forHash: hash, extension: entry.fileExtension).path) {
            initialIndex.removeValue(forKey: hash)
        }
        self.index = initialIndex
    }

    // MARK: - Reads

    /// Returns cached bytes for a hash, or nil. Invalid hash shapes return nil
    /// (never throw, never touch the disk path builder with untrusted input).
    func data(for sha256: String) -> Data? {
        guard StickerRefValidation.isValidSha256(sha256) else { return nil }
        let url: URL
        if let entry = index[sha256] {
            url = fileURL(forHash: sha256, extension: entry.fileExtension)
        } else {
            url = fileURL(forHash: sha256, extension: nil)
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        index[sha256] = IndexEntry(
            lastAccess: now().timeIntervalSince1970,
            fileExtension: index[sha256]?.fileExtension,
            size: data.count
        )
        persistIndex()
        return data
    }

    /// On-disk location of a cached sticker, for renderers that prefer a file
    /// URL (animated webp/gif). Nil when not cached or the hash shape is invalid.
    func fileURL(for sha256: String) -> URL? {
        guard StickerRefValidation.isValidSha256(sha256) else { return nil }
        if let entry = index[sha256] {
            let url = fileURL(forHash: sha256, extension: entry.fileExtension)
            return fileManager.fileExists(atPath: url.path) ? url : nil
        }
        let bare = fileURL(forHash: sha256, extension: nil)
        return fileManager.fileExists(atPath: bare.path) ? bare : nil
    }

    // MARK: - Writes

    /// Verifies the SHA-256 of `data` BEFORE writing anything. Rejects invalid
    /// hash shapes (traversal guard) and payloads over 4 MiB.
    func store(_ data: Data, sha256: String, mime: String) throws {
        guard StickerRefValidation.isValidSha256(sha256) else { throw Error.invalidSHA256 }
        guard data.count <= Self.maxStickerBytes else { throw Error.stickerTooLarge }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == sha256 else { throw Error.hashMismatch }
        let ext = Self.fileExtension(for: mime)
        let url = fileURL(forHash: sha256, extension: ext)
        try data.write(to: url, options: .atomic)
        index[sha256] = IndexEntry(
            lastAccess: now().timeIntervalSince1970,
            fileExtension: ext,
            size: data.count
        )
        persistIndex()
        evictIfNeeded(protecting: sha256)
    }

    // MARK: - Fetch with coalescing + negative cache

    /// Returns cached bytes when present; otherwise coalesces concurrent calls
    /// per hash onto a single in-flight download, stores the result (which
    /// re-verifies the hash), and applies exponential-backoff negative caching
    /// to failures (30s initial, doubling, capped at 30min).
    func fetch(
        sha256: String,
        url: URL,
        mime: String = "",
        using downloader: @escaping Downloader
    ) async throws -> Data {
        guard StickerRefValidation.isValidSha256(sha256) else { throw Error.invalidSHA256 }
        if let cached = data(for: sha256) { return cached }
        if let retryAfter = negativeCache[sha256], now() < retryAfter {
            throw Error.negativeCacheBackoff(retryAfter: retryAfter)
        }
        if let existing = inFlight[sha256] {
            return try await existing.value
        }
        let task = Task { try await downloader(url) }
        inFlight[sha256] = task
        do {
            let data = try await task.value
            inFlight.removeValue(forKey: sha256)
            try store(data, sha256: sha256, mime: mime)
            negativeCache.removeValue(forKey: sha256)
            failureCounts.removeValue(forKey: sha256)
            return data
        } catch {
            inFlight.removeValue(forKey: sha256)
            recordFailure(for: sha256)
            throw error
        }
    }

    // MARK: - Wipe

    /// Removes every cached sticker and all bookkeeping. In-flight downloads
    /// are left to finish (their `store` re-verifies and re-creates entries).
    func removeAll() {
        try? fileManager.removeItem(at: stickersDirectory)
        try? fileManager.createDirectory(at: stickersDirectory, withIntermediateDirectories: true)
        index.removeAll()
        negativeCache.removeAll()
        failureCounts.removeAll()
        lastIndexPersist = .distantPast
    }

    // MARK: - Internals

    static func fileExtension(for mime: String) -> String? {
        switch mime {
        case "image/webp": return "webp"
        case "image/png", "image/apng": return "png" // APNG carries a PNG signature/container
        case "image/gif": return "gif"
        default: return nil
        }
    }

    private nonisolated static func fileURL(in directory: URL, forHash hash: String, extension ext: String?) -> URL {
        let name = ext.map { "\(hash).\($0)" } ?? hash
        return directory.appendingPathComponent(name, isDirectory: false)
    }

    private nonisolated func fileURL(forHash hash: String, extension ext: String?) -> URL {
        Self.fileURL(in: stickersDirectory, forHash: hash, extension: ext)
    }

    private func recordFailure(for hash: String) {
        let count = (failureCounts[hash] ?? 0) + 1
        failureCounts[hash] = count
        let delay = min(
            Self.negativeCacheInitialDelay * pow(2.0, Double(count - 1)),
            Self.negativeCacheMaxDelay
        )
        negativeCache[hash] = now().addingTimeInterval(delay)
    }

    private func evictIfNeeded(protecting protectedHash: String? = nil) {
        var total = index.values.reduce(0) { $0 + $1.size }
        guard total > maxCacheBytes else { return }
        // Oldest last-access first.
        for (hash, entry) in index.sorted(by: { $0.value.lastAccess < $1.value.lastAccess }) {
            guard total > maxCacheBytes else { break }
            if hash == protectedHash { continue }
            try? fileManager.removeItem(at: fileURL(forHash: hash, extension: entry.fileExtension))
            index.removeValue(forKey: hash)
            total -= entry.size
        }
        persistIndex()
    }

    /// Index writes are throttled on the read path (one disk write per 5s at
    /// most) and forced on mutations, so hot render loops don't thrash the disk.
    private func persistIndex(force: Bool = false) {
        guard force || now().timeIntervalSince(lastIndexPersist) > 5 else { return }
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: indexURL, options: .atomic)
        lastIndexPersist = now()
    }
}
