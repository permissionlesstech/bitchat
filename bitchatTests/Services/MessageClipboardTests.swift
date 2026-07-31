import Foundation
import Testing
@testable import bitchat

struct MessageClipboardTests {
    @Test func quoteWrapsEachLineAndAddsSender() {
        let quoted = MessageClipboard.quoteForComposer("hello\nworld", sender: "alice")
        #expect(quoted == "> @alice:\n> hello\n> world\n\n")
    }

    @Test func quoteSkipsSystemSenderHeader() {
        let quoted = MessageClipboard.quoteForComposer("joined", sender: "system")
        #expect(quoted == "> joined\n\n")
    }

    @Test func emptyContentYieldsEmptyQuote() {
        #expect(MessageClipboard.quoteForComposer("   ", sender: "alice").isEmpty)
    }

    @Test func appendQuotePreservesExistingDraft() {
        let result = MessageClipboard.appendQuote(
            to: "already typing",
            content: "prior message",
            sender: "bob"
        )
        #expect(result == "already typing\n> @bob:\n> prior message\n\n")
    }

    @Test func appendQuoteOntoEmptyDraft() {
        let result = MessageClipboard.appendQuote(
            to: "",
            content: "solo",
            sender: "carol"
        )
        #expect(result == "> @carol:\n> solo\n\n")
    }
}
