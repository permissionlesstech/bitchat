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

    // MARK: - Receive-time timestamp policy

    @Test func rejectsPostCreatedBeyondClockSkew() throws {
        let clock = MutableClock(now: baseDate)
        let store = makeStore(clock: clock)
        let author = Curve25519.Signing.PrivateKey()
        let entry = try makePost(author: author, createdAt: baseMs + BoardStore.Limits.clockSkewMs + 60 * 1000)

        #expect(store.ingest(entry.wire, packet: entry.packet) == .rejected)
        #expect(store.posts(forGeohash: "9q8yy").isEmpty)
    }

    @Test func acceptsPostCreatedWithinClockSkew() throws {
        let clock = MutableClock(now: baseDate)
        let store = makeStore(clock: clock)
        let author = Curve25519.Signing.PrivateKey()
        let entry = try makePost(author: author, createdAt: baseMs + BoardStore.Limits.clockSkewMs - 60 * 1000)

        #expect(store.ingest(entry.wire, packet: entry.packet) == .accepted)
        #expect(store.posts(forGeohash: "9q8yy").count == 1)
    }

    @Test func rejectsPostExpiringTooFarInTheFuture() throws {
        // Builds the wire directly, bypassing the decoder's span check, to
        // exercise the ingest-level expiresAt bound on its own.
        let clock = MutableClock(now: baseDate)
        let store = makeStore(clock: clock)
        let author = Curve25519.Signing.PrivateKey()
        let entry = try makePost(author: author, createdAt: baseMs, lifetimeMs: 30 * 24 * 60 * 60 * 1000)

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

    @Test func orphanTombstoneRetentionIsBoundedByReceiveTime() throws {
        let clock = MutableClock(now: baseDate)
        let store = makeStore(clock: clock)
        let author = Curve25519.Signing.PrivateKey()
        let entry = try makePost(author: author, createdAt: baseMs) // never ingested

        // Attacker-chosen far-future deletedAt must not extend retention.
        let farFuture = baseMs + 365 * 24 * 60 * 60 * 1000
        let tombstone = try makeTombstone(for: entry.post, author: author, deletedAt: farFuture)
        #expect(store.ingest(tombstone.wire, packet: tombstone.packet) == .accepted)
        #expect(store.syncCandidates().count == 1)

        // No post can outlive 7 days from receipt, so neither may an orphan
        // tombstone (plus skew allowance).
        clock.now = baseDate.addingTimeInterval(8 * 24 * 60 * 60)
        #expect(store.syncCandidates().isEmpty)
    }

    @Test func orphanTombstonePerAuthorCapEvictsOldest() throws {
        let clock = MutableClock(now: baseDate)
        let store = makeStore(clock: clock)
        let author = Curve25519.Signing.PrivateKey()

        var unseenPosts: [(wire: BoardWire, packet: BitchatPacket, post: BoardPostPacket)] = []
        for index in 0..<(BoardStore.Limits.maxOrphanTombstonesPerAuthor + 1) {
            let entry = try makePost(author: author, createdAt: baseMs + UInt64(index))
            unseenPosts.append(entry)
            let tombstone = try makeTombstone(for: entry.post, author: author, deletedAt: baseMs + 1000)
            #expect(store.ingest(tombstone.wire, packet: tombstone.packet) == .accepted)
        }

        #expect(store.syncCandidates().count == BoardStore.Limits.maxOrphanTombstonesPerAuthor)
        // The oldest orphan was evicted, so its post is no longer suppressed…
        #expect(store.ingest(unseenPosts[0].wire, packet: unseenPosts[0].packet) == .accepted)
        // …while the surviving orphans still suppress theirs.
        #expect(store.ingest(unseenPosts[1].wire, packet: unseenPosts[1].packet) == .rejected)
    }

    @Test func orphanTombstoneGlobalCapEvictsOldest() throws {
        let clock = MutableClock(now: baseDate)
        let store = makeStore(clock: clock)

        var author = Curve25519.Signing.PrivateKey()
        for index in 0..<(BoardStore.Limits.maxOrphanTombstones + 1) {
            if index % BoardStore.Limits.maxOrphanTombstonesPerAuthor == 0 {
                author = Curve25519.Signing.PrivateKey()
            }
            let entry = try makePost(author: author, createdAt: baseMs + UInt64(index))
            let tombstone = try makeTombstone(for: entry.post, author: author, deletedAt: baseMs + 1000)
            #expect(store.ingest(tombstone.wire, packet: tombstone.packet) == .accepted)
        }

        #expect(store.syncCandidates().count == BoardStore.Limits.maxOrphanTombstones)
    }

    @Test func matchedTombstonesAreExemptFromOrphanCaps() throws {
        let clock = MutableClock(now: baseDate)
        let store = makeStore(clock: clock)
        let author = Curve25519.Signing.PrivateKey()

        // Post-then-delete more times than the per-author orphan cap; every
        // tombstone matched a live post, so none may be evicted.
        let cycles = BoardStore.Limits.maxOrphanTombstonesPerAuthor + 2
        for index in 0..<cycles {
            let entry = try makePost(author: author, createdAt: baseMs + UInt64(index) * 1000)
            #expect(store.ingest(entry.wire, packet: entry.packet) == .accepted)
            let tombstone = try makeTombstone(for: entry.post, author: author, deletedAt: baseMs + UInt64(index) * 1000 + 1)
            #expect(store.ingest(tombstone.wire, packet: tombstone.packet) == .accepted)
        }

        #expect(store.posts(forGeohash: "9q8yy").isEmpty)
        #expect(store.syncCandidates().count == cycles)
    }

    // MARK: - Endorsements

    private func makeEndorsement(
        of post: BoardPostPacket,
        endorser: Curve25519.Signing.PrivateKey,
        endorsedAt: UInt64,
        postAuthorKey: Data? = nil,
        postDigest: Data? = nil
    ) throws -> (wire: BoardWire, packet: BitchatPacket) {
        let authorKey = postAuthorKey ?? post.authorSigningKey
        let digest = postDigest ?? post.digest
        let endorserKey = endorser.publicKey.rawRepresentation
        let endorsement = BoardEndorsementPacket(
            postID: post.postID,
            postAuthorSigningKey: authorKey,
            postDigest: digest,
            endorserSigningKey: endorserKey,
            endorsedAt: endorsedAt,
            signature: try endorser.signature(for: BoardEndorsementPacket.signingBytes(
                postID: post.postID,
                postAuthorSigningKey: authorKey,
                postDigest: digest,
                endorserSigningKey: endorserKey,
                endorsedAt: endorsedAt
            ))
        )
        let wire = BoardWire.endorsement(endorsement)
        return (wire, makePacket(payload: wire.encode(), timestamp: endorsedAt))
    }

    @Test func endorsementIsStoredAndDeduplicated() throws {
        let clock = MutableClock(now: baseDate)
        let store = makeStore(clock: clock)
        let entry = try makePost(author: Curve25519.Signing.PrivateKey(), createdAt: baseMs)
        store.ingest(entry.wire, packet: entry.packet)
        let endorser = Curve25519.Signing.PrivateKey()
        let endorsement = try makeEndorsement(of: entry.post, endorser: endorser, endorsedAt: baseMs + 1)

        #expect(store.ingest(endorsement.wire, packet: endorsement.packet) == .accepted)
        #expect(store.ingest(endorsement.wire, packet: endorsement.packet) == .duplicate)
        #expect(store.endorserKeys(forPostID: entry.post.postID) == [endorser.publicKey.rawRepresentation])
        #expect(store.syncCandidates().count == 2)
    }

    @Test func selfEndorsementIsRejected() throws {
        let clock = MutableClock(now: baseDate)
        let store = makeStore(clock: clock)
        let author = Curve25519.Signing.PrivateKey()
        let entry = try makePost(author: author, createdAt: baseMs)
        store.ingest(entry.wire, packet: entry.packet)

        let endorsement = try makeEndorsement(of: entry.post, endorser: author, endorsedAt: baseMs + 1)
        #expect(store.ingest(endorsement.wire, packet: endorsement.packet) == .rejected)
        #expect(store.endorserKeys(forPostID: entry.post.postID).isEmpty)
    }

    @Test func endorsementNamingWrongAuthorIsRejected() throws {
        let clock = MutableClock(now: baseDate)
        let store = makeStore(clock: clock)
        let entry = try makePost(author: Curve25519.Signing.PrivateKey(), createdAt: baseMs)
        store.ingest(entry.wire, packet: entry.packet)

        let endorsement = try makeEndorsement(
            of: entry.post,
            endorser: Curve25519.Signing.PrivateKey(),
            endorsedAt: baseMs + 1,
            postAuthorKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        )
        #expect(store.ingest(endorsement.wire, packet: endorsement.packet) == .rejected)
    }

    @Test func endorsementFromTheFutureIsRejected() throws {
        let clock = MutableClock(now: baseDate)
        let store = makeStore(clock: clock)
        let entry = try makePost(author: Curve25519.Signing.PrivateKey(), createdAt: baseMs)
        store.ingest(entry.wire, packet: entry.packet)

        let tooEarly = baseMs + BoardStore.Limits.clockSkewMs + 1
        let endorsement = try makeEndorsement(of: entry.post, endorser: Curve25519.Signing.PrivateKey(), endorsedAt: tooEarly)
        #expect(store.ingest(endorsement.wire, packet: endorsement.packet) == .rejected)
    }

    @Test func endorsementArrivingBeforePostCountsOnceThePostLands() throws {
        let clock = MutableClock(now: baseDate)
        let store = makeStore(clock: clock)
        let entry = try makePost(author: Curve25519.Signing.PrivateKey(), createdAt: baseMs)
        let endorser = Curve25519.Signing.PrivateKey()
        let endorsement = try makeEndorsement(of: entry.post, endorser: endorser, endorsedAt: baseMs + 1)

        #expect(store.ingest(endorsement.wire, packet: endorsement.packet) == .accepted)
        #expect(store.endorserKeys(forPostID: entry.post.postID).isEmpty)

        #expect(store.ingest(entry.wire, packet: entry.packet) == .accepted)
        #expect(store.endorserKeys(forPostID: entry.post.postID) == [endorser.publicKey.rawRepresentation])
    }

    @Test func orphanEndorsementForADifferentAuthorIsDroppedWhenThePostLands() throws {
        let clock = MutableClock(now: baseDate)
        let store = makeStore(clock: clock)
        let entry = try makePost(author: Curve25519.Signing.PrivateKey(), createdAt: baseMs)
        let misattributed = try makeEndorsement(
            of: entry.post,
            endorser: Curve25519.Signing.PrivateKey(),
            endorsedAt: baseMs + 1,
            postAuthorKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        )
        #expect(store.ingest(misattributed.wire, packet: misattributed.packet) == .accepted)

        store.ingest(entry.wire, packet: entry.packet)
        #expect(store.endorserKeys(forPostID: entry.post.postID).isEmpty)
        #expect(store.syncCandidates().count == 1)
    }

    @Test func tombstoneDropsThePostsEndorsements() throws {
        let clock = MutableClock(now: baseDate)
        let store = makeStore(clock: clock)
        let author = Curve25519.Signing.PrivateKey()
        let entry = try makePost(author: author, createdAt: baseMs)
        store.ingest(entry.wire, packet: entry.packet)
        let endorsement = try makeEndorsement(of: entry.post, endorser: Curve25519.Signing.PrivateKey(), endorsedAt: baseMs + 1)
        store.ingest(endorsement.wire, packet: endorsement.packet)

        let tombstone = try makeTombstone(for: entry.post, author: author, deletedAt: baseMs + 2)
        store.ingest(tombstone.wire, packet: tombstone.packet)

        #expect(store.endorserKeys(forPostID: entry.post.postID).isEmpty)
        // Only the tombstone keeps syncing; a late copy of the endorsement is refused.
        #expect(store.syncCandidates().count == 1)
        #expect(store.ingest(endorsement.wire, packet: endorsement.packet) == .rejected)
    }

    @Test func endorsementsExpireWithTheirPost() throws {
        let clock = MutableClock(now: baseDate)
        let store = makeStore(clock: clock)
        let entry = try makePost(author: Curve25519.Signing.PrivateKey(), createdAt: baseMs, lifetimeMs: 60 * 60 * 1000)
        store.ingest(entry.wire, packet: entry.packet)
        let endorsement = try makeEndorsement(of: entry.post, endorser: Curve25519.Signing.PrivateKey(), endorsedAt: baseMs + 1)
        store.ingest(endorsement.wire, packet: endorsement.packet)

        clock.now = baseDate.addingTimeInterval(2 * 60 * 60)
        #expect(store.syncCandidates().isEmpty)
    }

    @Test func perPostCapKeepsTheFirstEndorsers() throws {
        let clock = MutableClock(now: baseDate)
        let store = makeStore(clock: clock)
        let entry = try makePost(author: Curve25519.Signing.PrivateKey(), createdAt: baseMs)
        store.ingest(entry.wire, packet: entry.packet)

        var firstKeys: [Data] = []
        for index in 0..<BoardStore.Limits.maxEndorsementsPerPost {
            let endorser = Curve25519.Signing.PrivateKey()
            firstKeys.append(endorser.publicKey.rawRepresentation)
            let endorsement = try makeEndorsement(of: entry.post, endorser: endorser, endorsedAt: baseMs + UInt64(index))
            #expect(store.ingest(endorsement.wire, packet: endorsement.packet) == .accepted)
        }
        // A burst of fresh keys still relays but cannot displace the endorsers
        // that already count.
        let late = try makeEndorsement(of: entry.post, endorser: Curve25519.Signing.PrivateKey(), endorsedAt: baseMs + 100)
        #expect(store.ingest(late.wire, packet: late.packet) == .accepted)
        #expect(store.endorserKeys(forPostID: entry.post.postID) == firstKeys)
    }

    @Test func trustedEndorserTakesTheNewestUntrustedSlotOnAFullPost() throws {
        let clock = MutableClock(now: baseDate)
        let store = makeStore(clock: clock)
        let trustedEndorser = Curve25519.Signing.PrivateKey()
        let trustedKey = trustedEndorser.publicKey.rawRepresentation
        store.setTrustedEndorsers { [trustedKey] }
        let entry = try makePost(author: Curve25519.Signing.PrivateKey(), createdAt: baseMs)
        store.ingest(entry.wire, packet: entry.packet)

        var flood: [Data] = []
        for index in 0..<BoardStore.Limits.maxEndorsementsPerPost {
            let endorser = Curve25519.Signing.PrivateKey()
            flood.append(endorser.publicKey.rawRepresentation)
            let endorsement = try makeEndorsement(of: entry.post, endorser: endorser, endorsedAt: baseMs + UInt64(index))
            store.ingest(endorsement.wire, packet: endorsement.packet)
        }

        let trusted = try makeEndorsement(of: entry.post, endorser: trustedEndorser, endorsedAt: baseMs + 100)
        #expect(store.ingest(trusted.wire, packet: trusted.packet) == .accepted)
        let stored = store.endorserKeys(forPostID: entry.post.postID)
        #expect(stored.count == BoardStore.Limits.maxEndorsementsPerPost)
        #expect(stored == Array(flood.dropLast()) + [trustedKey])
    }

    @Test func trustedOrphanEndorsersAreAdoptedFirst() throws {
        let clock = MutableClock(now: baseDate)
        let store = makeStore(clock: clock)
        let trustedEndorser = Curve25519.Signing.PrivateKey()
        let trustedKey = trustedEndorser.publicKey.rawRepresentation
        store.setTrustedEndorsers { [trustedKey] }
        let entry = try makePost(author: Curve25519.Signing.PrivateKey(), createdAt: baseMs)

        // More orphans than slots, the trusted one arriving last. The orphan
        // global cap is larger than the per-post cap, so all of them wait.
        for index in 0..<BoardStore.Limits.maxEndorsementsPerPost {
            let endorsement = try makeEndorsement(of: entry.post, endorser: Curve25519.Signing.PrivateKey(), endorsedAt: baseMs + UInt64(index))
            store.ingest(endorsement.wire, packet: endorsement.packet)
        }
        let trusted = try makeEndorsement(of: entry.post, endorser: trustedEndorser, endorsedAt: baseMs + 100)
        store.ingest(trusted.wire, packet: trusted.packet)

        store.ingest(entry.wire, packet: entry.packet)
        let stored = store.endorserKeys(forPostID: entry.post.postID)
        #expect(stored.count == BoardStore.Limits.maxEndorsementsPerPost)
        #expect(stored.contains(trustedKey))
    }

    @Test func endorsementOfADifferentVersionOfThePostIsRejected() throws {
        let clock = MutableClock(now: baseDate)
        let store = makeStore(clock: clock)
        let entry = try makePost(author: Curve25519.Signing.PrivateKey(), createdAt: baseMs)
        store.ingest(entry.wire, packet: entry.packet)

        // Signed for other content under the same ID and author.
        let endorsement = try makeEndorsement(
            of: entry.post,
            endorser: Curve25519.Signing.PrivateKey(),
            endorsedAt: baseMs + 1,
            postDigest: Data(repeating: 0xAB, count: BoardWireConstants.postDigestLength)
        )
        #expect(store.ingest(endorsement.wire, packet: endorsement.packet) == .rejected)
        #expect(store.endorserKeys(forPostID: entry.post.postID).isEmpty)
    }

    @Test func orphanEndorsementOfADifferentVersionIsDroppedWhenThePostLands() throws {
        let clock = MutableClock(now: baseDate)
        let store = makeStore(clock: clock)
        let entry = try makePost(author: Curve25519.Signing.PrivateKey(), createdAt: baseMs)
        let endorsement = try makeEndorsement(
            of: entry.post,
            endorser: Curve25519.Signing.PrivateKey(),
            endorsedAt: baseMs + 1,
            postDigest: Data(repeating: 0xAB, count: BoardWireConstants.postDigestLength)
        )
        #expect(store.ingest(endorsement.wire, packet: endorsement.packet) == .accepted)

        store.ingest(entry.wire, packet: entry.packet)
        #expect(store.endorserKeys(forPostID: entry.post.postID).isEmpty)
        #expect(store.syncCandidates().count == 1)
    }

    @Test func orphanEndorsementPerEndorserCapEvictsOldest() throws {
        let clock = MutableClock(now: baseDate)
        let store = makeStore(clock: clock)
        let endorser = Curve25519.Signing.PrivateKey()
        var unseen: [(wire: BoardWire, packet: BitchatPacket, post: BoardPostPacket)] = []
        for index in 0..<(BoardStore.Limits.maxOrphanEndorsementsPerEndorser + 1) {
            let entry = try makePost(author: Curve25519.Signing.PrivateKey(), createdAt: baseMs + UInt64(index))
            unseen.append(entry)
            let endorsement = try makeEndorsement(of: entry.post, endorser: endorser, endorsedAt: baseMs + 1000)
            #expect(store.ingest(endorsement.wire, packet: endorsement.packet) == .accepted)
        }
        #expect(store.syncCandidates().count == BoardStore.Limits.maxOrphanEndorsementsPerEndorser)

        store.ingest(unseen[0].wire, packet: unseen[0].packet)
        #expect(store.endorserKeys(forPostID: unseen[0].post.postID).isEmpty)
        store.ingest(unseen[1].wire, packet: unseen[1].packet)
        #expect(store.endorserKeys(forPostID: unseen[1].post.postID).count == 1)
    }

    @Test func orphanEndorsementGlobalCapHolds() throws {
        let clock = MutableClock(now: baseDate)
        let store = makeStore(clock: clock)
        for index in 0..<(BoardStore.Limits.maxOrphanEndorsements + 1) {
            let entry = try makePost(author: Curve25519.Signing.PrivateKey(), createdAt: baseMs + UInt64(index))
            let endorsement = try makeEndorsement(of: entry.post, endorser: Curve25519.Signing.PrivateKey(), endorsedAt: baseMs + 1000)
            #expect(store.ingest(endorsement.wire, packet: endorsement.packet) == .accepted)
        }
        #expect(store.syncCandidates().count == BoardStore.Limits.maxOrphanEndorsements)
    }

    @Test func globalEndorsementCapHolds() throws {
        let clock = MutableClock(now: baseDate)
        let store = makeStore(clock: clock)
        let postCount = BoardStore.Limits.maxEndorsements / BoardStore.Limits.maxEndorsementsPerPost + 1
        var author = Curve25519.Signing.PrivateKey()
        for postIndex in 0..<postCount {
            if postIndex % BoardStore.Limits.maxPostsPerAuthor == 0 {
                author = Curve25519.Signing.PrivateKey()
            }
            let entry = try makePost(author: author, createdAt: baseMs + UInt64(postIndex))
            store.ingest(entry.wire, packet: entry.packet)
            for index in 0..<BoardStore.Limits.maxEndorsementsPerPost {
                let endorsement = try makeEndorsement(of: entry.post, endorser: Curve25519.Signing.PrivateKey(), endorsedAt: baseMs + UInt64(index))
                store.ingest(endorsement.wire, packet: endorsement.packet)
            }
        }
        #expect(store.syncCandidates().count == postCount + BoardStore.Limits.maxEndorsements)
    }

    @Test func endorsementsPersistAcrossRestart() throws {
        let fileURL = tempFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let clock = MutableClock(now: baseDate)
        let first = makeStore(clock: clock, fileURL: fileURL)
        let entry = try makePost(author: Curve25519.Signing.PrivateKey(), createdAt: baseMs)
        first.ingest(entry.wire, packet: entry.packet)
        let endorser = Curve25519.Signing.PrivateKey()
        let endorsement = try makeEndorsement(of: entry.post, endorser: endorser, endorsedAt: baseMs + 1)
        first.ingest(endorsement.wire, packet: endorsement.packet)

        let second = makeStore(clock: clock, fileURL: fileURL)
        #expect(second.endorserKeys(forPostID: entry.post.postID) == [endorser.publicKey.rawRepresentation])
    }

    @Test func wipeClearsEndorsements() throws {
        let clock = MutableClock(now: baseDate)
        let store = makeStore(clock: clock)
        let entry = try makePost(author: Curve25519.Signing.PrivateKey(), createdAt: baseMs)
        store.ingest(entry.wire, packet: entry.packet)
        let endorsement = try makeEndorsement(of: entry.post, endorser: Curve25519.Signing.PrivateKey(), endorsedAt: baseMs + 1)
        store.ingest(endorsement.wire, packet: endorsement.packet)

        store.wipe()
        #expect(store.endorserKeys(forPostID: entry.post.postID).isEmpty)
        #expect(store.syncCandidates().isEmpty)
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
