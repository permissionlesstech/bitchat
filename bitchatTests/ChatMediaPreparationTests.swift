//
// ChatMediaPreparationTests.swift
// bitchatTests
//

import Foundation
import Testing
@testable import bitchat

struct ChatMediaPreparationTests {
    @Test func prepareProcessedImagePacketReusesOutputURLAndBytes() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let jpegURL = tempDir.appendingPathComponent("processed.jpg")
        let payload = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0xFF, 0xD9])
        try payload.write(to: jpegURL)

        let prepared = try ChatMediaPreparation.prepareProcessedImagePacket(from: jpegURL)

        #expect(prepared.outputURL == jpegURL)
        #expect(prepared.packet.fileName == "processed.jpg")
        #expect(prepared.packet.mimeType == "image/jpeg")
        #expect(prepared.packet.fileSize == UInt64(payload.count))
        #expect(prepared.packet.content == payload)
    }

    @Test func prepareProcessedImagePacketRejectsOversizedImageAndCleansUp() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let oversizedURL = tempDir.appendingPathComponent("oversized.jpg")
        let oversizedData = Data(repeating: 0xAA, count: FileTransferLimits.maxImageBytes + 1)
        try oversizedData.write(to: oversizedURL)

        #expect(throws: ChatMediaPreparationError.self) {
            _ = try ChatMediaPreparation.prepareProcessedImagePacket(from: oversizedURL)
        }
        #expect(!FileManager.default.fileExists(atPath: oversizedURL.path))
    }
}
