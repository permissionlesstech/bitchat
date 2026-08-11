import BitFoundation
import Foundation
import Testing
@testable import bitchat

struct ThreadMessageSearchTests {
    private func message(
        id: String,
        sender: String,
        content: String
    ) -> BitchatMessage {
        BitchatMessage(
            id: id,
            sender: sender,
            content: content,
            timestamp: Date(),
            isRelay: false,
            senderPeerID: PeerID(str: "0011223344556677")
        )
    }

    @Test("empty query returns the original timeline")
    func emptyQueryReturnsAll() {
        let messages = [
            message(id: "1", sender: "alice", content: "hello mesh"),
            message(id: "2", sender: "bob", content: "wave back")
        ]

        let result = ThreadMessageSearch.matchingMessages(in: messages, query: "   ")
        #expect(result == messages)
    }

    @Test("matches message body case-insensitively")
    func matchesContent() {
        let messages = [
            message(id: "1", sender: "alice", content: "Meet at NOON"),
            message(id: "2", sender: "bob", content: "see you later")
        ]

        let result = ThreadMessageSearch.matchingMessages(in: messages, query: "noon")
        #expect(result.map(\.id) == ["1"])
    }

    @Test("matches sender nickname")
    func matchesSender() {
        let messages = [
            message(id: "1", sender: "alice", content: "ping"),
            message(id: "2", sender: "mallory", content: "pong")
        ]

        let result = ThreadMessageSearch.matchingMessages(in: messages, query: "MALL")
        #expect(result.map(\.id) == ["2"])
    }

    @Test("skips whitespace-only message bodies")
    func skipsBlankBodies() {
        let messages = [
            message(id: "1", sender: "alice", content: "   "),
            message(id: "2", sender: "bob", content: "visible")
        ]

        let result = ThreadMessageSearch.matchingMessages(in: messages, query: "alice")
        #expect(result.isEmpty)
    }

    @Test("returns empty when nothing matches")
    func noMatches() {
        let messages = [
            message(id: "1", sender: "alice", content: "hello")
        ]

        let result = ThreadMessageSearch.matchingMessages(in: messages, query: "missing")
        #expect(result.isEmpty)
    }

    // MARK: - Result cap

    /// Search bypasses the message window, so without a cap a common term in a
    /// long thread renders every historical match in one pass.
    @Test("Results are capped at the limit")
    func resultsAreCapped() {
        let messages = (0..<500).map { message(id: "m\($0)", sender: "alice", content: "needle \($0)") }
        let matches = ThreadMessageSearch.matchingMessages(in: messages, query: "needle", limit: 200)
        #expect(matches.count == 200)
    }

    @Test("The cap keeps the newest matches")
    func capKeepsNewestMatches() {
        let messages = (0..<10).map { message(id: "m\($0)", sender: "alice", content: "needle \($0)") }
        let matches = ThreadMessageSearch.matchingMessages(in: messages, query: "needle", limit: 3)
        #expect(matches.map(\.id) == ["m7", "m8", "m9"])
    }

    @Test("A result set under the cap is returned whole")
    func underCapIsUntouched() {
        let messages = (0..<5).map { message(id: "m\($0)", sender: "alice", content: "needle") }
        #expect(ThreadMessageSearch.matchingMessages(in: messages, query: "needle", limit: 200).count == 5)
    }

    @Test("A non-positive limit disables the cap")
    func nonPositiveLimitIsUncapped() {
        let messages = (0..<300).map { message(id: "m\($0)", sender: "alice", content: "needle") }
        #expect(ThreadMessageSearch.matchingMessages(in: messages, query: "needle", limit: 0).count == 300)
    }

    @Test("Truncation is reported only when it happened")
    func truncationFlag() {
        #expect(ThreadMessageSearch.didTruncate(matchCount: 201, limit: 200))
        #expect(!ThreadMessageSearch.didTruncate(matchCount: 200, limit: 200))
        #expect(!ThreadMessageSearch.didTruncate(matchCount: 5, limit: 200))
        #expect(!ThreadMessageSearch.didTruncate(matchCount: 5, limit: 0))
    }
}
