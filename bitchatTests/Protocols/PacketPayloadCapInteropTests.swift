//
// PacketPayloadCapInteropTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation
import Testing
@testable import bitchat

/// Receive-side interop for the per-type payload caps in `BinaryProtocol`:
/// the largest payload each shipping encoder produces (iOS, and Android for
/// the types it sends) still decodes, while the same type inflated from ~1 KB
/// on air to ~1 MB, or reassembled uncompressed from a fragment stream, does
/// not.
struct PacketPayloadCapInteropTests {
    private let senderID = Data(repeating: 0x5A, count: 8)
    private let signature = Data(repeating: 0xAB, count: 64)

    @Test func longestPublicMessagesStillDecode() throws {
        // Both platforms send public messages as v1 frames (iOS
        // BLEService.sendMessage, Android MeshCore.sendMessage), so these
        // composer-sized messages are as large as the type legitimately gets.
        let cjk = String(repeating: "漢字仮名交じり文", count: 2_000)
        let ascii = String(repeating: "x", count: InputValidator.Limits.maxMessageLength)
        #expect(cjk.count == 16_000)
        for content in [cjk, ascii] {
            let packet = makePacket(type: .message, payload: Data(content.utf8))
            #expect(try roundTripIsCompressed(packet))
        }

        #expect(BinaryProtocol.decode(try inflatedFrame(type: .message)) == nil)
    }

    @Test func androidAndIOSSizedFragmentsStillDecode() throws {
        // Every byte value once, then zeros: the inner packet stays
        // uncompressed (its bytes are 100% unique) while the zero-filled
        // chunks compress, so the fragment frames take the inflate path.
        var inner = Data((0...255).map { UInt8($0) })
        inner.append(Data(count: 4_000))
        let packet = makePacket(type: .fileTransfer, payload: inner, version: 2)

        // 469 B: Android's MAX_FRAGMENT_SIZE and the iOS default chunk.
        // 482 B: the largest iOS chunk, from a 524-byte BLE link limit.
        // 500 B: the chunk both platforms used before mid-2025.
        let chunkSizes = [
            TransportConfig.bleDefaultFragmentSize,
            BLEOutboundPacketPolicy.fragmentChunkSize(forLinkLimit: 524),
            500
        ]
        for chunkSize in chunkSizes {
            let request = BLEOutboundFragmentTransferRequest(
                packet: packet,
                pad: false,
                maxChunk: chunkSize,
                directedPeer: nil,
                transferId: nil
            )
            let plan = try #require(BLEOutboundFragmentPlanner.makePlan(
                for: request,
                defaultChunkSize: TransportConfig.bleDefaultFragmentSize,
                bleMaxMTU: 512
            ))
            #expect(plan.fragmentPackets.map(\.payload.count).max() == 13 + chunkSize)

            var compressedFragments = 0
            for fragment in plan.fragmentPackets {
                if try roundTripIsCompressed(fragment) {
                    compressedFragments += 1
                }
            }
            #expect(compressedFragments > 0)
        }

        // Fragments are link-scale: 2 KiB is four times the largest any
        // sender produces, so a few dozen bytes on air cannot stand for it.
        let oversized = makePacket(type: .fragment, payload: Data(repeating: 0x41, count: 2 * 1_024))
        let oversizedFrame = try #require(oversized.toBinaryData(padding: false))
        #expect(oversizedFrame[BinaryProtocol.Offsets.flags] & BinaryProtocol.Flags.isCompressed != 0)
        #expect(BinaryProtocol.decode(oversizedFrame) == nil)
        #expect(BinaryProtocol.decode(try inflatedFrame(type: .fragment)) == nil)
    }

    @Test func largestControlAndEnvelopePayloadsStillDecode() throws {
        let cases: [(type: MessageType, payload: Data, compresses: Bool)] = [
            (.announce, try maxAnnounce(), true),
            (.boardPost, maxBoardPost(), true),
            (.nostrCarrier, try maxNostrCarrier(), true),
            (.requestSync, maxRequestSync(), false),
            (.courierEnvelope, try maxCourierEnvelope(), false),
            (.groupMessage, try maxGroupMessage(), false),
            (.prekeyBundle, try maxPrekeyBundle(), false),
            (.voiceFrame, try maxVoiceFrame(), false)
            // announceV2's largest payload is checked in BitFoundation's
            // PacketPayloadLimitsTests: nothing in the app emits it yet, and a
            // reference here would make it look used to the dead-code scan.
        ]
        for testCase in cases {
            let packet = makePacket(type: testCase.type, payload: testCase.payload)
            let compressed = try roundTripIsCompressed(packet)
            #expect(compressed || !testCase.compresses, "\(testCase.type.description) should take the inflate path")

            #expect(
                BinaryProtocol.decode(try inflatedFrame(type: testCase.type)) == nil,
                "\(testCase.type.description) inflated to ~1 MB must be rejected"
            )
        }
    }

    @Test func largeFileTransfersStillDecode() throws {
        // A 1 MiB image whose bytes compress well: the largest legitimate
        // inflation a broadcast file can ask for.
        var content = Data([0xFF, 0xD8, 0xFF, 0xE0])
        content.append(Data(count: FileTransferLimits.maxPayloadBytes - content.count))
        let file = BitchatFilePacket(fileName: "photo.jpg", fileSize: nil, mimeType: "image/jpeg", content: content)
        let payload = try #require(file.encode())
        let packet = makePacket(type: .fileTransfer, payload: payload, version: 2)
        #expect(try roundTripIsCompressed(packet))

        // The same bytes under a non-media type are what the caps stop.
        let asGroupMessage = makePacket(type: .groupMessage, payload: payload, version: 2)
        #expect(BinaryProtocol.decode(try #require(asGroupMessage.toBinaryData())) == nil)
    }

    // MARK: - Legitimate maxima, built with the real encoders

    private func maxAnnounce() throws -> Data {
        try #require(AnnouncementPacket(
            nickname: String(repeating: "n", count: 255),
            noisePublicKey: Data(repeating: 0x21, count: 32),
            signingPublicKey: Data(repeating: 0x22, count: 32),
            directNeighbors: (0..<10).map { Data(repeating: UInt8($0), count: 8) },
            capabilities: PeerCapabilities(rawValue: .max),
            bridgeGeohash: "9q8yyk8yuv12"
        ).encode())
    }

    private func maxBoardPost() -> Data {
        BoardWire.post(BoardPostPacket(
            postID: Data(repeating: 0x31, count: BoardWireConstants.postIDLength),
            geohash: "9q8yyk8yuv12",
            content: String(repeating: "x", count: BoardWireConstants.contentMaxBytes),
            authorSigningKey: Data(repeating: 0x32, count: BoardWireConstants.signingKeyLength),
            authorNickname: String(repeating: "n", count: BoardWireConstants.nicknameMaxBytes),
            createdAt: 1_740_000_000_000,
            expiresAt: 1_740_000_000_000 + BoardWireConstants.maxLifetimeMs,
            flags: BoardPostPacket.urgentFlag,
            signature: signature
        )).encode()
    }

    private func maxNostrCarrier() throws -> Data {
        let prefix = Data(#"{"content":""#.utf8)
        let suffix = Data(#""}"#.utf8)
        var json = prefix
        json.append(Data(repeating: 0x61, count: NostrCarrierPacket.maxEventJSONBytes - prefix.count - suffix.count))
        json.append(suffix)
        let carrier = try #require(NostrCarrierPacket(direction: .fromGateway, geohash: "9q8yyk8yuv12", eventJSON: json))
        return try #require(carrier.encode())
    }

    private func maxRequestSync() -> Data {
        let fragmentIDs = (0..<RequestSyncPacket.maxFragmentIdFilterCount).map {
            Data(repeating: UInt8($0), count: 8)
        }
        return RequestSyncPacket(
            p: 7,
            m: 1 << 20,
            data: Data((0..<1_024).map { UInt8(truncatingIfNeeded: $0 &* 37) }),
            types: [.publicMessages, .fragment, .fileTransfer, .groupMessage, .prekeyBundle, .board],
            sinceTimestamp: 1_740_000_000_000,
            fragmentIdFilter: RequestSyncPacket.encodeFragmentIdFilter(fragmentIDs)
        ).encode()
    }

    private func maxCourierEnvelope() throws -> Data {
        try #require(CourierEnvelope(
            recipientTag: Data(repeating: 0x41, count: CourierEnvelope.tagLength),
            expiry: 1_740_000_000_000,
            ciphertext: randomBytes(CourierEnvelope.maxCiphertextBytes),
            copies: CourierEnvelope.maxCopies,
            prekeyID: 7
        ).encode())
    }

    private func maxGroupMessage() throws -> Data {
        try GroupCrypto.sealMessage(
            content: String(repeating: "g", count: InputValidator.Limits.maxMessageLength),
            messageID: UUID().uuidString,
            senderNickname: String(repeating: "n", count: 50),
            senderSigningKey: Data(repeating: 0x51, count: 32),
            timestampMs: 1_740_000_000_000,
            groupID: Data(repeating: 0x52, count: BitchatGroup.groupIDLength),
            epoch: 1,
            key: Data(repeating: 0x53, count: BitchatGroup.keyLength),
            sign: { [signature] _ in signature }
        )
    }

    private func maxPrekeyBundle() throws -> Data {
        try #require(PrekeyBundle(
            noiseStaticPublicKey: Data(repeating: 0x61, count: PrekeyBundle.keyLength),
            prekeys: (0..<PrekeyBundle.maxPrekeys).map {
                PrekeyBundle.Prekey(id: UInt32($0), publicKey: randomBytes(PrekeyBundle.keyLength))
            },
            generatedAt: 1_740_000_000_000,
            signature: signature
        ).encode())
    }

    private func maxVoiceFrame() throws -> Data {
        // 11-byte header + 2-byte length + frame = the 210-byte burst budget.
        let frame = randomBytes(TransportConfig.pttMaxBurstContentBytes - 13)
        let burst = try #require(VoiceBurstPacket(burstID: Data(repeating: 0x71, count: 8), seq: 1, kind: .frames([frame])))
        return burst.encode()
    }

    // MARK: - Helpers

    private func makePacket(type: MessageType, payload: Data, version: UInt8 = 1) -> BitchatPacket {
        BitchatPacket(
            type: type.rawValue,
            senderID: senderID,
            recipientID: nil,
            timestamp: 1_740_000_000_000,
            payload: payload,
            signature: signature,
            ttl: TransportConfig.messageTTLDefault,
            version: version
        )
    }

    /// Encodes as on the wire (padded), decodes, and checks the payload
    /// survives; returns whether the frame went out compressed.
    private func roundTripIsCompressed(_ packet: BitchatPacket) throws -> Bool {
        let frame = try #require(packet.toBinaryData())
        let decoded = try #require(BinaryProtocol.decode(frame), "type \(packet.type) failed to decode")
        #expect(decoded.payload == packet.payload)
        return frame[BinaryProtocol.Offsets.flags] & BinaryProtocol.Flags.isCompressed != 0
    }

    /// ~1 MB of one byte in a v2 frame: about 1 KB on air, and accepted by
    /// the old frame-wide cap for every type.
    private func inflatedFrame(type: MessageType) throws -> Data {
        let packet = makePacket(type: type, payload: Data(repeating: 0x41, count: 1_024 * 1_024), version: 2)
        let frame = try #require(packet.toBinaryData(padding: false))
        #expect(frame.count < 4_096)
        return frame
    }

    private func randomBytes(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }
}
