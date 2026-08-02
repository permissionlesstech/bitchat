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
}
