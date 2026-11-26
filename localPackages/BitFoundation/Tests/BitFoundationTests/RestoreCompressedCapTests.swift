import Foundation
import Testing
@testable import BitFoundation

struct RestoreCompressedCapTests {
    private func packet(type: UInt8, compressedSize: Int, version: UInt8 = 2) throws -> BitchatPacket {
        var payloadSize = (compressedSize - 5) % 5
        if payloadSize == 0 { payloadSize = 5 }
        let payload = Data(repeating: 0x41, count: payloadSize)
        let emptyBlocks = (compressedSize - 5 - payloadSize) / 5
        var compressed = Data()
        for _ in 0..<emptyBlocks { compressed.append(contentsOf: [0, 0, 0, 255, 255]) }
        compressed.append(contentsOf: [1, UInt8(payloadSize), 0, UInt8(255 - payloadSize), 255])
        compressed.append(payload)
        #expect(compressed.count == compressedSize)
        #expect(CompressionUtil.decompress(compressed, originalSize: payload.count) == payload)
        var packet = BitchatPacket(type: type, senderID: Data(repeating: 1, count: 8),
            recipientID: nil, timestamp: 1_000_000, payload: payload,
            signature: nil, ttl: 0, version: version)
        packet.wirePayload = PacketWirePayload(compressedBytes: compressed)
        return packet
    }

    // Valid raw DEFLATE empty stored blocks separate encoded size from decoded size.
    @Test(arguments: [MessageType.message.rawValue, MessageType.announce.rawValue,
        MessageType.fragment.rawValue, MessageType.requestSync.rawValue,
        MessageType.courierEnvelope.rawValue, MessageType.fileTransfer.rawValue,
        MessageType.noiseEncrypted.rawValue, UInt8(0xff)], [0, 1])
    func codableChecksCompressedSizeAtAndAboveTypeLimit(type: UInt8, excess: Int) throws {
        let cap = PacketPayloadLimits.maxPayloadBytes(forType: type)
        let packet = try packet(type: type, compressedSize: cap + excess)
        let json = try JSONEncoder().encode(packet)
        if excess == 0 {
            let restored = try JSONDecoder().decode(BitchatPacket.self, from: json)
            #expect(restored.payload == packet.payload)
            #expect(restored.wirePayload?.compressedBytes == packet.wirePayload?.compressedBytes)
        } else {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(BitchatPacket.self, from: json)
            }
        }
    }

    @Test(arguments: [MessageType.message.rawValue, MessageType.announce.rawValue,
        MessageType.boardPost.rawValue, MessageType.fragment.rawValue,
        MessageType.requestSync.rawValue, MessageType.courierEnvelope.rawValue,
        MessageType.fileTransfer.rawValue, MessageType.noiseEncrypted.rawValue, UInt8(0xff)], [0, 1])
    func binaryDecodeChecksTheEncodedBoundary(type: UInt8, excess: Int) throws {
        // The existing global wire limit includes the four-byte expanded-size field.
        let cap = min(PacketPayloadLimits.maxPayloadBytes(forType: type), FileTransferLimits.maxFramedFileBytes - 4)
        let original = try packet(type: type, compressedSize: cap + excess)
        let frame = try #require(original.toBinaryData(padding: false))
        let decoded = BitchatPacket.from(frame)
        if excess == 0 {
            let accepted = try #require(decoded)
            #expect(accepted.payload == original.payload)
            #expect(accepted.toBinaryData(padding: false) == frame)
        } else {
            #expect(decoded == nil)
        }
    }

    @Test(arguments: [MessageType.announce.rawValue, MessageType.fragment.rawValue,
        MessageType.requestSync.rawValue], [0, 1])
    func v1BinaryDecodeChecksTheEncodedBoundary(type: UInt8, excess: Int) throws {
        let cap = PacketPayloadLimits.maxPayloadBytes(forType: type)
        let original = try packet(type: type, compressedSize: cap + excess, version: 1)
        let frame = try #require(original.toBinaryData(padding: false))
        let decoded = BitchatPacket.from(frame)
        if excess == 0 {
            #expect(try #require(decoded).toBinaryData(padding: false) == frame)
        } else {
            #expect(decoded == nil)
        }
    }

    @Test func acceptsSmallRepresentation() throws {
        let packet = try packet(type: MessageType.message.rawValue, compressedSize: 47)
        let restored = try JSONDecoder().decode(BitchatPacket.self, from: JSONEncoder().encode(packet))
        #expect(restored.payload == packet.payload)
        #expect(restored.wirePayload?.compressedBytes == packet.wirePayload?.compressedBytes)
    }
    @Test(arguments: [33, 4096])
    func rejectsSavedPrefixOfLongerExpansion(expandedSize: Int) throws {
        let full = Data(repeating: 0x41, count: expandedSize)
        let size = UInt16(full.count)
        var compressed = Data([1, UInt8(size & 255), UInt8(size >> 8), UInt8((~size) & 255), UInt8((~size) >> 8)])
        compressed.append(full)
        let json = try savedPacket(payload: Data(full.prefix(32)), compressed: compressed)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(BitchatPacket.self, from: json)
        }
    }

    @Test func rejectsDecodedPayloadAboveItsTypeLimit() throws {
        let cap = PacketPayloadLimits.maxPayloadBytes(forType: MessageType.message.rawValue)
        let payload = Data(repeating: 0x41, count: cap + 1)
        let compressed = try #require(CompressionUtil.compress(payload))
        #expect(compressed.count < cap)
        #expect(payload.count <= compressed.count * PacketPayloadLimits.maxDeflateRatio)
        let json = try savedPacket(payload: payload, compressed: compressed)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(BitchatPacket.self, from: json)
        }
    }

    @Test(arguments: [Data(), Data([0xff]), Data([0, 0, 0, 0, 0])])
    func rejectsInvalidCompressedContent(compressed: Data) throws {
        let json = try savedPacket(payload: Data(repeating: 0x41, count: 32), compressed: compressed)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(BitchatPacket.self, from: json)
        }
    }

    @Test func rejectsAnUnfinishedStoredBlockAfterExpectedOutput() throws {
        let payload = Data(repeating: 0x41, count: 32)
        var compressed = Data([0, 32, 0, 223, 255])
        compressed.append(payload)
        let json = try savedPacket(payload: payload, compressed: compressed)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(BitchatPacket.self, from: json)
        }
    }

    @Test(arguments: [false, true])
    func rejectsMalformedWireMetadata(invalidBase64: Bool) throws {
        let packet = BitchatPacket(type: MessageType.message.rawValue,
            senderID: Data(repeating: 1, count: 8), recipientID: nil,
            timestamp: 1_000_000, payload: Data([0x41]), signature: nil, ttl: 0)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(packet)) as? [String: Any])
        object["wirePayload"] = invalidBase64 ? ["compressedBytes": "invalid-base64!"] as Any : 1 as Any
        let json = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(BitchatPacket.self, from: json)
        }
    }

    @Test func nilCompressedMetadataKeepsAnUncompressedRepresentation() throws {
        var packet = BitchatPacket(type: MessageType.message.rawValue,
            senderID: Data(repeating: 1, count: 8), recipientID: nil,
            timestamp: 1_000_000, payload: Data(repeating: 0x41, count: 100), signature: nil, ttl: 0)
        packet.wirePayload = PacketWirePayload(compressedBytes: nil)
        let restored = try JSONDecoder().decode(BitchatPacket.self, from: JSONEncoder().encode(packet))
        let wire = try #require(restored.toBinaryData(padding: false))
        #expect(wire[11] & BinaryProtocol.Flags.isCompressed == 0)
        #expect(restored.payload == packet.payload)
    }

    private func savedPacket(payload: Data, compressed: Data) throws -> Data {
        var packet = BitchatPacket(type: MessageType.message.rawValue,
            senderID: Data(repeating: 1, count: 8), recipientID: nil,
            timestamp: 1_000_000, payload: payload, signature: nil, ttl: 0)
        packet.wirePayload = PacketWirePayload(compressedBytes: compressed)
        return try JSONEncoder().encode(packet)
    }
}
