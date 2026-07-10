//
// ChatComposerCoordinatorContextTests.swift
// bitchatTests
//
// Exercises `ChatComposerCoordinator` against a mock `ChatComposerContext` —
// proving the coordinator works without a `ChatViewModel`, following the
// `ChatDeliveryCoordinatorContextTests` exemplar.
//
// Scope note: mention parsing uses the shared, precompiled
// `ChatViewModel.Patterns.mention` regex (a static, stateless singleton);
// everything else flows through the mock context.
//

import Testing
import Foundation
import BitFoundation
@testable import bitchat

// MARK: - Mock Context

/// Lightweight stand-in for `ChatComposerContext` proving that
/// `ChatComposerCoordinator` is testable without a `ChatViewModel`.
@MainActor
private final class MockChatComposerContext: ChatComposerContext {
    // Autocomplete UI state
    var autocompleteSuggestions: [String] = []
    var autocompleteRange: NSRange?
    var showAutocomplete = false
    var selectedAutocompleteIndex = -1
    var queryResult: (suggestions: [String], range: NSRange?) = ([], nil)
    private(set) var queriedPeerCandidates: [[String]] = []
    private(set) var appliedSuggestions: [(suggestion: String, text: String, range: NSRange)] = []

    func autocompleteQuery(
        for text: String,
        peers: [String],
        cursorPosition: Int
    ) -> (suggestions: [String], range: NSRange?) {
        queriedPeerCandidates.append(peers.sorted())
        return queryResult
    }

    func applyAutocompleteSuggestion(_ suggestion: String, to text: String, range: NSRange) -> String {
        appliedSuggestions.append((suggestion, text, range))
        guard let textRange = Range(range, in: text) else { return text }
        return text.replacingCharacters(in: textRange, with: suggestion)
    }

    // Identity & channel state
    var nickname = "me"
    var myPeerID = PeerID(str: "0011223344556677")
    var activeChannel: ChannelID = .mesh
    var meshNickname = "me"
    var meshNicknamesByPeerID: [PeerID: String] = [:]

    func meshPeerNicknames() -> [PeerID: String] { meshNicknamesByPeerID }

    // Geohash identity
    var geoNicknames: [String: String] = [:]
    static let dummyIdentity = NostrIdentity(
        privateKey: Data(repeating: 0x11, count: 32),
        publicKey: Data(repeating: 0x22, count: 32),
        npub: "npub1mock",
        createdAt: Date(timeIntervalSince1970: 0)
    )

    func deriveNostrIdentity(forGeohash geohash: String) throws -> NostrIdentity {
        Self.dummyIdentity
    }
}

// MARK: - Coordinator Tests Against Mock Context

/// Exercises `ChatComposerCoordinator` against `MockChatComposerContext` with
/// no `ChatViewModel`.
struct ChatComposerCoordinatorContextTests {

    @Test @MainActor
    func updateAutocomplete_onMesh_excludesOwnNicknameAndPublishesSuggestions() {
        let context = MockChatComposerContext()
        let coordinator = ChatComposerCoordinator(context: context)
        context.meshNicknamesByPeerID = [
            PeerID(str: "1111111111111111"): "alice",
            PeerID(str: "2222222222222222"): "bob",
            PeerID(str: "3333333333333333"): "me"
        ]

        // Matching query: suggestions and range are published, index resets.
        context.queryResult = (["@alice"], NSRange(location: 0, length: 3))
        coordinator.updateAutocomplete(for: "@al", cursorPosition: 3)
        #expect(context.queriedPeerCandidates == [["alice", "bob"]])
        #expect(context.autocompleteSuggestions == ["@alice"])
        #expect(context.autocompleteRange == NSRange(location: 0, length: 3))
        #expect(context.showAutocomplete)
        #expect(context.selectedAutocompleteIndex == 0)

        // No match: all autocomplete state is cleared.
        context.queryResult = ([], nil)
        context.selectedAutocompleteIndex = 3
        coordinator.updateAutocomplete(for: "plain text", cursorPosition: 5)
        #expect(context.autocompleteSuggestions.isEmpty)
        #expect(context.autocompleteRange == nil)
        #expect(!context.showAutocomplete)
        #expect(context.selectedAutocompleteIndex == 0)
    }

    @Test @MainActor
    func updateAutocomplete_onLocationChannel_buildsGeoTokensWithoutOwnToken() {
        let context = MockChatComposerContext()
        let coordinator = ChatComposerCoordinator(context: context)
        context.activeChannel = .location(GeohashChannel(level: .city, geohash: "u4pruydq"))
        context.geoNicknames = [
            "aaaabbbbccccdddd": "carol",
            // Own token (nickname#last-4-of-pubkey) must be removed; the dummy
            // identity's public key hex ends in "2222".
            "ffffeeeeddddcccc2222": "me"
        ]

        coordinator.updateAutocomplete(for: "@ca", cursorPosition: 3)
        #expect(context.queriedPeerCandidates == [["carol#dddd"]])
    }

    @Test @MainActor
    func completeNickname_appliesSuggestionResetsStateAndReturnsCursor() {
        let context = MockChatComposerContext()
        let coordinator = ChatComposerCoordinator(context: context)

        // Without an active range the text is untouched.
        var text = "hello @al"
        #expect(coordinator.completeNickname("@alice", in: &text) == text.count)
        #expect(context.appliedSuggestions.isEmpty)

        // With a range the suggestion is applied and state cleared.
        context.autocompleteRange = NSRange(location: 6, length: 3)
        context.autocompleteSuggestions = ["@alice"]
        context.showAutocomplete = true
        let cursor = coordinator.completeNickname("@alice", in: &text)
        #expect(text == "hello @alice")
        #expect(cursor == 6 + "@alice".count + 1)
        #expect(!context.showAutocomplete)
        #expect(context.autocompleteSuggestions.isEmpty)
        #expect(context.autocompleteRange == nil)
        #expect(context.selectedAutocompleteIndex == 0)
    }

    @Test @MainActor
    func parseMentions_acceptsKnownPeersOwnNicknameAndHashSuffix() {
        let context = MockChatComposerContext()
        let coordinator = ChatComposerCoordinator(context: context)
        context.meshNicknamesByPeerID = [PeerID(str: "1111111111111111"): "alice"]

        let mentions = coordinator.parseMentions(
            from: "hi @alice and @me and @me#0011 but not @stranger"
        )
        #expect(Set(mentions) == ["alice", "me", "me#0011"])
    }
}
