import Testing
import Foundation
@testable import bitchat

struct NotificationStreamAssemblerTests {
    private func makePacket(timestamp: UInt64 = 0x0102030405) -> BitchatPacket {
        let sender = Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77])
        return BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: sender,
            recipientID: nil,
            timestamp: timestamp,
            payload: Data([0xDE, 0xAD, 0xBE, 0xEF]),
            signature: nil,
            ttl: 3
        )
    }

    @Test func assemblesSingleFrameAcrossChunks() throws {
        var assembler = NotificationStreamAssembler()
        let packet = makePacket()
        let frame = try #require(packet.toBinaryData(padding: false), "Failed to encode packet")

        #expect(BinaryProtocol.decode(frame) != nil)
        let payloadLen = (Int(frame[12]) << 8) | Int(frame[13])
        #expect(payloadLen == packet.payload.count)

        let splitIndex = min(20, max(1, frame.count / 2))
        let first = frame.prefix(splitIndex)
        let second = frame.suffix(from: splitIndex)
        #expect(first.count + second.count == frame.count)

        var result = assembler.append(first)
        #expect(result.frames.isEmpty)
        #expect(result.droppedPrefixes.isEmpty)
        #expect(!result.reset)

        result = assembler.append(second)
        #expect(result.frames.count == 1)
        #expect(result.droppedPrefixes.isEmpty)
        #expect(!result.reset)

        let frameData = try #require(result.frames.first, "Missing frame data")
        #expect(frameData.count == frame.count)
        
        let decoded = try #require(BinaryProtocol.decode(frameData), "Failed to decode frame")
        #expect(decoded.type == packet.type)
        #expect(decoded.payload == packet.payload)
        #expect(decoded.senderID == packet.senderID)
        #expect(decoded.timestamp == packet.timestamp)

        var directAssembler = NotificationStreamAssembler()
        let directResult = directAssembler.append(frame)
        #expect(directResult.frames.first?.count == frame.count)
    }

    @Test func assemblesMultipleFramesSequentially() throws {
        var assembler = NotificationStreamAssembler()
        let packet1 = makePacket(timestamp: 0xABC)
        let packet2 = makePacket(timestamp: 0xDEF)

        let frame1 = try #require(packet1.toBinaryData(padding: false), "Failed to encode packet")
        let frame2 = try #require(packet2.toBinaryData(padding: false), "Failed to encode packet")

        var combined = Data()
        combined.append(frame1)
        combined.append(frame2)
        let firstChunk = combined.prefix(20)
        let secondChunk = combined.suffix(from: 20)

        var result = assembler.append(firstChunk)
        #expect(result.frames.isEmpty)

        result = assembler.append(secondChunk)
        #expect(result.frames.count == 2)
        
        let decoded1 = try #require(BinaryProtocol.decode(result.frames[0]), "Failed to decode frame")
        let decoded2 = try #require(BinaryProtocol.decode(result.frames[1]), "Failed to decode frame")
        #expect(decoded1.timestamp == packet1.timestamp)
        #expect(decoded2.timestamp == packet2.timestamp)
    }

    @Test func dropsInvalidPrefixByte() throws {
        var assembler = NotificationStreamAssembler()
        let packet = makePacket(timestamp: 0xF00)
        let frame = try #require(packet.toBinaryData(padding: false), "Failed to encode packet")
        var noisyFrame = Data([0x00])
        noisyFrame.append(frame)

        let result = assembler.append(noisyFrame)
        #expect(result.droppedPrefixes == [0x00])
        #expect(result.frames.count == 1)
        #expect(result.reset == false)

        let decoded = try #require(BinaryProtocol.decode(result.frames[0]), "Failed to decode frame after drop")
        #expect(decoded.timestamp == packet.timestamp)
    }
}
