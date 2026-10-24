//
// MessageListChannelPolicyTests.swift
// bitchatTests
//
// A message list draws its notes strip, its nearby-notes hold, its empty
// state and its ambient footer from the channel of the timeline it renders,
// never from the selection: the split layout's #mesh list renders beside a
// selected geohash.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation
import Testing
@testable import bitchat

private let selectedGeohash = ChannelID.location(GeohashChannel(level: .city, geohash: "u4pru"))

@MainActor
private func makeRow(id: String, sender: String = "alice") -> BitchatMessage {
    BitchatMessage(
        id: id,
        sender: sender,
        content: "row \(id)",
        timestamp: Date(),
        isRelay: false,
        senderPeerID: PeerID(str: "aabbccddeeff0011")
    )
}

@Suite("MessageListChannelPolicy")
@MainActor
struct MessageListChannelPolicyTests {
    /// The pinned #mesh pane while a geohash is selected: every decision is
    /// #mesh's, taken from the pane's own model.
    @Test("the pinned #mesh list decides as #mesh while a geohash is selected")
    func pinnedMeshList_decidesAsMeshBesideASelectedGeohash() {
        let store = ConversationStore()
        store.setActiveChannel(selectedGeohash)
        let meshPane = PublicChatModel(conversations: store, pinnedTo: .mesh)

        let policy = MessageListChannelPolicy(channel: meshPane.channel, privatePeer: nil)

        #expect(policy.holdsNotesCounter)
        #expect(policy.showsNotesStrip(noteCount: 2))
        #expect(!policy.showsNotesStrip(noteCount: 0))
        #expect(policy.emptyState == .mesh)
        #expect(policy.showsAmbientFooter(below: [makeRow(id: "notice", sender: "system")]))
    }

    /// The trailing geohash list: no notes, no ambient layer, and the empty
    /// state names its own geohash.
    @Test("a geohash list names its geohash and never shows #mesh's chrome")
    func geohashList_namesItsGeohash() {
        let store = ConversationStore()
        store.setActiveChannel(selectedGeohash)
        let selected = PublicChatModel(conversations: store)

        let policy = MessageListChannelPolicy(channel: selected.channel, privatePeer: nil)

        #expect(!policy.holdsNotesCounter)
        #expect(!policy.showsNotesStrip(noteCount: 2))
        #expect(policy.emptyState == .location(geohash: "u4pru"))
        #expect(!policy.showsAmbientFooter(below: [makeRow(id: "notice", sender: "system")]))
    }

    @Test("a private list shows none of a public timeline's chrome")
    func privateList_showsNoPublicChrome() {
        let peer = PeerID(str: "0102030405060708")
        for policy in [
            MessageListChannelPolicy(channel: .mesh, privatePeer: peer),
            MessageListChannelPolicy(channel: nil, privatePeer: peer),
            MessageListChannelPolicy(channel: nil, privatePeer: nil)
        ] {
            #expect(!policy.holdsNotesCounter)
            #expect(!policy.showsNotesStrip(noteCount: 2))
            #expect(policy.emptyState == nil)
            #expect(!policy.showsAmbientFooter(below: [makeRow(id: "notice", sender: "system")]))
        }
    }

    /// The ambient layer stays below #mesh rows only while they are carried
    /// history and system lines: no live conversation yet.
    @Test("the #mesh ambient footer follows only echoes and system lines")
    func meshAmbientFooter_followsOnlyEchoesAndSystemLines() {
        let policy = MessageListChannelPolicy(channel: .mesh, privatePeer: nil)
        let echo = makeRow(id: BitchatMessage.archivedEchoIDPrefix + "1")
        let notice = makeRow(id: "notice", sender: "system")
        let live = makeRow(id: "live")

        #expect(!policy.showsAmbientFooter(below: [BitchatMessage]()))
        #expect(policy.showsAmbientFooter(below: [echo, notice]))
        #expect(!policy.showsAmbientFooter(below: [echo, notice, live]))
    }

    /// Every channel decision of the list goes through its own timeline's
    /// channel. A selection read in the list would render the selected
    /// geohash's chrome over the pinned #mesh pane.
    @Test("MessageListView never reads the selected channel")
    func messageListView_neverReadsTheSelection() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // bitchatTests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("bitchat/Views/MessageListView.swift")
        let text = try String(contentsOf: source, encoding: .utf8)

        let offenders = text.components(separatedBy: .newlines)
            .enumerated()
            .filter { $0.element.contains("selectedChannel") }
            .map { "MessageListView.swift:\($0.offset + 1): \($0.element.trimmingCharacters(in: .whitespaces))" }
        #expect(offenders.isEmpty, "\(offenders)")
    }
}
