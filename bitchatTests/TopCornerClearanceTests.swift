import CoreGraphics
import SwiftUI
import Testing
@testable import bitchat

/// Corner and safe-area sizes as the iPhone Duo simulator (iOS 27.1) and an
/// iPhone 17 Pro report them left-to-right. Right-to-left reuses the Duo's
/// sizes under what Mac Catalyst and AppKit probes showed: display corners
/// keep their physical names while safe-area insets follow the layout
/// direction. One case is synthetic, for the top-inset guard.
struct TopCornerClearanceTests {
    /// The main header's content sits 12pt in from its bar.
    private let headerInset: CGFloat = 12

    /// Inner display: the header sits at y = 0 beside a 55pt corner. The
    /// vertical status column, reported as a rectangle in the other corner,
    /// is behind the trailing safe-area inset.
    @Test
    func innerDisplayCornerPadsTheHeader() {
        let clearance = TopCornerClearance(
            topLeft: CGSize(width: 55, height: 55),
            topRight: CGSize(width: 84, height: 124),
            safeArea: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 84),
            isRightToLeft: false
        )

        #expect(clearance == TopCornerClearance(leading: 55, trailing: 0))
        #expect(TopCornerClearance.padding(forReach: clearance.leading, contentInset: headerInset) == 43)
    }

    /// Outer display: the hinge-side corner is 8pt, inside the base padding.
    @Test
    func outerDisplayNeedsNothing() {
        let clearance = TopCornerClearance(
            topLeft: CGSize(width: 8, height: 8),
            topRight: CGSize(width: 84, height: 174),
            safeArea: EdgeInsets(top: 0, leading: 0, bottom: 34, trailing: 84),
            isRightToLeft: false
        )

        #expect(TopCornerClearance.padding(forReach: clearance.leading, contentInset: headerInset) == 0)
        #expect(TopCornerClearance.padding(forReach: clearance.trailing, contentInset: headerInset) == 0)
    }

    /// Right-to-left, the status column stays on the right, where it is the
    /// leading inset, and the 55pt corner on the left becomes the trailing
    /// side: on the split layout, the column's top rows meet it.
    @Test
    func rightToLeftPadsTheCornerOnItsPhysicalSide() {
        let clearance = TopCornerClearance(
            topLeft: CGSize(width: 55, height: 55),
            topRight: CGSize(width: 84, height: 124),
            safeArea: EdgeInsets(top: 0, leading: 84, bottom: 0, trailing: 0),
            isRightToLeft: true
        )

        #expect(clearance == TopCornerClearance(leading: 0, trailing: 55))
        #expect(TopCornerClearance.padding(forReach: clearance.trailing, contentInset: headerInset) == 43)
    }

    /// System UI in a corner can be named by layout direction instead
    /// (macOS's window controls are). Were the status column reported in the
    /// top-left slot right-to-left, pairing it with the left side's zero
    /// inset would pad the outer display's hinge side by 72pt; as a
    /// rectangle it is skipped.
    @Test
    func statusColumnNamedForTheOtherSideIsSkipped() {
        let clearance = TopCornerClearance(
            topLeft: CGSize(width: 84, height: 174),
            topRight: .zero,
            safeArea: EdgeInsets(top: 0, leading: 84, bottom: 34, trailing: 0),
            isRightToLeft: true
        )

        #expect(clearance == TopCornerClearance())
    }

    /// A regular iPhone reports its top corners relative to the status bar's
    /// inset: 0x0 on an iPhone 17 Pro, under a 62pt top inset.
    @Test
    func regularIPhoneNeedsNothing() {
        let clearance = TopCornerClearance(
            topLeft: .zero,
            topRight: .zero,
            safeArea: EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0),
            isRightToLeft: false
        )

        #expect(clearance == TopCornerClearance())
    }

    /// Synthetic: a corner no taller than the top safe-area inset ends above
    /// the bars. No measured display needs this guard; regular iPhones report
    /// 0x0 top corners, which need no padding either way.
    @Test
    func cornerAboveTheTopInsetNeedsNothing() {
        let clearance = TopCornerClearance(
            topLeft: CGSize(width: 55, height: 55),
            topRight: .zero,
            safeArea: EdgeInsets(top: 59, leading: 0, bottom: 0, trailing: 0),
            isRightToLeft: false
        )

        #expect(clearance == TopCornerClearance())
    }
}
