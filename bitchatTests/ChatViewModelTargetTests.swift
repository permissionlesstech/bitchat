//
// ChatViewModelTargetTests.swift
// bitchatTests
//
// The target-taking ChatViewModel APIs, end to end through a real view
// model: text and commands go to the conversation they were aimed at,
// whatever is selected.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
import BitFoundation
@testable import bitchat

@MainActor
private func makeTargetTestViewModel() -> (viewModel: ChatViewModel, transport: MockTransport) {
    let keychain = MockKeychain()
    let transport = MockTransport()
    let viewModel = ChatViewModel(
        keychain: keychain,
        idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
        identityManager: MockIdentityManager(keychain),
        transport: transport
    )
    return (viewModel, transport)
}

private let geohashChannel = GeohashChannel(level: .city, geohash: "u4pruy")
private let otherGeohashChannel = ChannelID.location(GeohashChannel(level: .city, geohash: "9q8yyk"))

@Suite(.serialized)
struct ChatViewModelTargetTests {
    private let alice = PeerID(str: "a11ce000a11ce000")
    private let bob = PeerID(str: "b0b0b0b0b0b0b0b0")

    // MARK: Text

    @Test @MainActor
    func meshTargetSendsOverTheMeshWhileAGeohashAndADMAreSelected() async {
        let (viewModel, transport) = makeTargetTestViewModel()
        viewModel.switchLocationChannel(to: .location(geohashChannel))
        viewModel.selectedPrivateChatPeer = alice

        viewModel.sendMessage("hello mesh", to: .mesh)

        #expect(transport.sentMessages.map(\.content) == ["hello mesh"])
        #expect(transport.sentPrivateMessages.isEmpty)
        #expect(viewModel.publicMessages(for: .mesh).contains { $0.content == "hello mesh" })
        #expect(!viewModel.publicMessages(for: .location(geohashChannel)).contains { $0.content == "hello mesh" })
        #expect(viewModel.privateMessages(for: alice).isEmpty)
    }

    @Test @MainActor
    func aDMTargetGoesToItsPeerWhileAnotherDMIsSelected() async {
        let (viewModel, transport) = makeTargetTestViewModel()
        transport.connectedPeers.insert(bob)
        transport.peerNicknames[bob] = "bob"
        viewModel.selectedPrivateChatPeer = alice

        viewModel.sendMessage("for bob", to: ConversationTarget(channel: .mesh, privatePeer: bob))

        #expect(transport.sentPrivateMessages.map(\.peerID) == [bob])
        #expect(viewModel.privateMessages(for: bob).map(\.content) == ["for bob"])
        #expect(viewModel.privateMessages(for: alice).isEmpty)
        #expect(transport.sentMessages.isEmpty)
    }

    // MARK: Commands

    @Test @MainActor
    func commandOutputFromMeshStaysInMeshWhileADMIsOpen() async {
        let (viewModel, transport) = makeTargetTestViewModel()
        transport.simulateConnect(alice, nickname: "alice")
        viewModel.selectedPrivateChatPeer = alice

        viewModel.handleCommand("/bogus", from: .mesh)

        #expect(viewModel.publicMessages(for: .mesh).last?.content.hasPrefix("unknown command: /bogus") == true)
        #expect(!viewModel.privateMessages(for: alice).contains { $0.content.hasPrefix("unknown command") })
    }

    @Test @MainActor
    func msgFromMeshPrintsInTheChatItOpened() async {
        let (viewModel, transport) = makeTargetTestViewModel()
        transport.simulateConnect(alice, nickname: "Alice")
        transport.simulateConnect(bob, nickname: "Bob")
        let resolved = await TestHelpers.waitUntil({
            viewModel.getPeerIDForNickname("Alice", in: .mesh) == alice
        }, timeout: TestConstants.settleTimeout)
        #expect(resolved)
        viewModel.selectedPrivateChatPeer = bob

        viewModel.handleCommand("/msg Alice", from: .mesh)

        #expect(viewModel.selectedPrivateChatPeer == alice)
        #expect(viewModel.privateMessages(for: alice).last?.content == "started private chat with Alice")
        #expect(!viewModel.privateMessages(for: bob).contains { $0.content == "started private chat with Alice" })
        #expect(!viewModel.publicMessages(for: .mesh).contains { $0.content == "started private chat with Alice" })
    }

    @Test @MainActor
    func clearInMeshScopeLeavesTheSelectedGeohashAlone() async {
        let (viewModel, _) = makeTargetTestViewModel()
        viewModel.switchLocationChannel(to: .location(geohashChannel))
        viewModel.addPublicSystemMessage("geo line", to: .location(geohashChannel))
        viewModel.addPublicSystemMessage("mesh line", to: .mesh)

        viewModel.handleCommand("/clear", from: .mesh)

        #expect(viewModel.publicMessages(for: .mesh).isEmpty)
        #expect(viewModel.publicMessages(for: .location(geohashChannel)).contains { $0.content == "geo line" })
    }

    // MARK: People in a scope

    @Test @MainActor
    func namesResolveOnlyInTheScopeTheyWereTypedIn() async {
        let (viewModel, transport) = makeTargetTestViewModel()
        transport.simulateConnect(alice, nickname: "alice")
        let resolved = await TestHelpers.waitUntil({
            viewModel.getPeerIDForNickname("alice", in: .mesh) == alice
        }, timeout: TestConstants.settleTimeout)
        #expect(resolved)

        viewModel.switchLocationChannel(to: .location(geohashChannel))
        let carol = String(repeating: "c", count: 64)
        viewModel.geoNicknames = [carol: "carol"]

        // The live geohash resolves its own people first...
        #expect(viewModel.getPeerIDForNickname("carol", in: .location(geohashChannel)) == PeerID(nostr_: carol))
        // ...#mesh beside it resolves mesh peers only...
        #expect(viewModel.getPeerIDForNickname("carol", in: .mesh) == nil)
        #expect(viewModel.getPeerIDForNickname("alice", in: .mesh) == alice)
        // ...and a geohash that isn't live knows none of its people.
        #expect(viewModel.getPeerIDForNickname("carol", in: otherGeohashChannel) == nil)

        // Participants are tracked for the live geohash alone.
        #expect(viewModel.getVisibleGeoParticipants(in: .mesh).isEmpty)
        #expect(viewModel.getVisibleGeoParticipants(in: otherGeohashChannel).isEmpty)
    }

    @Test @MainActor
    func aBlockByNameNeverReachesAnotherChannelsPeople() async {
        let (viewModel, _) = makeTargetTestViewModel()
        viewModel.switchLocationChannel(to: .location(geohashChannel))
        // carol is known in the live geohash, and is no mesh peer.
        let carol = String(repeating: "c", count: 64)
        viewModel.geoNicknames = [carol: "carol"]
        #expect(viewModel.nostrPubkeyForDisplayName("carol", in: .location(geohashChannel)) == carol)
        #expect(viewModel.nostrPubkeyForDisplayName("carol", in: .mesh) == nil)
        #expect(viewModel.nostrPubkeyForDisplayName("carol", in: otherGeohashChannel) == nil)

        // /block typed in #mesh beside the geohash finds nobody.
        viewModel.handleCommand("/block carol", from: .mesh)
        #expect(!viewModel.isNostrBlocked(pubkeyHexLowercased: carol))
        #expect(viewModel.publicMessages(for: .mesh).last?.content
            == "cannot block carol: not found or unable to verify identity")

        // Typed in the geohash, it blocks her; #mesh can't unblock her.
        viewModel.handleCommand("/block carol", from: .publicChannel(.location(geohashChannel)))
        #expect(viewModel.isNostrBlocked(pubkeyHexLowercased: carol))
        viewModel.handleCommand("/unblock carol", from: .mesh)
        #expect(viewModel.isNostrBlocked(pubkeyHexLowercased: carol))
    }

    // MARK: A geohash that isn't live

    @Test @MainActor
    func aGeohashThatIsNotLiveGetsALocalNoticeAndNothingIsSent() {
        let (viewModel, transport) = makeTargetTestViewModel()
        // #mesh is selected, so a geohash target can only be stale.
        let stale = ChannelID.location(geohashChannel)
        let meshCount = viewModel.publicMessages(for: .mesh).count

        #expect(!viewModel.sendPublicRaw("* 🫂 me hugs carol *", to: stale))
        #expect(!viewModel.sendPublicMessage("cashuAtoken", to: stale))
        viewModel.sendMessage("hello geo", to: .publicChannel(stale))

        #expect(transport.sentMessages.isEmpty)
        let geohashTimeline = viewModel.publicMessages(for: stale)
        #expect(geohashTimeline.filter { $0.sender == "system" }.count == 3)
        #expect(!geohashTimeline.contains { $0.content == "hello geo" || $0.content == "cashuAtoken" })
        #expect(viewModel.publicMessages(for: .mesh).count == meshCount)
    }
}
