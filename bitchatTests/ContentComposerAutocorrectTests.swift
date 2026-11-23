//
// ContentComposerAutocorrectTests.swift
// bitchatTests
//

import Testing
@testable import bitchat

struct ContentComposerAutocorrectTests {
    @Test func autocorrectionEnabledForNormalMessages() {
        #expect(!ContentComposerView.shouldDisableAutocorrection(for: "hello world", isAutocompleting: false))
        #expect(!ContentComposerView.shouldDisableAutocorrection(for: "", isAutocompleting: false))
    }

    @Test func autocorrectionDisabledForSlashCommandsAndAutocomplete() {
        #expect(ContentComposerView.shouldDisableAutocorrection(for: "/nick alice", isAutocompleting: false))
        #expect(ContentComposerView.shouldDisableAutocorrection(for: "  /nick qwerty", isAutocompleting: false))
        #expect(ContentComposerView.shouldDisableAutocorrection(for: "hey @al", isAutocompleting: true))
    }
}
