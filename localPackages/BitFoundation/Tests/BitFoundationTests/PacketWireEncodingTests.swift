import CryptoKit
import Foundation
import Testing

@testable import BitFoundation

struct PacketWireEncodingTests {
    private let payload = Data(String(repeating: "synthetic message ", count: 160).utf8)
    private let sender = Data([0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88])

    // A valid raw DEFLATE stored block gives a deterministic representation
    // different from the native compressor, without another codec dependency.
    private func frame(version: UInt8, compressed: Bool, signature: Data? = nil) -> Data {
        var body = payload
        if compressed {
            let length = UInt16(payload.count)
            body = Data([1, UInt8(length & 255), UInt8(length >> 8), UInt8((~length) & 255), UInt8((~length) >> 8)])
            body.append(payload)
        }
        var bytes = Data([version, MessageType.message.rawValue, 0])
        appendInteger(1_000_000, bytes: 8, to: &bytes)
        bytes.append((compressed ? 4 : 0) | (signature == nil ? 0 : 2))
        let lengthBytes = version == 1 ? 2 : 4
        appendInteger(UInt64(body.count + (compressed ? lengthBytes : 0)), bytes: lengthBytes, to: &bytes)
        bytes.append(sender)
        if compressed { appendInteger(UInt64(payload.count), bytes: lengthBytes, to: &bytes) }
        bytes.append(body)
        if let signature { bytes.append(signature) }
        return bytes
    }

    private func appendInteger(_ value: UInt64, bytes: Int, to data: inout Data) {
        for shift in stride(from: (bytes - 1) * 8, through: 0, by: -8) {
            data.append(UInt8((value >> shift) & 255))
        }
    }

    @Test(arguments: [UInt8(1), UInt8(2)], [false, true])
    func receivedEncodingSurvivesVerificationRelayAndPersistence(version: UInt8, compressed: Bool) throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
        let signedBytes = frame(version: version, compressed: compressed)
        let signature = try key.signature(for: signedBytes)
        let wire = frame(version: version, compressed: compressed, signature: signature)
        var packet = try #require(BitchatPacket.from(wire))
        #expect(packet.payload == payload)
        #expect(packet.toBinaryData(padding: false) == wire)
        #expect(packet.toBinaryDataForSigning() == signedBytes)
        #expect(packet.retainedPayloadBytes == payload.count + (compressed ? payload.count + 5 : 0))

        packet.ttl = 2
        packet.isRSR = true
        let relayed = try #require(packet.toBinaryData(padding: false))
        let restored = try #require(BitchatPacket.from(relayed))
        let restoredBytes = try #require(restored.toBinaryDataForSigning())
        #expect(key.publicKey.isValidSignature(signature, for: restoredBytes))
        // Check Codable round-tripping as well as the binary round-trip above.
        let json = try JSONEncoder().encode(restored)
        let decodedJSON = try JSONDecoder().decode(BitchatPacket.self, from: json)
        #expect(decodedJSON.toBinaryData(padding: false) == relayed)
        #expect(decodedJSON.toBinaryDataForSigning() == signedBytes)
    }

    @Test(arguments: [false, true])
    func smallForeignFramesKeepSigningPadding(compressed: Bool) throws {
        let content = Data(repeating: 0x41, count: 128)
        var encoded = content
        if compressed {
            encoded = Data([1, 128, 0, 127, 255])
            encoded.append(content)
        }
        var unsigned = Data([1, 2, 0])
        appendInteger(1_000_000, bytes: 8, to: &unsigned)
        unsigned.append(compressed ? 4 : 0)
        appendInteger(UInt64(encoded.count + (compressed ? 2 : 0)), bytes: 2, to: &unsigned)
        unsigned.append(sender)
        if compressed { appendInteger(128, bytes: 2, to: &unsigned) }
        unsigned.append(encoded)
        let preimage = MessagePadding.pad(unsigned, toSize: MessagePadding.optimalBlockSize(for: unsigned.count))
        #expect(preimage.count > unsigned.count)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
        let signature = try key.signature(for: preimage)
        var wire = unsigned
        wire[11] |= 2
        wire[2] = 3
        wire.append(signature)
        let packet = try #require(BitchatPacket.from(wire))
        let reconstructed = try #require(packet.toBinaryDataForSigning())
        #expect(reconstructed == preimage)
        #expect(key.publicKey.isValidSignature(signature, for: reconstructed))
    }

    @Test(arguments: [false, true])
    func receivedRouteSurvivesRelayAndPersistence(compressed: Bool) throws {
        let route = [Data(repeating: 0x33, count: 8), Data(repeating: 0x44, count: 8)]
        var signedBytes = frame(version: 2, compressed: compressed)
        signedBytes[11] |= BinaryProtocol.Flags.hasRoute
        var routeBytes = Data([UInt8(route.count)])
        for hop in route { routeBytes.append(hop) }
        // The v2 header and sender occupy 24 bytes; this frame has no recipient.
        signedBytes.insert(contentsOf: routeBytes, at: 24)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
        let signature = try key.signature(for: signedBytes)
        var wire = signedBytes
        wire[11] |= BinaryProtocol.Flags.hasSignature
        wire.append(signature)
        var packet = try #require(BitchatPacket.from(wire))
        #expect(packet.route == route)
        #expect(packet.toBinaryData(padding: false) == wire)
        packet.ttl = 2
        packet.isRSR = true
        let forwardedBytes = try #require(packet.toBinaryData(padding: false))
        let forwarded = try #require(BitchatPacket.from(forwardedBytes))
        let restored = try JSONDecoder().decode(BitchatPacket.self, from: JSONEncoder().encode(forwarded))
        #expect(restored.route == route)
        let reconstructed = try #require(restored.toBinaryDataForSigning())
        #expect(reconstructed == signedBytes)
        #expect(key.publicKey.isValidSignature(signature, for: reconstructed))
    }

    @Test func alteredSignedFieldsDoNotVerify() throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
        let original = frame(version: 2, compressed: true)
        let signature = try key.signature(for: original)
        let wire = frame(version: 2, compressed: true, signature: signature)
        for offset in [10, 16, wire.count - 1] {
            var changed = wire
            changed[offset] ^= 1
            let decoded = try #require(BitchatPacket.from(changed))
            let preimage = try #require(decoded.toBinaryDataForSigning())
            let candidateSignature = try #require(decoded.signature)
            #expect(!key.publicKey.isValidSignature(candidateSignature, for: preimage))
        }
        var changedRoute = try #require(BitchatPacket.from(wire))
        changedRoute.route = [Data(repeating: 0x33, count: 8)]
        let routedBytes = try #require(changedRoute.toBinaryDataForSigning())
        #expect(!key.publicKey.isValidSignature(signature, for: routedBytes))
    }

    @Test func codableRejectsWireBytesForDifferentContent() throws {
        let packet = try #require(BitchatPacket.from(frame(version: 1, compressed: true)))
        let json = try JSONEncoder().encode(packet)
        var object = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
        var altered = payload
        altered[0] ^= 1
        object["payload"] = altered.base64EncodedString()
        let corrupted = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(BitchatPacket.self, from: corrupted)
        }
    }

    @Test func legacyCodableAndNewPacketsUseNativeEncoding() throws {
        let packet = BitchatPacket(
            type: 2, senderID: sender, recipientID: nil, timestamp: 1_000_000, payload: payload, signature: nil, ttl: 0)
        let json = try JSONEncoder().encode(packet)
        let object = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(object["wirePayload"] == nil)
        let restored = try JSONDecoder().decode(BitchatPacket.self, from: json)
        #expect(restored.toBinaryData(padding: false) == packet.toBinaryData(padding: false))
        #expect(restored.retainedPayloadBytes == payload.count)
    }
}
