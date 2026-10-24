//
// MessageListActionsTests.swift
// bitchatTests
//
// A message list's actions act in the list's own conversation and type into
// the list's own composer, never the selection's: beside another pane the
// selection names that pane's conversation. A public list acts in the
// channel its own timeline model shows (the split layout's pinned #mesh
// pane beside a selected geohash included), a DM list in its DM.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation
import Testing
@testable import bitchat

@MainActor
private func makeActionsUIModel() -> (ui: ConversationUIModel, viewModel: ChatViewModel, transport: MockTransport) {
    let suiteName = "MessageListActionsTests.\(UUID().uuidString)"
    let storage = UserDefaults(suiteName: suiteName) ?? .standard
    storage.removePersistentDomain(forName: suiteName)
    let locationManager = LocationChannelManager(storage: storage)
    let keychain = MockKeychain()
    let transport = MockTransport()
    let viewModel = ChatViewModel(
        keychain: keychain,
        idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
        identityManager: MockIdentityManager(keychain),
        transport: transport,
        locationManager: locationManager
    )
    let ui = ConversationUIModel(
        chatViewModel: viewModel,
        conversations: viewModel.conversations
    )
    return (ui, viewModel, transport)
}

@Suite("MessageListActions", .serialized)
@MainActor
struct MessageListActionsTests {
    private let geohash = GeohashChannel(level: .city, geohash: "u4pruy")
    private let alice = PeerID(str: "a11ce000a11ce000")
    private let bob = PeerID(str: "b0b0b0b0b0b0b0b0")

    private func actions(
        target: ConversationTarget,
        composer: ComposerSession?,
        performer: any MessageListActionPerforming,
        focused: @escaping (ComposerSlot) -> Void = { _ in }
    ) -> MessageListActions {
        MessageListActions(target: target, composer: composer, focusComposer: focused, performer: performer)
    }

    /// A public list acts in the channel its own model shows, not the
    /// selected one; a DM list in its DM, with the scope its owner gave it.
    @Test("a list acts in its own timeline's channel or its own DM")
    func aListActsInItsOwnConversation() {
        let store = ConversationStore()
        store.setActiveChannel(.location(geohash))
        let meshPane = PublicChatModel(conversations: store, pinnedTo: .mesh)
        let following = PublicChatModel(conversations: store)

        #expect(MessageListActions.target(privateTarget: nil, timelineChannel: meshPane.channel) == .mesh)
        #expect(
            MessageListActions.target(privateTarget: nil, timelineChannel: following.channel)
                == .publicChannel(.location(geohash))
        )

        let geohashDM = ConversationTarget(channel: .location(geohash), privatePeer: PeerID(nostr_: String(repeating: "ab", count: 32)))
        #expect(MessageListActions.target(privateTarget: geohashDM, timelineChannel: nil) == geohashDM)
        // Only a DM target stands in for the timeline's channel.
        #expect(MessageListActions.target(privateTarget: .mesh, timelineChannel: following.channel) == .publicChannel(.location(geohash)))
        #expect(MessageListActions.target(privateTarget: nil, timelineChannel: nil) == nil)
    }

    @Test("a mention types into the list's own composer and focuses it")
    func aMentionGoesToTheListsOwnComposer() {
        let sessions = ComposerSessions(drafts: InMemoryComposerDraftStore())
        sessions.primary.text = "mesh draft"
        var focused: [ComposerSlot] = []
        let dmList = actions(
            target: ConversationTarget(channel: .mesh, privatePeer: alice),
            composer: sessions.secondary,
            performer: RecordingMessageListActions(),
            focused: { focused.append($0) }
        )

        #expect(dmList.canMention)
        dmList.mention("bob")

        #expect(sessions.secondary.text == "@bob ")
        #expect(sessions.primary.text == "mesh draft", "the other composer is untouched")
        #expect(focused == [.secondary])
    }

    @Test("a list whose composer is off screen offers no mention")
    func aListWithoutItsComposerOffersNoMention() {
        var focused: [ComposerSlot] = []
        let list = actions(target: .mesh, composer: nil, performer: RecordingMessageListActions(), focused: { focused.append($0) })

        #expect(!list.canMention)
        list.mention("bob")
        #expect(focused.isEmpty)
    }

    @Test("hug, slap, block, clear and resend act in the list's target")
    func everyActionCarriesTheListsTarget() {
        let performer = RecordingMessageListActions()
        let geohashList = actions(target: .publicChannel(.location(geohash)), composer: nil, performer: performer)
        let dm = ConversationTarget(channel: .mesh, privatePeer: alice)
        let dmList = actions(target: dm, composer: nil, performer: performer)
        let failed = BitchatMessage(
            id: "failed-1",
            sender: "me",
            content: "again",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true
        )

        geohashList.hug("carol")
        geohashList.slap("carol")
        geohashList.block(peerID: bob, displayName: "bob")
        geohashList.clear()
        dmList.resend(failed)
        dmList.clear()

        let geo = ConversationTarget.publicChannel(.location(geohash))
        #expect(performer.calls == [
            .hug("carol", geo),
            .slap("carol", geo),
            .block(bob, "bob", geo),
            .clear(geo),
            .resend("failed-1", dm),
            .clear(dm)
        ])
    }

    /// End to end: the split layout's #mesh list, on the pinned #mesh model,
    /// while the selection names a geohash and a DM covers it. The list's
    /// target comes from its own model, as the list takes it; its block
    /// confirms and its triple-tap clear empties in #mesh, and neither the
    /// selected geohash nor the DM gets anything.
    @Test("a #mesh list's block and clear stay in #mesh beside a geohash and a DM")
    func meshListActionsStayInMeshWhileTheSelectionIsElsewhere() async throws {
        let (ui, viewModel, transport) = makeActionsUIModel()
        transport.peerFingerprints[bob] = "fp-bob"
        let geohashChannel = ChannelID.location(geohash)
        viewModel.locationManager.select(geohashChannel)
        let selected = await TestHelpers.waitUntil(
            { viewModel.activeChannel == geohashChannel },
            timeout: TestConstants.settleTimeout
        )
        #expect(selected)
        viewModel.selectedPrivateChatPeer = alice
        #expect(viewModel.selectionTarget == ConversationTarget(channel: geohashChannel, privatePeer: alice))
        viewModel.conversations.append(
            BitchatMessage(id: "mesh-row", sender: "bob", content: "on the mesh", timestamp: Date(), isRelay: false, senderPeerID: bob),
            to: .mesh
        )
        viewModel.conversations.append(
            BitchatMessage(id: "geo-row", sender: "carol", content: "in the geohash", timestamp: Date(), isRelay: false),
            to: ConversationID(channelID: geohashChannel)
        )
        let meshPane = PublicChatModel(conversations: viewModel.conversations, pinnedTo: .mesh)
        let meshList = actions(
            target: try #require(MessageListActions.target(privateTarget: nil, timelineChannel: meshPane.channel)),
            composer: nil,
            performer: ui
        )
        #expect(meshList.target == .mesh)

        meshList.block(peerID: bob, displayName: "bob")
        let blocked = String(format: String(localized: "system.mesh.blocked"), locale: .current, "bob")
        #expect(viewModel.publicMessages(for: .mesh).last?.content == blocked)

        meshList.clear()
        let cleared = await TestHelpers.waitUntil(
            { !viewModel.publicMessages(for: .mesh).contains { $0.id == "mesh-row" } },
            timeout: TestConstants.settleTimeout
        )
        #expect(cleared)
        let geohashRows = viewModel.publicMessages(for: geohashChannel)
        #expect(geohashRows.contains { $0.id == "geo-row" }, "the selected geohash isn't cleared")
        #expect(!geohashRows.contains { $0.content == blocked })
        #expect(viewModel.privateMessages(for: alice).isEmpty)
        #expect(viewModel.selectionTarget == ConversationTarget(channel: geohashChannel, privatePeer: alice))
    }

    /// A list acts in its own conversation: nothing in MessageListView reads
    /// which DM is open or what the selection targets (stage B's policy
    /// test already rules out the selected channel). #1792's gate read the
    /// open DM to decide whether the public list's actions were its own.
    @Test("MessageListView never reads the open DM or the selection target")
    func messageListViewNeverReadsTheSelection() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // bitchatTests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("bitchat/Views/MessageListView.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let selectionReads = ["selectedPeerID", "selectedPrivateChatPeer", "selectionTarget", "activeChannel"]

        let offenders = text.components(separatedBy: .newlines)
            .enumerated()
            .filter { line in selectionReads.contains { line.element.contains($0) } }
            .map { "MessageListView.swift:\($0.offset + 1): \($0.element.trimmingCharacters(in: .whitespaces))" }
        #expect(offenders.isEmpty, "\(offenders)")
    }
}
