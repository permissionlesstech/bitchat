//
// GroupProtocolTests.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import CryptoKit
import Foundation
import Testing
import BitFoundation
@testable import bitchat

struct GroupProtocolTests {

    // MARK: - Fixtures

    /// Deterministic member identity: an Ed25519 keypair plus the 64-hex
    /// fingerprint the roster pins.
    private struct TestIdentity {
        let signingKey: Curve25519.Signing.PrivateKey
        let fingerprint: String

        init(seed: UInt8) {
            signingKey = Curve25519.Signing.PrivateKey()
            fingerprint = Data(repeating: seed, count: 32).hexEncodedString()
        }

        var member: GroupMember {
            GroupMember(
                fingerprint: fingerprint,
                signingKey: signingKey.publicKey.rawRepresentation,
                nickname: "peer-\(fingerprint.prefix(4))"
            )
        }

        func sign(_ data: Data) -> Data? {
            try? signingKey.signature(for: data)
        }
    }

    private let creator = TestIdentity(seed: 0xC1)
    private let member = TestIdentity(seed: 0xA2)
    private let outsider = TestIdentity(seed: 0xE3)

    private let groupID = Data((0..<16).map { UInt8($0) })
    private let key = Data(repeating: 0x42, count: 32)

    private func makeGroup(extraMembers: [GroupMember] = [], epoch: UInt32 = 1) -> BitchatGroup {
        BitchatGroup(
            groupID: groupID,
            name: "trail crew",
            epoch: epoch,
            members: [creator.member, member.member] + extraMembers,
            creatorFingerprint: creator.fingerprint
        )
    }

    // MARK: - State payload (invite / key update)

    @Test func statePayloadRoundTripAndSignatureVerify() throws {
        let group = makeGroup()
        let payload = try #require(GroupStatePayload.makeSigned(group: group, key: key, sign: creator.sign))
        let encoded = try #require(payload.encode())

        let decoded = try #require(GroupStatePayload.decode(encoded))
        #expect(decoded == payload)
        #expect(decoded.groupID == groupID)
        #expect(decoded.name == "trail crew")
        #expect(decoded.key == key)
        #expect(decoded.epoch == 1)
        #expect(decoded.members == group.members)
        #expect(decoded.creatorFingerprint == creator.fingerprint)
        #expect(decoded.verifyCreatorSignature())
        #expect(decoded.asGroup == group)
    }

    @Test func forgedCreatorSignatureIsRejected() throws {
        let group = makeGroup()
        // Signed by a member who is in the roster but is NOT the creator.
        let forged = try #require(GroupStatePayload.makeSigned(group: group, key: key, sign: member.sign))
        #expect(!forged.verifyCreatorSignature())

        // An outsider signing is equally rejected.
        let outsiderForged = try #require(GroupStatePayload.makeSigned(group: group, key: key, sign: outsider.sign))
        #expect(!outsiderForged.verifyCreatorSignature())
    }

    @Test func tamperedStateFailsSignature() throws {
        let group = makeGroup()
        let payload = try #require(GroupStatePayload.makeSigned(group: group, key: key, sign: creator.sign))

        // Bumping the epoch invalidates the signature.
        let epochTampered = GroupStatePayload(
            groupID: payload.groupID,
            name: payload.name,
            key: payload.key,
            epoch: payload.epoch + 1,
            members: payload.members,
            creatorFingerprint: payload.creatorFingerprint,
            signature: payload.signature
        )
        #expect(!epochTampered.verifyCreatorSignature())

        // So does swapping the key.
        let keyTampered = GroupStatePayload(
            groupID: payload.groupID,
            name: payload.name,
            key: Data(repeating: 0x99, count: 32),
            epoch: payload.epoch,
            members: payload.members,
            creatorFingerprint: payload.creatorFingerprint,
            signature: payload.signature
        )
        #expect(!keyTampered.verifyCreatorSignature())

        // And so does adding a member to the roster.
        let rosterTampered = GroupStatePayload(
            groupID: payload.groupID,
            name: payload.name,
            key: payload.key,
            epoch: payload.epoch,
            members: payload.members + [outsider.member],
            creatorFingerprint: payload.creatorFingerprint,
            signature: payload.signature
        )
        #expect(!rosterTampered.verifyCreatorSignature())
    }

    @Test func creatorMissingFromRosterIsRejected() throws {
        // State claiming a creator whose fingerprint is not in the roster has
        // no key to verify against and must fail closed.
        let group = BitchatGroup(
            groupID: groupID,
            name: "orphan",
            epoch: 1,
            members: [member.member],
            creatorFingerprint: creator.fingerprint
        )
        guard let rosterBlob = GroupRosterCoding.encode(group.members) else {
            Issue.record("roster should encode")
            return
        }
        let content = GroupStatePayload.signingContent(groupID: groupID, epoch: 1, key: key, rosterBlob: rosterBlob, name: group.name)
        let payload = GroupStatePayload(
            groupID: groupID,
            name: group.name,
            key: key,
            epoch: 1,
            members: group.members,
            creatorFingerprint: creator.fingerprint,
            signature: creator.sign(content) ?? Data()
        )
        #expect(!payload.verifyCreatorSignature())
    }

    @Test func rosterCapIsEnforcedOnTheWire() {
        // 17 members cannot be encoded (hard cap is 16)…
        let seventeen = (0..<17).map { TestIdentity(seed: UInt8($0 + 1)).member }
        #expect(GroupRosterCoding.encode(seventeen) == nil)

        // …and a hand-built blob claiming 17 members fails to decode.
        let sixteen = (0..<16).map { TestIdentity(seed: UInt8($0 + 1)).member }
        guard var blob = GroupRosterCoding.encode(sixteen) else {
            Issue.record("16-member roster should encode")
            return
        }
        #expect(GroupRosterCoding.decode(blob)?.count == 16)
        blob[blob.startIndex] = 17
        #expect(GroupRosterCoding.decode(blob) == nil)
    }

    // MARK: - Message seal / open

    @Test func messageRoundTrip() throws {
        let group = makeGroup()
        let timestampMs: UInt64 = 1_750_000_000_000
        let sealed = try GroupCrypto.sealMessage(
            content: "summit at noon",
            messageID: "msg-1",
            senderNickname: "alice",
            senderSigningKey: member.member.signingKey,
            timestampMs: timestampMs,
            groupID: groupID,
            epoch: group.epoch,
            key: key,
            sign: member.sign
        )

        let envelope = try #require(GroupMessageEnvelope.decode(sealed))
        #expect(envelope.groupID == groupID)
        #expect(envelope.epoch == group.epoch)

        let plaintext = try GroupCrypto.openMessage(envelope, key: key)
        #expect(plaintext.messageID == "msg-1")
        #expect(plaintext.content == "summit at noon")
        #expect(plaintext.senderNickname == "alice")
        #expect(plaintext.timestampMs == timestampMs)
        #expect(plaintext.senderSigningKey == member.member.signingKey)

        // The roster resolves the sender; an outsider's key would not.
        #expect(group.member(withSigningKey: plaintext.senderSigningKey) != nil)
        #expect(group.member(withSigningKey: outsider.member.signingKey) == nil)
    }

    @Test func wrongKeyFailsToDecrypt() throws {
        let sealed = try GroupCrypto.sealMessage(
            content: "hi",
            messageID: "msg-2",
            senderNickname: "alice",
            senderSigningKey: member.member.signingKey,
            timestampMs: 1,
            groupID: groupID,
            epoch: 1,
            key: key,
            sign: member.sign
        )
        let envelope = try #require(GroupMessageEnvelope.decode(sealed))
        #expect(throws: GroupCryptoError.decryptionFailed) {
            _ = try GroupCrypto.openMessage(envelope, key: Data(repeating: 0x7F, count: 32))
        }
    }

    @Test func epochIsBoundIntoTheCiphertext() throws {
        // Re-labeling an epoch-1 envelope as epoch 2 must break the AEAD:
        // a rotated-out member cannot replay old ciphertext into a new epoch.
        let sealed = try GroupCrypto.sealMessage(
            content: "hi",
            messageID: "msg-3",
            senderNickname: "alice",
            senderSigningKey: member.member.signingKey,
            timestampMs: 1,
            groupID: groupID,
            epoch: 1,
            key: key,
            sign: member.sign
        )
        let envelope = try #require(GroupMessageEnvelope.decode(sealed))
        let relabeled = GroupMessageEnvelope(
            groupID: envelope.groupID,
            epoch: 2,
            nonce: envelope.nonce,
            ciphertext: envelope.ciphertext
        )
        #expect(throws: GroupCryptoError.decryptionFailed) {
            _ = try GroupCrypto.openMessage(relabeled, key: key)
        }
    }

    @Test func badSenderSignatureIsRejected() throws {
        // A key-holder who signs with a key other than the one they claim
        // (or garbage) is dropped even though decryption succeeds.
        let sealed = try GroupCrypto.sealMessage(
            content: "spoof",
            messageID: "msg-4",
            senderNickname: "mallory",
            senderSigningKey: member.member.signingKey, // claims member's key…
            timestampMs: 1,
            groupID: groupID,
            epoch: 1,
            key: key,
            sign: outsider.sign // …but signs with the outsider's
        )
        let envelope = try #require(GroupMessageEnvelope.decode(sealed))
        #expect(throws: GroupCryptoError.badSenderSignature) {
            _ = try GroupCrypto.openMessage(envelope, key: key)
        }
    }

    @Test func tamperedCiphertextFailsToOpen() throws {
        let sealed = try GroupCrypto.sealMessage(
            content: "hi",
            messageID: "msg-5",
            senderNickname: "alice",
            senderSigningKey: member.member.signingKey,
            timestampMs: 1,
            groupID: groupID,
            epoch: 1,
            key: key,
            sign: member.sign
        )
        let envelope = try #require(GroupMessageEnvelope.decode(sealed))
        var flipped = envelope.ciphertext
        flipped[flipped.startIndex] ^= 0x01
        let tampered = GroupMessageEnvelope(
            groupID: envelope.groupID,
            epoch: envelope.epoch,
            nonce: envelope.nonce,
            ciphertext: flipped
        )
        #expect(throws: GroupCryptoError.decryptionFailed) {
            _ = try GroupCrypto.openMessage(tampered, key: key)
        }
    }

    @Test func malformedEnvelopesAreRejected() {
        #expect(GroupMessageEnvelope.decode(Data()) == nil)
        #expect(GroupMessageEnvelope.decode(Data([0x01, 0x00])) == nil)
        #expect(GroupStatePayload.decode(Data([0xFF, 0x00, 0x01])) == nil)
    }

    // MARK: - Oversize / UTF-8 safety (Codex findings)

    @Test func oversizeMessageContentFailsToSealInsteadOfTruncating() {
        // A content whose UTF-8 exceeds the 16-bit TLV length must fail to
        // seal (surfacing send_failed) rather than silently truncate into a
        // ciphertext recipients would drop.
        let oversize = String(repeating: "a", count: 70_000)
        #expect(throws: (any Error).self) {
            _ = try GroupCrypto.sealMessage(
                content: oversize,
                messageID: "big",
                senderNickname: "alice",
                senderSigningKey: member.member.signingKey,
                timestampMs: 1,
                groupID: groupID,
                epoch: 1,
                key: key,
                sign: member.sign
            )
        }
    }

    @Test func multiByteNicknameTruncatesOnScalarBoundary() throws {
        // 40 euro signs = 120 UTF-8 bytes; a raw 64-byte prefix would split
        // the 21st scalar and make the roster undecodable. Truncation must
        // land on a Character boundary so the blob round-trips.
        let euros = String(repeating: "€", count: 40)
        let wide = GroupMember(
            fingerprint: creator.fingerprint,
            signingKey: creator.member.signingKey,
            nickname: euros
        )
        let blob = try #require(GroupRosterCoding.encode([wide]))
        let decoded = try #require(GroupRosterCoding.decode(blob))
        #expect(decoded.count == 1)
        #expect(Data(decoded[0].nickname.utf8).count <= 64)
        #expect(decoded[0].nickname.allSatisfy { $0 == "€" })
        #expect(!decoded[0].nickname.isEmpty)
    }

    // MARK: - Signable-bytes forward-proofing

    @Test func creatorSignatureCoversName() throws {
        let group = makeGroup()
        let payload = try #require(GroupStatePayload.makeSigned(group: group, key: key, sign: creator.sign))
        #expect(payload.verifyCreatorSignature())

        // Swapping only the display name must invalidate the creator signature.
        let renamed = GroupStatePayload(
            groupID: payload.groupID,
            name: "totally different name",
            key: payload.key,
            epoch: payload.epoch,
            members: payload.members,
            creatorFingerprint: payload.creatorFingerprint,
            signature: payload.signature
        )
        #expect(!renamed.verifyCreatorSignature())
    }

    @Test func messageSignatureCoversEpoch() {
        // The signed bytes differ by epoch, so a signature captured at one
        // epoch cannot verify when re-sealed under a later epoch key.
        let atEpoch1 = GroupCrypto.messageSigningContent(
            groupID: groupID, epoch: 1, messageID: "m", timestampMs: 1, content: "x"
        )
        let atEpoch2 = GroupCrypto.messageSigningContent(
            groupID: groupID, epoch: 2, messageID: "m", timestampMs: 1, content: "x"
        )
        #expect(atEpoch1 != atEpoch2)
    }
}
