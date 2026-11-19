import Foundation
import Testing
@testable import bitchat

struct MessageClipboardTests {
    @Test func quoteWrapsEachLineAndAddsSender() {
        let quoted = MessageClipboard.quoteForComposer("hello\nworld", sender: "alice")
        #expect(quoted == "> alice:\n> hello\n> world\n\n")
    }

    @Test func quoteNeutralizesMentionsWithoutGrowingTheDraft() {
        let body = "👋 @bob#1234" + "\n" + "@@日本語 @🙂"
        let quote = MessageClipboard.quoteForComposer(body, sender: "@alice")
        let unsanitized = "> @alice:\n> 👋 @bob#1234\n> @@日本語 @🙂\n\n"

        #expect(MessageFormattingEngine.extractMentions(from: quote).isEmpty)
        #expect(quote.contains("bob#1234"))
        #expect(quote.contains("日本語"))
        #expect(quote.contains("@🙂"))
        #expect(quote.utf8.count == unsanitized.utf8.count)

        let draft = MessageClipboard.appendQuote(to: "hi @carol ", content: body, sender: "alice")
        #expect(MessageFormattingEngine.extractMentions(from: draft) == ["carol"])
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
        #expect(result == "already typing\n> bob:\n> prior message\n\n")
    }

    @Test func appendQuoteOntoEmptyDraft() {
        let result = MessageClipboard.appendQuote(
            to: "",
            content: "solo",
            sender: "carol"
        )
        #expect(result == "> carol:\n> solo\n\n")
    }

    @Test func appendQuoteAfterTrailingSpaceStartsNewLine() {
        let result = MessageClipboard.appendQuote(
            to: "draft with space ",
            content: "quoted",
            sender: "dana"
        )
        #expect(result == "draft with space \n> dana:\n> quoted\n\n")
    }
}
