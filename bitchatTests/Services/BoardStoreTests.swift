//
// BoardStoreTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import CryptoKit
import Foundation
import Testing
@testable import bitchat

struct BoardStoreTests {

    private final class MutableClock: @unchecked Sendable {
        var now: Date
        init(now: Date) { self.now = now }
    }

    private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
    private var baseMs: UInt64 { UInt64(baseDate.timeIntervalSince1970 * 1000) }

    private func makeStore(clock: MutableClock, fileURL: URL? = nil) -> BoardStore {
        BoardStore(persistsToDisk: fileURL != nil, fileURL: fileURL, now: { clock.now })
    }

    private func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("board-store-\(UUID().uuidString).json")
    }

    private func makePost(
        author: Curve25519.Signing.PrivateKey,
        geohash: String = "9q8yy",
        content: String = "note",
        createdAt: UInt64,
        lifetimeMs: UInt64 = 24 * 60 * 60 * 1000
    ) throws -> (wire: BoardWire, packet: BitchatPacket, post: BoardPostPacket) {
        let postID = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let key = author.publicKey.rawRepresentation
        let expiresAt = createdAt + lifetimeMs
        let signingBytes = BoardPostPacket.signingBytes(
            postID: postID,
            geohash: geohash,
            content: content,
            authorSigningKey: key,
            authorNickname: "tester",
            createdAt: createdAt,
            expiresAt: expiresAt,
            flags: 0
        )
        let post = BoardPostPacket(
            postID: postID,
            geohash: geohash,
            content: content,
            authorSigningKey: key,
            authorNickname: "tester",
            createdAt: createdAt,
            expiresAt: expiresAt,
            flags: 0,
            signature: try author.signature(for: signingBytes)
        )
        let wire = BoardWire.post(post)
        return (wire, makePacket(payload: wire.encode(), timestamp: createdAt), post)
    }

    private func makeTombstone(
        for post: BoardPostPacket,
        author: Curve25519.Signing.PrivateKey,
        deletedAt: UInt64,
        claimKey: Data? = nil
    ) throws -> (wire: BoardWire, packet: BitchatPacket) {
        let tombstone = BoardTombstonePacket(
            postID: post.postID,
            authorSigningKey: claimKey ?? author.publicKey.rawRepresentation,
            deletedAt: deletedAt,
            signature: try author.signature(for: BoardTombstonePacket.signingBytes(postID: post.postID, deletedAt: deletedAt))
        )
        let wire = BoardWire.tombstone(tombstone)
        return (wire, makePacket(payload: wire.encode(), timestamp: deletedAt))
    }

    private func makePacket(payload: Data, timestamp: UInt64) -> BitchatPacket {
        BitchatPacket(
            type: MessageType.boardPost.rawValue,
            senderID: Data((0..<8).map { _ in UInt8.random(in: 0...255) }),
            recipientID: nil,
            timestamp: timestamp,
            payload: payload,
            signature: nil,
            ttl: 7
        )
    }

    // MARK: - Ingest basics

    @Test func ingestStoresAndDeduplicates() throws {
        let clock = MutableClock(now: baseDate)
        let store = makeStore(clock: clock)
        let author = Curve25519.Signing.PrivateKey()
        let entry = try makePost(author: author, createdAt: baseMs)

        #expect(store.ingest(entry.wire, packet: entry.packet) == .accepted)
        #expect(store.ingest(entry.wire, packet: entry.packet) == .duplicate)
        #expect(store.posts(forGeohash: "9q8yy").count == 1)
        #expect(store.posts(forGeohash: "").isEmpty)
        #expect(store.syncCandidates().count == 1)
    }

    @Test func rejectsAlreadyExpiredPost() throws {
        let clock = MutableClock(now: baseDate)
        let store = makeStore(clock: clock)
        let author = Curve25519.Signing.PrivateKey()
        let entry = try makePost(author: author, createdAt: baseMs - 2 * 60 * 60 * 1000, lifetimeMs: 60 * 60 * 1000)

        #expect(store.ingest(entry.wire, packet: entry.packet) == .rejected)
        #expect(store.posts(forGeohash: "9q8yy").isEmpty)
    }

    // MARK: - Caps and eviction

    @Test func perAuthorCapEvictsOldest() throws {
        let clock = MutableClock(now: baseDate)
        let store = makeStore(clock: clock)
        let author = Curve25519.Signing.PrivateKey()

        var oldestID: Data?
        for index in 0..<(BoardStore.Limits.maxPostsPerAuthor + 1) {
            let entry = try makePost(author: author, createdAt: baseMs + UInt64(index) * 1000)
            if index == 0 { oldestID = entry.post.postID }
            #expect(store.ingest(entry.wire, packet: entry.packet) == .accepted)
        }

        let posts = store.posts(forGeohash: "9q8yy")
        #expect(posts.count == BoardStore.Limits.maxPostsPerAuthor)
        #expect(!posts.contains { $0.postID == oldestID })
    }

    @Test func globalCapEvictsOldest() throws {
        let clock = MutableClock(now: baseDate)
        let store = makeStore(clock: clock)

        var oldestID: Data?
        var author = Curve25519.Signing.PrivateKey()
        for index in 0..<(BoardStore.Limits.maxPosts + 1) {
            if index % BoardStore.Limits.maxPostsPerAuthor == 0 {
                author = Curve25519.Signing.PrivateKey()
            }
            let entry = try makePost(author: author, createdAt: baseMs + UInt64(index) * 1000)
            if index == 0 { oldestID = entry.post.postID }
            #expect(store.ingest(entry.wire, packet: entry.packet) == .accepted)
        }

        let posts = store.posts(forGeohash: "9q8yy")
        #expect(posts.count == BoardStore.Limits.maxPosts)
        #expect(!posts.contains { $0.postID == oldestID })
    }

    // MARK: - Expiry sweep

    @Test func expiredPostsAreSwept() throws {
        let clock = MutableClock(now: baseDate)
        let store = makeStore(clock: clock)
        let author = Curve25519.Signing.PrivateKey()
        let shortLived = try makePost(author: author, createdAt: baseMs, lifetimeMs: 60 * 60 * 1000)
        let longLived = try makePost(author: author, createdAt: baseMs, lifetimeMs: 48 * 60 * 60 * 1000)
        store.ingest(shortLived.wire, packet: shortLived.packet)
        store.ingest(longLived.wire, packet: longLived.packet)
        #expect(store.posts(forGeohash: "9q8yy").count == 2)

        clock.now = baseDate.addingTimeInterval(2 * 60 * 60) // 2h later
        let remaining = store.posts(forGeohash: "9q8yy")
        #expect(remaining.count == 1)
        #expect(remaining.first?.postID == longLived.post.postID)
        #expect(store.syncCandidates().count == 1)
    }

    // MARK: - Tombstones

    @Test func tombstoneDeletesPostAndPropagatesUntilOriginalExpiry() throws {
        let clock = MutableClock(now: baseDate)
        let store = makeStore(clock: clock)
        let author = Curve25519.Signing.PrivateKey()
        let entry = try makePost(author: author, createdAt: baseMs, lifetimeMs: 24 * 60 * 60 * 1000)
        store.ingest(entry.wire, packet: entry.packet)

        let tombstone = try makeTombstone(for: entry.post, author: author, deletedAt: baseMs + 1000)
        #expect(store.ingest(tombstone.wire, packet: tombstone.packet) == .accepted)

        // Post is gone, tombstone still syncs so the delete propagates.
        #expect(store.posts(forGeohash: "9q8yy").isEmpty)
        #expect(store.syncCandidates().count == 1)

        // Replayed copy of the deleted post is refused.
        #expect(store.ingest(entry.wire, packet: entry.packet) == .rejected)

        // After the post's original expiry the tombstone is dropped too.
        clock.now = baseDate.addingTimeInterval(25 * 60 * 60)
        #expect(store.syncCandidates().isEmpty)
    }

    @Test func tombstoneFromWrongKeyIsRejected() throws {
        let clock = MutableClock(now: baseDate)
        let store = makeStore(clock: clock)
        let author = Curve25519.Signing.PrivateKey()
        let attacker = Curve25519.Signing.PrivateKey()
        let entry = try makePost(author: author, createdAt: baseMs)
        store.ingest(entry.wire, packet: entry.packet)

        // Attacker signs with their own key (self-consistent wire, so it
        // passes signature verification) but targets the victim's post.
        let forged = try makeTombstone(for: entry.post, author: attacker, deletedAt: baseMs + 1000)
        #expect(store.ingest(forged.wire, packet: forged.packet) == .rejected)
        #expect(store.posts(forGeohash: "9q8yy").count == 1)
    }

    @Test func tombstoneArrivingBeforePostSuppressesIt() throws {
        let clock = MutableClock(now: baseDate)
        let store = makeStore(clock: clock)
        let author = Curve25519.Signing.PrivateKey()
        let entry = try makePost(author: author, createdAt: baseMs)

        let tombstone = try makeTombstone(for: entry.post, author: author, deletedAt: baseMs + 1000)
        #expect(store.ingest(tombstone.wire, packet: tombstone.packet) == .accepted)
        #expect(store.ingest(entry.wire, packet: entry.packet) == .rejected)
        #expect(store.posts(forGeohash: "9q8yy").isEmpty)
    }

    // MARK: - Persistence and wipe

    @Test func persistsAcrossRestart() throws {
        let fileURL = tempFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let clock = MutableClock(now: baseDate)
        let author = Curve25519.Signing.PrivateKey()

        let first = makeStore(clock: clock, fileURL: fileURL)
        let entry = try makePost(author: author, createdAt: baseMs)
        let deleted = try makePost(author: author, createdAt: baseMs + 1)
        first.ingest(entry.wire, packet: entry.packet)
        first.ingest(deleted.wire, packet: deleted.packet)
        let tombstone = try makeTombstone(for: deleted.post, author: author, deletedAt: baseMs + 1000)
        first.ingest(tombstone.wire, packet: tombstone.packet)

        let second = makeStore(clock: clock, fileURL: fileURL)
        let restored = second.posts(forGeohash: "9q8yy")
        #expect(restored.count == 1)
        #expect(restored.first?.postID == entry.post.postID)
        // Post + tombstone both restored into sync.
        #expect(second.syncCandidates().count == 2)

        // Restart after expiry drops everything.
        clock.now = baseDate.addingTimeInterval(25 * 60 * 60)
        let third = makeStore(clock: clock, fileURL: fileURL)
        #expect(third.posts(forGeohash: "9q8yy").isEmpty)
        #expect(third.syncCandidates().isEmpty)
    }

    @Test func wipeClearsMemoryAndDisk() throws {
        let fileURL = tempFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let clock = MutableClock(now: baseDate)
        let author = Curve25519.Signing.PrivateKey()

        let store = makeStore(clock: clock, fileURL: fileURL)
        let entry = try makePost(author: author, createdAt: baseMs)
        store.ingest(entry.wire, packet: entry.packet)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        store.wipe()
        #expect(store.posts(forGeohash: "9q8yy").isEmpty)
        #expect(store.syncCandidates().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }
}
