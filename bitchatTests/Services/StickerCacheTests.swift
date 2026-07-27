//
// StickerCacheTests.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import CryptoKit
import Foundation
import Testing
@testable import bitchat

@Suite("StickerCache Tests")
struct StickerCacheTests {

    // MARK: - Helpers

    private final class MutableClock: @unchecked Sendable {
        var current: Date = Date(timeIntervalSince1970: 1_000)
        func now() -> Date { current }
    }

    private final class Counter: @unchecked Sendable {
        var value = 0
    }

    private func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sticker-cache-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Tests

    @Test("store → data round-trip returns identical bytes")
    func storeThenReadRoundTrip() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let cache = StickerCache(baseDirectory: dir)

        let bytes = Data("hello sticker".utf8)
        let hash = sha256Hex(bytes)
        try await cache.store(bytes, sha256: hash, mime: "image/webp")

        let read = await cache.data(for: hash)
        #expect(read == bytes)
        // Extension is derived from the MIME type.
        let fileURL = await cache.fileURL(for: hash)
        #expect(fileURL?.lastPathComponent == "\(hash).webp")
    }

    @Test("mismatched hash throws before writing and leaves no file")
    func mismatchedHashRejectedBeforeWrite() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let cache = StickerCache(baseDirectory: dir)

        let bytes = Data("actual bytes".utf8)
        let wrongHash = String(repeating: "f", count: 64)

        await #expect(throws: StickerCache.Error.hashMismatch) {
            try await cache.store(bytes, sha256: wrongHash, mime: "image/png")
        }

        let stickersDir = dir.appendingPathComponent("files/stickers", isDirectory: true)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: stickersDir.path)) ?? []
        #expect(contents.isEmpty)
        #expect(await cache.data(for: wrongHash) == nil)
    }

    @Test("payloads over 4 MiB are rejected")
    func oversizedRejected() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let cache = StickerCache(baseDirectory: dir)

        let big = Data(repeating: 0xAB, count: StickerCache.maxStickerBytes + 1)
        let hash = sha256Hex(big)
        await #expect(throws: StickerCache.Error.stickerTooLarge) {
            try await cache.store(big, sha256: hash, mime: "image/webp")
        }
        #expect(await cache.data(for: hash) == nil)
    }

    @Test("path-traversal and malformed hash strings are rejected")
    func traversalRejected() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let cache = StickerCache(baseDirectory: dir)
        let bytes = Data("x".utf8)

        let bad = [
            "../\(String(repeating: "a", count: 61))",
            "\(String(repeating: "a", count: 32))/../\(String(repeating: "b", count: 27))",
            String(repeating: "A", count: 64), // uppercase is not a valid file name
            String(repeating: "g", count: 64), // not hex
            String(repeating: "a", count: 63), // too short
            "a/a" + String(repeating: "0", count: 61)
        ]
        for hash in bad {
            await #expect(throws: StickerCache.Error.invalidSHA256) {
                try await cache.store(bytes, sha256: hash, mime: "image/png")
            }
            #expect(await cache.data(for: hash) == nil)
        }
    }

    @Test("removeAll clears cached bytes and negative-cache state")
    func removeAllClears() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let cache = StickerCache(baseDirectory: dir)

        let bytes = Data("wipe me".utf8)
        let hash = sha256Hex(bytes)
        try await cache.store(bytes, sha256: hash, mime: "image/gif")
        #expect(await cache.data(for: hash) != nil)

        await cache.removeAll()
        #expect(await cache.data(for: hash) == nil)
        #expect(await cache.fileURL(for: hash) == nil)
    }

    @Test("LRU eviction removes the oldest last-access entry first")
    func lruEvictsOldestAccess() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let clock = MutableClock()
        // Cap of 100 bytes: three 40-byte stickers cannot all fit.
        let cache = StickerCache(baseDirectory: dir, maxCacheBytes: 100, now: clock.now)

        let aBytes = Data(repeating: 0xA1, count: 40)
        let bBytes = Data(repeating: 0xB2, count: 40)
        let cBytes = Data(repeating: 0xC3, count: 40)
        let a = sha256Hex(aBytes)
        let b = sha256Hex(bBytes)
        let c = sha256Hex(cBytes)

        clock.current = Date(timeIntervalSince1970: 1)
        try await cache.store(aBytes, sha256: a, mime: "image/png")
        clock.current = Date(timeIntervalSince1970: 2)
        try await cache.store(bBytes, sha256: b, mime: "image/png")
        // Touch A so B becomes the oldest last-access entry.
        clock.current = Date(timeIntervalSince1970: 3)
        _ = await cache.data(for: a)
        clock.current = Date(timeIntervalSince1970: 4)
        try await cache.store(cBytes, sha256: c, mime: "image/png")

        #expect(await cache.data(for: b) == nil) // evicted
        #expect(await cache.data(for: a) != nil)
        #expect(await cache.data(for: c) != nil)
    }

    @Test("negative cache blocks immediate refetch after a failure")
    func negativeCacheBackoffBlocksRefetch() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let cache = StickerCache(baseDirectory: dir)

        let hash = String(repeating: "1", count: 64)
        let url = URL(string: "https://cdn.example.com/stickers/\(hash).webp")!
        let calls = Counter()

        await #expect(throws: URLError.self) {
            _ = try await cache.fetch(sha256: hash, url: url) { _ in
                calls.value += 1
                throw URLError(.notConnectedToInternet)
            }
        }
        #expect(calls.value == 1)

        // Immediate retry must short-circuit without invoking the downloader.
        do {
            _ = try await cache.fetch(sha256: hash, url: url) { _ in
                calls.value += 1
                return Data()
            }
            Issue.record("expected negativeCacheBackoff error")
        } catch let StickerCache.Error.negativeCacheBackoff(retryAfter) {
            #expect(retryAfter > Date())
        }
        #expect(calls.value == 1)
    }

    @Test("concurrent fetches for the same hash coalesce onto one download")
    func fetchCoalescesInFlight() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let cache = StickerCache(baseDirectory: dir)

        let bytes = Data("coalesced".utf8)
        let hash = sha256Hex(bytes)
        let url = URL(string: "https://cdn.example.com/stickers/\(hash).webp")!
        let calls = Counter()

        async let first = cache.fetch(sha256: hash, url: url, mime: "image/webp") { _ in
            calls.value += 1
            try? await Task.sleep(nanoseconds: 100_000_000)
            return bytes
        }
        async let second = cache.fetch(sha256: hash, url: url, mime: "image/webp") { _ in
            calls.value += 1
            try? await Task.sleep(nanoseconds: 100_000_000)
            return bytes
        }

        let results = try await [first, second]
        #expect(results == [bytes, bytes])
        #expect(calls.value == 1)
        // And the result was persisted.
        #expect(await cache.data(for: hash) == bytes)
    }
}
