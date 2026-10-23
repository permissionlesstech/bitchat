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
    let privateModel = PrivateConversationModel(
        chatViewModel: viewModel,
        conversations: viewModel.conversations,
        locationChannelsModel: LocationChannelsModel(manager: locationManager)
    )
    let ui = ConversationUIModel(
        chatViewModel: viewModel,
        privateConversationModel: privateModel,
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

    /// End to end: the split layout's #mesh list beside an open DM. Its
    /// block confirms and its triple-tap clear empties in #mesh; the DM
    /// the selection names gets neither.
    @Test("a #mesh list's block and clear stay in #mesh while a DM is open")
    func meshListActionsStayInMeshWhileADMIsOpen() async {
        let (ui, viewModel, transport) = makeActionsUIModel()
        transport.peerFingerprints[bob] = "fp-bob"
        viewModel.conversations.append(
            BitchatMessage(id: "mesh-row", sender: "bob", content: "on the mesh", timestamp: Date(), isRelay: false, senderPeerID: bob),
            to: .mesh
        )
        viewModel.selectedPrivateChatPeer = alice
        let meshList = actions(
            target: MessageListActions.target(privateTarget: nil, timelineChannel: .mesh) ?? .mesh,
            composer: nil,
            performer: ui
        )

        meshList.block(peerID: bob, displayName: "bob")
        let blocked = String(format: String(localized: "system.mesh.blocked"), locale: .current, "bob")
        #expect(viewModel.publicMessages(for: .mesh).last?.content == blocked)

        meshList.clear()
        let cleared = await TestHelpers.waitUntil(
            { !viewModel.publicMessages(for: .mesh).contains { $0.id == "mesh-row" } },
            timeout: TestConstants.settleTimeout
        )
        #expect(cleared)
        #expect(viewModel.privateMessages(for: alice).isEmpty)
        #expect(viewModel.selectedPrivateChatPeer == alice)
    }
}
