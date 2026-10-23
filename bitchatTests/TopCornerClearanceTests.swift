import CoreGraphics
import Testing
@testable import bitchat

/// Corner and safe-area sizes as the iPhone Duo simulator (iOS 27.1)
/// reports them, plus a Dynamic Island iPhone for comparison.
struct TopCornerClearanceTests {
    /// Inner display: the header sits at y = 0 beside a 55pt corner.
    @Test
    func innerDisplayCornerPadsTheHeader() {
        #expect(TopCornerClearance.extraPadding(
            cornerWidth: 55,
            cornerHeight: 55,
            safeTop: 0,
            safeEdgeInset: 0,
            basePadding: 12
        ) == 43)
    }

    /// Outer display, hinge side: an 8pt corner is inside the base padding.
    @Test
    func smallCornerNeedsNothing() {
        #expect(TopCornerClearance.extraPadding(
            cornerWidth: 8,
            cornerHeight: 8,
            safeTop: 0,
            safeEdgeInset: 0,
            basePadding: 12
        ) == 0)
    }

    /// The vertical status column is reported as a corner, but the trailing
    /// safe-area inset already keeps the header clear of it.
    @Test
    func statusColumnBehindTheSafeAreaNeedsNothing() {
        #expect(TopCornerClearance.extraPadding(
            cornerWidth: 84,
            cornerHeight: 174,
            safeTop: 0,
            safeEdgeInset: 84,
            basePadding: 12
        ) == 0)
    }

    /// Regular iPhones: the status bar's inset already clears the corner.
    @Test
    func statusBarAboveTheCornerNeedsNothing() {
        #expect(TopCornerClearance.extraPadding(
            cornerWidth: 55,
            cornerHeight: 55,
            safeTop: 59,
            safeEdgeInset: 0,
            basePadding: 12
        ) == 0)
    }
}
