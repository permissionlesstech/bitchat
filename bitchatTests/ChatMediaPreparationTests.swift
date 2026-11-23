import BitFoundation
import Foundation
import Testing
#if os(iOS)
import UIKit
#else
import AppKit
#endif
@testable import bitchat

struct ChatMediaPreparationTests {
    @Test
    func prepareVoiceNotePacket_buildsEncodedAudioPacket() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
        try Data("voice".utf8).write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let packet = try ChatMediaPreparation.prepareVoiceNotePacket(at: url)

        #expect(packet.fileName == url.lastPathComponent)
        #expect(packet.mimeType == "audio/mp4")
        #expect(packet.fileSize == 5)
        #expect(packet.encode() != nil)
    }

    @Test
    func prepareVoiceNotePacket_rejectsOversizedAudio() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-too-large-\(UUID().uuidString).m4a")
        try Data(repeating: 0x55, count: FileTransferLimits.maxVoiceNoteBytes + 1).write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: ChatMediaPreparationError.voiceNoteTooLarge(bytes: FileTransferLimits.maxVoiceNoteBytes + 1)) {
            try ChatMediaPreparation.prepareVoiceNotePacket(at: url)
        }
    }

    @Test
    func prepareImagePacket_rejectsInvalidImage() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("invalid-\(UUID().uuidString).jpg")
        try Data("not-an-image".utf8).write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: ImageUtilsError.invalidImage) {
            try ChatMediaPreparation.prepareImagePacket(from: url)
        }
    }

    @Test
    func prepareImagePacket_buildsEncodedJpegPacket() throws {
        let sourceURL = try makeTemporaryImageURL()
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let prepared = try ChatMediaPreparation.prepareImagePacket(from: sourceURL)
        defer { try? FileManager.default.removeItem(at: prepared.outputURL) }

        #expect(prepared.packet.fileName == prepared.outputURL.lastPathComponent)
        #expect(prepared.packet.mimeType == "image/jpeg")
        #expect(prepared.packet.fileSize == UInt64(prepared.packet.content.count))
        #expect(prepared.packet.encode() != nil)
    }

    @Test
    func prepareProcessedImagePacket_reusesOutputURLAndBytes() throws {
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

    @Test
    func prepareProcessedImagePacket_rejectsOversizedImageAndCleansUp() throws {
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

private func makeTemporaryImageURL() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("image-\(UUID().uuidString).png")
    #if os(iOS)
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64))
    let image = renderer.image { context in
        UIColor.systemTeal.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    }
    guard let data = image.pngData() else {
        throw ChatMediaPreparationTestError.imageEncodingFailed
    }
    #else
    let image = NSImage(size: NSSize(width: 64, height: 64))
    image.lockFocus()
    NSColor.systemTeal.setFill()
    NSRect(x: 0, y: 0, width: 64, height: 64).fill()
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let data = bitmap.representation(using: .png, properties: [:]) else {
        throw ChatMediaPreparationTestError.imageEncodingFailed
    }
    #endif
    try data.write(to: url, options: .atomic)
    return url
}

private enum ChatMediaPreparationTestError: Error {
    case imageEncodingFailed
}
