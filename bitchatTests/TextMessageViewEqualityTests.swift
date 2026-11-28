import Foundation
import Testing
import BitFoundation
@testable import bitchat

/// `TextMessageView` is used with `.equatable()`, so its `==` decides when
/// SwiftUI skips a row. Each test changes one input of `==`.
@MainActor
struct TextMessageViewEqualityTests {
    private func makeMessage() -> BitchatMessage {
        BitchatMessage(
            id: "dm-equality-1",
            sender: "anon",
            content: "hello",
            timestamp: Date(timeIntervalSince1970: 10),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "builder",
            deliveryStatus: .sent
        )
    }

    @Test
    func sameMessageAndValuesCompareEqual() {
        let message = makeMessage()
        let reactions = [AggregatedReaction(emoji: "👍", count: 1, includesCurrentUser: false)]

        // Closures are not compared, so new closures still let SwiftUI skip the row.
        let first = TextMessageView(message: message, reactions: reactions, onToggleReaction: { _ in })
        let second = TextMessageView(message: message, reactions: reactions, onToggleReaction: { _ in })

        #expect(first == second)
    }

    @Test
    func statusChangedInPlaceComparesDifferent() {
        // The store changes the status on the same object, for example on a read receipt.
        let message = makeMessage()
        let before = TextMessageView(message: message)
        message.deliveryStatus = .read(by: "builder", at: Date(timeIntervalSince1970: 20))
        let after = TextMessageView(message: message)

        #expect(before != after)
    }

    @Test
    func newObjectWithSameIDComparesDifferent() {
        // Some code paths replace a message with a new object under the same id.
        let before = TextMessageView(message: makeMessage())
        let after = TextMessageView(message: makeMessage())

        #expect(before != after)
    }

    @Test
    func changedReactionsCompareDifferent() {
        let message = makeMessage()
        let before = TextMessageView(message: message)
        let after = TextMessageView(
            message: message,
            reactions: [AggregatedReaction(emoji: "👍", count: 1, includesCurrentUser: true)]
        )

        #expect(before != after)
    }

    @Test
    func changedHighlightComparesDifferent() {
        let message = makeMessage()
        let before = TextMessageView(message: message)
        let after = TextMessageView(message: message, isHighlighted: true)

        #expect(before != after)
    }
}
