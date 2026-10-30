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

    @Test func endorsementIsNeverReadAsUrgent() throws {
        let post = try makeSignedPost(flags: BoardPostPacket.urgentFlag)
        let endorsement = try makeSignedEndorsement(of: post)
        #expect(!BoardWire.urgentFlag(in: BoardWire.endorsement(endorsement).encode()))
    }

    // MARK: - Endorsements

    private func makeSignedEndorsement(
        of post: BoardPostPacket,
        endorsedAt: UInt64 = 1_700_000_050_000,
        signWith key: Curve25519.Signing.PrivateKey = Curve25519.Signing.PrivateKey(),
        claimKey: Data? = nil
    ) throws -> BoardEndorsementPacket {
        let endorserKey = claimKey ?? key.publicKey.rawRepresentation
        let signingBytes = BoardEndorsementPacket.signingBytes(
            postID: post.postID,
            postAuthorSigningKey: post.authorSigningKey,
            postDigest: post.digest,
            endorserSigningKey: endorserKey,
            endorsedAt: endorsedAt
        )
        return BoardEndorsementPacket(
            postID: post.postID,
            postAuthorSigningKey: post.authorSigningKey,
            postDigest: post.digest,
            endorserSigningKey: endorserKey,
            endorsedAt: endorsedAt,
            signature: try key.signature(for: signingBytes)
        )
    }

    @Test func endorsementRoundTrip() throws {
        let post = try makeSignedPost(flags: BoardPostPacket.urgentFlag)
        let endorsement = try makeSignedEndorsement(of: post)
        let decoded = try #require(BoardWire.decode(from: BoardWire.endorsement(endorsement).encode()))
        #expect(decoded == .endorsement(endorsement))
        #expect(decoded.verifySignature())
    }

    @Test func forgedEndorsementSignatureFailsVerification() throws {
        let post = try makeSignedPost()
        let victim = Curve25519.Signing.PrivateKey()
        let forged = try makeSignedEndorsement(of: post, claimKey: victim.publicKey.rawRepresentation)
        let decoded = try #require(BoardWire.decode(from: BoardWire.endorsement(forged).encode()))
        #expect(!decoded.verifySignature())
    }

    @Test func endorsementCannotBeRepointedAtAnotherAuthor() throws {
        let post = try makeSignedPost()
        let endorsement = try makeSignedEndorsement(of: post)
        let repointed = BoardEndorsementPacket(
            postID: endorsement.postID,
            postAuthorSigningKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
            postDigest: endorsement.postDigest,
            endorserSigningKey: endorsement.endorserSigningKey,
            endorsedAt: endorsement.endorsedAt,
            signature: endorsement.signature
        )
        let decoded = try #require(BoardWire.decode(from: BoardWire.endorsement(repointed).encode()))
        #expect(!decoded.verifySignature())
    }

    @Test func endorsementCannotBeRepointedAtAnotherVersionOfThePost() throws {
        let post = try makeSignedPost()
        let endorsement = try makeSignedEndorsement(of: post)
        let repointed = BoardEndorsementPacket(
            postID: endorsement.postID,
            postAuthorSigningKey: endorsement.postAuthorSigningKey,
            postDigest: Data(repeating: 0xAB, count: BoardWireConstants.postDigestLength),
            endorserSigningKey: endorsement.endorserSigningKey,
            endorsedAt: endorsement.endorsedAt,
            signature: endorsement.signature
        )
        let decoded = try #require(BoardWire.decode(from: BoardWire.endorsement(repointed).encode()))
        #expect(!decoded.verifySignature())
    }

    @Test func endorsementCarryingPostOnlyFieldsIsRejected() throws {
        let post = try makeSignedPost()
        let encoded = BoardWire.endorsement(try makeSignedEndorsement(of: post)).encode()
        let urgentFlags = Data([0x09, 0x00, 0x01, BoardPostPacket.urgentFlag])
        #expect(BoardWire.decode(from: encoded + urgentFlags) == nil)
        let content = Data([0x04, 0x00, 0x01, 0x41])
        #expect(BoardWire.decode(from: encoded + content) == nil)
    }

    @Test func onlyUrgentPostsPeekAsUrgent() throws {
        let urgentPost = try makeSignedPost(flags: BoardPostPacket.urgentFlag)
        #expect(BoardWire.urgentFlag(in: BoardWire.post(urgentPost).encode()))

        // A flags TLV appended to a non-post never earns the urgent relay reach.
        let urgentFlags = Data([0x09, 0x00, 0x01, BoardPostPacket.urgentFlag])
        let endorsement = BoardWire.endorsement(try makeSignedEndorsement(of: urgentPost)).encode()
        #expect(!BoardWire.urgentFlag(in: endorsement + urgentFlags))
        #expect(!BoardWire.urgentFlag(in: urgentFlags))
    }

    @Test func endorsementMissingEndorserKeyIsRejected() throws {
        let post = try makeSignedPost()
        let endorsement = try makeSignedEndorsement(of: post)
        var encoded = Data()
        func putTLV(_ type: UInt8, _ value: Data) {
            encoded.append(type)
            encoded.append(UInt8(value.count >> 8))
            encoded.append(UInt8(value.count & 0xFF))
            encoded.append(value)
        }
        putTLV(0x01, Data([0x03]))
        putTLV(0x02, endorsement.postID)
        putTLV(0x05, endorsement.postAuthorSigningKey)
        putTLV(0x0D, BoardWireEncoding.uint64Data(endorsement.endorsedAt))
        putTLV(0x0A, endorsement.signature)
        #expect(BoardWire.decode(from: encoded) == nil)
    }

    @Test func endorsementSigningContextIsDistinctFromPostsAndTombstones() throws {
        // A signature over one board kind must never verify as another.
        let contexts = [
            BoardWireConstants.postSigningContext,
            BoardWireConstants.tombstoneSigningContext,
            BoardWireConstants.endorsementSigningContext
        ]
        #expect(Set(contexts).count == contexts.count)
    }
}
