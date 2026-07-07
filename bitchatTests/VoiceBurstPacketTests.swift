//
// VoiceBurstPacketTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
@testable import bitchat

struct VoiceBurstPacketTests {
    private let burstID = Data((0..<8).map { UInt8($0 + 1) })

    // MARK: - Round trips

    @Test func startRoundTrip() throws {
        let packet = try #require(VoiceBurstPacket(burstID: burstID, seq: 0, kind: .start(codec: .aacLC16kMono)))
        let decoded = try #require(VoiceBurstPacket.decode(packet.encode()))
        #expect(decoded == packet)
        #expect(decoded.seq == 0)
    }

    @Test func framesRoundTrip() throws {
        let frames = [Data([0xDE, 0xAD]), Data(repeating: 0x42, count: 130)]
        let packet = try #require(VoiceBurstPacket(burstID: burstID, seq: 7, kind: .frames(frames)))
        let decoded = try #require(VoiceBurstPacket.decode(packet.encode()))
        #expect(decoded == packet)
        guard case .frames(let decodedFrames) = decoded.kind else {
            Issue.record("expected frames")
            return
        }
        #expect(decodedFrames == frames)
    }

    @Test func endRoundTrip() throws {
        let packet = try #require(VoiceBurstPacket(burstID: burstID, seq: 42, kind: .end(totalDataPackets: 41, durationMs: 2_688)))
        let decoded = try #require(VoiceBurstPacket.decode(packet.encode()))
        #expect(decoded == packet)
    }

    @Test func canceledRoundTrip() throws {
        let packet = try #require(VoiceBurstPacket(burstID: burstID, seq: 3, kind: .canceled))
        let decoded = try #require(VoiceBurstPacket.decode(packet.encode()))
        #expect(decoded == packet)
    }

    @Test func decodeSurvivesReslicedData() throws {
        // Simulates the payload arriving as a slice with a non-zero start index.
        let packet = try #require(VoiceBurstPacket(burstID: burstID, seq: 1, kind: .frames([Data([1, 2, 3])])))
        var padded = Data([0xAA, 0xBB])
        padded.append(packet.encode())
        let slice = padded.dropFirst(2)
        #expect(VoiceBurstPacket.decode(slice) == packet)
    }

    // MARK: - Validation

    @Test func rejectsMalformedInput() {
        #expect(VoiceBurstPacket.decode(Data()) == nil)
        #expect(VoiceBurstPacket.decode(Data(repeating: 0, count: 10)) == nil)
        // Unknown flags byte.
        var unknownFlags = burstID
        unknownFlags.append(contentsOf: [0, 1, 0xFF])
        #expect(VoiceBurstPacket.decode(unknownFlags) == nil)
        // Data packet with zero frames.
        var empty = burstID
        empty.append(contentsOf: [0, 1, 0])
        #expect(VoiceBurstPacket.decode(empty) == nil)
        // Truncated frame length.
        var truncated = burstID
        truncated.append(contentsOf: [0, 1, 0, 0x00, 0x10, 0xAB])
        #expect(VoiceBurstPacket.decode(truncated) == nil)
        // Unknown codec in START.
        var badCodec = burstID
        badCodec.append(contentsOf: [0, 0, 0x01, 0x7F])
        #expect(VoiceBurstPacket.decode(badCodec) == nil)
    }

    @Test func rejectsInvalidConstruction() {
        #expect(VoiceBurstPacket(burstID: Data([1, 2]), seq: 0, kind: .canceled) == nil)
        #expect(VoiceBurstPacket(burstID: burstID, seq: 1, kind: .frames([])) == nil)
        #expect(VoiceBurstPacket(burstID: burstID, seq: 1, kind: .frames([Data()])) == nil)
        let tooMany = Array(repeating: Data([0x01]), count: VoiceBurstPacket.maxFramesPerPacket + 1)
        #expect(VoiceBurstPacket(burstID: burstID, seq: 1, kind: .frames(tooMany)) == nil)
    }

    @Test func makeBurstIDProducesUniqueEightBytes() {
        let a = VoiceBurstPacket.makeBurstID()
        let b = VoiceBurstPacket.makeBurstID()
        #expect(a.count == VoiceBurstPacket.burstIDSize)
        #expect(a != b)
    }

    // MARK: - Packetizer

    @Test func packetizerRespectsBudgetAndCounts() throws {
        var packetizer = VoiceBurstPacketizer(burstID: burstID, budget: 210)
        let frame = Data(repeating: 0x55, count: 130) // realistic 16 kbps AAC frame

        // First frame buffers, second forces a flush of the first.
        #expect(packetizer.add(frame).isEmpty)
        let flushed = packetizer.add(frame)
        #expect(flushed.count == 1)
        let first = try #require(VoiceBurstPacket.decode(flushed[0]))
        #expect(first.seq == 1)
        guard case .frames(let frames) = first.kind else {
            Issue.record("expected frames")
            return
        }
        #expect(frames == [frame])

        // Remaining frame flushes on demand; counters advance.
        let final = packetizer.flush()
        #expect(final.count == 1)
        #expect(try #require(VoiceBurstPacket.decode(final[0])).seq == 2)
        #expect(packetizer.dataPacketCount == 2)
        #expect(packetizer.nextSeq == 3)
        #expect(packetizer.flush().isEmpty)
    }

    @Test func packetizerBatchesSmallFrames() throws {
        var packetizer = VoiceBurstPacketizer(burstID: burstID, budget: 210)
        let small = Data(repeating: 0x11, count: 40)
        for _ in 0..<4 {
            #expect(packetizer.add(small).isEmpty) // 4 * 42 + 11 = 179 <= 210
        }
        let packets = packetizer.flush()
        #expect(packets.count == 1)
        guard case .frames(let frames) = try #require(VoiceBurstPacket.decode(packets[0])).kind else {
            Issue.record("expected frames")
            return
        }
        #expect(frames.count == 4)
    }

    @Test func packetizerDropsOversizedFrame() {
        var packetizer = VoiceBurstPacketizer(burstID: burstID, budget: 210)
        #expect(packetizer.add(Data(repeating: 0, count: 500)).isEmpty)
        #expect(packetizer.flush().isEmpty)
        #expect(packetizer.dataPacketCount == 0)
    }

    @Test func encodedPacketStaysWithinNoisePaddingBucket() throws {
        // The whole point of the budget: burst content + 1 type byte +
        // 16-byte Noise tag must stay within MessagePadding's 256 bucket.
        var packetizer = VoiceBurstPacketizer(burstID: burstID)
        var largest = 0
        for _ in 0..<3 {
            for packet in packetizer.add(Data(repeating: 0xAB, count: 160)) {
                largest = max(largest, packet.count)
            }
        }
        for packet in packetizer.flush() {
            largest = max(largest, packet.count)
        }
        #expect(largest > 0)
        #expect(largest + 1 + 16 <= 256)
    }
}
