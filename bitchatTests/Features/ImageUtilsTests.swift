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
}
