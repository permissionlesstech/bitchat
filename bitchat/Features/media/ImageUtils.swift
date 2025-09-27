import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
import ImageIO
import UniformTypeIdentifiers
#endif

enum ImageUtilsError: Error {
    case invalidImage
    case encodingFailed
}

enum ImageUtils {
    private static let compressionQuality: CGFloat = 0.85
    private static let targetImageBytes: Int = 60_000

    static func processImage(at url: URL, maxDimension: CGFloat = 512) throws -> URL {
        let data = try Data(contentsOf: url)
        #if os(iOS)
        guard let image = UIImage(data: data) else { throw ImageUtilsError.invalidImage }
        return try processImage(image, maxDimension: maxDimension)
        #else
        guard let image = NSImage(data: data) else { throw ImageUtilsError.invalidImage }
        return try processImage(image, maxDimension: maxDimension)
        #endif
    }

    #if os(iOS)
    static func processImage(_ image: UIImage, maxDimension: CGFloat = 512) throws -> URL {
        let scaled = scaledImage(image, maxDimension: maxDimension)
        var quality = compressionQuality
        guard var jpegData = scaled.jpegData(compressionQuality: quality) else {
            throw ImageUtilsError.encodingFailed
        }
        while jpegData.count > targetImageBytes && quality > 0.3 {
            quality -= 0.1
            guard let next = scaled.jpegData(compressionQuality: quality) else { break }
            jpegData = next
        }
        let outputURL = try makeOutputURL()
        try jpegData.write(to: outputURL, options: .atomic)
        return outputURL
    }

    private static func scaledImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let maxSide = max(size.width, size.height)
        guard maxSide > maxDimension else { return image }
        let scale = maxDimension / maxSide
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        UIGraphicsBeginImageContextWithOptions(newSize, true, 1.0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let rendered = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return rendered ?? image
    }
    #else
    static func processImage(_ image: NSImage, maxDimension: CGFloat = 512) throws -> URL {
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
            guard let next = encodeJPEG(from: cgImage, quality: quality) else { break }
            jpegData = next
        }
        let outputURL = try makeOutputURL()
        try jpegData.write(to: outputURL, options: .atomic)
        return outputURL
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

    private static func encodeJPEG(from cgImage: CGImage, quality: CGFloat) -> Data? {
        guard let data = CFDataCreateMutable(nil, 0) else {
            return nil
        }
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyExifDictionary: [:],
            kCGImagePropertyTIFFDictionary: [:],
            kCGImagePropertyIPTCDictionary: [:],
            kCGImagePropertyOrientation: 1
        ]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return data as Data
    }
    #endif

    private static func makeOutputURL() throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let fileName = "img_\(formatter.string(from: Date())).jpg"

        let directory = try applicationFilesDirectory().appendingPathComponent("images/outgoing", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        return directory.appendingPathComponent(fileName)
    }

    private static func applicationFilesDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent("files", isDirectory: true)
    }
}
