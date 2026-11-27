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

    @Test("Mention token detection is true exactly where suggestions are possible")
    func hasMentionTokenMatchesSuggestionContext() {
        let service = AutocompleteService()
        let samples: [(text: String, cursor: Int, hasToken: Bool)] = [
            ("", 0, false),
            ("plain text", 10, false),
            ("hi @al there", 12, false),
            ("a @b-c", 6, false),
            ("@", 1, true),
            ("hi @al", 6, true),
            ("hi @al there", 6, true),
            ("@@al", 4, true),
            ("salut @émi", 10, true),
            ("@x_1", 4, true),
            ("mail me@host", 12, true)
        ]

        for sample in samples {
            #expect(
                AutocompleteService.hasMentionToken(in: sample.text, cursorPosition: sample.cursor) == sample.hasToken,
                "\(sample.text) @ \(sample.cursor)"
            )
            // A peer named after the token's own prefix always matches it, so
            // suggestions appear exactly when a token is detected.
            let prefix = String(sample.text.prefix(sample.cursor).split(separator: "@", omittingEmptySubsequences: false).last ?? "")
            let result = service.getSuggestions(
                for: sample.text,
                peers: [prefix + "z"],
                cursorPosition: sample.cursor
            )
            #expect(result.suggestions.isEmpty == !sample.hasToken, "\(sample.text) @ \(sample.cursor)")
        }
    }

    @Test("Applying suggestions replaces the range")
    func applySuggestionReplacesRange() {
        let service = AutocompleteService()

        let mentionResult = service.applySuggestion("@alice", to: "hi @al", range: NSRange(location: 3, length: 3))

        #expect(mentionResult == "hi @alice")
    }
}
