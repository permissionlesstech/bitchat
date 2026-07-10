import Foundation
import Testing
@testable import bitchat

@Suite("AutocompleteService Tests")
struct AutocompleteServiceTests {

    @Test("Mention suggestions are sorted, capped, and include replacement range")
    func mentionSuggestionsAreSortedAndCapped() {
        let service = AutocompleteService()
        let text = "hi @al"

        let result = service.getSuggestions(
            for: text,
            peers: ["zoe", "alice", "albert", "bob", "alex", "ally", "alpha"],
            cursorPosition: text.count
        )

        #expect(result.suggestions == ["@albert", "@alex", "@alice", "@ally", "@alpha"])
        #expect(result.range == NSRange(location: 3, length: 3))
    }

    @Test("Suggestions are empty when cursor is not at a trailing mention")
    func suggestionsRequireTrailingMentionContext() {
        let service = AutocompleteService()
        let text = "hi @al there"

        let result = service.getSuggestions(
            for: text,
            peers: ["alice", "albert"],
            cursorPosition: text.count
        )

        #expect(result.suggestions.isEmpty)
        #expect(result.range == nil)
    }

    @Test("Applying suggestions replaces the range and adds command spacing only when needed")
    func applySuggestionReplacesRangeAndHandlesCommandSpacing() {
        let service = AutocompleteService()

        let mentionResult = service.applySuggestion("@alice", to: "hi @al", range: NSRange(location: 3, length: 3))
        let msgCommand = service.applySuggestion("/msg", to: "/m", range: NSRange(location: 0, length: 2))
        let clearCommand = service.applySuggestion("/clear", to: "/c", range: NSRange(location: 0, length: 2))

        #expect(mentionResult == "hi @alice")
        #expect(msgCommand == "/msg ")
        #expect(clearCommand == "/clear")
    }
}
