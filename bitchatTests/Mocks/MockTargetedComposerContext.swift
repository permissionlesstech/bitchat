//
// MockTargetedComposerContext.swift
// bitchatTests
//
// A `ChatComposerContext` that records the mention candidates each query
// was handed, so autocomplete tests can see whose names a target offers.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import BitFoundation
@testable import bitchat

@MainActor
final class MockTargetedComposerContext: ChatComposerContext {
    // The shared published state the single composer reads.
    var autocompleteSuggestions: [String] = []
    var autocompleteRange: NSRange?
    var showAutocomplete = false
    var selectedAutocompleteIndex = 0

    /// What every query returns, so the candidates are what's under test.
    var queryResult: (suggestions: [String], range: NSRange?) = (["@x"], NSRange(location: 0, length: 1))
    private(set) var queriedCandidates: [[String]] = []

    func autocompleteQuery(
        for text: String,
        peers: [String],
        cursorPosition: Int
    ) -> (suggestions: [String], range: NSRange?) {
        queriedCandidates.append(peers.sorted())
        return queryResult
    }

    func applyAutocompleteSuggestion(_ suggestion: String, to text: String, range: NSRange) -> String {
        guard let textRange = Range(range, in: text) else { return text }
        return text.replacingCharacters(in: textRange, with: suggestion)
    }

    // Identity & channel state
    var nickname = "me"
    var myPeerID = PeerID(str: "0011223344556677")
    var activeChannel: ChannelID = .mesh
    var selectedPrivateChatPeer: PeerID?
    var meshNickname = "me"
    var meshNicknamesByPeerID: [PeerID: String] = [:]

    func meshPeerNicknames() -> [PeerID: String] { meshNicknamesByPeerID }
    func isMeshNicknameBlocked(_ nickname: String) -> Bool { false }
    func isNostrBlocked(pubkeyHexLowercased: String) -> Bool { false }

    // Geohash identity: the selected geohash's nicknames.
    var geoNicknames: [String: String] = [:]

    func deriveNostrIdentity(forGeohash geohash: String) throws -> NostrIdentity {
        NostrIdentity(
            privateKey: Data(repeating: 0x11, count: 32),
            publicKey: Data(repeating: 0x22, count: 32),
            npub: "npub1mock",
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }
}
