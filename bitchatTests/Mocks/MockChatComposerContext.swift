//
// MockChatComposerContext.swift
// bitchatTests
//
// A `ChatComposerContext` that records the mention candidates each query
// was handed and the suggestions applied, so autocomplete tests can see
// whose names a target offers, without a `ChatViewModel`.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import BitFoundation
@testable import bitchat

@MainActor
final class MockChatComposerContext: ChatComposerContext {
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
