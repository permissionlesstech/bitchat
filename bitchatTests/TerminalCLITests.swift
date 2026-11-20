#if os(macOS)
import Foundation
import Testing
@testable import bitchat

struct TerminalCLITests {
    private let samplePeers: [(name: String, peerID: String, status: String)] = [
        (name: "alice", peerID: "a1b2c3d4", status: "BLE connected"),
        (name: "bob", peerID: "deadbeef", status: "mesh reachable"),
        (name: "alex", peerID: "cafe0123", status: "nostr available")
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
}
#endif
