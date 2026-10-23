import CoreGraphics
import SwiftUI
import Testing
@testable import bitchat

/// The themed backdrop has to cover the safe-area insets too. If it stops at
/// the safe area, a sheet's own background shows through the home-indicator
/// inset: a dark-gray band under the Matrix people list in dark mode.
@Suite("ThemedRootBackground")
@MainActor
struct ThemedRootBackgroundTests {
    @Test(arguments: AppTheme.allCases, ColorScheme.allCases)
    func sheetBackground_fillsBottomSafeAreaInset(theme: AppTheme, colorScheme: ColorScheme) throws {
        // A SwiftUI safe-area inset stands in for the home indicator: it
        // reserves the bottom 20 pt, the way a sheet's bottom inset does.
        let view = Color.clear
            .themedSheetBackground()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: 20)
            }
            .frame(width: 40, height: 100)
            .environment(\.appTheme, theme)
            .environment(\.colorScheme, colorScheme)

        let image = try RenderedPixels(view)
        // Sanity check: the backdrop renders inside the safe area.
        #expect(image.alpha(x: 20, y: 40) == 255)
        // Regression: the backdrop also covers the inset.
        #expect(image.alpha(x: 20, y: 90) == 255)
    }
}

/// RGBA8 pixels of a view rendered offscreen at 1x.
@MainActor
private struct RenderedPixels {
    private let width: Int
    private let bytes: [UInt8]

    init(_ view: some View) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        width = image.width
        var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        try #require(drawn)
        bytes = buffer
    }

    /// Alpha at (x, y), with y measured from the top edge.
    func alpha(x: Int, y: Int) -> UInt8 {
        bytes[(y * width + x) * 4 + 3]
    }
}
