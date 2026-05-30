import BitFoundation
import Foundation
import Testing
@testable import bitchat

struct BLEFragmentAssemblyBufferTests {
    @Test
    func appendCompletesOutOfOrderFragments() throws {
        var buffer = BLEFragmentAssemblyBuffer()
        let original = makePacket(payload: makePayload(count: 512))
        let fragmentPackets = try makeFragments(for: original, chunkSize: 128, fragmentID: Data(repeating: 0x01, count: 8))
        let headers = try fragmentPackets.reversed().map { try #require(BLEFragmentHeader(packet: $0)) }
        var result: BLEFragmentAssemblyBuffer.AppendResult?

        for header in headers {
            result = buffer.append(header, maxInFlightAssemblies: 8)
        }

        if case let .complete(header, reassembledData, started) = result {
            #expect(header.total == fragmentPackets.count)
            #expect(!started)
            #expect(BinaryProtocol.decode(reassembledData)?.payload == original.payload)
        } else {
            Issue.record("Expected final fragment to complete reassembly")
        }
    }

    @Test
    func appendDuplicateFragmentDoesNotCompleteEarly() throws {
        var buffer = BLEFragmentAssemblyBuffer()
        let original = makePacket(payload: makePayload(count: 384))
        let fragmentPackets = try makeFragments(for: original, chunkSize: 128, fragmentID: Data(repeating: 0x02, count: 8))
        let first = try #require(BLEFragmentHeader(packet: fragmentPackets[0]))
        let second = try #require(BLEFragmentHeader(packet: fragmentPackets[1]))

        if case let .stored(_, started) = buffer.append(first, maxInFlightAssemblies: 8) {
            #expect(started)
        } else {
            Issue.record("Expected first fragment to be stored")
        }

        if case .stored = buffer.append(first, maxInFlightAssemblies: 8) {
            // Duplicate should replace the same index, not increase completion count.
        } else {
            Issue.record("Expected duplicate fragment to remain incomplete")
        }

        if case .stored = buffer.append(second, maxInFlightAssemblies: 8) {
            // Still missing at least one fragment.
        } else {
            Issue.record("Expected assembly to remain incomplete")
        }
    }

    @Test
    func appendEvictsOldestAssemblyWhenCapIsReached() throws {
        var buffer = BLEFragmentAssemblyBuffer()
        let oldPacket = makePacket(payload: makePayload(count: 256, seed: 1), timestamp: 1)
        let newPacket = makePacket(payload: makePayload(count: 256, seed: 2), timestamp: 2)
        let oldFragments = try makeFragments(for: oldPacket, chunkSize: 128, fragmentID: Data(repeating: 0x03, count: 8))
        let newFragments = try makeFragments(for: newPacket, chunkSize: 128, fragmentID: Data(repeating: 0x04, count: 8))
        let oldFirst = try #require(BLEFragmentHeader(packet: oldFragments[0]))
        let oldSecond = try #require(BLEFragmentHeader(packet: oldFragments[1]))
        let newFirst = try #require(BLEFragmentHeader(packet: newFragments[0]))
        let newSecond = try #require(BLEFragmentHeader(packet: newFragments[1]))

        _ = buffer.append(oldFirst, maxInFlightAssemblies: 1, now: Date(timeIntervalSince1970: 1))
        _ = buffer.append(newFirst, maxInFlightAssemblies: 1, now: Date(timeIntervalSince1970: 2))

        if case let .stored(_, started) = buffer.append(oldSecond, maxInFlightAssemblies: 1) {
            #expect(started)
        } else {
            Issue.record("Expected evicted assembly to restart when old fragment arrives")
        }

        if case let .stored(_, started) = buffer.append(newSecond, maxInFlightAssemblies: 1) {
            #expect(started)
        } else {
            Issue.record("Expected new assembly to restart after old one consumed the only slot")
        }
    }

    @Test
    func appendOversizedAssemblyDropsPartialState() throws {
        var buffer = BLEFragmentAssemblyBuffer()
        let fragmentID = Data(repeating: 0x05, count: 8)
        let first = try #require(BLEFragmentHeader(packet: makeFragmentPacket(
            fragmentID: fragmentID,
            index: 0,
            total: 2,
            originalType: MessageType.message.rawValue,
            fragmentData: Data(repeating: 0x01, count: FileTransferLimits.maxPayloadBytes)
        )))
        let oversized = try #require(BLEFragmentHeader(packet: makeFragmentPacket(
            fragmentID: fragmentID,
            index: 1,
            total: 2,
            originalType: MessageType.message.rawValue,
            fragmentData: Data([0x02])
        )))

        _ = buffer.append(first, maxInFlightAssemblies: 8)
        let result = buffer.append(oversized, maxInFlightAssemblies: 8)

        if case let .oversized(_, projectedSize, limit, started) = result {
            #expect(projectedSize == FileTransferLimits.maxPayloadBytes + 1)
            #expect(limit == FileTransferLimits.maxPayloadBytes)
            #expect(!started)
        } else {
            Issue.record("Expected oversized fragment assembly to be evicted")
        }

        if case let .stored(_, started) = buffer.append(oversized, maxInFlightAssemblies: 8) {
            #expect(started)
        } else {
            Issue.record("Expected later fragment to start a clean assembly")
        }
    }

    @Test
    func removeExpiredDropsOldAssemblies() throws {
        var buffer = BLEFragmentAssemblyBuffer()
        let packet = makePacket(payload: makePayload(count: 256))
        let fragments = try makeFragments(for: packet, chunkSize: 128, fragmentID: Data(repeating: 0x06, count: 8))
        let first = try #require(BLEFragmentHeader(packet: fragments[0]))
        let second = try #require(BLEFragmentHeader(packet: fragments[1]))

        _ = buffer.append(first, maxInFlightAssemblies: 8, now: Date(timeIntervalSince1970: 1))
        #expect(buffer.removeExpired(before: Date(timeIntervalSince1970: 2)) == 1)

        if case let .stored(_, started) = buffer.append(second, maxInFlightAssemblies: 8) {
            #expect(started)
        } else {
            Issue.record("Expected expired assembly to be gone")
        }
    }

    private func makePacket(payload: Data, timestamp: UInt64 = 0x0102030405) -> BitchatPacket {
        BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77]),
            recipientID: nil,
            timestamp: timestamp,
            payload: payload,
            signature: nil,
            ttl: 3
        )
    }

    private func makePayload(count: Int, seed: UInt64 = 0x1234ABCD) -> Data {
        var state = seed
        return Data((0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: state >> 32)
        })
    }

    private func makeFragments(for packet: BitchatPacket, chunkSize: Int, fragmentID: Data) throws -> [BitchatPacket] {
        let fullData = try #require(packet.toBinaryData(padding: false))
        let chunks = stride(from: 0, to: fullData.count, by: chunkSize).map { offset in
            Data(fullData[offset..<min(offset + chunkSize, fullData.count)])
        }

        return chunks.enumerated().map { index, chunk in
            makeFragmentPacket(
                fragmentID: fragmentID,
                index: index,
                total: chunks.count,
                originalType: packet.type,
                fragmentData: chunk,
                senderID: packet.senderID,
                recipientID: packet.recipientID,
                timestamp: packet.timestamp
            )
        }
    }

    private func makeFragmentPacket(
        fragmentID: Data,
        index: Int,
        total: Int,
        originalType: UInt8,
        fragmentData: Data,
        senderID: Data = Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77]),
        recipientID: Data? = nil,
        timestamp: UInt64 = 0x0102030405
    ) -> BitchatPacket {
        var payload = Data()
        payload.append(fragmentID)
        payload.append(contentsOf: withUnsafeBytes(of: UInt16(index).bigEndian) { Data($0) })
        payload.append(contentsOf: withUnsafeBytes(of: UInt16(total).bigEndian) { Data($0) })
        payload.append(originalType)
        payload.append(fragmentData)

        return BitchatPacket(
            type: MessageType.fragment.rawValue,
            senderID: senderID,
            recipientID: recipientID,
            timestamp: timestamp,
            payload: payload,
            signature: nil,
            ttl: 3
        )
    }
}
