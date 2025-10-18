//
// BinaryTransferTests.swift
// bitchatTests
//
// Exercises the binary transfer metadata and chunk helpers to ensure
// stability of the wire format.
//

import Testing
import Foundation
@testable import bitchat

struct BinaryTransferTests {

    @Test func metadataRoundTrip() throws {
        let transferID = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
        let checksum = Data(repeating: 0xAA, count: 16)
        let metadata = try #require(
            BinaryTransferMetadata(
                transferID: transferID,
                kind: .image,
                mimeType: "image/jpeg",
                totalSize: 150_000,
                chunkSize: 1024,
                filename: "photo.jpg",
                checksum: checksum
            ),
            "Failed to construct metadata"
        )

        let encoded = metadata.toBinaryData()
        let decoded = try #require(BinaryTransferMetadata(data: encoded), "Failed to decode metadata")

        #expect(decoded == metadata)
        #expect(decoded.filename == "photo.jpg")
        #expect(decoded.mimeType == "image/jpeg")
        #expect(decoded.chunkCount == 147)
    }

    @Test func metadataValidationRejectsInvalidInput() throws {
        // Missing slash in MIME type should be rejected
        #expect(BinaryTransferMetadata(kind: .audio, mimeType: "audio", totalSize: 1024, chunkSize: 512) == nil)

        // Oversized payload should be rejected
        #expect(BinaryTransferMetadata(kind: .image, mimeType: "image/png", totalSize: 3_000_000, chunkSize: 512) == nil)

        // Chunk size larger than allowed should be rejected
        #expect(BinaryTransferMetadata(kind: .image, mimeType: "image/png", totalSize: 1024, chunkSize: 10_000) == nil)
    }

    @Test func chunkRoundTrip() throws {
        let transferID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let payload = Data(repeating: 0x11, count: 512)
        let chunk = try #require(
            BinaryTransferChunk(
                transferID: transferID,
                sequenceNumber: 5,
                totalChunks: 20,
                payload: payload
            ),
            "Failed to create chunk"
        )

        let encoded = chunk.toBinaryData()
        let decoded = try #require(BinaryTransferChunk(data: encoded), "Failed to decode chunk")

        #expect(decoded == chunk)
        #expect(decoded.payload.count == 512)
    }

    @Test func chunkValidationRejectsInvalidInput() throws {
        let payload = Data(repeating: 0x01, count: 16)
        let transferID = UUID()

        // Sequence equal to total should be rejected
        #expect(BinaryTransferChunk(transferID: transferID, sequenceNumber: 4, totalChunks: 4, payload: payload) == nil)

        // Empty payload should be rejected
        #expect(BinaryTransferChunk(transferID: transferID, sequenceNumber: 0, totalChunks: 1, payload: Data()) == nil)
    }

    @Test func packetsEncodeWithBinaryTypes() throws {
        let metadata = try #require(
            BinaryTransferMetadata(
                kind: .audio,
                mimeType: "audio/ogg",
                totalSize: 4096,
                chunkSize: 512
            ),
            "Failed to build metadata"
        )

        let packet = TestHelpers.createTestPacket(
            type: MessageType.binaryMetadata.rawValue,
            payload: metadata.toBinaryData()
        )

        let encoded = try #require(BinaryProtocol.encode(packet), "Failed to encode packet")
        let decoded = try #require(BinaryProtocol.decode(encoded), "Failed to decode packet")
        #expect(decoded.type == MessageType.binaryMetadata.rawValue)
        #expect(BinaryTransferMetadata(data: decoded.payload) != nil)
    }
}
