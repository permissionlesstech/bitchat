import Testing
@testable import bitchat

struct ComposerAutocorrectTests {
    @Test func emptyAndProseKeepAutocorrectOn() {
        #expect(!ComposerAutocorrect.shouldDisable(for: "", cursorPosition: 0))
        #expect(!ComposerAutocorrect.shouldDisable(for: "hello there", cursorPosition: 11))
        #expect(!ComposerAutocorrect.shouldDisable(for: "hello there", cursorPosition: 5))
    }

    @Test func commandMentionAndChannelTokensDisableAutocorrect() {
        #expect(ComposerAutocorrect.shouldDisable(for: "/help", cursorPosition: 5))
        #expect(ComposerAutocorrect.shouldDisable(for: "/h", cursorPosition: 2))
        #expect(ComposerAutocorrect.shouldDisable(for: "@alice", cursorPosition: 6))
        #expect(ComposerAutocorrect.shouldDisable(for: "#u4pruy", cursorPosition: 7))
        #expect(ComposerAutocorrect.shouldDisable(for: "say @al", cursorPosition: 7))
        #expect(ComposerAutocorrect.shouldDisable(for: "go #u4", cursorPosition: 6))
        #expect(ComposerAutocorrect.shouldDisable(for: "run /bl", cursorPosition: 7))
    }

    @Test func finishedSpecialTokenFollowedBySpaceReenablesAutocorrect() {
        // Caret after the space starts a new (empty) prose token.
        #expect(!ComposerAutocorrect.shouldDisable(for: "@alice ", cursorPosition: 7))
        #expect(!ComposerAutocorrect.shouldDisable(for: "/help ", cursorPosition: 6))
        #expect(!ComposerAutocorrect.shouldDisable(for: "hi @alice more", cursorPosition: 14))
    }

    @Test func currentTokenSplitsOnWhitespace() {
        #expect(ComposerAutocorrect.currentToken(in: "a @bo", cursorPosition: 5) == "@bo")
        #expect(ComposerAutocorrect.currentToken(in: "/msg", cursorPosition: 4) == "/msg")
        #expect(ComposerAutocorrect.currentToken(in: "hi ", cursorPosition: 3) == "")
    }
}
