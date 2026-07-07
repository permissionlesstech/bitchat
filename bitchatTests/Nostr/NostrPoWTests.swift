//
// NostrPoWTests.swift
// bitchatTests
//
// Tests for NIP-13 proof-of-work: leading-zero-bit counting, commitment
// semantics, and nonce-tag mining for geohash (kind 20000) events.
//

import CryptoKit
import Foundation
import Testing
import BitFoundation
@testable import bitchat

struct NostrPoWTests {

    // MARK: - Leading zero bits

    @Test func leadingZeroBitsVectors() {
        #expect(NostrPoW.leadingZeroBits(Data()) == 0)
        #expect(NostrPoW.leadingZeroBits(Data([0x80])) == 0)
        #expect(NostrPoW.leadingZeroBits(Data([0xFF, 0x00])) == 0)
        #expect(NostrPoW.leadingZeroBits(Data([0x40])) == 1)
        #expect(NostrPoW.leadingZeroBits(Data([0x01])) == 7)
        #expect(NostrPoW.leadingZeroBits(Data([0x00, 0x00, 0xF0])) == 16)
        #expect(NostrPoW.leadingZeroBits(Data(repeating: 0x00, count: 32)) == 256)
    }

    @Test func leadingZeroBitsExactByteBoundaries() {
        // Zero byte contributes exactly 8, then the next byte decides.
        #expect(NostrPoW.leadingZeroBits(Data([0x00, 0xFF])) == 8)
        #expect(NostrPoW.leadingZeroBits(Data([0x00, 0x80])) == 8)
        #expect(NostrPoW.leadingZeroBits(Data([0x00, 0x7F])) == 9)
        #expect(NostrPoW.leadingZeroBits(Data([0x00, 0x01])) == 15)
        #expect(NostrPoW.leadingZeroBits(Data([0x00, 0x00, 0x01])) == 23)
    }

    @Test func leadingZeroBitsMatchesNIP13ExampleVector() throws {
        // Worked example from the NIP-13 spec: this event ID has 36 leading
        // zero bits.
        let idHex = "000000000e9d97a1ab09fc381030b346cdd7a142ad57e6df0b46dc9bef6c7e2d"
        let idData = try #require(Data(hexString: idHex))
        #expect(NostrPoW.leadingZeroBits(idData) == 36)
    }

    // MARK: - Commitment semantics

    /// An ID with exactly 16 leading zero bits.
    private let id16 = "0000f000" + String(repeating: "ab", count: 28)

    @Test func committedTargetCountsNotActualDifficulty() {
        // Claimed < actual: only the committed target is credited, so lucky
        // extra zeroes earn nothing beyond the commitment.
        let tags = [["g", "u4pruy"], ["nonce", "12345", "8"]]
        #expect(NostrPoW.validatedDifficulty(idHex: id16, tags: tags) == 8)
    }

    @Test func unmetCommitmentScoresZero() {
        // Actual < claimed: the commitment is not met, so the claim is void.
        let tags = [["nonce", "12345", "24"]]
        #expect(NostrPoW.validatedDifficulty(idHex: id16, tags: tags) == 0)
    }

    @Test func exactCommitmentIsCredited() {
        let tags = [["nonce", "12345", "16"]]
        #expect(NostrPoW.validatedDifficulty(idHex: id16, tags: tags) == 16)
    }

    @Test func missingOrMalformedNonceTagScoresZero() {
        // No nonce tag at all: leading zeroes without a commitment earn no
        // credit (old clients simply keep the strict rate limits).
        #expect(NostrPoW.validatedDifficulty(idHex: id16, tags: [["g", "u4pruy"]]) == 0)
        // Nonce tag without a committed target.
        #expect(NostrPoW.validatedDifficulty(idHex: id16, tags: [["nonce", "12345"]]) == 0)
        // Non-numeric or nonsensical targets.
        #expect(NostrPoW.validatedDifficulty(idHex: id16, tags: [["nonce", "1", "high"]]) == 0)
        #expect(NostrPoW.validatedDifficulty(idHex: id16, tags: [["nonce", "1", "0"]]) == 0)
        #expect(NostrPoW.validatedDifficulty(idHex: id16, tags: [["nonce", "1", "-4"]]) == 0)
        #expect(NostrPoW.validatedDifficulty(idHex: id16, tags: [["nonce", "1", "400"]]) == 0)
        // Malformed event ID.
        #expect(NostrPoW.validatedDifficulty(idHex: "not-hex", tags: [["nonce", "1", "8"]]) == 0)
    }

    // MARK: - Mining

    @Test func minedNonceTagMeetsCommittedDifficulty() async throws {
        let pubkey = String(repeating: "a", count: 64)
        let createdAt = 1_700_000_000
        let baseTags = [["g", "u4pruydq"], ["n", "tester"]]
        let content = "hello pow"

        let nonceTag = try #require(await NostrPoW.mineNonceTag(
            pubkey: pubkey,
            createdAt: createdAt,
            kind: 20000,
            tags: baseTags,
            content: content,
            targetBits: 8
        ))

        #expect(nonceTag.count == 3)
        #expect(nonceTag.first == "nonce")
        #expect(nonceTag[2] == "8")

        // Recompute the canonical NIP-01 event ID with the mined tag appended
        // and verify the committed difficulty is genuinely met.
        let idData = try Self.eventIDHash(
            pubkey: pubkey,
            createdAt: createdAt,
            kind: 20000,
            tags: baseTags + [nonceTag],
            content: content
        )
        #expect(NostrPoW.leadingZeroBits(idData) >= 8)
        let idHex = idData.map { String(format: "%02x", $0) }.joined()
        #expect(NostrPoW.validatedDifficulty(idHex: idHex, tags: baseTags + [nonceTag]) == 8)
    }

    @Test func miningSurvivesContentThatNeedsEscaping() async throws {
        // The in-place template mutation must stay correct when the content
        // gets JSON-escaped — including content that contains hex runs that
        // look exactly like the internal nonce placeholder.
        let pubkey = String(repeating: "b", count: 64)
        let createdAt = 1_700_000_123
        let content = "she said \"hi\"\n0000000000000000 / ffffffffffffffff 😀\\"
        let baseTags = [["g", "9q8yy"]]

        let nonceTag = try #require(await NostrPoW.mineNonceTag(
            pubkey: pubkey,
            createdAt: createdAt,
            kind: 20000,
            tags: baseTags,
            content: content,
            targetBits: 4
        ))

        let idData = try Self.eventIDHash(
            pubkey: pubkey,
            createdAt: createdAt,
            kind: 20000,
            tags: baseTags + [nonceTag],
            content: content
        )
        #expect(NostrPoW.leadingZeroBits(idData) >= 4)
    }

    @Test func minedGeohashEventValidatesEndToEnd() async throws {
        let identity = try NostrIdentity.generate()
        let event = try await NostrProtocol.createMinedEphemeralGeohashEvent(
            content: "hello from a mined event",
            geohash: "u4pruydq",
            senderIdentity: identity,
            nickname: "miner",
            teleported: false
        )

        // The signed event's own ID (recomputed by sign()) carries the work.
        #expect(event.isValidSignature())
        let idData = try #require(Data(hexString: event.id))
        #expect(NostrPoW.leadingZeroBits(idData) >= NostrPoW.targetBits)
        #expect(NostrPoW.validatedDifficulty(idHex: event.id, tags: event.tags) == NostrPoW.targetBits)

        // Mining must not disturb the regular geohash tags.
        #expect(event.tags.contains(["g", "u4pruydq"]))
        #expect(event.tags.contains(["n", "miner"]))
        #expect(event.kind == NostrProtocol.EventKind.ephemeralEvent.rawValue)
    }

    @Test func cancelledMiningStillProducesHonestCommitment() async throws {
        // Cancelling the surrounding task expedites mining: it steps the
        // committed target down and still returns a tag whose commitment the
        // hash actually meets — the message is never dropped or dishonest.
        let pubkey = String(repeating: "c", count: 64)
        let createdAt = 1_700_000_456
        let baseTags = [["g", "gbsuv"]]
        let content = "expedited"

        let miningTask = Task {
            await NostrPoW.mineNonceTag(
                pubkey: pubkey,
                createdAt: createdAt,
                kind: 20000,
                tags: baseTags,
                content: content,
                targetBits: 240 // unreachable: forces the cap/cancel path
            )
        }
        miningTask.cancel()

        let nonceTag = try #require(await miningTask.value)
        let committed = try #require(Int(nonceTag[2]))
        #expect(committed >= 0)
        #expect(committed < 240)

        if committed > 0 {
            let idData = try Self.eventIDHash(
                pubkey: pubkey,
                createdAt: createdAt,
                kind: 20000,
                tags: baseTags + [nonceTag],
                content: content
            )
            #expect(NostrPoW.leadingZeroBits(idData) >= committed)
        }
    }

    // MARK: - Helpers

    /// Canonical NIP-01 event ID hash, computed independently of the
    /// production code path.
    private static func eventIDHash(
        pubkey: String,
        createdAt: Int,
        kind: Int,
        tags: [[String]],
        content: String
    ) throws -> Data {
        let serialized: [Any] = [0, pubkey, createdAt, kind, tags, content]
        let json = try JSONSerialization.data(withJSONObject: serialized, options: [.withoutEscapingSlashes])
        return Data(SHA256.hash(data: json))
    }
}
