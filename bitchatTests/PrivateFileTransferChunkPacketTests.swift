import BitFoundation
import Foundation
import Testing
@testable import bitchat

struct PrivateFileTransferChunkPacketTests {
    @Test
    func chunkPacketRoundTrips() throws {
        let packet = PrivateFileTransferChunkPacket(
            transferID: "transfer-1",
            index: 1,
            total: 3,
            fileName: "original.png",
            mimeType: "image/png",
            fileSize: 9,
            fileSHA256: Data(repeating: 0xAB, count: 32),
            content: Data([0x01, 0x02, 0x03])
        )

        let encoded = try #require(packet.encode())
        let decoded = try #require(PrivateFileTransferChunkPacket.decode(encoded))

        #expect(decoded == packet)
    }

    @Test
    func factoryChunksRespectNoiseSizeAndReassembleByteIdentical() throws {
        let original = Data((0..<(150 * 1024)).map { UInt8($0 % 251) })
        let filePacket = BitchatFilePacket(
            fileName: "source.png",
            fileSize: UInt64(original.count),
            mimeType: "image/png",
            content: original
        )

        let typedChunks = try #require(BLENoisePayloadFactory.privateFileTransferChunks(filePacket, transferId: "tx-original"))

        #expect(typedChunks.count > 1)
        #expect(typedChunks.allSatisfy { $0.count <= NoiseSecurityConstants.maxMessageSize })
        #expect(typedChunks.allSatisfy { $0.first == NoisePayloadType.fileTransfer.rawValue })

        let decoded = try typedChunks.map { typed -> PrivateFileTransferChunkPacket in
            try #require(PrivateFileTransferChunkPacket.decode(Data(typed.dropFirst())))
        }
        let reassembled = decoded
            .sorted { $0.index < $1.index }
            .reduce(into: Data()) { $0.append($1.content) }

        #expect(reassembled == original)
        #expect(reassembled.sha256Hash() == decoded.first?.fileSHA256)
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

        #expect(BLENoisePayloadFactory.privateFileTransferChunks(filePacket, transferId: "tx-large") == nil)
    }
}
