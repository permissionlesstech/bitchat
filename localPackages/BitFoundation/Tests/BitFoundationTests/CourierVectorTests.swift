//
// CourierVectorTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
import CryptoKit
@testable import BitFoundation

/// Golden vectors for the courier wire format, mirrored in
/// `docs/courier-test-vectors.json` so a second implementation can check itself
/// without running this app.
///
/// These cover the three ways a courier client fails *silently* — it builds,
/// connects, and delivers nothing, with no error at either end:
///
/// 1. `expiry` is milliseconds. Seconds makes every envelope read as long
///    expired, so it is dropped at deposit with nothing logged.
/// 2. The signature does not cover the wire bytes. It covers a re-encoding with
///    `ttl = 0`, `isRSR` cleared and the signature omitted, which is then
///    PKCS#7-padded. Signing the unpadded bytes produces a signature that never
///    verifies.
/// 3. The signing key is Ed25519. CryptoKit spells it `Curve25519.Signing`;
///    reaching for a "Curve25519" primitive elsewhere yields X25519 key
///    agreement instead.
struct CourierVectorTests {

    // MARK: Fixed inputs (synthetic — not derived from any real key)

    static let recipientTag = Data((0..<16).map { UInt8($0) })
    static let noiseStaticKey = Data((0..<32).map { UInt8(0xA0 &+ $0) })
    static let ciphertext = Data("courier-vector-ciphertext-0001".utf8)
    static let expiryMs: UInt64 = 1_800_000_000_000
    static let epochDay: UInt32 = 20_833
    static let senderID = Data([0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88])
    static let recipientID = Data([0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00])
    static let timestampMs: UInt64 = 1_750_000_000_000
    static let signingSeed = Data(repeating: 0x42, count: 32)

    // MARK: Envelope

    /// `expiry` is milliseconds since epoch, big-endian, in an 8-byte TLV.
    @Test func envelopeTLVEncoding() throws {
        let envelope = CourierEnvelope(recipientTag: Self.recipientTag,
                                       expiry: Self.expiryMs,
                                       ciphertext: Self.ciphertext,
                                       copies: 4,
                                       prekeyID: 0x1122_3344)
        let encoded = try #require(envelope.encode())
        #expect(encoded.hexEncodedString() == """
        010010000102030405060708090a0b0c0d0e0f020008000001a3185c500003001e636f7\
        5726965722d766563746f722d636970686572746578742d30303031040001040500041122\
        3344
        """.replacingOccurrences(of: "\n", with: ""))

        // 0x02 carries 000001a3185c50 00 == 1_800_000_000_000 ms, not seconds.
        let decoded = try #require(CourierEnvelope.decode(encoded))
        #expect(decoded.expiry == Self.expiryMs)
        #expect(decoded.copies == 4)
        #expect(decoded.prekeyID == 0x1122_3344)
    }

    /// `copies` is clamped into 1...maxCopies, never rejected. An implementation
    /// that rejects out-of-range values drops envelopes this one accepts.
    @Test func copiesAreClampedNotRejected() {
        func copies(_ requested: UInt8) -> UInt8 {
            CourierEnvelope(recipientTag: Self.recipientTag,
                            expiry: Self.expiryMs,
                            ciphertext: Self.ciphertext,
                            copies: requested).copies
        }
        #expect(copies(0) == 1)
        #expect(copies(200) == CourierEnvelope.maxCopies)
        #expect(CourierEnvelope.maxCopies == 8)
    }

    /// HMAC-SHA256(noiseStaticKey, "bitchat-courier-tag-v1" || BE32(epochDay)),
    /// truncated to 16 bytes.
    @Test func recipientTagDerivation() {
        let tag = CourierEnvelope.recipientTag(noiseStaticKey: Self.noiseStaticKey,
                                               epochDay: Self.epochDay)
        #expect(tag.hexEncodedString() == "ad8514c90ca1fa6bf44e38c8a6252482")
        #expect(tag.count == CourierEnvelope.tagLength)
    }

    /// The 16-byte envelope identity a spray receipt carries.
    @Test func ciphertextHashIsSHA256TruncatedTo16() {
        let hash = Data(Self.ciphertext.sha256Hash().prefix(CourierEnvelope.tagLength))
        #expect(hash.hexEncodedString() == "bb85dcc4d8b17377c61817992df95826")
    }

    // MARK: Packet canonicalization — the trap worth a vector

    /// A real `courierEnvelope` frame: type 0x04 carrying an encoded envelope,
    /// which is what a deposit actually puts on the wire.
    static func envelopePacket() throws -> BitchatPacket {
        let envelope = CourierEnvelope(recipientTag: recipientTag,
                                       expiry: expiryMs,
                                       ciphertext: ciphertext,
                                       copies: 4,
                                       prekeyID: 0x1122_3344)
        return BitchatPacket(type: 0x04,
                             senderID: senderID,
                             recipientID: recipientID,
                             timestamp: timestampMs,
                             payload: try #require(envelope.encode()),
                             signature: nil,
                             ttl: 7)
    }

    /// Every byte of the unsigned frame. 14 header + 8 sender + 8 recipient +
    /// 74 envelope = 104. The envelope is under the 100-byte compression
    /// threshold, so the compressed path never applies here.
    static let unpaddedHex = """
    010407000001977420dc0001004a112233445566778899aabbccddeeff000100100001020\
    30405060708090a0b0c0d0e0f020008000001a3185c500003001e636f75726965722d76656\
    3746f722d636970686572746578742d303030310400010405000411223344
    """.replacingOccurrences(of: "\n", with: "")

    /// Identical to `unpaddedHex` except `ttl` at offset 2 is zeroed.
    static let preimageBodyHex = """
    010400000001977420dc0001004a112233445566778899aabbccddeeff000100100001020\
    30405060708090a0b0c0d0e0f020008000001a3185c500003001e636f75726965722d76656\
    3746f722d636970686572746578742d303030310400010405000411223344
    """.replacingOccurrences(of: "\n", with: "")

    /// The signed pre-image is **not** the wire bytes. It zeroes `ttl`, clears
    /// the `hasSignature` flag, and is PKCS#7-padded to a block boundary.
    /// Both sequences are compared in full — a change to timestamp encoding,
    /// payload length, or field layout has to fail here, otherwise the JSON
    /// fixture could go stale while this stayed green.
    @Test func signingPreimageIsTTLZeroedAndPadded() throws {
        let packet = try Self.envelopePacket()

        let unpadded = try #require(BinaryProtocol.encode(packet, padding: false))
        #expect(unpadded.count == 104)
        #expect(unpadded.hexEncodedString() == Self.unpaddedHex)

        let preimage = try #require(packet.toBinaryDataForSigning())
        #expect(preimage.count == 256)
        #expect(preimage.hexEncodedString()
                == Self.preimageBodyHex + String(repeating: "98", count: 152))

        // 152 == 0x98 == the shortfall to the 256-byte block, and every pad
        // byte equals it.
        #expect(preimage.dropFirst(104).allSatisfy { $0 == 152 })
        #expect(preimage[BinaryProtocol.Offsets.flags] == BinaryProtocol.Flags.hasRecipient)
        #expect(unpadded[2] == 7 && preimage[2] == 0)   // ttl on wire vs signed
    }

    /// Ed25519 — CryptoKit's `Curve25519.Signing`, not X25519 key agreement.
    @Test func signatureOverPreimageVerifies() throws {
        let packet = try Self.envelopePacket()
        let preimage = try #require(packet.toBinaryDataForSigning())

        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Self.signingSeed)
        #expect(key.publicKey.rawRepresentation.hexEncodedString()
                == "2152f8d19b791d24453242e15f2eab6cb7cffa7b6a5ed30097960e069881db12")

        // Signature BYTES are deliberately not pinned. CryptoKit's Ed25519
        // signing is randomized rather than the deterministic RFC 8032
        // construction, so two signatures over identical input differ and both
        // verify. A second implementation using a deterministic Ed25519 library
        // will therefore not reproduce iOS's bytes — and does not need to.
        // What must match is the pre-image above; verification is the contract.
        let a = try key.signature(for: preimage)
        let b = try key.signature(for: preimage)
        #expect(Data(a) != Data(b), "CryptoKit Ed25519 signing is randomized")
        #expect(key.publicKey.isValidSignature(a, for: preimage))
        #expect(key.publicKey.isValidSignature(b, for: preimage))
        #expect(Data(a).count == BinaryProtocol.signatureSize)

        let signature = a

        // On the wire the packet is 168 bytes — the 104 above plus a 64-byte
        // signature — and the flags byte now also carries hasSignature.
        var signed = packet
        signed.signature = Data(signature)
        let wire = try #require(BinaryProtocol.encode(signed, padding: false))
        #expect(wire.count == 168)
        #expect(wire[BinaryProtocol.Offsets.flags]
                == BinaryProtocol.Flags.hasRecipient | BinaryProtocol.Flags.hasSignature)
    }
}
