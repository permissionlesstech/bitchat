//
// ChatComposerCoordinatorTargetTests.swift
// bitchatTests
//
// Autocomplete as a function of a target: each composer is offered the
// people of its own conversation and the commands that work there, and the
// result is a value only that composer keeps.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Testing
import BitFoundation
@testable import bitchat

@MainActor
struct ChatComposerCoordinatorTargetTests {
    private static let geohash = GeohashChannel(level: .city, geohash: "u4pruydq")
    private static let geoChannel = ChannelID.location(geohash)
    private static let meshPeer = PeerID(str: "1111111111111111")
    private static let geoDM = PeerID(nostr_: String(repeating: "ab", count: 32))

    private func makeContext() -> MockChatComposerContext {
        let context = MockChatComposerContext()
        context.meshNicknamesByPeerID = [
            PeerID(str: "2222222222222222"): "alice",
            PeerID(str: "3333333333333333"): "bob"
        ]
        context.geoNicknames = ["aaaabbbbccccdddd": "carol"]
        return context
    }

    @Test func meshTargetsOfferMeshPeersWhileAGeohashIsSelected() {
        let context = makeContext()
        context.activeChannel = Self.geoChannel
        let coordinator = ChatComposerCoordinator(context: context)

        _ = coordinator.autocomplete(for: "@", cursorPosition: 1, in: .mesh)
        // A mesh DM or group, even scoped to the selected geohash, is mesh too.
        _ = coordinator.autocomplete(for: "@", cursorPosition: 1, in: ConversationTarget(channel: Self.geoChannel, privatePeer: Self.meshPeer))

        #expect(context.queriedPeerCandidates == [["alice", "bob"], ["alice", "bob"]])
    }

    @Test func geohashTargetsOfferTheLiveGeohashsPeopleOnly() {
        let context = makeContext()
        let coordinator = ChatComposerCoordinator(context: context)
        let geohashTarget = ConversationTarget.publicChannel(Self.geoChannel)
        let geohashDM = ConversationTarget(channel: Self.geoChannel, privatePeer: Self.geoDM)

        context.activeChannel = Self.geoChannel
        _ = coordinator.autocomplete(for: "@", cursorPosition: 1, in: geohashTarget)
        _ = coordinator.autocomplete(for: "@", cursorPosition: 1, in: geohashDM)
        #expect(context.queriedPeerCandidates == [["carol#dddd"], ["carol#dddd"]])

        // The nicknames on hand are the selected geohash's; another geohash
        // (or #mesh) being selected means nobody to offer, not the wrong people.
        context.activeChannel = .location(GeohashChannel(level: .city, geohash: "9q8yyk"))
        _ = coordinator.autocomplete(for: "@", cursorPosition: 1, in: geohashTarget)
        context.activeChannel = .mesh
        _ = coordinator.autocomplete(for: "@", cursorPosition: 1, in: geohashTarget)
        #expect(context.queriedPeerCandidates.suffix(2) == [[], []])
    }

    @Test func theResultIsTheComposersOwnValue() {
        let context = makeContext()
        let coordinator = ChatComposerCoordinator(context: context)
        context.queryResult = (["@alice"], NSRange(location: 6, length: 3))

        let state = coordinator.autocomplete(for: "hello @al", cursorPosition: 9, in: .mesh)

        #expect(state == ComposerAutocompleteState(suggestions: ["@alice"], range: NSRange(location: 6, length: 3)))
        #expect(state.isShowing)

        var text = "hello @al"
        let cursor = coordinator.complete("@alice", in: &text, state: state)
        #expect(text == "hello @alice")
        #expect(cursor == 6 + "@alice".count + 1)

        var untouched = "hello @al"
        #expect(coordinator.complete("@alice", in: &untouched, state: ComposerAutocompleteState()) == untouched.count)
        #expect(untouched == "hello @al")

        context.queryResult = ([], nil)
        #expect(coordinator.autocomplete(for: "plain", cursorPosition: 5, in: .mesh) == ComposerAutocompleteState())
    }

    @Test func commandSuggestionsFollowTheTargetsContext() {
        func aliases(_ text: String, _ target: ConversationTarget) -> Set<String> {
            Set(ChatComposerCoordinator.commandSuggestions(for: text, in: target).map(\.alias))
        }
        let meshOnly: Set<String> = ["/fav", "/unfav", "/ping", "/trace", "/group"]

        let mesh = aliases("/", .mesh)
        #expect(meshOnly.isSubset(of: mesh))
        #expect(mesh.contains("/pay"))

        let geohash = aliases("/", .publicChannel(Self.geoChannel))
        #expect(meshOnly.isDisjoint(with: geohash))
        #expect(!geohash.contains("/pay"))

        // The same inputs as the processor's gates: a DM in a geohash scope
        // is offered what that scope accepts.
        let geohashDM = aliases("/", ConversationTarget(channel: Self.geoChannel, privatePeer: Self.geoDM))
        #expect(meshOnly.isDisjoint(with: geohashDM))
        #expect(geohashDM == Set(CommandInfo.all(isGeoPublic: true, isGeoDM: true).map(\.alias)))

        // The mesh pane keeps its mesh commands whatever else is selected.
        #expect(aliases("/", ConversationTarget(channel: .mesh, privatePeer: Self.meshPeer)) == mesh)

        #expect(aliases("/ms", .mesh) == ["/msg"])
        #expect(aliases("/msg al", .mesh) == ["/msg"])
        #expect(aliases("hello", .mesh).isEmpty)
    }
}
