import BitFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
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
    func prepareOriginalImagePacket_rejectsOversizedOriginalImage() throws {
        let sourceURL = try makeOversizedPNGURL()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let sourceSize = try Data(contentsOf: sourceURL).count
        #expect(sourceSize > FileTransferLimits.maxImageBytes)

        #expect(throws: ChatMediaPreparationError.imageTooLarge(bytes: sourceSize)) {
            try ChatMediaPreparation.prepareOriginalImagePacket(from: sourceURL)
        }
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

private func makeOversizedPNGURL() throws -> URL {
    let width = 1024
    let height = 1024
    var state: UInt64 = 0x1234_5678_9ABC_DEF0
    var rgba = Data(count: width * height * 4)
    rgba.withUnsafeMutableBytes { rawBuffer in
        let bytes = rawBuffer.bindMemory(to: UInt8.self)
        for pixel in 0..<(width * height) {
            let offset = pixel * 4
            state = state &* 6364136223846793005 &+ 1442695040888963407
            bytes[offset] = UInt8(truncatingIfNeeded: state >> 24)
            state = state &* 6364136223846793005 &+ 1442695040888963407
            bytes[offset + 1] = UInt8(truncatingIfNeeded: state >> 32)
            state = state &* 6364136223846793005 &+ 1442695040888963407
            bytes[offset + 2] = UInt8(truncatingIfNeeded: state >> 40)
            bytes[offset + 3] = 0xFF
        }
    }

    guard let provider = CGDataProvider(data: rgba as CFData),
          let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
          ) else {
        throw ChatMediaPreparationTestError.imageEncodingFailed
    }

    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
        throw ChatMediaPreparationTestError.imageEncodingFailed
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw ChatMediaPreparationTestError.imageEncodingFailed
    }

    let url = FileManager.default.temporaryDirectory.appendingPathComponent("image-too-large-\(UUID().uuidString).png")
    try (data as Data).write(to: url, options: .atomic)
    return url
}

private enum ChatMediaPreparationTestError: Error {
    case imageEncodingFailed
}
