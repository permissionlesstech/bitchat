//
// DroppedImageLoaderTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

#if os(iOS)
import Foundation
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import bitchat

struct DroppedImageLoaderTests {
    @Test
    func imageProviders_keepsOnlyImagesInDropOrder() throws {
        let first = try makeDroppedImageProvider(size: CGSize(width: 8, height: 8))
        let text = NSItemProvider(object: "hello" as NSString)
        let second = try makeDroppedImageProvider(size: CGSize(width: 8, height: 8))

        let result = DroppedImageLoader.imageProviders(in: [first, text, second])

        #expect(result.count == 2)
        #expect(result.first === first)
        #expect(result.last === second)
    }

    @Test
    func imageProviders_capsTheImagesPerDrop() throws {
        let providers = try (0..<(DroppedImageLoader.maxImagesPerDrop + 2)).map { _ in
            try makeDroppedImageProvider(size: CGSize(width: 8, height: 8))
        }

        let result = DroppedImageLoader.imageProviders(in: providers)

        #expect(result.count == DroppedImageLoader.maxImagesPerDrop)
        #expect(zip(result, providers).allSatisfy { $0 === $1 })
    }

    @Test
    func loadImage_downsamplesLargeImage() async throws {
        let provider = try makeDroppedImageProvider(size: CGSize(width: 2048, height: 1024))

        let image = try await DroppedImageLoader.loadImage(from: provider)

        let cgImage = try #require(image.cgImage)
        #expect(CGFloat(cgImage.width) == DroppedImageLoader.maxPixelSize)
        #expect(CGFloat(cgImage.height) == DroppedImageLoader.maxPixelSize / 2)
    }

    @Test
    func loadImage_keepsSmallImageSize() async throws {
        let provider = try makeDroppedImageProvider(size: CGSize(width: 64, height: 32))

        let image = try await DroppedImageLoader.loadImage(from: provider)

        let cgImage = try #require(image.cgImage)
        #expect(cgImage.width == 64)
        #expect(cgImage.height == 32)
    }

    @Test
    func loadImage_rejectsDataThatIsNotAnImage() async throws {
        let provider = NSItemProvider(
            item: Data("not-an-image".utf8) as NSData,
            typeIdentifier: UTType.png.identifier
        )

        await #expect(throws: (any Error).self) {
            _ = try await DroppedImageLoader.loadImage(from: provider)
        }
    }
}

/// Builds a provider like the one a drag from Photos or Files delivers.
func makeDroppedImageProvider(size: CGSize) throws -> NSItemProvider {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
        UIColor.systemTeal.setFill()
        context.fill(CGRect(origin: .zero, size: size))
    }
    let data = try #require(image.pngData())
    return NSItemProvider(item: data as NSData, typeIdentifier: UTType.png.identifier)
}
#endif
