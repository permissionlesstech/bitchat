import Testing
import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif
@testable import bitchat

private func makeTemporaryFileURL(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(name)
}

private func makeTemporaryDirectoryURL(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
}

#if os(iOS)
private func makePlatformImage(size: CGSize) -> UIImage {
    UIGraphicsImageRenderer(size: size).image { context in
        UIColor.systemTeal.setFill()
        context.fill(CGRect(origin: .zero, size: size))
    }
}
#else
private func makePlatformImage(size: CGSize) -> NSImage {
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.systemTeal.setFill()
    NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
    image.unlockFocus()
    return image
}
#endif

struct ImageUtilsTests {
    @Test
    func processImage_rejectsOversizedSourceFile() throws {
        let url = makeTemporaryFileURL("image-too-large.bin")
        try Data(repeating: 0xFF, count: 10 * 1024 * 1024 + 1).write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: ImageUtilsError.self) {
            try ImageUtils.processImage(at: url)
        }
    }

    @Test
    func processImage_rejectsInvalidImageData() throws {
        let url = makeTemporaryFileURL("image-invalid.bin")
        try Data("not-an-image".utf8).write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: ImageUtilsError.self) {
            try ImageUtils.processImage(at: url)
        }
    }

    @Test
    func processImage_writesCompressedJpeg() throws {
        let image = makePlatformImage(size: CGSize(width: 1024, height: 768))
        let outputDirectory = makeTemporaryDirectoryURL("image-output-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let outputURL = try ImageUtils.processImage(image, maxDimension: 256, outputDirectory: outputDirectory)

        let data = try Data(contentsOf: outputURL)

        #expect(outputURL.deletingLastPathComponent() == outputDirectory)
        #expect(outputURL.pathExtension.lowercased() == "jpg")
        #expect(data.starts(with: Data([0xFF, 0xD8])))
        #expect(data.count > 0)
    }

    @Test
    func processImage_usesUniqueOutputURLs() throws {
        let image = makePlatformImage(size: CGSize(width: 64, height: 64))
        let outputDirectory = makeTemporaryDirectoryURL("image-output-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let firstURL = try ImageUtils.processImage(image, maxDimension: 64, outputDirectory: outputDirectory)
        let secondURL = try ImageUtils.processImage(image, maxDimension: 64, outputDirectory: outputDirectory)

        #expect(firstURL != secondURL)
        #expect(FileManager.default.fileExists(atPath: firstURL.path))
        #expect(FileManager.default.fileExists(atPath: secondURL.path))
    }

    @Test
    func processImageAtURL_downsamplesAndWritesJpeg() throws {
        let sourceImage = makePlatformImage(size: CGSize(width: 800, height: 600))
        let sourceDir = makeTemporaryDirectoryURL("image-src-\(UUID().uuidString)")
        let outputDir = makeTemporaryDirectoryURL("image-dst-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: sourceDir)
            try? FileManager.default.removeItem(at: outputDir)
        }

        let sourceURL = try ImageUtils.processImage(sourceImage, maxDimension: 800, outputDirectory: sourceDir)
        let downsampledURL = try ImageUtils.processImage(at: sourceURL, maxDimension: 200, outputDirectory: outputDir)

        let data = try Data(contentsOf: downsampledURL)
        #expect(data.starts(with: Data([0xFF, 0xD8])))
        let loaded = try #require(ImageDownsampler.loadDownsampledImage(from: downsampledURL, maxPixelSize: 1024))
        #expect(max(loaded.size.width, loaded.size.height) <= 200.5)
    }

    @Test
    func imageDownsampler_cachesAndClearsOnPanicReset() throws {
        let image = makePlatformImage(size: CGSize(width: 128, height: 128))
        let dir = makeTemporaryDirectoryURL("image-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = try ImageUtils.processImage(image, maxDimension: 128, outputDirectory: dir)
        #expect(ImageDownsampler.cachedImage(for: fileURL, maxPixelSize: 64) == nil)
        let decoded = try #require(ImageDownsampler.loadDownsampledImage(from: fileURL, maxPixelSize: 64))
        let cached = try #require(ImageDownsampler.cachedImage(for: fileURL, maxPixelSize: 64))
        #expect(decoded === cached)

        ImageDownsampler.resetForPanic()
        #expect(ImageDownsampler.cachedImage(for: fileURL, maxPixelSize: 64) == nil)
    }

    @Test
    func processImageAtURL_acceptsHighResolution24MPPhotoAndDownsamples() throws {
        // 5712 x 4284 (~24.5 MP) exceeds the incoming BLE 4096 px / 16.7 MP cap
        // (ImageContainerValidator.maxDimensionPixels), matching modern iPhone
        // default photos. Outgoing ImageUtils must still accept and downsample it.
        let dir = makeTemporaryDirectoryURL("image-24mp-\(UUID().uuidString)")
        let outputDir = makeTemporaryDirectoryURL("image-24mp-out-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: outputDir)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let sourceURL = dir.appendingPathComponent("iphone-24mp.png")
        try TestImageFixtures.makePNG(width: 5_712, height: 4_284).write(to: sourceURL)

        let downsampledURL = try ImageUtils.processImage(at: sourceURL, maxDimension: 448, outputDirectory: outputDir)
        let data = try Data(contentsOf: downsampledURL)
        #expect(data.starts(with: Data([0xFF, 0xD8])))
        let loaded = try #require(ImageDownsampler.loadDownsampledImage(from: downsampledURL, maxPixelSize: 1024))
        #expect(max(loaded.size.width, loaded.size.height) <= 448.5)
    }

    @Test
    func processImageAtURL_stillRejectsExtremeDecompressionBomb() throws {
        let dir = makeTemporaryDirectoryURL("image-bomb-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let bombURL = dir.appendingPathComponent("bomb.png")
        try TestImageFixtures.makePNGBomb(width: 20_000, height: 20_000).write(to: bombURL)

        #expect(throws: ImageUtilsError.self) {
            try ImageUtils.processImage(at: bombURL)
        }
    }
}
