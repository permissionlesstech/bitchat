import Foundation
import Testing

@testable import bitchat

struct PacketsTests {
    @Test
    func announcementPacketRoundTripsNeighborsAndSkipsUnknownTLVs() throws {
        let neighbors = (0..<12).map { index in
            Data(repeating: UInt8(index), count: 8)
        }
        let packet = AnnouncementPacket(
            nickname: "alice",
            noisePublicKey: Data(repeating: 0x11, count: 32),
            signingPublicKey: Data(repeating: 0x22, count: 32),
            directNeighbors: neighbors
        )

        var encoded = try #require(packet.encode())
        encoded.append(makeTLV(type: 0xFF, value: Data([0xAB])))

        let decoded = try #require(AnnouncementPacket.decode(from: encoded))
        #expect(decoded.nickname == "alice")
        #expect(decoded.noisePublicKey == Data(repeating: 0x11, count: 32))
        #expect(decoded.signingPublicKey == Data(repeating: 0x22, count: 32))
        #expect(decoded.directNeighbors?.count == 10)
        #expect(decoded.directNeighbors?.first == neighbors.first)
        #expect(decoded.directNeighbors?.last == neighbors[9])
    }

    @Test
    func announcementPacketEncodeRejectsOversizedFieldsAndInvalidNeighborGroups() {
        let oversizedNickname = String(repeating: "a", count: 256)
        let validKey = Data(repeating: 0x44, count: 32)

        #expect(
            AnnouncementPacket(
                nickname: oversizedNickname,
                noisePublicKey: validKey,
                signingPublicKey: validKey,
                directNeighbors: nil
            ).encode() == nil
        )

        #expect(
            AnnouncementPacket(
                nickname: "alice",
                noisePublicKey: Data(repeating: 0x55, count: 256),
                signingPublicKey: validKey,
                directNeighbors: nil
            ).encode() == nil
        )

        #expect(
            AnnouncementPacket(
                nickname: "alice",
                noisePublicKey: validKey,
                signingPublicKey: Data(repeating: 0x66, count: 256),
                directNeighbors: nil
            ).encode() == nil
        )

        let invalidNeighborPacket = AnnouncementPacket(
            nickname: "alice",
            noisePublicKey: validKey,
            signingPublicKey: validKey,
            directNeighbors: [Data([0x01, 0x02, 0x03])]
        )
        let encodedWithoutNeighbors = AnnouncementPacket(
            nickname: "alice",
            noisePublicKey: validKey,
            signingPublicKey: validKey,
            directNeighbors: nil
        ).encode()
        #expect(invalidNeighborPacket.encode() == encodedWithoutNeighbors)
    }

    @Test
    func announcementPacketDecodeRejectsMissingFieldsAndTruncation() throws {
        let missingSigningKey = makeTLV(type: 0x01, value: Data("alice".utf8))
            + makeTLV(type: 0x02, value: Data(repeating: 0x11, count: 32))
        #expect(AnnouncementPacket.decode(from: missingSigningKey) == nil)

        let validPacket = try #require(
            AnnouncementPacket(
                nickname: "alice",
                noisePublicKey: Data(repeating: 0x11, count: 32),
                signingPublicKey: Data(repeating: 0x22, count: 32),
                directNeighbors: nil
            ).encode()
        )
        #expect(AnnouncementPacket.decode(from: validPacket.dropLast()) == nil)
    }

    @Test
    func announcementPacketDecodeIgnoresInvalidNeighborLengths() throws {
        var encoded = try #require(
            AnnouncementPacket(
                nickname: "alice",
                noisePublicKey: Data(repeating: 0x11, count: 32),
                signingPublicKey: Data(repeating: 0x22, count: 32),
                directNeighbors: nil
            ).encode()
        )
        encoded.append(makeTLV(type: 0x04, value: Data(repeating: 0x99, count: 7)))

        let decoded = try #require(AnnouncementPacket.decode(from: encoded))
        #expect(decoded.directNeighbors == nil)
    }

    @Test
    func privateMessagePacketRejectsUnknownTypeAndTruncation() {
        let unknownTLV = Data([0x7F, 0x01, 0x41])
        #expect(PrivateMessagePacket.decode(from: unknownTLV) == nil)

        let truncated = Data([0x00, 0x05, 0x61])
        #expect(PrivateMessagePacket.decode(from: truncated) == nil)
    }

    private func makeTLV(type: UInt8, value: Data) -> Data {
        var data = Data([type, UInt8(value.count)])
        data.append(value)
        return data
    }
}
