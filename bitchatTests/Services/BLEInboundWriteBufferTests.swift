import BitFoundation
import Foundation
import Testing
@testable import bitchat

struct BLEInboundWriteBufferTests {
    @Test
    func appendDecodesPacketAcrossChunkedWrites() throws {
        var buffer = BLEInboundWriteBuffer()
        let packet = makePacket()
        let frame = try #require(packet.toBinaryData(padding: false))
        let splitIndex = max(1, frame.count / 2)

        let firstResult = buffer.append(
            chunks: [BLEInboundWriteChunk(offset: 0, data: frame.prefix(splitIndex))],
            for: "central-1",
            capBytes: 1024
        )

        if case let .waiting(metadata) = firstResult {
            #expect(metadata.accumulatedBytes == splitIndex)
            #expect(metadata.appendedBytes == splitIndex)
            #expect(metadata.offsets == [0])
            #expect(metadata.packetType == MessageType.message.rawValue)
        } else {
            Issue.record("Expected first chunk to wait for more data")
        }

        let secondResult = buffer.append(
            chunks: [BLEInboundWriteChunk(offset: splitIndex, data: frame.suffix(from: splitIndex))],
            for: "central-1",
            capBytes: 1024
        )

        if case let .decoded(decoded, metadata) = secondResult {
            #expect(decoded.type == packet.type)
            #expect(decoded.senderID == packet.senderID)
            #expect(decoded.payload == packet.payload)
            #expect(metadata.accumulatedBytes == frame.count)
            #expect(metadata.offsets == [splitIndex])
        } else {
            Issue.record("Expected complete frame to decode")
        }
    }

    @Test
    func appendMergesMultipleOffsetChunksInOneCall() throws {
        var buffer = BLEInboundWriteBuffer()
        let packet = makePacket(timestamp: 0xABC)
        let frame = try #require(packet.toBinaryData(padding: false))
        let splitIndex = max(1, frame.count / 3)

        let result = buffer.append(
            chunks: [
                BLEInboundWriteChunk(offset: 0, data: frame.prefix(splitIndex)),
                BLEInboundWriteChunk(offset: splitIndex, data: frame.suffix(from: splitIndex))
            ],
            for: "central-1",
            capBytes: 1024
        )

        if case let .decoded(decoded, metadata) = result {
            #expect(decoded.timestamp == packet.timestamp)
            #expect(metadata.appendedBytes == frame.count)
            #expect(metadata.offsets == [0, splitIndex])
        } else {
            Issue.record("Expected merged chunks to decode")
        }
    }

    @Test
    func appendDropsOversizedBufferAndAllowsLaterDecode() throws {
        var buffer = BLEInboundWriteBuffer()
        let oversized = buffer.append(
            chunks: [BLEInboundWriteChunk(offset: 0, data: Data(repeating: 0xAA, count: 8))],
            for: "central-1",
            capBytes: 4
        )

        if case let .oversized(metadata) = oversized {
            #expect(metadata.accumulatedBytes == 8)
            #expect(metadata.appendedBytes == 8)
        } else {
            Issue.record("Expected oversized buffer to be dropped")
        }

        let packet = makePacket(timestamp: 0xDEF)
        let frame = try #require(packet.toBinaryData(padding: false))
        let decoded = buffer.append(
            chunks: [BLEInboundWriteChunk(offset: 0, data: frame)],
            for: "central-1",
            capBytes: 1024
        )

        if case let .decoded(decodedPacket, _) = decoded {
            #expect(decodedPacket.timestamp == packet.timestamp)
        } else {
            Issue.record("Expected later clean frame to decode")
        }
    }

    @Test
    func removeAllClearsPartialWrites() throws {
        var buffer = BLEInboundWriteBuffer()
        let packet = makePacket()
        let frame = try #require(packet.toBinaryData(padding: false))
        let splitIndex = max(1, frame.count / 2)

        _ = buffer.append(
            chunks: [BLEInboundWriteChunk(offset: 0, data: frame.prefix(splitIndex))],
            for: "central-1",
            capBytes: 1024
        )
        buffer.removeAll()

        let result = buffer.append(
            chunks: [BLEInboundWriteChunk(offset: splitIndex, data: frame.suffix(from: splitIndex))],
            for: "central-1",
            capBytes: 1024
        )

        if case .waiting = result {
            // Expected: the first half was cleared, so the second half alone cannot decode.
        } else {
            Issue.record("Expected buffer reset to discard the earlier partial write")
        }
    }

    @Test
    func removeValueClearsOnlyTheTargetedCentralsPartialWrite() throws {
        var buffer = BLEInboundWriteBuffer()
        let packet = makePacket()
        let frame = try #require(packet.toBinaryData(padding: false))
        let splitIndex = max(1, frame.count / 2)

        // Two centrals each mid-write, as if both had connected and started
        // sending a fragmented frame before central-1 disconnected.
        _ = buffer.append(
            chunks: [BLEInboundWriteChunk(offset: 0, data: frame.prefix(splitIndex))],
            for: "central-1",
            capBytes: 1024
        )
        _ = buffer.append(
            chunks: [BLEInboundWriteChunk(offset: 0, data: frame.prefix(splitIndex))],
            for: "central-2",
            capBytes: 1024
        )

        buffer.removeValue(forCentralID: "central-1")

        // central-1's abandoned first half must be gone: completing it with
        // only the second half now must not decode (nothing to decode against).
        let afterRemoval = buffer.append(
            chunks: [BLEInboundWriteChunk(offset: splitIndex, data: frame.suffix(from: splitIndex))],
            for: "central-1",
            capBytes: 1024
        )
        if case .waiting = afterRemoval {
            // Expected: central-1's earlier half was discarded on disconnect.
        } else {
            Issue.record("Expected central-1's partial write to be discarded by removeValue")
        }

        // central-2's own in-flight write must be untouched by central-1's cleanup.
        let central2Result = buffer.append(
            chunks: [BLEInboundWriteChunk(offset: splitIndex, data: frame.suffix(from: splitIndex))],
            for: "central-2",
            capBytes: 1024
        )
        if case let .decoded(decoded, _) = central2Result {
            #expect(decoded.timestamp == packet.timestamp)
        } else {
            Issue.record("Expected central-2's unrelated partial write to still complete normally")
        }
    }

    private func makePacket(timestamp: UInt64 = 0x0102030405) -> BitchatPacket {
        BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77]),
            recipientID: nil,
            timestamp: timestamp,
            payload: Data([0xDE, 0xAD, 0xBE, 0xEF]),
            signature: nil,
            ttl: 3
        )
    }
}
