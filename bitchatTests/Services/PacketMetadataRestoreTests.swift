import BitFoundation
import Foundation
import Testing

struct PacketMetadataRestoreTests {
    @Test(arguments: [0, 1])
    func restorationChecksTheEncodedTypeBoundary(excess: Int) throws {
        // Message payloads use a 128 KiB limit; keep this fixture independent of the private lookup.
        let cap = 128 * 1024
        let encodedSize = cap + excess
        var payloadSize = (encodedSize - 5) % 5
        if payloadSize == 0 { payloadSize = 5 }
        let payload = Data(repeating: 0x41, count: payloadSize)
        let frame = RetainedPacketTestFixture.frame(sender: Data(repeating: 1, count: 8),
            timestamp: 1_000_000, payload: payload,
            emptyBlocks: (encodedSize - 5 - payloadSize) / 5)
        let packet = BitchatPacket(type: MessageType.message.rawValue,
            senderID: Data(repeating: 1, count: 8), recipientID: nil,
            timestamp: 1_000_000, payload: payload, signature: nil, ttl: 1, version: 2)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(packet)) as? [String: Any])
        // Bypass binary admission so an oversized saved representation reaches Codable validation.
        object["wirePayload"] = ["compressedBytes": Data(frame.suffix(encodedSize)).base64EncodedString()]
        let json = try JSONSerialization.data(withJSONObject: object)
        if excess == 0 {
            let restored = try JSONDecoder().decode(BitchatPacket.self, from: json)
            #expect(restored.payload == payload)
            #expect(restored.retainedPayloadBytes == encodedSize + payload.count)
        } else {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(BitchatPacket.self, from: json)
            }
        }
    }

    @Test(arguments: [33, 4096])
    func restorationRejectsASavedPrefix(expandedSize: Int) throws {
        let payload = Data(repeating: 0x41, count: expandedSize)
        let packet = try RetainedPacketTestFixture.packet(sender: Data(repeating: 1, count: 8),
            timestamp: 1_000_000, payload: payload)
        let json = try JSONEncoder().encode(packet)
        let accepted = try JSONDecoder().decode(BitchatPacket.self, from: json)
        #expect(accepted.payload == payload)
        var object = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
        object["payload"] = Data(payload.prefix(32)).base64EncodedString()
        let shortened = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(BitchatPacket.self, from: shortened)
        }
    }

    @Test func restorationRejectsAnUnfinishedStoredBlock() throws {
        let payload = Data(repeating: 0x41, count: 32)
        let packet = BitchatPacket(type: MessageType.message.rawValue,
            senderID: Data(repeating: 1, count: 8), recipientID: nil,
            timestamp: 1_000_000, payload: payload, signature: nil, ttl: 0)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(packet)) as? [String: Any])
        var unfinished = Data([0, 32, 0, 223, 255])
        unfinished.append(payload)
        object["wirePayload"] = ["compressedBytes": unfinished.base64EncodedString()]
        let json = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(BitchatPacket.self, from: json)
        }
    }
}
