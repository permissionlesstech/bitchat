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

    private static let cache: NSCache<NSString, PlatformImage> = {
        let cache = NSCache<NSString, PlatformImage>()
        cache.countLimit = 48
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    private static func cacheKey(for url: URL, maxPixelSize: Int) -> NSString {
        "\(url.path)#\(maxPixelSize)" as NSString
    }

    static func cachedImage(for url: URL, maxPixelSize: Int) -> PlatformImage? {
        guard maxPixelSize > 0 else { return nil }
        return cache.object(forKey: cacheKey(for: url, maxPixelSize: maxPixelSize))
    }

    static func resetForPanic() {
        cache.removeAllObjects()
    }

    static func loadDownsampledImage(from url: URL, maxPixelSize: Int) -> PlatformImage? {
        guard maxPixelSize > 0 else { return nil }
        let key = cacheKey(for: url, maxPixelSize: maxPixelSize)
        if let cached = cache.object(forKey: key) {
            return cached
        }
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

        let image: PlatformImage
        #if os(iOS)
        image = UIImage(cgImage: cgImage)
        #else
        image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #endif
        let cost = max(1, cgImage.width * cgImage.height * 4)
        cache.setObject(image, forKey: key, cost: cost)
        return image
    }
}
