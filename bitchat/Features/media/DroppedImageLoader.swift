//
// DroppedImageLoader.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

#if os(iOS)
import Foundation
import UIKit
import UniformTypeIdentifiers

/// Turns items that the user drops into a chat into images ready to send.
///
/// The items come from other apps, so they are untrusted. The loader reads
/// each one as a file, checks its size and type, and decodes it at a reduced
/// size. The send path then scales and encodes it like a picked photo.
enum DroppedImageLoader {
    /// The content types that a chat accepts as a drop.
    static let acceptedTypes: [UTType] = [.image]

    /// The maximum number of images that one drop sends. Each image is a
    /// separate mesh transfer, so a large selection must not flood the mesh.
    static let maxImagesPerDrop = 4

    /// The long side of the decoded image, in pixels. It is larger than the
    /// final send size, so the send path still does the last scale step.
    static let maxPixelSize: CGFloat = 1024

    /// Returns the dropped items that carry an image, in drop order, up to
    /// `maxImagesPerDrop`.
    static func imageProviders(in providers: [NSItemProvider]) -> [NSItemProvider] {
        let imageProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }
        return Array(imageProviders.prefix(maxImagesPerDrop))
    }

    /// Loads one dropped image.
    static func loadImage(from provider: NSItemProvider) async throws -> UIImage {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, error in
                // The system deletes this file when the handler returns, so
                // decode it here, before the handler ends.
                guard let url else {
                    continuation.resume(throwing: error ?? ImageUtilsError.invalidImage)
                    return
                }
                do {
                    let image = try ImageUtils.downsampledImage(at: url, maxPixelSize: maxPixelSize)
                    continuation.resume(returning: image)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
#endif
