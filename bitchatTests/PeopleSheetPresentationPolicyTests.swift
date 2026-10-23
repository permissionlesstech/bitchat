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

    /// The sheet's setter skips its side effects when the getter already
    /// reads false. Unfolding with a DM open flips the layout first, so the
    /// dismissal SwiftUI reports afterwards must not look like a person
    /// leaving the conversation.
    @Test
    func unfoldingWithAnOpenConversationReadsAsAlreadyDismissed() {
        let beforeUnfold = PeopleSheetPresentationPolicy.isPresented(
            isSplitLayout: false,
            showSidebar: true,
            hasSelectedConversation: true
        )
        let afterUnfold = PeopleSheetPresentationPolicy.isPresented(
            isSplitLayout: true,
            showSidebar: true,
            hasSelectedConversation: true
        )

        #expect(beforeUnfold)
        #expect(!afterUnfold)
    }

    @Test
    func personDismissingTheSheetEndsTheConversation() {
        #expect(PeopleSheetPresentationPolicy.shouldEndConversationOnDismiss(
            sceneIsActive: true,
            alertPending: false
        ))
    }

    @Test
    func backgroundReconciliationKeepsTheConversation() {
        #expect(!PeopleSheetPresentationPolicy.shouldEndConversationOnDismiss(
            sceneIsActive: false,
            alertPending: false
        ))
    }

    @Test
    func alertTakingOverKeepsTheConversation() {
        #expect(!PeopleSheetPresentationPolicy.shouldEndConversationOnDismiss(
            sceneIsActive: true,
            alertPending: true
        ))
        #expect(!PeopleSheetPresentationPolicy.shouldEndConversationOnDismiss(
            sceneIsActive: false,
            alertPending: true
        ))
    }
}
