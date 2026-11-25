//
// ContentSplitLayout.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

#if os(iOS)
import SwiftUI

/// Column widths for regular width: the public timeline leading, the people
/// list or open DM trailing, split at the hinge so neither column straddles
/// the fold (iPhone Duo's inner display). Nil keeps the single column, with
/// people and DMs in the sheet.
struct ContentSplitLayout: Equatable {
    /// The people and DM views were built for ~375pt sheets; narrower than
    /// this, either column gets cramped.
    static let minimumColumnWidth: CGFloat = 340
    /// Gap used while the system reports no fold region: the fold's margins
    /// as the Duo reports them, 20pt either side of the hinge, so the
    /// columns don't move when the region arrives and controls stay off the
    /// crease meanwhile.
    static let fallbackGapWidth: CGFloat = 40

    let leadingWidth: CGFloat
    let gapWidth: CGFloat
    let trailingWidth: CGFloat

    /// - Parameters:
    ///   - width: Content width inside the safe area.
    ///   - leadingInset: Leading safe-area inset of the window.
    ///   - trailingInset: Trailing safe-area inset. The vertical status bar
    ///     makes the two differ, so the hinge is not at the content's centre.
    ///   - division: The fold's division region in content coordinates,
    ///     margins included.
    static func resolve(
        isRegularWidth: Bool,
        width: CGFloat,
        leadingInset: CGFloat,
        trailingInset: CGFloat,
        division: CGRect?
    ) -> ContentSplitLayout? {
        guard isRegularWidth else { return nil }
        let gapMinX: CGFloat
        let gapMaxX: CGFloat
        if let division {
            // A fold across the screen can't separate side-by-side columns.
            guard division.height > division.width else { return nil }
            // The region's margins keep interactive content off the curve.
            gapMinX = division.minX
            gapMaxX = division.maxX
        } else {
            // No region yet: the hinge sits at the window's centre.
            let hingeX = (width + leadingInset + trailingInset) / 2 - leadingInset
            gapMinX = hingeX - fallbackGapWidth / 2
            gapMaxX = hingeX + fallbackGapWidth / 2
        }
        let leadingWidth = gapMinX
        let trailingWidth = width - gapMaxX
        guard leadingWidth >= minimumColumnWidth,
              trailingWidth >= minimumColumnWidth else {
            return nil
        }
        return ContentSplitLayout(
            leadingWidth: leadingWidth,
            gapWidth: gapMaxX - gapMinX,
            trailingWidth: trailingWidth
        )
    }

    /// The fold's division region, inactive ones included (the device lying
    /// flat) so the columns don't jump as the hinge moves. Nil before iOS
    /// 27.1, and whenever the system reports none: it can be missing right
    /// after launch, until the first hinge change.
    static func division(in proxy: GeometryProxy) -> CGRect? {
        #if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            return proxy.reservedRegions(kind: .division, options: .includeInactive).first?.frame
        }
        #endif
        return nil
    }
}

/// The space between the columns. Matrix draws a hairline on the hinge;
/// glass leaves it clear, since the root gradient spans both columns.
struct ContentColumnGap: View {
    let width: CGFloat

    @Environment(\.appTheme) private var theme
    @Environment(\.displayScale) private var displayScale
    @ThemedPalette private var palette

    var body: some View {
        Color.clear
            .frame(width: width)
            .overlay {
                if !theme.usesGlassChrome {
                    palette.divider
                        .frame(width: 1 / displayScale)
                }
            }
            .accessibilityHidden(true)
    }
}
#endif
