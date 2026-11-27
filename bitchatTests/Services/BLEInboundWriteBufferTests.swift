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
    func removeForCentralDropsOnlyThatCentralsPartialBuffer() throws {
        var buffer = BLEInboundWriteBuffer()
        let packet = makePacket(timestamp: 0x123456)
        let frame = try #require(packet.toBinaryData(padding: false))
        let splitIndex = max(1, frame.count / 2)

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

        buffer.remove(for: "central-1")

        let c1Result = buffer.append(
            chunks: [BLEInboundWriteChunk(offset: splitIndex, data: frame.suffix(from: splitIndex))],
            for: "central-1",
            capBytes: 1024
        )
        if case .waiting = c1Result {
            // Expected: central-1's partial buffer was cleared on disconnect.
        } else {
            Issue.record("Expected central-1 partial buffer to be cleared")
        }

        let c2Result = buffer.append(
            chunks: [BLEInboundWriteChunk(offset: splitIndex, data: frame.suffix(from: splitIndex))],
            for: "central-2",
            capBytes: 1024
        )
        if case let .decoded(decoded, _) = c2Result {
            #expect(decoded.timestamp == packet.timestamp)
        } else {
            Issue.record("Expected central-2 partial buffer to remain intact")
        }
    }

    @Test
    func extremeOrNegativeOffsetRejectsWithoutAllocating() {
        var buffer = BLEInboundWriteBuffer()

        let hugeOffsetResult = buffer.append(
            chunks: [BLEInboundWriteChunk(offset: 1_000_000_000, data: Data([0x01, 0x02]))],
            for: "attacker-huge",
            capBytes: 1024
        )
        if case .oversized = hugeOffsetResult {
            // Rejected immediately before allocating zero-fill padding.
        } else {
            Issue.record("Expected huge offset to be rejected as oversized")
        }

        let overflowResult = buffer.append(
            chunks: [BLEInboundWriteChunk(offset: Int.max - 1, data: Data([0x01, 0x02, 0x03]))],
            for: "attacker-overflow",
            capBytes: 1024
        )
        if case .oversized = overflowResult {
            // Expected overflow guard.
        } else {
            Issue.record("Expected overflowing offset+length to be rejected")
        }

        let negativeResult = buffer.append(
            chunks: [BLEInboundWriteChunk(offset: -4, data: Data([0x01]))],
            for: "attacker-neg",
            capBytes: 1024
        )
        if case .oversized = negativeResult {
            // Expected negative offset guard.
        } else {
            Issue.record("Expected negative offset to be rejected")
        }
    }

    @Test
    func removeForCentralAndMaxTrackedCentralsBoundState() throws {
        var buffer = BLEInboundWriteBuffer()
        let packet = makePacket()
        let frame = try #require(packet.toBinaryData(padding: false))
        let splitIndex = max(1, frame.count / 2)

        _ = buffer.append(
            chunks: [BLEInboundWriteChunk(offset: 0, data: frame.prefix(splitIndex))],
            for: "central-a",
            capBytes: 1024,
            maxTrackedCentrals: 2
        )
        _ = buffer.append(
            chunks: [BLEInboundWriteChunk(offset: 0, data: frame.prefix(splitIndex))],
            for: "central-b",
            capBytes: 1024,
            maxTrackedCentrals: 2
        )
        // Third central evicts oldest ("central-a").
        _ = buffer.append(
            chunks: [BLEInboundWriteChunk(offset: 0, data: frame.prefix(splitIndex))],
            for: "central-c",
            capBytes: 1024,
            maxTrackedCentrals: 2
        )

        // Removing central-b explicitly drops its partial buffer.
        buffer.remove(for: "central-b")

        let aSecondHalf = buffer.append(
            chunks: [BLEInboundWriteChunk(offset: splitIndex, data: frame.suffix(from: splitIndex))],
            for: "central-a",
            capBytes: 1024,
            maxTrackedCentrals: 2
        )
        if case .waiting = aSecondHalf {
            // Expected: central-a was evicted by cap.
        } else {
            Issue.record("Expected evicted central-a partial buffer to be gone")
        }

        let bSecondHalf = buffer.append(
            chunks: [BLEInboundWriteChunk(offset: splitIndex, data: frame.suffix(from: splitIndex))],
            for: "central-b",
            capBytes: 1024,
            maxTrackedCentrals: 2
        )
        if case .waiting = bSecondHalf {
            // Expected: central-b was removed explicitly.
        } else {
            Issue.record("Expected explicitly removed central-b partial buffer to be gone")
        }
    }

    @Test
    func appendDecodesSlicedFirstChunkFollowedByOutOfOrderOrOverlappingChunk() throws {
        var buffer = BLEInboundWriteBuffer()
        let packet = makePacket(timestamp: 0x765432)
        let frame = try #require(packet.toBinaryData(padding: false))
        let splitIndex = max(2, frame.count / 2)

        let padded = Data([0xFF, 0xFE, 0xFD]) + frame
        let firstSlice = padded[3..<(3 + splitIndex)]
        #expect(firstSlice.startIndex == 3)

        let firstResult = buffer.append(
            chunks: [BLEInboundWriteChunk(offset: 0, data: firstSlice)],
            for: "central-slice",
            capBytes: 1024
        )
        if case .waiting = firstResult {
            // Expected: partial sliced frame buffered.
        } else {
            Issue.record("Expected sliced first chunk to wait for remaining bytes")
        }

        // Overlapping non-sequential write triggers replaceSubrange on combined.
        let secondResult = buffer.append(
            chunks: [BLEInboundWriteChunk(offset: splitIndex - 1, data: frame.suffix(from: splitIndex - 1))],
            for: "central-slice",
            capBytes: 1024
        )
        if case let .decoded(decoded, _) = secondResult {
            #expect(decoded.timestamp == packet.timestamp)
        } else {
            Issue.record("Expected overlapping chunk after sliced first chunk to decode")
        }
    }

    @Test
    func appendHandlesOversizedSlicedChunkWithoutCrashing() throws {
        var buffer = BLEInboundWriteBuffer()
        let packet = makePacket(timestamp: 0xABCDEF)
        let frame = try #require(packet.toBinaryData(padding: false))
        let padded = Data([0xAA, 0xBB]) + frame

        // Single oversized sliced chunk (chunk.data.startIndex > 0)
        let singleSlice = padded[2...]
        #expect(singleSlice.startIndex == 2)
        let singleOversized = buffer.append(
            chunks: [BLEInboundWriteChunk(offset: 0, data: singleSlice)],
            for: "central-oversized-1",
            capBytes: frame.count - 1
        )
        if case let .oversized(metadata) = singleOversized {
            #expect(metadata.packetType == MessageType.message.rawValue)
        } else {
            Issue.record("Expected single sliced chunk above cap to be rejected as oversized")
        }

        // Sliced first chunk followed by an oversized second chunk (combined.startIndex > 0)
        let firstSlice = padded[2..<6]
        #expect(firstSlice.startIndex == 2)
        _ = buffer.append(
            chunks: [BLEInboundWriteChunk(offset: 0, data: firstSlice)],
            for: "central-oversized-2",
            capBytes: 16
        )
        let secondOversized = buffer.append(
            chunks: [BLEInboundWriteChunk(offset: 4, data: Data(repeating: 0x01, count: 20))],
            for: "central-oversized-2",
            capBytes: 16
        )
        if case let .oversized(metadata) = secondOversized {
            #expect(metadata.packetType == MessageType.message.rawValue)
        } else {
            Issue.record("Expected oversized second chunk after sliced first chunk to be rejected")
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
