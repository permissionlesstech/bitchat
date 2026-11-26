//
// LiveVideoFrameSizeTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
import BitFoundation
@testable import bitchat

/// A live video packet must ride one BLE write: the fragment path would put
/// a sustained stream behind the fragment scheduler. 512 bytes is the write
/// limit on a 517-byte ATT MTU link.
struct LiveVideoFrameSizeTests {
    private static let bleWriteLimit = 512
    /// Noise transport overhead: 4-byte extracted nonce + 16-byte tag.
    private static let noiseOverhead = 4 + 16

    private func largestPacket() throws -> Data {
        let region = VideoBurstPacket.encodeEntries([
            LiveVideoEntry(
                track: .video,
                keyframe: false,
                unitSequence: 7,
                ptsMs: 1_000,
                fragmentIndex: 0,
                fragmentCount: 1,
                bytes: Data((0..<(VideoBurstPacket.maxEntriesRegion - LiveVideoEntry.headerSize)).map { _ in UInt8.random(in: 0...255) })
            )
        ])
        let packet = try #require(VideoBurstPacket(
            streamID: Data(repeating: 0x5A, count: VideoBurstPacket.streamIDSize),
            sequence: 9,
            kind: .data(block: 1, index: 0, entriesRegion: region)
        ))
        let encoded = packet.encode()
        #expect(encoded.count <= VideoBurstPacket.maxPacketBytes)
        return encoded
    }

    @Test func signedPublicPacketFitsOneWrite() throws {
        let packet = BitchatPacket(
            type: MessageType.videoFrame.rawValue,
            senderID: Data(repeating: 0x01, count: 8),
            recipientID: nil,
            timestamp: 1_740_000_000_000,
            payload: try largestPacket(),
            signature: Data(repeating: 0x02, count: 64),
            ttl: 7
        )
        #expect(!BLEOutboundPacketPolicy.padsBLEFrame(for: packet.type))
        let frame = try #require(packet.toBinaryData(padding: false))
        #expect(frame.count <= Self.bleWriteLimit)
    }

    @Test func noiseWrappedPacketFitsOneWriteWithFourHopRoute() throws {
        let typed = NoisePayload(type: .videoFrame, data: try largestPacket()).encode()
        let ciphertext = Data((0..<(typed.count + Self.noiseOverhead)).map { _ in UInt8.random(in: 0...255) })
        var packet = BitchatPacket(
            type: MessageType.noiseEncrypted.rawValue,
            senderID: Data(repeating: 0x01, count: 8),
            recipientID: Data(repeating: 0x03, count: 8),
            timestamp: 1_740_000_000_000,
            payload: ciphertext,
            signature: nil,
            ttl: 7,
            version: 2
        )
        packet.route = (0..<4).map { Data(repeating: UInt8($0 + 0x10), count: 8) }
        #expect(BLEOutboundPacketPolicy.padsBLEFrame(for: packet.type))
        let frame = try #require(packet.toBinaryData(padding: true))
        #expect(frame.count <= Self.bleWriteLimit)
    }
}
