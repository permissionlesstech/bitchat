//
// BoardPacketsTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import CryptoKit
import Foundation
import Testing
@testable import bitchat

struct BoardPacketsTests {

    private let authorKey = Curve25519.Signing.PrivateKey()

    private func makeSignedPost(
        geohash: String = "9q8yy",
        content: String = "water point at the north gate",
        nickname: String = "ranger",
        createdAt: UInt64 = 1_700_000_000_000,
        lifetimeMs: UInt64 = 24 * 60 * 60 * 1000,
        flags: UInt8 = 0,
        signWith key: Curve25519.Signing.PrivateKey? = nil,
        claimKey: Data? = nil
    ) throws -> BoardPostPacket {
        let signer = key ?? authorKey
        let publicKey = claimKey ?? signer.publicKey.rawRepresentation
        let postID = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let expiresAt = createdAt + lifetimeMs
        let signingBytes = BoardPostPacket.signingBytes(
            postID: postID,
            geohash: geohash,
            content: content,
            authorSigningKey: publicKey,
            authorNickname: nickname,
            createdAt: createdAt,
            expiresAt: expiresAt,
            flags: flags
        )
        let signature = try signer.signature(for: signingBytes)
        return BoardPostPacket(
            postID: postID,
            geohash: geohash,
            content: content,
            authorSigningKey: publicKey,
            authorNickname: nickname,
            createdAt: createdAt,
            expiresAt: expiresAt,
            flags: flags,
            signature: signature
        )
    }

    private func makeSignedTombstone(
        postID: Data,
        deletedAt: UInt64 = 1_700_000_100_000,
        signWith key: Curve25519.Signing.PrivateKey? = nil,
        claimKey: Data? = nil
    ) throws -> BoardTombstonePacket {
        let signer = key ?? authorKey
        let publicKey = claimKey ?? signer.publicKey.rawRepresentation
        let signature = try signer.signature(for: BoardTombstonePacket.signingBytes(postID: postID, deletedAt: deletedAt))
        return BoardTombstonePacket(
            postID: postID,
            authorSigningKey: publicKey,
            deletedAt: deletedAt,
            signature: signature
        )
    }

    // MARK: - Round trips

    @Test func postRoundTrip() throws {
        let post = try makeSignedPost(flags: BoardPostPacket.urgentFlag)
        let encoded = BoardWire.post(post).encode()
        let decoded = try #require(BoardWire.decode(from: encoded))
        #expect(decoded == .post(post))
        #expect(decoded.verifySignature())
        guard case .post(let roundTripped) = decoded else {
            Issue.record("expected a post")
            return
        }
        #expect(roundTripped.isUrgent)
        #expect(roundTripped.geohash == "9q8yy")
    }

    @Test func meshLocalPostRoundTrip() throws {
        let post = try makeSignedPost(geohash: "")
        let decoded = try #require(BoardWire.decode(from: BoardWire.post(post).encode()))
        #expect(decoded == .post(post))
        #expect(decoded.verifySignature())
    }

    @Test func tombstoneRoundTrip() throws {
        let post = try makeSignedPost()
        let tombstone = try makeSignedTombstone(postID: post.postID)
        let encoded = BoardWire.tombstone(tombstone).encode()
        let decoded = try #require(BoardWire.decode(from: encoded))
        #expect(decoded == .tombstone(tombstone))
        #expect(decoded.verifySignature())
    }

    // MARK: - Signature verification

    @Test func forgedPostSignatureFailsVerification() throws {
        // Signed by an attacker's key but claiming the victim's key as author.
        let attacker = Curve25519.Signing.PrivateKey()
        let victim = Curve25519.Signing.PrivateKey()
        let forged = try makeSignedPost(signWith: attacker, claimKey: victim.publicKey.rawRepresentation)
        let decoded = try #require(BoardWire.decode(from: BoardWire.post(forged).encode()))
        #expect(!decoded.verifySignature())
    }

    @Test func tamperedContentFailsVerification() throws {
        let post = try makeSignedPost(content: "meet at noon")
        let tampered = BoardPostPacket(
            postID: post.postID,
            geohash: post.geohash,
            content: "meet at midnight",
            authorSigningKey: post.authorSigningKey,
            authorNickname: post.authorNickname,
            createdAt: post.createdAt,
            expiresAt: post.expiresAt,
            flags: post.flags,
            signature: post.signature
        )
        let decoded = try #require(BoardWire.decode(from: BoardWire.post(tampered).encode()))
        #expect(!decoded.verifySignature())
    }

    @Test func forgedTombstoneSignatureFailsVerification() throws {
        let post = try makeSignedPost()
        let attacker = Curve25519.Signing.PrivateKey()
        let forged = try makeSignedTombstone(
            postID: post.postID,
            signWith: attacker,
            claimKey: post.authorSigningKey
        )
        let decoded = try #require(BoardWire.decode(from: BoardWire.tombstone(forged).encode()))
        #expect(!decoded.verifySignature())
    }

    // MARK: - Decode validation

    @Test func rejectsExpiryBeyondSevenDays() throws {
        let tooLong = try makeSignedPost(lifetimeMs: BoardWireConstants.maxLifetimeMs + 1)
        #expect(BoardWire.decode(from: BoardWire.post(tooLong).encode()) == nil)

        let exactlySevenDays = try makeSignedPost(lifetimeMs: BoardWireConstants.maxLifetimeMs)
        #expect(BoardWire.decode(from: BoardWire.post(exactlySevenDays).encode()) != nil)
    }

    @Test func rejectsExpiryBeforeCreation() throws {
        let post = try makeSignedPost()
        let inverted = BoardPostPacket(
            postID: post.postID,
            geohash: post.geohash,
            content: post.content,
            authorSigningKey: post.authorSigningKey,
            authorNickname: post.authorNickname,
            createdAt: post.expiresAt,
            expiresAt: post.createdAt,
            flags: post.flags,
            signature: post.signature
        )
        #expect(BoardWire.decode(from: BoardWire.post(inverted).encode()) == nil)
    }

    @Test func rejectsOversizedContent() throws {
        let oversized = try makeSignedPost(content: String(repeating: "x", count: BoardWireConstants.contentMaxBytes + 1))
        #expect(BoardWire.decode(from: BoardWire.post(oversized).encode()) == nil)

        let maxed = try makeSignedPost(content: String(repeating: "x", count: BoardWireConstants.contentMaxBytes))
        #expect(BoardWire.decode(from: BoardWire.post(maxed).encode()) != nil)
    }

    @Test func rejectsInvalidGeohashCharacters() throws {
        let invalid = try makeSignedPost(geohash: "9q8yA") // "A" is outside base32
        #expect(BoardWire.decode(from: BoardWire.post(invalid).encode()) == nil)
    }

    @Test func toleratesUnknownTLVs() throws {
        let post = try makeSignedPost()
        var encoded = BoardWire.post(post).encode()
        // Append an unknown TLV; decoders must skip it.
        encoded.append(contentsOf: [0x7F, 0x00, 0x02, 0xDE, 0xAD])
        let decoded = try #require(BoardWire.decode(from: encoded))
        #expect(decoded == .post(post))
        #expect(decoded.verifySignature())
    }

    @Test func rejectsTruncatedPayload() throws {
        let post = try makeSignedPost()
        let encoded = BoardWire.post(post).encode()
        #expect(BoardWire.decode(from: encoded.prefix(encoded.count - 1)) == nil)
    }

    // MARK: - Urgent flag peek

    @Test func urgentFlagPeekMatchesFullDecode() throws {
        let urgent = try makeSignedPost(flags: BoardPostPacket.urgentFlag)
        let calm = try makeSignedPost()
        let tombstone = try makeSignedTombstone(postID: calm.postID)
        #expect(BoardWire.urgentFlag(in: BoardWire.post(urgent).encode()))
        #expect(!BoardWire.urgentFlag(in: BoardWire.post(calm).encode()))
        #expect(!BoardWire.urgentFlag(in: BoardWire.tombstone(tombstone).encode()))
        #expect(!BoardWire.urgentFlag(in: Data()))
    }
}
