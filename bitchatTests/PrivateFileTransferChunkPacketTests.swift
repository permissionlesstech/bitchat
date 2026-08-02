import BitFoundation
import Foundation
import Testing
@testable import bitchat

struct PrivateFileTransferPacketTests {
    @Test
    func privateFilePacketRoundTripsAndVerifiesDigest() throws {
        let original = Data((0..<(150 * 1024)).map { UInt8($0 % 251) })
        let filePacket = BitchatFilePacket(
            fileName: "source.png",
            fileSize: UInt64(original.count),
            mimeType: "image/png",
            content: original
        )
        let packet = PrivateFileTransferPacket(
            transferID: "transfer-1",
            fileSHA256: original.sha256Hash(),
            filePacket: filePacket
        )

        let encoded = try #require(packet.encode())
        let decoded = try #require(PrivateFileTransferPacket.decode(encoded))

        #expect(decoded.transferID == "transfer-1")
        #expect(decoded.fileSHA256 == original.sha256Hash())
        #expect(decoded.filePacket.fileName == "source.png")
        #expect(decoded.filePacket.mimeType == "image/png")
        #expect(decoded.filePacket.content == original)
    }

    @Test
    func privateFilePayloadCarriesOneTypedEnvelope() throws {
        let original = Data((0..<(150 * 1024)).map { UInt8($0 % 251) })
        let filePacket = BitchatFilePacket(
            fileName: "source.png",
            fileSize: UInt64(original.count),
            mimeType: "image/png",
            content: original
        )

        let typedPayload = try #require(BLENoisePayloadFactory.privateFileTransferPayload(filePacket, transferId: "tx-original"))

        #expect(typedPayload.first == NoisePayloadType.fileTransfer.rawValue)
        #expect(typedPayload.count > NoiseSecurityConstants.maxMessageSize)
        #expect(NoiseSecurityValidator.validatePrivateFileMessageSize(typedPayload))

        let decoded = try #require(PrivateFileTransferPacket.decode(Data(typedPayload.dropFirst())))
        #expect(decoded.transferID == "tx-original")
        #expect(decoded.filePacket.content == original)
        #expect(decoded.fileSHA256 == original.sha256Hash())
    }

    @Test
    func factoryRejectsOversizedImagePayload() {
        let oversized = Data(repeating: 0x44, count: FileTransferLimits.maxImageBytes + 1)
        let filePacket = BitchatFilePacket(
            fileName: "too-large.png",
            fileSize: UInt64(oversized.count),
            mimeType: "image/png",
            content: oversized
        )

        #expect(BLENoisePayloadFactory.privateFileTransferPayload(filePacket, transferId: "tx-large") == nil)
    }

    @Test
    func decodeRejectsDigestMismatch() throws {
        let original = Data(repeating: 0x41, count: 128)
        let filePacket = BitchatFilePacket(
            fileName: "source.png",
            fileSize: UInt64(original.count),
            mimeType: "image/png",
            content: original
        )
        let packet = PrivateFileTransferPacket(
            transferID: "transfer-1",
            fileSHA256: Data(repeating: 0xAA, count: PrivateFileTransferPacket.sha256Length),
            filePacket: filePacket
        )

        let encoded = try #require(packet.encode())

        #expect(PrivateFileTransferPacket.decode(encoded) == nil)
    }
}
