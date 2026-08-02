import BitFoundation
import Foundation
import Testing

struct ChatPlaintextExporterTests {
    private static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func exportIncludesSealingWarningAndScope() {
        let message = BitchatMessage(
            sender: "alice",
            content: "hello mesh",
            timestamp: Self.fixedDate,
            isRelay: false
        )
        let text = ChatPlaintextExporter.exportText(
            messages: [message],
            context: ChatPlaintextExporter.Context(scopeTitle: "mesh", exportedAt: Self.fixedDate)
        )
        #expect(text.contains("bitchat export — mesh"))
        #expect(text.contains("warning: this file is unsealed plaintext"))
        #expect(text.contains("alice: hello mesh"))
    }

    @Test func emptyConversationStillWarns() {
        let text = ChatPlaintextExporter.exportText(
            messages: [],
            context: ChatPlaintextExporter.Context(scopeTitle: "dm with @bob", exportedAt: Self.fixedDate)
        )
        #expect(text.contains("warning: this file is unsealed plaintext"))
        #expect(text.contains("(no messages in this conversation)"))
    }

    @Test func messagesPreserveChronologicalOrder() {
        let first = BitchatMessage(
            sender: "a",
            content: "one",
            timestamp: Self.fixedDate,
            isRelay: false
        )
        let second = BitchatMessage(
            sender: "b",
            content: "two",
            timestamp: Self.fixedDate.addingTimeInterval(60),
            isRelay: false
        )
        let text = ChatPlaintextExporter.exportText(
            messages: [first, second],
            context: ChatPlaintextExporter.Context(scopeTitle: "mesh", exportedAt: Self.fixedDate)
        )
        let oneRange = text.range(of: "one")!
        let twoRange = text.range(of: "two")!
        #expect(oneRange.lowerBound < twoRange.lowerBound)
    }
}
