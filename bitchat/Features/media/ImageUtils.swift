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
    private static let targetImageBytes: Int = 45_000
    private static let maxSourceImageBytes: Int = 10 * 1024 * 1024
    private static let photoLibraryStagingDirectoryName = "bitchat-photo-library-staging"
    private static let photoLibraryStagingFilePrefix = "bitchat-picked-"

    static func processImage(at url: URL, maxDimension: CGFloat = 448, outputDirectory: URL? = nil) throws -> URL {
        try validateImageSource(at: url)

        let data = try Data(contentsOf: url)
        #if os(iOS)
        guard let image = UIImage(data: data) else { throw ImageUtilsError.invalidImage }
        return try processImage(image, maxDimension: maxDimension, outputDirectory: outputDirectory)
        #else
        guard let image = NSImage(data: data) else { throw ImageUtilsError.invalidImage }
        return try processImage(image, maxDimension: maxDimension, outputDirectory: outputDirectory)
        #endif
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

    static func copyOriginalImage(at url: URL, outputDirectory: URL? = nil) throws -> URL {
        try validateImageSource(at: url)
        let data = try Data(contentsOf: url)
        let outputURL = try makeOutputURL(
            fileName: url.lastPathComponent,
            outputDirectory: outputDirectory
        )
        try data.write(to: outputURL, options: .atomic)
        return outputURL
    }

    static func mimeTypeForImage(at url: URL) throws -> String {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let type = CGImageSourceGetType(source) else {
            throw ImageUtilsError.invalidImage
        }

        if let utType = UTType(type as String),
           let mimeType = utType.preferredMIMEType {
            return mimeType
        }

        throw ImageUtilsError.invalidImage
    }

    static func stagePhotoLibraryImageFile(at sourceURL: URL, suggestedName: String?) throws -> URL {
        let fileManager = FileManager.default
        let extensionFromSource = nonEmptyExtension(sourceURL.pathExtension)
        let extensionFromSuggestion = suggestedName.flatMap { nonEmptyExtension(URL(fileURLWithPath: $0).pathExtension) }
        let fileExtension = extensionFromSource ?? extensionFromSuggestion ?? "img"
        let stagingDirectory = try photoLibraryStagingDirectory()
        let stagedURL = stagingDirectory
            .appendingPathComponent("\(photoLibraryStagingFilePrefix)\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)

        try fileManager.copyItem(at: sourceURL, to: stagedURL)
        return stagedURL
    }

    static func removePhotoLibraryStagedImage(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func clearPhotoLibraryStagingDirectory() {
        guard let stagingDirectory = try? photoLibraryStagingDirectory(create: false) else { return }
        try? FileManager.default.removeItem(at: stagingDirectory)
    }

    #if os(iOS)
    static func processImage(_ image: UIImage, maxDimension: CGFloat = 448, outputDirectory: URL? = nil) throws -> URL {
        return try autoreleasepool {
            // Scale the image first
            let scaled = scaledImage(image, maxDimension: maxDimension)

            // Get CGImage from UIImage - this is the key to stripping metadata
            guard let cgImage = scaled.cgImage else {
                throw ImageUtilsError.encodingFailed
            }

            // Use CGImageDestination to encode without metadata (same as macOS)
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
    }

    static func writeCameraOriginalCandidate(_ image: UIImage, outputDirectory: URL? = nil) throws -> URL {
        return try autoreleasepool {
            guard let cgImage = image.cgImage else {
                throw ImageUtilsError.encodingFailed
            }

            guard let jpegData = encodeJPEG(from: cgImage, quality: 1.0) else {
                throw ImageUtilsError.encodingFailed
            }

            let outputURL = try makeOutputURL(outputDirectory: outputDirectory)
            try jpegData.write(to: outputURL, options: .atomic)
            return outputURL
        }
    }

    private static func scaledImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let maxSide = max(size.width, size.height)
        guard maxSide > maxDimension else { return image }
        let scale = maxDimension / maxSide
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)

        // Draw into a new context to get a clean CGImage without metadata
        UIGraphicsBeginImageContextWithOptions(newSize, true, 1.0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let rendered = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return rendered ?? image
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
    #else
    static func processImage(_ image: NSImage, maxDimension: CGFloat = 448, outputDirectory: URL? = nil) throws -> URL {
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
            var quality = compressionQuality
            guard var jpegData = encodeJPEG(from: cgImage, quality: quality) else {
                throw ImageUtilsError.encodingFailed
            }
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
    }

    private static func scaledImage(_ image: NSImage, maxDimension: CGFloat) -> NSImage {
        let size = image.size
        let maxSide = max(size.width, size.height)
        guard maxSide > maxDimension else { return image }
        let scale = maxDimension / maxSide
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
    #endif

    private static func makeOutputURL(outputDirectory: URL? = nil) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let fileName = "img_\(formatter.string(from: Date()))_\(UUID().uuidString).jpg"

        return try makeOutputURL(fileName: fileName, outputDirectory: outputDirectory)
    }

    private static func makeOutputURL(fileName: String, outputDirectory: URL? = nil) throws -> URL {
        let directory: URL
        if let outputDirectory {
            directory = outputDirectory
        } else {
            directory = try applicationFilesDirectory().appendingPathComponent("images/outgoing", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        let safeName = sanitizedFileName(fileName)
        var candidate = directory.appendingPathComponent(safeName)
        if !FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }

        let baseName = (safeName as NSString).deletingPathExtension
        let ext = (safeName as NSString).pathExtension
        candidate = directory.appendingPathComponent(
            ext.isEmpty
                ? "\(baseName)_\(UUID().uuidString)"
                : "\(baseName)_\(UUID().uuidString).\(ext)"
        )
        return candidate
    }

    private static func applicationFilesDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent("files", isDirectory: true)
    }

    private static func sanitizedFileName(_ fileName: String) -> String {
        var candidate = (fileName as NSString).lastPathComponent
            .replacingOccurrences(of: "\0", with: "")
            .precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")

        let invalid = CharacterSet(charactersIn: "<>:\"|?*\0").union(.controlCharacters)
        candidate = candidate.components(separatedBy: invalid).joined(separator: "_").trimmed
        if candidate.isEmpty { candidate = "img_\(UUID().uuidString)" }
        if candidate.hasPrefix(".") { candidate = "_" + candidate }
        return candidate
    }

    private static func photoLibraryStagingDirectory(create: Bool = true) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            photoLibraryStagingDirectoryName,
            isDirectory: true
        )
        if create {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        }
        return directory
    }

    private static func nonEmptyExtension(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }
}
