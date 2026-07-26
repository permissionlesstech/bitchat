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

/// Golden vectors for the courier wire format, published as
/// `docs/courier-test-vectors.json` so a second implementation can check itself
/// without running this app.
///
/// Every value asserted below is **read from that file**, not duplicated here.
/// A format change that updates only the Swift side leaves the published JSON
/// stale, and a stale JSON fails these tests — which is the only thing that
/// makes the document trustworthy to someone who cannot run it.
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

    // MARK: Loading the published vectors

    /// The published file, located relative to this source file. It lives at
    /// repo-root `docs/`, outside this package, so it cannot be a SwiftPM
    /// resource the way `NoiseTestVectors.json` is — the repo already resolves
    /// a repo-root path this way in `bitchatTests/LocalizationCoverageTests`.
    static let vectorFileURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // → BitFoundationTests
        .deletingLastPathComponent()   // → Tests
        .deletingLastPathComponent()   // → BitFoundation
        .deletingLastPathComponent()   // → localPackages
        .deletingLastPathComponent()   // → repo root
        .appendingPathComponent("docs/courier-test-vectors.json")

    struct MissingVectorFile: Error, CustomStringConvertible {
        let path: String
        var description: String {
            "docs/courier-test-vectors.json not found at \(path). These tests assert "
            + "the published vectors; they must not silently pass without them."
        }
    }

    static func loadVectors() throws -> Vectors {
        guard FileManager.default.fileExists(atPath: vectorFileURL.path) else {
            throw MissingVectorFile(path: vectorFileURL.path)
        }
        return try JSONDecoder().decode(Vectors.self,
                                        from: try Data(contentsOf: vectorFileURL))
    }

    /// Decoded shape of the published file. `_comment` keys are prose for human
    /// readers and are deliberately not decoded; every other key is, so a field
    /// cannot be renamed or dropped without failing here.
    struct Vectors: Decodable {
        struct Inputs: Decodable {
            let recipientTag: String
            let noiseStaticKey: String
            let ciphertextUTF8: String
            let ciphertext: String
            let expiryMillis: UInt64
            let epochDay: UInt32
            let senderID: String
            let recipientID: String
            let timestampMillis: UInt64
            let signingSeed: String
        }
        struct EnvelopeTLV: Decodable {
            let copies: UInt8
            let prekeyID: UInt32
            let encoded: String
            let encodedLength: Int
        }
        struct CopiesClamping: Decodable {
            struct Case: Decodable {
                let requested: UInt8
                let stored: UInt8
            }
            let maxCopies: UInt8
            let cases: [Case]
        }
        struct RecipientTagDerivation: Decodable {
            let label: String
            let epochDay: UInt32
            let expected: String
        }
        struct CiphertextHash: Decodable {
            let expected: String
        }
        struct PacketSigning: Decodable {
            struct Packet: Decodable {
                let version: UInt8
                let type: String
                let ttlOnWire: UInt8
            }
            struct Flags: Decodable {
                let unsignedUnpadded: String
                let signingPreimage: String
                let signedWirePacket: String
            }
            let packet: Packet
            let unsignedUnpaddedLength: Int
            let unsignedUnpadded: String
            let signingPreimageLength: Int
            let signingPreimagePadByte: String
            let signingPreimagePadCount: Int
            let signingPreimage: String
            let signedWireLength: Int
            let flags: Flags
        }
        struct Signature: Decodable {
            let publicKey: String
            let signatureLength: Int
            let deterministic: Bool
        }

        let inputs: Inputs
        let envelopeTLV: EnvelopeTLV
        let copiesClamping: CopiesClamping
        let recipientTagDerivation: RecipientTagDerivation
        let ciphertextHash: CiphertextHash
        let packetSigning: PacketSigning
        let signature: Signature
    }

    /// Fails loudly if the published file is missing, renamed, or has lost a
    /// key — otherwise a rename would skip every assertion below while the
    /// suite still reported green.
    @Test func publishedVectorFileLoads() throws {
        let v = try Self.loadVectors()
        #expect(v.inputs.ciphertextUTF8 == "courier-vector-ciphertext-0001")
        #expect(v.copiesClamping.cases.isEmpty == false)
    }

    // MARK: Decoded inputs

    private static func hex(_ string: String) throws -> Data {
        try #require(Data(hexString: string), "not valid hex: \(string)")
    }

    /// `"0x03"` → `3`.
    private static func flagByte(_ string: String) throws -> UInt8 {
        let digits = string.hasPrefix("0x") ? String(string.dropFirst(2)) : string
        return try #require(UInt8(digits, radix: 16), "not a hex byte: \(string)")
    }

    private static func envelope(from v: Vectors) throws -> CourierEnvelope {
        CourierEnvelope(recipientTag: try hex(v.inputs.recipientTag),
                        expiry: v.inputs.expiryMillis,
                        ciphertext: try hex(v.inputs.ciphertext),
                        copies: v.envelopeTLV.copies,
                        prekeyID: v.envelopeTLV.prekeyID)
    }

    // MARK: Envelope

    /// `expiry` is milliseconds since epoch, big-endian, in an 8-byte TLV.
    @Test func envelopeTLVEncoding() throws {
        let v = try Self.loadVectors()

        // The published ciphertext hex and its UTF-8 source must agree, or the
        // document contradicts itself.
        #expect(try Self.hex(v.inputs.ciphertext) == Data(v.inputs.ciphertextUTF8.utf8))

        let encoded = try #require(try Self.envelope(from: v).encode())
        #expect(encoded.hexEncodedString() == v.envelopeTLV.encoded)
        #expect(encoded.count == v.envelopeTLV.encodedLength)

        // 0x02 carries 000001a3185c5000 == 1_800_000_000_000 ms, not seconds.
        let decoded = try #require(CourierEnvelope.decode(encoded))
        #expect(decoded.expiry == v.inputs.expiryMillis)
        #expect(decoded.copies == v.envelopeTLV.copies)
        #expect(decoded.prekeyID == v.envelopeTLV.prekeyID)
    }

    /// `copies` is clamped into 1...maxCopies, never rejected. An implementation
    /// that rejects out-of-range values drops envelopes this one accepts.
    @Test func copiesAreClampedNotRejected() throws {
        let v = try Self.loadVectors()
        #expect(CourierEnvelope.maxCopies == v.copiesClamping.maxCopies)

        for testCase in v.copiesClamping.cases {
            let stored = CourierEnvelope(recipientTag: try Self.hex(v.inputs.recipientTag),
                                         expiry: v.inputs.expiryMillis,
                                         ciphertext: try Self.hex(v.inputs.ciphertext),
                                         copies: testCase.requested).copies
            #expect(stored == testCase.stored,
                    "copies(\(testCase.requested)) expected \(testCase.stored), got \(stored)")
        }
    }

    /// HMAC-SHA256(noiseStaticKey, "bitchat-courier-tag-v1" || BE32(epochDay)),
    /// truncated to 16 bytes.
    @Test func recipientTagDerivation() throws {
        let v = try Self.loadVectors()
        let noiseStaticKey = try Self.hex(v.inputs.noiseStaticKey)
        #expect(v.recipientTagDerivation.epochDay == v.inputs.epochDay)

        let tag = CourierEnvelope.recipientTag(noiseStaticKey: noiseStaticKey,
                                               epochDay: v.recipientTagDerivation.epochDay)
        #expect(tag.hexEncodedString() == v.recipientTagDerivation.expected)
        #expect(tag.count == CourierEnvelope.tagLength)

        // Recompute from the published `label` so that field is load-bearing
        // too: the implementation's context string is private, so without this
        // the document could name the wrong label and nothing would notice.
        var message = Data(v.recipientTagDerivation.label.utf8)
        withUnsafeBytes(of: v.recipientTagDerivation.epochDay.bigEndian) { message.append(contentsOf: $0) }
        let recomputed = Data(HMAC<SHA256>.authenticationCode(
            for: message, using: SymmetricKey(data: noiseStaticKey)
        ).prefix(CourierEnvelope.tagLength))
        #expect(recomputed == tag)
    }

    /// The 16-byte envelope identity a spray receipt carries.
    @Test func ciphertextHashIsSHA256TruncatedTo16() throws {
        let v = try Self.loadVectors()
        let hash = Data(try Self.hex(v.inputs.ciphertext)
            .sha256Hash()
            .prefix(CourierEnvelope.tagLength))
        #expect(hash.hexEncodedString() == v.ciphertextHash.expected)
    }

    // MARK: Packet canonicalization — the trap worth a vector

    /// A real `courierEnvelope` frame: type 0x04 carrying an encoded envelope,
    /// which is what a deposit actually puts on the wire.
    static func envelopePacket(from v: Vectors) throws -> BitchatPacket {
        BitchatPacket(type: try flagByte(v.packetSigning.packet.type),
                      senderID: try hex(v.inputs.senderID),
                      recipientID: try hex(v.inputs.recipientID),
                      timestamp: v.inputs.timestampMillis,
                      payload: try #require(try envelope(from: v).encode()),
                      signature: nil,
                      ttl: v.packetSigning.packet.ttlOnWire)
    }

    /// The signed pre-image is **not** the wire bytes. It zeroes `ttl`, clears
    /// the `hasSignature` flag, and is PKCS#7-padded to a block boundary.
    /// Both sequences are compared in full — a change to timestamp encoding,
    /// payload length, or field layout has to fail here, otherwise the JSON
    /// fixture could go stale while this stayed green.
    @Test func signingPreimageIsTTLZeroedAndPadded() throws {
        let v = try Self.loadVectors()
        let signing = v.packetSigning
        let packet = try Self.envelopePacket(from: v)

        let unpadded = try #require(BinaryProtocol.encode(packet, padding: false))
        #expect(unpadded.count == signing.unsignedUnpaddedLength)
        #expect(unpadded.hexEncodedString() == signing.unsignedUnpadded)

        let preimage = try #require(packet.toBinaryDataForSigning())
        #expect(preimage.count == signing.signingPreimageLength)
        #expect(preimage.hexEncodedString() == signing.signingPreimage)

        // The pad byte equals the shortfall to the block boundary, and every
        // pad byte equals it.
        let padByte = try Self.flagByte(signing.signingPreimagePadByte)
        #expect(Int(padByte) == signing.signingPreimagePadCount)
        #expect(signing.unsignedUnpaddedLength + signing.signingPreimagePadCount
                == signing.signingPreimageLength)
        #expect(preimage.dropFirst(signing.unsignedUnpaddedLength).count
                == signing.signingPreimagePadCount)
        #expect(preimage.dropFirst(signing.unsignedUnpaddedLength).allSatisfy { $0 == padByte })

        #expect(preimage[BinaryProtocol.Offsets.flags]
                == (try Self.flagByte(signing.flags.signingPreimage)))
        #expect(unpadded[BinaryProtocol.Offsets.flags]
                == (try Self.flagByte(signing.flags.unsignedUnpadded)))
        #expect(unpadded[2] == signing.packet.ttlOnWire && preimage[2] == 0)
        #expect(unpadded[0] == signing.packet.version)
    }

    /// Ed25519 — CryptoKit's `Curve25519.Signing`, not X25519 key agreement.
    @Test func signatureOverPreimageVerifies() throws {
        let v = try Self.loadVectors()
        let packet = try Self.envelopePacket(from: v)
        let preimage = try #require(packet.toBinaryDataForSigning())

        // Pin what is being signed. Without this the test is self-consistent by
        // construction — it would sign whatever it was handed, verify it, and
        // pass over a wrong canonicalization. Proven by mutating an input and
        // watching this line, not the verification below, be the one that fails.
        #expect(preimage.hexEncodedString() == v.packetSigning.signingPreimage)

        let key = try Curve25519.Signing.PrivateKey(
            rawRepresentation: try Self.hex(v.inputs.signingSeed)
        )
        #expect(key.publicKey.rawRepresentation.hexEncodedString() == v.signature.publicKey)

        // Signature BYTES are deliberately not pinned. CryptoKit's Ed25519
        // signing is randomized rather than the deterministic RFC 8032
        // construction, so two signatures over identical input differ and both
        // verify. A second implementation using a deterministic Ed25519 library
        // will therefore not reproduce iOS's bytes — and does not need to.
        // What must match is the pre-image above; verification is the contract.
        let a = try key.signature(for: preimage)
        let b = try key.signature(for: preimage)
        #expect(v.signature.deterministic == false)
        #expect(Data(a) != Data(b), "CryptoKit Ed25519 signing is randomized")
        #expect(key.publicKey.isValidSignature(a, for: preimage))
        #expect(key.publicKey.isValidSignature(b, for: preimage))
        #expect(Data(a).count == BinaryProtocol.signatureSize)
        #expect(Data(a).count == v.signature.signatureLength)

        // On the wire the packet carries the 64-byte signature on top of the
        // unsigned frame, and the flags byte now also carries hasSignature.
        var signed = packet
        signed.signature = Data(a)
        let wire = try #require(BinaryProtocol.encode(signed, padding: false))
        #expect(wire.count == v.packetSigning.signedWireLength)
        #expect(wire.count == v.packetSigning.unsignedUnpaddedLength + v.signature.signatureLength)
        #expect(wire[BinaryProtocol.Offsets.flags]
                == (try Self.flagByte(v.packetSigning.flags.signedWirePacket)))
    }
}
