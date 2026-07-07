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
    private static let compressionQuality: CGFloat = 0.85
    // Upper bound for the compressed JPEG. This is only a ceiling: the encoder
    // keeps whatever a photo naturally weighs at `defaultMaxDimension` and
    // `compressionQuality`, and only steps quality down when a payload would
    // exceed this budget. It stays well under `FileTransferLimits.maxImageBytes`
    // (512 KiB) so the BLE path never overruns its cap.
    //
    // Wi-Fi bulk relevance: the old 45 KB / 448 px budget crushed every photo
    // to ~40 KB — below `TransportConfig.wifiBulkMinPayloadBytes` (64 KiB) — so
    // `WifiBulkPolicy.shouldOffer` never fired and the AWDL data plane was dead
    // in production. A genuinely detailed photo at `defaultMaxDimension` now
    // weighs well over 64 KiB, so it becomes Wi-Fi-bulk eligible to a capable
    // direct peer while still riding BLE fragmentation for everyone else.
    private static let targetImageBytes: Int = 200_000
    private static let maxSourceImageBytes: Int = 10 * 1024 * 1024
    // Longest-side ceiling for shared photos. 448 px was thumbnail-tier and
    // (together with the tiny byte budget) forced every photo below the Wi-Fi
    // bulk threshold. 1024 px keeps a shared photo legible and lets detailed
    // images clear 64 KiB, without approaching the 512 KiB hard cap.
    static let defaultMaxDimension: CGFloat = 1024

    static func processImage(at url: URL, maxDimension: CGFloat = defaultMaxDimension, outputDirectory: URL? = nil) throws -> URL {
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

    #if os(iOS)
    static func processImage(_ image: UIImage, maxDimension: CGFloat = defaultMaxDimension, outputDirectory: URL? = nil) throws -> URL {
        return try autoreleasepool {
            var dimension = maxDimension
            var jpegData: Data?
            // Downscale-and-compress until the payload fits the hard image cap.
            // A normal photo converges on the first pass; this loop only kicks
            // in for near-incompressible inputs (e.g. full-frame noise) that
            // would otherwise overrun `maxImageBytes` at the raised dimension.
            while true {
                let scaled = scaledImage(image, maxDimension: dimension)
                // Get CGImage from UIImage - this is the key to stripping metadata
                guard let cgImage = scaled.cgImage else {
                    throw ImageUtilsError.encodingFailed
                }
                guard let data = compressToBudget(cgImage) else {
                    throw ImageUtilsError.encodingFailed
                }
                jpegData = data
                if data.count <= FileTransferLimits.maxImageBytes || dimension <= minRetryDimension {
                    break
                }
                dimension = (dimension * dimensionRetryFactor).rounded(.down)
            }
            guard let finalData = jpegData else { throw ImageUtilsError.encodingFailed }

            let outputURL = try makeOutputURL(outputDirectory: outputDirectory)
            try finalData.write(to: outputURL, options: .atomic)
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
    #else
    static func processImage(_ image: NSImage, maxDimension: CGFloat = defaultMaxDimension, outputDirectory: URL? = nil) throws -> URL {
        return try autoreleasepool {
            var dimension = maxDimension
            var jpegData: Data?
            // See the iOS path: normal photos converge immediately; the loop
            // only shrinks further for near-incompressible inputs so the
            // output never overruns `maxImageBytes`.
            while true {
                let scaled = scaledImage(image, maxDimension: dimension)
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
                guard let data = compressToBudget(cgImage) else {
                    throw ImageUtilsError.encodingFailed
                }
                jpegData = data
                if data.count <= FileTransferLimits.maxImageBytes || dimension <= minRetryDimension {
                    break
                }
                dimension = (dimension * dimensionRetryFactor).rounded(.down)
            }
            guard let finalData = jpegData else { throw ImageUtilsError.encodingFailed }
            let outputURL = try makeOutputURL(outputDirectory: outputDirectory)
            try finalData.write(to: outputURL, options: .atomic)
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
    #endif

    // When even the quality floor can't get an image under the byte budget,
    // shrink the longest side by this factor and re-encode. Bounded below so
    // the retry loop always terminates.
    private static let dimensionRetryFactor: CGFloat = 0.75
    private static let minRetryDimension: CGFloat = 256

    /// Encodes `cgImage` to JPEG, stepping quality down toward
    /// `targetImageBytes`. Shared by both platforms.
    private static func compressToBudget(_ cgImage: CGImage) -> Data? {
        var quality = compressionQuality
        guard var jpegData = encodeJPEG(from: cgImage, quality: quality) else {
            return nil
        }
        while jpegData.count > targetImageBytes && quality > 0.3 {
            quality -= 0.1
            autoreleasepool {
                if let next = encodeJPEG(from: cgImage, quality: quality) {
                    jpegData = next
                }
            }
        }
        return jpegData
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
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let fileName = "img_\(formatter.string(from: Date()))_\(UUID().uuidString).jpg"

        let directory: URL
        if let outputDirectory {
            directory = outputDirectory
        } else {
            directory = try applicationFilesDirectory().appendingPathComponent("images/outgoing", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        return directory.appendingPathComponent(fileName)
    }

    private static func applicationFilesDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent("files", isDirectory: true)
    }
}
