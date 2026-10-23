#if os(iOS)
import CoreGraphics
import Testing
@testable import bitchat

/// Geometry measured on the iPhone Duo simulator (iOS 27.1): the inner
/// display's content is 867pt wide beside an 84pt trailing status column
/// (window 951pt), and the fold's division region is (455.5, 0, 40, 669),
/// 20pt of margin either side of the hinge at x = 475.5.
struct ContentSplitLayoutTests {
    private let innerWidth: CGFloat = 867
    private let statusColumn: CGFloat = 84

    @Test
    func divisionRegionBecomesTheGap() throws {
        let layout = try #require(ContentSplitLayout.resolve(
            isRegularWidth: true,
            width: innerWidth,
            leadingInset: 0,
            trailingInset: statusColumn,
            division: CGRect(x: 455.5, y: 0, width: 40, height: 669)
        ))

        #expect(layout.leadingWidth == 455.5)
        #expect(layout.gapWidth == 40)
        #expect(layout.trailingWidth == 371.5)
    }

    /// The region can be missing until the first hinge change; the hinge is
    /// then the window's centre, not the content's.
    @Test
    func withoutARegionTheGapCentresOnTheWindow() throws {
        let layout = try #require(ContentSplitLayout.resolve(
            isRegularWidth: true,
            width: innerWidth,
            leadingInset: 0,
            trailingInset: statusColumn,
            division: nil
        ))

        #expect(layout.gapWidth == ContentSplitLayout.fallbackGapWidth)
        #expect(layout.leadingWidth + layout.gapWidth / 2 == 475.5)
        #expect(layout.leadingWidth + layout.gapWidth + layout.trailingWidth == innerWidth)
    }

    /// Right-to-left puts the status column on the leading edge.
    @Test
    func leadingStatusColumnMovesTheHingeLeading() throws {
        let layout = try #require(ContentSplitLayout.resolve(
            isRegularWidth: true,
            width: innerWidth,
            leadingInset: statusColumn,
            trailingInset: 0,
            division: nil
        ))

        #expect(layout.leadingWidth + layout.gapWidth / 2 == 391.5)
        #expect(layout.leadingWidth + layout.gapWidth + layout.trailingWidth == innerWidth)
    }

    @Test
    func compactWidthKeepsOneColumn() {
        #expect(ContentSplitLayout.resolve(
            isRegularWidth: false,
            width: innerWidth,
            leadingInset: 0,
            trailingInset: statusColumn,
            division: CGRect(x: 455.5, y: 0, width: 40, height: 669)
        ) == nil)
    }

    /// The inner display held upright: regular width, but 669pt can't hold
    /// two 340pt columns.
    @Test
    func innerPortraitKeepsOneColumn() {
        #expect(ContentSplitLayout.resolve(
            isRegularWidth: true,
            width: 669,
            leadingInset: 0,
            trailingInset: 0,
            division: nil
        ) == nil)
    }

    @Test
    func horizontalFoldKeepsOneColumn() {
        #expect(ContentSplitLayout.resolve(
            isRegularWidth: true,
            width: innerWidth,
            leadingInset: 0,
            trailingInset: statusColumn,
            division: CGRect(x: 0, y: 300, width: innerWidth, height: 40)
        ) == nil)
    }

    @Test
    func foldLeavingANarrowSideKeepsOneColumn() {
        #expect(ContentSplitLayout.resolve(
            isRegularWidth: true,
            width: innerWidth,
            leadingInset: 0,
            trailingInset: statusColumn,
            division: CGRect(x: 300, y: 0, width: 40, height: 669)
        ) == nil)
        #expect(ContentSplitLayout.resolve(
            isRegularWidth: true,
            width: innerWidth,
            leadingInset: 0,
            trailingInset: statusColumn,
            division: CGRect(x: 520, y: 0, width: 40, height: 669)
        ) == nil)
    }
}
#endif
