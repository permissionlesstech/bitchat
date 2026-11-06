//
// VideoBurstPacketTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
@testable import bitchat

struct VideoBurstPacketTests {
    private let streamID = Data((0..<8).map { UInt8($0 + 1) })
    private let config = LiveVideoConfig(
        videoCodec: .h264AnnexB,
        width: 144,
        height: 192,
        fps: 8,
        bitrateKbps: 24,
        audioCodec: .aacLC16kMono
    )

    private func hex(_ value: String) -> Data {
        let digits = Array(value.replacingOccurrences(of: " ", with: ""))
        return Data(stride(from: 0, to: digits.count, by: 2).map { UInt8(String(digits[$0...$0 + 1]), radix: 16)! })
    }

    private func packet(_ sequence: Int, _ kind: VideoBurstPacket.Kind) throws -> VideoBurstPacket {
        try #require(VideoBurstPacket(streamID: streamID, sequence: sequence, kind: kind))
    }

    private func mutated(_ data: Data, _ changes: [Int: UInt8]) -> Data {
        var bytes = [UInt8](data)
        for (index, value) in changes { bytes[index] = value }
        return Data(bytes)
    }

    // MARK: - Round trips

    @Test func everyKindRoundTrips() throws {
        let entries = [
            LiveVideoEntry(track: .video, keyframe: true, unitSequence: 7, ptsMs: 1_000,
                           fragmentIndex: 0, fragmentCount: 2, bytes: Data(repeating: 1, count: 40)),
            LiveVideoEntry(track: .audio, keyframe: false, unitSequence: 9, ptsMs: 1_064,
                           fragmentIndex: 0, fragmentCount: 1, bytes: Data([5, 6, 7]))
        ]
        let region = VideoBurstPacket.encodeEntries(entries)
        let kinds: [VideoBurstPacket.Kind] = [
            .start(config),
            .data(block: 3, index: 1, entriesRegion: region),
            .parity(block: 3, parityIndex: 0, sourceCount: 4, parityCount: 2,
                    symbol: Data((0..<60).map { UInt8($0) })),
            .end(durationMs: 12_345, videoUnits: 99, audioUnits: 190, packets: 777),
            .canceled
        ]
        for (sequence, kind) in kinds.enumerated() {
            let original = try packet(sequence, kind)
            let decoded = try #require(VideoBurstPacket.decode(original.encode()))
            #expect(decoded.streamID == streamID)
            #expect(decoded.sequence == sequence)
            #expect(decoded.kind == kind)
            #expect(decoded == original)
        }
        #expect(LiveVideoEntry.decodeAll(region) == entries)
    }

    @Test func decodesFromNonZeroIndexedSlices() throws {
        let encoded = try packet(9, .end(durationMs: 1, videoUnits: 2, audioUnits: 3, packets: 4)).encode()
        let padded = Data([0xFF, 0xFF]) + encoded
        let slice = padded[2...]
        #expect(slice.startIndex == 2)
        let decoded = try #require(VideoBurstPacket.decode(slice))
        #expect(decoded.kind == .end(durationMs: 1, videoUnits: 2, audioUnits: 3, packets: 4))
    }

    // MARK: - Golden vectors (docs/LIVE_VIDEO_V1.md)

    @Test func goldenVectorsMatchSpecification() throws {
        let entry = LiveVideoEntry(track: .video, keyframe: true, unitSequence: 1, ptsMs: 64,
                                   fragmentIndex: 0, fragmentCount: 1, bytes: hex("DEADBE"))
        let vectors: [(String, VideoBurstPacket)] = [
            ("01 02 03 04 05 06 07 08 00 00 01 01 01 00 90 00 C0 08 00 18 01",
             try packet(0, .start(config))),
            ("01 02 03 04 05 06 07 08 00 05 00 00 02 00 04 00 01 00 00 00 40 00 01 00 03 DE AD BE",
             try packet(5, .data(block: 2, index: 0, entriesRegion: VideoBurstPacket.encodeEntries([entry])))),
            ("01 02 03 04 05 06 07 08 00 06 03 00 02 00 01 01 00 03 AA BB CC",
             try packet(6, .parity(block: 2, parityIndex: 0, sourceCount: 1, parityCount: 1, symbol: hex("AABBCC")))),
            ("01 02 03 04 05 06 07 08 00 2A 02 00 00 0A 80 00 10 00 29 00 2A",
             try packet(42, .end(durationMs: 2_688, videoUnits: 16, audioUnits: 41, packets: 42))),
            ("01 02 03 04 05 06 07 08 00 03 04",
             try packet(3, .canceled))
        ]
        for (wire, expected) in vectors {
            #expect(expected.encode() == hex(wire))
            #expect(VideoBurstPacket.decode(hex(wire)) == expected)
        }
        guard case .data(_, _, let region) = try packet(5, .data(block: 2, index: 0,
                                                              entriesRegion: VideoBurstPacket.encodeEntries([entry]))).kind
        else {
            Issue.record("expected data")
            return
        }
        #expect(LiveVideoEntry.decodeAll(region) == [entry])
    }

    // MARK: - Validation

    @Test func malformedPacketsAreRejected() throws {
        let start = try packet(0, .start(config)).encode()
        #expect(VideoBurstPacket.decode(start.prefix(start.count - 1)) == nil)
        #expect(VideoBurstPacket.decode(start + Data([0])) == nil)
        #expect(VideoBurstPacket.decode(mutated(start, [11: 0x09])) == nil) // version
        #expect(VideoBurstPacket.decode(mutated(start, [12: 0x02])) == nil) // video codec
        #expect(VideoBurstPacket.decode(mutated(start, [20: 0x02])) == nil) // audio codec
        #expect(VideoBurstPacket.decode(mutated(start, [10: 0x07])) == nil) // kind
        #expect(VideoBurstPacket.decode(Data(count: VideoBurstPacket.maxPacketBytes + 1)) == nil)
        #expect(VideoBurstPacket.decode(Data(count: VideoBurstPacket.headerSize - 1)) == nil)

        let entry = LiveVideoEntry(track: .audio, keyframe: false, unitSequence: 1, ptsMs: 0,
                                   fragmentIndex: 0, fragmentCount: 1, bytes: Data([1, 2]))
        let data = try packet(1, .data(block: 0, index: 0, entriesRegion: VideoBurstPacket.encodeEntries([entry]))).encode()
        #expect(VideoBurstPacket.decode(data) != nil)
        // Truncated entry, unknown flag bits, keyframe audio, and zero-length entries.
        #expect(VideoBurstPacket.decode(data.prefix(data.count - 1)) == nil)
        #expect(VideoBurstPacket.decode(mutated(data, [14: 0x08])) == nil)
        #expect(VideoBurstPacket.decode(mutated(data, [14: 0x05])) == nil)
        #expect(VideoBurstPacket.decode(mutated(data, [23: 0, 24: 0])) == nil)
        // Fragment index beyond its count; zero fragment count.
        #expect(VideoBurstPacket.decode(mutated(data, [21: 1])) == nil)
        #expect(VideoBurstPacket.decode(mutated(data, [22: 0])) == nil)
        // Shard index must be below 32; empty entries region.
        #expect(VideoBurstPacket.decode(mutated(data, [13: 32])) == nil)
        #expect(VideoBurstPacket.decode(data.prefix(VideoBurstPacket.dataHeaderSize)) == nil)

        let parity = try packet(2, .parity(block: 0, parityIndex: 1, sourceCount: 4, parityCount: 2,
                                           symbol: Data(repeating: 3, count: 10))).encode()
        #expect(VideoBurstPacket.decode(parity.prefix(parity.count - 1)) == nil) // symbolLen mismatch
        #expect(VideoBurstPacket.decode(mutated(parity, [14: 0])) == nil)       // k = 0
        #expect(VideoBurstPacket.decode(mutated(parity, [14: 33])) == nil)      // k > 32
        #expect(VideoBurstPacket.decode(mutated(parity, [15: 17])) == nil)      // r > 16
        #expect(VideoBurstPacket.decode(mutated(parity, [13: 2])) == nil)       // parityIndex >= r

        let end = try packet(3, .end(durationMs: 1, videoUnits: 1, audioUnits: 1, packets: 1)).encode()
        #expect(VideoBurstPacket.decode(end + Data([0])) == nil)
        let canceled = try packet(4, .canceled).encode()
        #expect(VideoBurstPacket.decode(canceled + Data([0])) == nil)
    }

    @Test func invalidFieldsAreRejectedAtConstruction() {
        func start(width: Int = 144, height: Int = 192, fps: Int = 8, kbps: Int = 24) -> VideoBurstPacket? {
            VideoBurstPacket(streamID: streamID, sequence: 0, kind: .start(LiveVideoConfig(
                videoCodec: .h264AnnexB, width: width, height: height, fps: fps,
                bitrateKbps: kbps, audioCodec: .none)))
        }
        #expect(start() != nil)
        #expect(start(width: 145) == nil)
        #expect(start(width: 14) == nil)
        #expect(start(height: 1_922) == nil)
        #expect(start(width: 1_920, height: 1_920) != nil)
        #expect(start(fps: 0) == nil)
        #expect(start(fps: 61) == nil)
        #expect(start(kbps: 0) == nil)
        #expect(start(kbps: 0x10000) == nil)
        #expect(VideoBurstPacket(streamID: Data(count: 7), sequence: 0, kind: .canceled) == nil)
        #expect(VideoBurstPacket(streamID: streamID, sequence: 0x10000, kind: .canceled) == nil)
        #expect(VideoBurstPacket(streamID: streamID, sequence: -1, kind: .canceled) == nil)
        #expect(VideoBurstPacket(streamID: streamID, sequence: 0,
                                 kind: .end(durationMs: 0x1_0000_0000, videoUnits: 0, audioUnits: 0, packets: 0)) == nil)
        #expect(VideoBurstPacket(streamID: streamID, sequence: 0,
                                 kind: .data(block: 0, index: 0, entriesRegion: Data([1, 2, 3]))) == nil)
    }

    @Test func maximalPacketsStayWithinBudget() throws {
        #expect(VideoBurstPacket.maxEntriesRegion == 332)
        let fullEntry = LiveVideoEntry(
            track: .video, keyframe: false, unitSequence: 1, ptsMs: 0, fragmentIndex: 0, fragmentCount: 1,
            bytes: Data(repeating: 7, count: VideoBurstPacket.maxEntriesRegion - LiveVideoEntry.headerSize)
        )
        let data = try packet(1, .data(block: 0, index: 0,
                                       entriesRegion: VideoBurstPacket.encodeEntries([fullEntry]))).encode()
        let parity = try packet(2, .parity(block: 0, parityIndex: 0, sourceCount: 1, parityCount: 1,
                                           symbol: Data(count: VideoBurstPacket.maxEntriesRegion + 2))).encode()
        #expect(data.count <= VideoBurstPacket.maxPacketBytes)
        #expect(parity.count == VideoBurstPacket.maxPacketBytes)
        #expect(VideoBurstPacket.decode(parity) != nil)
        #expect(VideoBurstPacket(streamID: streamID, sequence: 2, kind: .parity(
            block: 0, parityIndex: 0, sourceCount: 1, parityCount: 1,
            symbol: Data(count: VideoBurstPacket.maxEntriesRegion + 3))) == nil)
    }

    // MARK: - Stream IDs

    @Test func streamIDsAreRandomAndHexEncoded() {
        let first = VideoBurstPacket.makeStreamID()
        let second = VideoBurstPacket.makeStreamID()
        #expect(first.count == VideoBurstPacket.streamIDSize)
        #expect(first != second)
        #expect(VideoBurstPacket.streamIDHex(Data([0x01, 0xAB, 0x00, 0xFF, 0x10, 0x20, 0x30, 0x40])) == "01ab00ff10203040")
    }
}
