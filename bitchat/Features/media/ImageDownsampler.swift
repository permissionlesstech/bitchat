import Foundation
import ImageIO
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Decodes images via ImageIO thumbnail downsampling after validating header
/// dimensions against `ImageContainerValidator` bounds, preventing OOM crashes
/// from decompression bombs even if an unvalidated file exists on disk.
enum ImageDownsampler {
    static let blurredPreviewMaxPixelSize = 64
    static let inlineMaxPixelSize = 1_024
    static let fullScreenMaxPixelSize = 2_048

    #if os(iOS)
    typealias PlatformImage = UIImage
    #else
    typealias PlatformImage = NSImage
    #endif

    static func loadDownsampledImage(from url: URL, maxPixelSize: Int) -> PlatformImage? {
        guard maxPixelSize > 0 else { return nil }
        let sourceOptions: CFDictionary = [
            kCGImageSourceShouldCache: false
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return nil
        }
        guard ImageContainerValidator.validateDimensions(of: source) == nil else {
            return nil
        }

        let thumbnailOptions: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return nil
        }

        #if os(iOS)
        return UIImage(cgImage: cgImage)
        #else
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #endif
    }
}
