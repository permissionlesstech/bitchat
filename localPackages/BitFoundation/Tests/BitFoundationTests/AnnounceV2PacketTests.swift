import Foundation
import Testing
@testable import BitFoundation

/// Wire-format tests for the identity-free announce. These are the second half
/// of the cross-platform contract: Android must encode and decode byte-identical
/// packets, so anything asserted here is a promise, not an implementation detail.
struct AnnounceV2PacketTests {
    private var block: Data {
        Data(repeating: 0xAB, count: AnnounceV2Packet.tagBlockLength)
    }

    @Test func typeValueIsStable() {
        // Changing this breaks every deployed decoder.
        //
        // Deliberately NOT 0x05, which merely looks free: it has been recycled
        // twice already (announce, then bulkTransferResponse, then fragmentStart
        // until #446), so an old peer could still map it to a fragment header
        // and misparse presence as a partial message. Values above
        // voiceFrame = 0x29 have only ever been allocated forward; 0x2A/0x2B
        // belong to the courier spray-ack work.
        #expect(MessageType.announceV2.rawValue == 0x2C)
        #expect(MessageType(rawValue: 0x2C) == .announceV2)
        #expect(MessageType.announceV2.description == "announceV2")
    }

    @Test func tagBlockIsSixtyFourBytes() {
        #expect(AnnounceV2Packet.tagBlockLength == 64)
    }

    @Test func roundTripsWithEveryField() throws {
        let packet = AnnounceV2Packet(
            epoch: 495_555,
            tagBlock: block,
            capabilities: [.bridge, .prekeys],
            bridgeGeohash: "u4pruy"
        )
        let encoded = try #require(packet.encode())
        let decoded = try #require(AnnounceV2Packet.decode(from: encoded))
        #expect(decoded == packet)
    }

    @Test func roundTripsWithOnlyRequiredFields() throws {
        let packet = AnnounceV2Packet(epoch: 0, tagBlock: block)
        let encoded = try #require(packet.encode())
        let decoded = try #require(AnnounceV2Packet.decode(from: encoded))
        #expect(decoded == packet)
        #expect(decoded.capabilities == nil)
        #expect(decoded.bridgeGeohash == nil)
    }

    @Test func epochIsBigEndianOnTheWire() throws {
        let encoded = try #require(AnnounceV2Packet(epoch: 0x0102_0304, tagBlock: block).encode())
        // TLV 0x01, length 4, then the epoch most-significant byte first.
        #expect(Array(encoded.prefix(6)) == [0x01, 0x04, 0x01, 0x02, 0x03, 0x04])
    }

    /// The whole point of the format: none of the identifying v1 fields appear.
    @Test func encodingCarriesNoIdentity() throws {
        let noiseKey = Data(repeating: 0x11, count: 32)
        let signingKey = Data(repeating: 0x22, count: 32)
        let nickname = Data("alice".utf8)

        let encoded = try #require(
            AnnounceV2Packet(
                epoch: 100,
                tagBlock: block,
                capabilities: [.bridge],
                bridgeGeohash: "u4pruy"
            ).encode()
        )

        #expect(!encoded.contains(noiseKey))
        #expect(!encoded.contains(signingKey))
        #expect(encoded.range(of: nickname) == nil)
    }

    @Test func encodingIsSmallerThanAV1Announce() throws {
        let v2 = try #require(
            AnnounceV2Packet(epoch: 100, tagBlock: block, capabilities: [.bridge]).encode()
        )
        // v1 with a 10-byte nickname and a full neighbour list, before its
        // 64-byte signature: nickname 12 + noise 34 + signing 34 + neighbours 82
        // + capabilities 3.
        let v1PayloadEstimate = 12 + 34 + 34 + 82 + 3
        #expect(v2.count < v1PayloadEstimate)
    }

    // MARK: - Rejection

    @Test func encodeRejectsAWrongWidthTagBlock() {
        // A short block would disclose the favourite count, so it must never go
        // on the wire.
        #expect(AnnounceV2Packet(epoch: 1, tagBlock: Data(repeating: 0, count: 63)).encode() == nil)
        #expect(AnnounceV2Packet(epoch: 1, tagBlock: Data(repeating: 0, count: 65)).encode() == nil)
        #expect(AnnounceV2Packet(epoch: 1, tagBlock: Data()).encode() == nil)
    }

    @Test func encodeRejectsAnOversizedGeohash() {
        #expect(AnnounceV2Packet(
            epoch: 1,
            tagBlock: block,
            bridgeGeohash: String(repeating: "u", count: 13)
        ).encode() == nil)
    }

    @Test func decodeRequiresEpochAndTagBlock() throws {
        // Capabilities alone is not a valid announce.
        var onlyCapabilities = Data([0x03, 0x01])
        onlyCapabilities.append(PeerCapabilities([.bridge]).encoded())
        #expect(AnnounceV2Packet.decode(from: onlyCapabilities) == nil)

        // Epoch without a tag block is not either.
        let onlyEpoch = Data([0x01, 0x04, 0x00, 0x00, 0x00, 0x64])
        #expect(AnnounceV2Packet.decode(from: onlyEpoch) == nil)
    }

    @Test func decodeRejectsTruncatedAndMalformedInput() {
        #expect(AnnounceV2Packet.decode(from: Data()) == nil)
        // Declares 4 bytes, supplies 2.
        #expect(AnnounceV2Packet.decode(from: Data([0x01, 0x04, 0x00, 0x00])) == nil)
        // Dangling type byte with no length.
        #expect(AnnounceV2Packet.decode(from: Data([0x01])) == nil)
        // Wrong epoch width.
        #expect(AnnounceV2Packet.decode(from: Data([0x01, 0x02, 0x00, 0x64])) == nil)
    }

    @Test func decodeRejectsAWrongWidthTagBlock() {
        var data = Data([0x01, 0x04, 0x00, 0x00, 0x00, 0x64])
        data.append(0x02)
        data.append(UInt8(63))
        data.append(Data(repeating: 0xAB, count: 63))
        #expect(AnnounceV2Packet.decode(from: data) == nil)
    }

    @Test func decodeRejectsNonCanonicalCapabilities() throws {
        // Same capability set, non-minimal encoding: it must not be accepted, or
        // one set could travel as several distinct byte strings.
        var data = Data([0x01, 0x04, 0x00, 0x00, 0x00, 0x64])
        data.append(0x02)
        data.append(UInt8(AnnounceV2Packet.tagBlockLength))
        data.append(block)
        data.append(0x03)
        data.append(UInt8(3))
        data.append(Data([0x80, 0x00, 0x00]))  // trailing zero bytes are non-minimal
        #expect(AnnounceV2Packet.decode(from: data) == nil)
    }

    @Test func unknownTLVsAreSkippedForForwardCompatibility() throws {
        var data = try #require(AnnounceV2Packet(epoch: 100, tagBlock: block).encode())
        data.append(0x7F)              // a type this build has never heard of
        data.append(UInt8(3))
        data.append(Data([0x01, 0x02, 0x03]))

        let decoded = try #require(AnnounceV2Packet.decode(from: data))
        #expect(decoded.epoch == 100)
        #expect(decoded.tagBlock == block)
    }
}
