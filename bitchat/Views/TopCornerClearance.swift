//
// TopCornerClearance.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import CoreGraphics

/// Extra horizontal padding that keeps a top bar's content off a rounded
/// display corner the safe area leaves uncovered. The iPhone Duo's inner
/// display puts the header at y = 0 beside a 55pt corner; where the status
/// bar already sits above the corner, nothing changes.
enum TopCornerClearance {
    /// - Parameters:
    ///   - cornerWidth: Width of the container's corner inset on this side
    ///     (`GeometryProxy.containerCornerInsets`). It also reports system UI
    ///     the safe area already excludes, such as the vertical status
    ///     column, hence `safeEdgeInset`.
    ///   - cornerHeight: Height of that corner inset; a corner no taller than
    ///     the top safe-area inset ends above the bar.
    ///   - safeTop: Top safe-area inset.
    ///   - safeEdgeInset: Safe-area inset on this side.
    ///   - basePadding: How far the bar's content already sits from the edge.
    static func extraPadding(
        cornerWidth: CGFloat,
        cornerHeight: CGFloat,
        safeTop: CGFloat,
        safeEdgeInset: CGFloat,
        basePadding: CGFloat
    ) -> CGFloat {
        guard cornerHeight > safeTop else { return 0 }
        return max(0, cornerWidth - safeEdgeInset - basePadding)
    }
}
