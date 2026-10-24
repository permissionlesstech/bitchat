import Testing
@testable import bitchat

struct PeopleSheetPresentationPolicyTests {
    @Test
    func compactPresentsForThePeopleListOrAnOpenConversation() {
        #expect(PeopleSheetPresentationPolicy.isPresented(
            isSplitLayout: false,
            showSidebar: true,
            hasSelectedConversation: false
        ))
        #expect(PeopleSheetPresentationPolicy.isPresented(
            isSplitLayout: false,
            showSidebar: false,
            hasSelectedConversation: true
        ))
        #expect(PeopleSheetPresentationPolicy.isPresented(
            isSplitLayout: false,
            showSidebar: true,
            hasSelectedConversation: true
        ))
    }

    @Test
    func compactStaysClosedWithNothingToShow() {
        #expect(!PeopleSheetPresentationPolicy.isPresented(
            isSplitLayout: false,
            showSidebar: false,
            hasSelectedConversation: false
        ))
    }

    @Test
    func splitLayoutNeverPresentsTheSheet() {
        for showSidebar in [false, true] {
            for hasSelectedConversation in [false, true] {
                #expect(!PeopleSheetPresentationPolicy.isPresented(
                    isSplitLayout: true,
                    showSidebar: showSidebar,
                    hasSelectedConversation: hasSelectedConversation
                ))
            }
        }
    }

    /// Unfolding with a DM open flips the layout and clears the sidebar flag
    /// before SwiftUI reports the departing sheet's dismissal. The getter
    /// then already reads false, and the DM, now in the column, must stay
    /// open whatever the scene and alerts are doing.
    @Test
    func layoutDrivenDismissalIsIgnored() {
        let stillPresented = PeopleSheetPresentationPolicy.isPresented(
            isSplitLayout: true,
            showSidebar: false,
            hasSelectedConversation: true
        )
        #expect(!stillPresented)

        for sceneIsActive in [true, false] {
            for alertPending in [true, false] {
                #expect(PeopleSheetPresentationPolicy.dismissal(
                    sheetStillPresented: stillPresented,
                    sceneIsActive: sceneIsActive,
                    alertPending: alertPending
                ) == .ignore)
            }
        }
    }

    @Test
    func personDismissingTheSheetEndsTheConversation() {
        #expect(PeopleSheetPresentationPolicy.dismissal(
            sheetStillPresented: true,
            sceneIsActive: true,
            alertPending: false
        ) == .endConversation)
    }

    @Test
    func backgroundReconciliationKeepsTheConversation() {
        #expect(PeopleSheetPresentationPolicy.dismissal(
            sheetStillPresented: true,
            sceneIsActive: false,
            alertPending: false
        ) == .closeList)
    }

    @Test
    func alertTakingOverKeepsTheConversation() {
        #expect(PeopleSheetPresentationPolicy.dismissal(
            sheetStillPresented: true,
            sceneIsActive: true,
            alertPending: true
        ) == .closeList)
        #expect(PeopleSheetPresentationPolicy.dismissal(
            sheetStillPresented: true,
            sceneIsActive: false,
            alertPending: true
        ) == .closeList)
    }
}
