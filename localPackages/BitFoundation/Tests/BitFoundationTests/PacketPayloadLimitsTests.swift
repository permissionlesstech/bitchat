//
// PacketPayloadLimitsTests.swift
// BitFoundationTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Testing
@testable import BitFoundation

/// Per-type payload caps at decode: a payload may reach its type's cap and no
/// further, whether it inflates from a few bytes on the wire or arrives
/// uncompressed (as a reassembled fragment stream does).
struct PacketPayloadLimitsTests {

    private static let cappedTypes: [UInt8] = [
        MessageType.message.rawValue,
        MessageType.groupMessage.rawValue,
        MessageType.fragment.rawValue,
        MessageType.announce.rawValue,
        MessageType.requestSync.rawValue,
        MessageType.courierEnvelope.rawValue,
        MessageType.nostrCarrier.rawValue,
        MessageType.boardPost.rawValue,
        MessageType.noiseHandshake.rawValue,
        0x7F // unassigned: future types keep a v1 frame's worth
    ]

    @Test(arguments: cappedTypes)
    func compressedPayloadInflatesToItsTypeCapAndNoFurther(type: UInt8) throws {
        let cap = PacketPayloadLimits.maxPayloadBytes(forType: type)
        #expect(cap < FileTransferLimits.maxFramedFileBytes)
        // v1 frames carry a 16-bit original size, so caps below that are
        // exercised on v1 (the default for everything but media) too.
        let version: UInt8 = cap + 1 <= Int(UInt16.max) ? 1 : 2

        let atCap = try encodeCompressed(type: type, payloadSize: cap, version: version)
        #expect(BinaryProtocol.decode(atCap)?.payload.count == cap)

        let pastCap = try encodeCompressed(type: type, payloadSize: cap + 1, version: version)
        #expect(BinaryProtocol.decode(pastCap) == nil)
    }

    @Test(arguments: cappedTypes)
    func uncompressedPayloadIsCappedLikeACompressedOne(type: UInt8) throws {
        let cap = PacketPayloadLimits.maxPayloadBytes(forType: type)
        let version: UInt8 = cap + 1 <= Int(UInt16.max) ? 1 : 2

        let atCap = try encodeUncompressed(type: type, payloadSize: cap, version: version)
        #expect(BinaryProtocol.decode(atCap)?.payload.count == cap)

        let pastCap = try encodeUncompressed(type: type, payloadSize: cap + 1, version: version)
        #expect(BinaryProtocol.decode(pastCap) == nil)
    }

    @Test func onlyMediaTypesReachTheFramedFileCeiling() throws {
        let size = FileTransferLimits.maxFramedFileBytes
        for mediaType in [MessageType.fileTransfer, .noiseEncrypted] {
            let frame = try encodeCompressed(type: mediaType.rawValue, payloadSize: size, version: 2)
            #expect(BinaryProtocol.decode(frame)?.payload.count == size)
            let raw = try encodeUncompressed(type: mediaType.rawValue, payloadSize: size, version: 2)
            #expect(BinaryProtocol.decode(raw)?.payload.count == size)
        }

        // The same ~1 KB on air as a public message would have pinned ~1.1 MB.
        let message = try encodeCompressed(type: MessageType.message.rawValue, payloadSize: size, version: 2)
        #expect(BinaryProtocol.decode(message) == nil)
    }

    @Test func frameCeilingCoversTheLargestFrameThatStillDecodes() throws {
        // An uncompressed payload at its cap with everything optional at its
        // widest (recipient, a 255-hop route, signature), padded as iOS pads
        // before fragmenting. Reassembly must never cut off such a frame.
        for type in Self.cappedTypes + [MessageType.fileTransfer.rawValue] {
            let cap = PacketPayloadLimits.maxPayloadBytes(forType: type)
            let packet = BitchatPacket(
                type: type,
                senderID: Data(repeating: 0x11, count: BinaryProtocol.senderIDSize),
                recipientID: Data(repeating: 0x22, count: BinaryProtocol.recipientIDSize),
                timestamp: 1_740_000_000_000,
                payload: diversePayload(count: cap),
                signature: Data(repeating: 0x33, count: BinaryProtocol.signatureSize),
                ttl: 7,
                version: 2,
                route: (0..<255).map { Data(repeating: UInt8($0), count: BinaryProtocol.senderIDSize) }
            )
            let raw = try #require(BinaryProtocol.encode(packet, padding: true))
            #expect(raw[BinaryProtocol.Offsets.flags] & BinaryProtocol.Flags.isCompressed == 0)
            #expect(BinaryProtocol.decode(raw)?.payload.count == cap)
            #expect(raw.count <= PacketPayloadLimits.maxFrameBytes(forType: type))
        }
    }

    /// AnnounceV2 isn't emitted by the app yet, so its largest payload is
    /// checked here rather than in the app's interop tests.
    @Test func largestAnnounceV2PayloadDecodesWithHeadroom() throws {
        let payload = try #require(AnnounceV2Packet(
            epoch: 1,
            tagBlock: Data(repeating: 0x5A, count: AnnounceV2Packet.tagBlockLength),
            capabilities: PeerCapabilities(rawValue: .max),
            bridgeGeohash: "9q8yyk8yuv12"
        ).encode())
        #expect(payload.count * 2 <= PacketPayloadLimits.maxPayloadBytes(forType: MessageType.announceV2.rawValue))

        let packet = BitchatPacket(
            type: MessageType.announceV2.rawValue,
            senderID: Data(repeating: 0x11, count: BinaryProtocol.senderIDSize),
            recipientID: nil,
            timestamp: 1_740_000_000_000,
            payload: payload,
            signature: Data(repeating: 0x33, count: BinaryProtocol.signatureSize),
            ttl: 7,
            version: 1
        )
        let frame = try #require(BinaryProtocol.encode(packet, padding: true))
        #expect(BinaryProtocol.decode(frame)?.payload == payload)
    }

    /// Every byte value once, then zeros: 100% byte diversity, so the encoder
    /// leaves it uncompressed, while the zero run would still compress well
    /// inside fragments (the reassembly bypass shape).
    private func diversePayload(count: Int) -> Data {
        var payload = Data((0...255).map { UInt8($0) }.prefix(count))
        payload.append(Data(count: count - payload.count))
        return payload
    }

    private func encodeUncompressed(type: UInt8, payloadSize: Int, version: UInt8) throws -> Data {
        let packet = BitchatPacket(
            type: type,
            senderID: Data(repeating: 0x11, count: BinaryProtocol.senderIDSize),
            recipientID: nil,
            timestamp: 1_740_000_000_000,
            payload: diversePayload(count: payloadSize),
            signature: nil,
            ttl: 7,
            version: version
        )
        let frame = try #require(BinaryProtocol.encode(packet, padding: false))
        #expect(frame[BinaryProtocol.Offsets.flags] & BinaryProtocol.Flags.isCompressed == 0)
        return frame
    }

    /// Encodes a maximally compressible payload and checks that the frame
    /// really went out compressed, so decode exercises the inflate path.
    private func encodeCompressed(type: UInt8, payloadSize: Int, version: UInt8) throws -> Data {
        let packet = BitchatPacket(
            type: type,
            senderID: Data(repeating: 0x11, count: BinaryProtocol.senderIDSize),
            recipientID: nil,
            timestamp: 1_740_000_000_000,
            payload: Data(repeating: 0x41, count: payloadSize),
            signature: nil,
            ttl: 7,
            version: version
        )
        let frame = try #require(BinaryProtocol.encode(packet, padding: false))
        #expect(frame.count < payloadSize / 10)
        #expect(frame[BinaryProtocol.Offsets.flags] & BinaryProtocol.Flags.isCompressed != 0)
        return frame
    }
}
