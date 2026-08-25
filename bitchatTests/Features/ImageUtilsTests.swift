import Testing
import Foundation
import ImageIO
import BitFoundation
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

private func makeNoisyPlatformImage(size: CGSize) -> UIImage {
    UIGraphicsImageRenderer(size: size).image { context in
        for i in 0..<600 {
            UIColor(
                hue: CGFloat(i % 47) / 47,
                saturation: 1,
                brightness: CGFloat((i * 13) % 100) / 100,
                alpha: 1
            ).setStroke()
            let path = UIBezierPath()
            path.move(to: CGPoint(x: CGFloat(i * 3 % Int(size.width)), y: 0))
            path.addLine(to: CGPoint(x: 0, y: CGFloat(i * 5 % Int(size.height))))
            path.lineWidth = 2
            path.stroke()
        }
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

private func makeNoisyPlatformImage(size: CGSize) -> NSImage {
    let image = NSImage(size: size)
    image.lockFocus()
    for i in 0..<600 {
        NSColor(
            hue: CGFloat(i % 47) / 47,
            saturation: 1,
            brightness: CGFloat((i * 13) % 100) / 100,
            alpha: 1
        ).setStroke()
        let path = NSBezierPath()
        path.move(to: CGPoint(x: CGFloat(i * 3 % Int(size.width)), y: 0))
        path.line(to: CGPoint(x: 0, y: CGFloat(i * 5 % Int(size.height))))
        path.lineWidth = 2
        path.stroke()
    }
    image.unlockFocus()
    return image
}
#endif

private func jpegPixelSize(_ data: Data) -> CGSize {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = props[kCGImagePropertyPixelWidth] as? Int,
          let height = props[kCGImagePropertyPixelHeight] as? Int else {
        return .zero
    }
    return CGSize(width: width, height: height)
}

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
    func processImage_usesThe512KiBBudgetInsteadOfCrushingTo45KB() throws {
        let image = makeNoisyPlatformImage(size: CGSize(width: 1600, height: 1200))
        let outputDirectory = makeTemporaryDirectoryURL("image-budget-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let outputURL = try ImageUtils.processImage(image, outputDirectory: outputDirectory)
        let data = try Data(contentsOf: outputURL)
        let pixelSize = jpegPixelSize(data)

        #expect(data.count > 45_000)
        #expect(data.count <= FileTransferLimits.maxImageBytes)
        #expect(pixelSize.width <= 512)
        #expect(pixelSize.height <= 512)
        #expect(max(pixelSize.width, pixelSize.height) == 512)
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
}
