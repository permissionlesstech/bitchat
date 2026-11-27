import BitFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#else
import AppKit
#endif

enum ImageUtilsError: Error {
    case invalidImage
    case encodingFailed
}

enum ImageUtils {
    private static let compressionQuality: CGFloat = 0.82
    /// Encode against the protocol image budget, not a second magic squeeze.
    /// Voice notes already travel at 512 KiB; photos should too. Android
    /// encodes at 512px / q=85 with no 45 KB crush, so matching that budget
    /// is what keeps a photo readable on the same radio.
    private static let targetImageBytes: Int = FileTransferLimits.maxImageBytes
    private static let maxSourceImageBytes: Int = 10 * 1024 * 1024

    private static let timestampFormatterLock = NSLock()
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter
    }()

    static func processImage(at url: URL, maxDimension: CGFloat = 512, outputDirectory: URL? = nil) throws -> URL {
        try validateImageSource(at: url)

        return try autoreleasepool {
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
                  ImageContainerValidator.validateDimensions(of: source) == nil else {
                throw ImageUtilsError.invalidImage
            }

            // Downsample directly through ImageIO so sending a 12-48 MP photo never
            // decodes the full-resolution bitmap into memory.
            let maxPixelSize = max(1, Int(ceil(maxDimension)))
            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: false,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
                throw ImageUtilsError.invalidImage
            }
            return try encodeAndWriteJPEG(from: cgImage, outputDirectory: outputDirectory)
        }
    }

    static func validateImageSource(at url: URL) throws {
        // Security H1: Check file size BEFORE reading into memory.
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let fileSize = attrs[.size] as? Int,
              fileSize > 0,
              fileSize <= maxSourceImageBytes else {
            throw ImageUtilsError.invalidImage
        }

        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              CGImageSourceGetType(source) != nil else {
            throw ImageUtilsError.invalidImage
        }
    }

    #if os(iOS)
    static func processImage(_ image: UIImage, maxDimension: CGFloat = 512, outputDirectory: URL? = nil) throws -> URL {
        return try autoreleasepool {
            // Scale the image first
            let scaled = scaledImage(image, maxDimension: maxDimension)

            // Get CGImage from UIImage - this is the key to stripping metadata
            guard let cgImage = scaled.cgImage else {
                throw ImageUtilsError.encodingFailed
            }

            return try encodeAndWriteJPEG(from: cgImage, outputDirectory: outputDirectory)
        }
    }

    private static func scaledImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let maxSide = max(size.width, size.height)
        let scale = maxSide > maxDimension ? maxDimension / maxSide : 1
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)

        // Always redraw so EXIF orientation is baked in even when the
        // pixel size already fits. Returning the original left
        // `image.cgImage` rotated for camera stills under 512px.
        UIGraphicsBeginImageContextWithOptions(newSize, true, 1.0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let rendered = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return rendered ?? image
    }
    #else
    static func processImage(_ image: NSImage, maxDimension: CGFloat = 512, outputDirectory: URL? = nil) throws -> URL {
        return try autoreleasepool {
            let scaled = scaledImage(image, maxDimension: maxDimension)
            guard let inputCG = scaled.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw ImageUtilsError.encodingFailed
            }
            let width = inputCG.width
            let height = inputCG.height
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                throw ImageUtilsError.encodingFailed
            }
            context.draw(inputCG, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let cgImage = context.makeImage() else {
                throw ImageUtilsError.encodingFailed
            }
            return try encodeAndWriteJPEG(from: cgImage, outputDirectory: outputDirectory)
        }
    }

    private static func scaledImage(_ image: NSImage, maxDimension: CGFloat) -> NSImage {
        let size = image.size
        let maxSide = max(size.width, size.height)
        let scale = maxSide > maxDimension ? maxDimension / maxSide : 1
        let newSize = NSSize(width: size.width * scale, height: size.height * scale)
        let scaledImage = NSImage(size: newSize)
        scaledImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize),
                   from: NSRect(origin: .zero, size: size),
                   operation: .copy,
                   fraction: 1.0)
        scaledImage.unlockFocus()
        return scaledImage
    }
    #endif

    private static func encodeAndWriteJPEG(from cgImage: CGImage, outputDirectory: URL?) throws -> URL {
        var quality = compressionQuality
        guard var jpegData = encodeJPEG(from: cgImage, quality: quality) else {
            throw ImageUtilsError.encodingFailed
        }

        // Compress to target size
        while jpegData.count > targetImageBytes && quality > 0.3 {
            quality -= 0.1
            autoreleasepool {
                if let next = encodeJPEG(from: cgImage, quality: quality) {
                    jpegData = next
                }
            }
        }

        let outputURL = try makeOutputURL(outputDirectory: outputDirectory)
        try jpegData.write(to: outputURL, options: .atomic)
        return outputURL
    }

    // Shared EXIF-stripping JPEG encoder for both iOS and macOS
    private static func encodeJPEG(from cgImage: CGImage, quality: CGFloat) -> Data? {
        guard let data = CFDataCreateMutable(nil, 0) else {
            return nil
        }
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        // Security: Strip ALL metadata (EXIF, GPS, TIFF, IPTC, XMP)
        // By only specifying compression quality and no metadata keys,
        // we ensure a clean JPEG with no privacy-leaking information
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return data as Data
    }

    private static func makeOutputURL(outputDirectory: URL? = nil) throws -> URL {
        let timestamp = timestampFormatterLock.withLock {
            timestampFormatter.string(from: Date())
        }
        let fileName = "img_\(timestamp)_\(UUID().uuidString).jpg"

        let directory: URL
        if let outputDirectory {
            directory = outputDirectory
        } else {
            directory = try applicationFilesDirectory().appendingPathComponent("images/outgoing", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: BLEIncomingFileStore.mediaProtectionAttributes)
        return directory.appendingPathComponent(fileName)
    }

    private static func applicationFilesDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent("files", isDirectory: true)
    }
}
