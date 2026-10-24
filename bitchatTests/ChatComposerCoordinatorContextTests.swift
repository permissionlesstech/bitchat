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
    var blockedMeshNicknames: Set<String> = []
    var blockedNostrPubkeys: Set<String> = []

    func meshPeerNicknames() -> [PeerID: String] { meshNicknamesByPeerID }

    func isMeshNicknameBlocked(_ nickname: String) -> Bool {
        blockedMeshNicknames.contains(nickname)
    }

    func isNostrBlocked(pubkeyHexLowercased: String) -> Bool {
        blockedNostrPubkeys.contains(pubkeyHexLowercased.lowercased())
    }

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
    func autocomplete_onMesh_excludesOwnNicknameAndReturnsSuggestions() {
        let context = MockChatComposerContext()
        let coordinator = ChatComposerCoordinator(context: context)
        context.meshNicknamesByPeerID = [
            PeerID(str: "1111111111111111"): "alice",
            PeerID(str: "2222222222222222"): "bob",
            PeerID(str: "3333333333333333"): "me"
        ]

        // Matching query: suggestions and range come back, index at the top.
        context.queryResult = (["@alice"], NSRange(location: 0, length: 3))
        let state = coordinator.autocomplete(for: "@al", cursorPosition: 3, in: .mesh)
        #expect(context.queriedPeerCandidates == [["alice", "bob"]])
        #expect(state.suggestions == ["@alice"])
        #expect(state.range == NSRange(location: 0, length: 3))
        #expect(state.isShowing)
        #expect(state.selectedIndex == 0)

        // No match: no autocomplete state.
        context.queryResult = ([], nil)
        let cleared = coordinator.autocomplete(for: "plain text", cursorPosition: 5, in: .mesh)
        #expect(cleared.suggestions.isEmpty)
        #expect(cleared.range == nil)
        #expect(!cleared.isShowing)
        #expect(cleared.selectedIndex == 0)
    }

    @Test @MainActor
    func autocomplete_onLocationChannel_buildsGeoTokensWithoutOwnToken() {
        let context = MockChatComposerContext()
        let coordinator = ChatComposerCoordinator(context: context)
        context.activeChannel = .location(GeohashChannel(level: .city, geohash: "u4pruydq"))
        context.geoNicknames = [
            "aaaabbbbccccdddd": "carol",
            // Own token (nickname#last-4-of-pubkey) must be removed; the dummy
            // identity's public key hex ends in "2222".
            "ffffeeeeddddcccc2222": "me"
        ]

        _ = coordinator.autocomplete(for: "@ca", cursorPosition: 3, in: .publicChannel(context.activeChannel))
        #expect(context.queriedPeerCandidates == [["carol#dddd"]])
    }

    @Test @MainActor
    func autocomplete_excludesBlockedMeshAndGeohashPeers() {
        let context = MockChatComposerContext()
        let coordinator = ChatComposerCoordinator(context: context)
        context.meshNicknamesByPeerID = [
            PeerID(str: "1111111111111111"): "alice",
            PeerID(str: "2222222222222222"): "eve",
            PeerID(str: "3333333333333333"): "me"
        ]
        context.blockedMeshNicknames = ["eve"]
        context.queryResult = (["@alice"], NSRange(location: 0, length: 3))

        _ = coordinator.autocomplete(for: "@a", cursorPosition: 2, in: .mesh)
        #expect(context.queriedPeerCandidates == [["alice"]])

        let geoContext = MockChatComposerContext()
        let geoCoordinator = ChatComposerCoordinator(context: geoContext)
        geoContext.activeChannel = .location(GeohashChannel(level: .city, geohash: "u4pruydq"))
        geoContext.geoNicknames = [
            "aaaabbbbccccdddd": "carol",
            "bbbbccccddddeeee": "blocked"
        ]
        geoContext.blockedNostrPubkeys = ["bbbbccccddddeeee"]

        _ = geoCoordinator.autocomplete(for: "@", cursorPosition: 1, in: .publicChannel(geoContext.activeChannel))
        #expect(geoContext.queriedPeerCandidates == [["carol#dddd"]])
    }

    @Test @MainActor
    func autocomplete_withoutMentionTokenAtCursor_skipsCandidateQuery() {
        let context = MockChatComposerContext()
        let coordinator = ChatComposerCoordinator(context: context)
        context.meshNicknamesByPeerID = [PeerID(str: "1111111111111111"): "alice"]
        context.queryResult = (["@alice"], NSRange(location: 3, length: 3))

        // Plain text, and a mention that no longer ends at the cursor: the
        // query could not suggest anything, so it never runs.
        let plain = coordinator.autocomplete(for: "plain text", cursorPosition: 10, in: .mesh)
        let moved = coordinator.autocomplete(for: "hi @al there", cursorPosition: 12, in: .mesh)
        #expect(context.queriedPeerCandidates.isEmpty)
        #expect(plain.suggestions.isEmpty && moved.suggestions.isEmpty)
        #expect(!plain.isShowing && !moved.isShowing)

        // The same text with the cursor right after the token queries.
        let state = coordinator.autocomplete(for: "hi @al there", cursorPosition: 6, in: .mesh)
        #expect(context.queriedPeerCandidates == [["alice"]])
        #expect(state.suggestions == ["@alice"])
        #expect(state.isShowing)
    }

    @Test @MainActor
    func complete_appliesSuggestionAndReturnsCursor() {
        let context = MockChatComposerContext()
        let coordinator = ChatComposerCoordinator(context: context)

        // Without an active range the text is untouched.
        var text = "hello @al"
        #expect(coordinator.complete("@alice", in: &text, state: ComposerAutocompleteState()) == text.count)
        #expect(context.appliedSuggestions.isEmpty)

        // With a range the suggestion is applied.
        let state = ComposerAutocompleteState(suggestions: ["@alice"], range: NSRange(location: 6, length: 3))
        let cursor = coordinator.complete("@alice", in: &text, state: state)
        #expect(text == "hello @alice")
        #expect(cursor == 6 + "@alice".count + 1)
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
