//
// TopCornerClearance.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

/// How far rounded display corners reach into the top bars past the safe
/// area, per layout side. The iPhone Duo's inner display puts the header at
/// y = 0 beside a 55pt corner; where the status bar already sits above a
/// corner, nothing reaches the bars. Each bar pads by whatever its own
/// content inset leaves uncovered (`padding(forReach:contentInset:)`).
struct TopCornerClearance: Equatable {
    var leading: CGFloat = 0
    var trailing: CGFloat = 0
}

extension TopCornerClearance {
    /// - Parameters:
    ///   - topLeft: `GeometryProxy.containerCornerInsets.topLeading`, read as
    ///     the top-left corner.
    ///   - topRight: `containerCornerInsets.topTrailing`, read as the top-right.
    ///   - safeArea: Safe-area insets. Their leading and trailing follow the
    ///     layout direction, as does the padding.
    ///   - isRightToLeft: The layout direction.
    ///
    /// Left-to-right, the corners come back by physical side. Right-to-left
    /// they don't add up: on the iPhone Duo simulator (iOS 27.1) the status
    /// column takes the top-leading slot and the bare 55pt corner goes
    /// unreported, and reading them in a left-to-right subtree instead
    /// mirrors the outer display's 8pt and 59pt corners. Because only square
    /// corners count, a misplaced status column can never pad a bar; right
    /// to left the bars keep their own insets, which hold the people
    /// column's controls clear of the inner display's corner.
    init(
        topLeft: CGSize,
        topRight: CGSize,
        safeArea: EdgeInsets,
        isRightToLeft: Bool
    ) {
        let left = Self.reach(
            of: topLeft,
            safeTop: safeArea.top,
            safeSideInset: isRightToLeft ? safeArea.trailing : safeArea.leading
        )
        let right = Self.reach(
            of: topRight,
            safeTop: safeArea.top,
            safeSideInset: isRightToLeft ? safeArea.leading : safeArea.trailing
        )
        self.init(
            leading: isRightToLeft ? right : left,
            trailing: isRightToLeft ? left : right
        )
    }

    /// Extra padding for a bar whose content already sits `contentInset`
    /// in from the edge a corner reaches in from.
    static func padding(forReach reach: CGFloat, contentInset: CGFloat) -> CGFloat {
        max(0, reach - contentInset)
    }

    private static func reach(
        of corner: CGSize,
        safeTop: CGFloat,
        safeSideInset: CGFloat
    ) -> CGFloat {
        // A display corner reports its radius on both axes. Corner insets
        // also report system UI the safe area already excludes, such as the
        // Duo's vertical status column (84x124), as a rectangle that may be
        // named by layout direction rather than physical side; paired with
        // the wrong side's inset it would pad a bar by the column's width.
        guard abs(corner.width - corner.height) <= 1 else { return 0 }
        // A corner no taller than the top inset ends above the bars.
        guard corner.height > safeTop else { return 0 }
        return max(0, corner.width - safeSideInset)
    }
}
