#if os(macOS)
import Foundation
import Testing
@testable import bitchat

struct TerminalCLITests {
    private let samplePeers: [TerminalPeerEntry] = [
        TerminalPeerEntry(name: "alice", peerID: "a1b2c3d4", status: "BLE connected"),
        TerminalPeerEntry(name: "bob", peerID: "deadbeef", status: "mesh reachable"),
        TerminalPeerEntry(name: "alex", peerID: "cafe0123", status: "nostr available")
    ]

    @Test func nonSlashInputProducesNoSuggestions() {
        #expect(TerminalCommandCatalog.suggestions(for: "", peers: samplePeers).isEmpty)
        #expect(TerminalCommandCatalog.suggestions(for: "hello world", peers: samplePeers).isEmpty)
    }

    @Test func bareSlashListsAllCommands() {
        let results = TerminalCommandCatalog.suggestions(for: "/", peers: samplePeers)
        #expect(results.count == TerminalCommandCatalog.commands.count)
    }

    @Test func prefixMatchingOrdersCommandMatchesAndAddsTrailingSpaceWhenExpected() {
        let dmMatches = TerminalCommandCatalog.suggestions(for: "/d", peers: samplePeers)
        #expect(dmMatches.first?.completion == "/dm ")

        let peersMatches = TerminalCommandCatalog.suggestions(for: "/pe", peers: samplePeers)
        #expect(peersMatches.count == 1)
        #expect(peersMatches.first?.completion == "/peers")
    }

    @Test func substringFallbackFindsMatchingCommands() {
        let matches = TerminalCommandCatalog.suggestions(for: "/block", peers: samplePeers)
        let labels = matches.map(\.label)
        #expect(labels.contains("/block @<nick>"))
        #expect(labels.contains("/unblock @<nick>"))
        #expect(labels.first == "/block @<nick>")
    }

    @Test func dmCommandCompletesPeersByNicknameAndPeerID() {
        let allPeers = TerminalCommandCatalog.suggestions(for: "/dm ", peers: samplePeers)
        #expect(allPeers.count == 3)
        #expect(allPeers[0].completion == "/dm alice ")

        let byNick = TerminalCommandCatalog.suggestions(for: "/dm al", peers: samplePeers)
        #expect(byNick.map(\.label) == ["/dm alice", "/dm alex"])

        let byPeerID = TerminalCommandCatalog.suggestions(for: "/dm dead", peers: samplePeers)
        #expect(byPeerID.map(\.label) == ["/dm bob"])
    }

    @Test func dmSuggestionsDisambiguateCollidingPeerNamesWithPeerIDs() {
        let collidingPeers = [
            TerminalPeerEntry(name: "alice", peerID: "1111aaaa", status: "BLE connected"),
            TerminalPeerEntry(name: "Alice", peerID: "2222bbbb", status: "mesh reachable")
        ]
        let matches = TerminalCommandCatalog.suggestions(for: "/dm al", peers: collidingPeers)
        #expect(matches.count == 2)
        #expect(matches[0].completion == "/dm 1111aaaa ")
        #expect(matches[1].completion == "/dm 2222bbbb ")
    }

    @Test func resolvePeerRejectsAmbiguousNamesAndResolvesUniquePeerID() {
        let collidingPeers = [
            TerminalPeerEntry(name: "alice", peerID: "1111aaaa", status: "BLE connected"),
            TerminalPeerEntry(name: "Alice", peerID: "2222bbbb", status: "mesh reachable")
        ]
        let ambiguous = TerminalCommandCatalog.resolvePeer(
            matching: "alice",
            in: collidingPeers,
            names: { [$0.name] },
            peerID: { $0.peerID }
        )
        if case .ambiguous(let matches) = ambiguous {
            #expect(matches.count == 2)
        } else {
            Issue.record("Expected ambiguous match for colliding nicknames")
        }

        let unique = TerminalCommandCatalog.resolvePeer(
            matching: "2222bbbb",
            in: collidingPeers,
            names: { [$0.name] },
            peerID: { $0.peerID }
        )
        if case .unique(let peer) = unique {
            #expect(peer.peerID == "2222bbbb")
        } else {
            Issue.record("Expected unique match for exact peer ID")
        }
    }

    @Test func msgCommandCompletesPeersWithAtPrefix() {
        let matches = TerminalCommandCatalog.suggestions(for: "/msg @b", peers: samplePeers)
        #expect(matches.count == 1)
        #expect(matches.first?.completion == "/msg @bob ")
        #expect(matches.first?.label == "/msg @bob")
    }

    @Test func suggestionsStopAfterFirstArgumentOrForNonPeerCommands() {
        #expect(TerminalCommandCatalog.suggestions(for: "/dm alice hello", peers: samplePeers).isEmpty)
        #expect(TerminalCommandCatalog.suggestions(for: "/nick a", peers: samplePeers).isEmpty)
    }

    @Test func sanitizerStripsANSISequencesAndControlCharacters() {
        let malicious = "hi \u{001B}[2J\u{001B}[H\r\u{001B}]0;spoof\u{0007}world\u{0008}!"
        #expect(TerminalSanitizer.sanitize(malicious) == "hi world!")

        let multiline = "line1\nline2\r\nline3"
        #expect(TerminalSanitizer.sanitize(multiline, allowNewlines: true) == "line1\nline2\nline3")
        #expect(TerminalSanitizer.sanitize(multiline, allowNewlines: false) == "line1 line2 line3")
    }
}
#endif
