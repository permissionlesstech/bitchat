//
// WireFormatVectorTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
import CryptoKit
@testable import BitFoundation

/// Asserts the encoder, decoder, and signing transcript against
/// `spec/vectors/wire-format.json`, the normative vector file for
/// `spec/01-wire-format.md` (see `spec/07-conformance.md` §7). The vectors are
/// produced by an independent encoder that shares no code with this package,
/// so a failure here means the spec text and this implementation have drifted.
struct WireFormatVectorTests {
    private struct VectorFile: Decodable {
        let specVersion: String
        let vectors: [Vector]
    }

    private struct Vector: Decodable {
        let name: String
        let packet: Packet
        let encodedUnpadded: String
        let encodedPadded: String
        let signingTranscript: String
        let ed25519: Ed25519?
    }

    private struct Packet: Decodable {
        let version: UInt8
        let type: UInt8
        let ttl: UInt8
        let timestamp: UInt64
        let senderId: String
        let recipientId: String?
        let route: [String]?
        let payload: String
        let signature: String?
        let isRsr: Bool
    }

    private struct Ed25519: Decodable {
        let privateKeySeed: String
        let publicKey: String
    }

    private static func loadVectors() throws -> VectorFile {
        // Tests/BitFoundationTests/<file> -> repo root is five levels up.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("spec/vectors/wire-format.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(VectorFile.self, from: Data(contentsOf: url))
    }

    private static func hex(_ string: String) throws -> Data {
        try #require(Data(hexString: string), "vector hex is well-formed: \(string.prefix(16))…")
    }

    private static func packet(from p: Packet) throws -> BitchatPacket {
        BitchatPacket(
            type: p.type,
            senderID: try hex(p.senderId),
            recipientID: try p.recipientId.map(hex),
            timestamp: p.timestamp,
            payload: try hex(p.payload),
            signature: try p.signature.map(hex),
            ttl: p.ttl,
            version: p.version,
            route: try p.route?.map(hex),
            isRSR: p.isRsr
        )
    }

    @Test func vectorFileMatchesSpecVersion() throws {
        let file = try Self.loadVectors()
        #expect(file.specVersion == "0.1.0")
        #expect(file.vectors.isEmpty == false)
    }

    @Test func encoderReproducesEveryVector() throws {
        for vector in try Self.loadVectors().vectors {
            let packet = try Self.packet(from: vector.packet)
            let unpadded = try #require(BinaryProtocol.encode(packet, padding: false), "\(vector.name): encodes unpadded")
            let padded = try #require(BinaryProtocol.encode(packet, padding: true), "\(vector.name): encodes padded")
            let expectedUnpadded = try Self.hex(vector.encodedUnpadded)
            let expectedPadded = try Self.hex(vector.encodedPadded)
            #expect(unpadded == expectedUnpadded, "\(vector.name): §2–§4 frame")
            #expect(padded == expectedPadded, "\(vector.name): §6 padded frame")
        }
    }

    @Test func signingTranscriptMatchesEveryVector() throws {
        for vector in try Self.loadVectors().vectors {
            let packet = try Self.packet(from: vector.packet)
            let transcript = try #require(packet.toBinaryDataForSigning(), "\(vector.name): builds signing transcript")
            let expected = try Self.hex(vector.signingTranscript)
            #expect(transcript == expected, "\(vector.name): §5 signing transcript")
        }
    }

    @Test func decoderRecoversEveryVector() throws {
        for vector in try Self.loadVectors().vectors {
            let expected = try Self.packet(from: vector.packet)
            for (label, encoded) in [("unpadded", vector.encodedUnpadded), ("padded", vector.encodedPadded)] {
                let frame = try Self.hex(encoded)
                let decoded = try #require(BinaryProtocol.decode(frame), "\(vector.name): decodes \(label)")
                #expect(decoded.version == expected.version, "\(vector.name) \(label): version")
                #expect(decoded.type == expected.type, "\(vector.name) \(label): type")
                #expect(decoded.ttl == expected.ttl, "\(vector.name) \(label): ttl")
                #expect(decoded.timestamp == expected.timestamp, "\(vector.name) \(label): timestamp")
                #expect(decoded.senderID == expected.senderID, "\(vector.name) \(label): senderID")
                #expect(decoded.recipientID == expected.recipientID, "\(vector.name) \(label): recipientID")
                #expect(decoded.route == expected.route, "\(vector.name) \(label): route")
                #expect(decoded.payload == expected.payload, "\(vector.name) \(label): payload")
                #expect(decoded.signature == expected.signature, "\(vector.name) \(label): signature")
                #expect(decoded.isRSR == expected.isRSR, "\(vector.name) \(label): isRSR")
            }
        }
    }

    @Test func ed25519SignaturesVerifyOverTranscript() throws {
        let signed = try Self.loadVectors().vectors.filter { $0.ed25519 != nil }
        #expect(signed.isEmpty == false, "at least one vector carries a real signature")
        for vector in signed {
            let keys = try #require(vector.ed25519)
            let publicKeyBytes = try Self.hex(keys.publicKey)
            let seedBytes = try Self.hex(keys.privateKeySeed)
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyBytes)
            let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seedBytes)
            #expect(privateKey.publicKey.rawRepresentation == publicKey.rawRepresentation, "\(vector.name): seed derives the listed public key")

            let signatureHex = try #require(vector.packet.signature)
            let signature = try Self.hex(signatureHex)
            let transcript = try Self.hex(vector.signingTranscript)
            #expect(publicKey.isValidSignature(signature, for: transcript), "\(vector.name): signature verifies over the §5 transcript")
            // The vector's signature is RFC 8032 deterministic; CryptoKit's own
            // signing is randomized, so only verification is asserted.
        }
    }
}
