//
// CommandProcessorScopeTests.swift
// bitchatTests
//
// `CommandProcessor.process(_:in:)` acts in the conversation a command was
// typed into. Each test types into one scope while the selection says
// something else, and checks the command touched only the scope.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Testing
import BitFoundation
@testable import bitchat

@MainActor
struct CommandProcessorScopeTests {
    private static let geohash = GeohashChannel(level: .city, geohash: "u4pruy")
    private static let geoChannel = ChannelID.location(geohash)
    private static let alice = PeerID(str: "a11ce000a11ce000")
    private static let bob = PeerID(str: "b0b0b0b0b0b0b0b0")
    private static let group = PeerID(groupID: Data(repeating: 0x42, count: 16))
    private static let geoDM = PeerID(nostr_: String(repeating: "cd", count: 32))

    private func makeProcessor(
        _ context: MockScopedCommandContext,
        transport: MockTransport = MockTransport(),
        identityManager: MockIdentityManager = MockIdentityManager(MockKeychain())
    ) -> CommandProcessor {
        CommandProcessor(contextProvider: context, meshService: transport, identityManager: identityManager)
    }

    private func message(of result: CommandResult) -> String? {
        switch result {
        case .success(let message): return message
        case .error(let message): return message
        case .handled: return nil
        }
    }

    // MARK: /who

    @Test func whoListsMeshPeersInMeshScopeWhileAGeohashIsSelected() {
        let context = MockScopedCommandContext()
        context.activeChannel = Self.geoChannel
        let transport = MockTransport()
        transport.peerNicknames = [Self.alice: "alice"]

        let result = makeProcessor(context, transport: transport).process("/who", in: .mesh)

        #expect(message(of: result) == "online: alice")
        #expect(context.participantQueries.isEmpty)
    }

    @Test func whoListsTheGeohashsPeopleInGeohashScopeWhileMeshIsSelected() {
        let context = MockScopedCommandContext()
        context.activeChannel = .mesh
        context.selectedPrivateChatPeer = Self.alice
        context.geoParticipantsByChannel[Self.geoChannel] = [
            CommandGeoParticipant(id: String(repeating: "b", count: 64), displayName: "bob#bbbb")
        ]
        let transport = MockTransport()
        transport.peerNicknames = [Self.alice: "alice"]

        let result = makeProcessor(context, transport: transport).process("/who", in: .publicChannel(Self.geoChannel))

        #expect(message(of: result) == "online: bob#bbbb")
        #expect(context.participantQueries == [Self.geoChannel])
    }

    // MARK: /clear

    @Test func clearClearsTheScopesConversationOnly() {
        let context = MockScopedCommandContext()
        let processor = makeProcessor(context)

        // #mesh typed beside an open DM.
        context.selectedPrivateChatPeer = Self.alice
        _ = processor.process("/clear", in: .mesh)
        #expect(context.clearedPublicTimelines == [.mesh])
        #expect(context.clearedPrivateChats.isEmpty)

        // Bob's DM while alice's is the one selected.
        _ = processor.process("/clear", in: ConversationTarget(channel: .mesh, privatePeer: Self.bob))
        #expect(context.clearedPrivateChats == [Self.bob])

        // A geohash while #mesh is selected.
        context.selectedPrivateChatPeer = nil
        _ = processor.process("/clear", in: .publicChannel(Self.geoChannel))
        #expect(context.clearedPublicTimelines == [.mesh, Self.geoChannel])
    }

    // MARK: /hug and /slap

    @Test func emotesGoToTheScopesChannelNotTheSelection() {
        let context = MockScopedCommandContext()
        context.activeChannel = Self.geoChannel
        context.selectedPrivateChatPeer = Self.alice
        context.peersByChannel[.mesh] = ["bob": Self.bob]
        let transport = MockTransport()
        transport.peerNicknames[Self.bob] = "bob"
        let processor = makeProcessor(context, transport: transport)

        _ = processor.process("/hug @bob", in: .mesh)

        #expect(context.lookups.map(\.scope) == [.mesh])
        #expect(context.sentPublicRaw.map(\.channel) == [.mesh])
        #expect(context.sentPublicRaw.map(\.content) == ["* 🫂 me hugs bob *"])
        #expect(context.publicSystemMessages.map(\.channel) == [.mesh])
        // Neither the selected geohash nor the open DM heard about it.
        #expect(transport.sentPrivateMessages.isEmpty)
        #expect(context.localPrivateSystemMessages.isEmpty)

        context.activeChannel = .mesh
        context.peersByChannel[Self.geoChannel] = ["carol": Self.geoDM]
        _ = processor.process("/slap carol", in: .publicChannel(Self.geoChannel))
        #expect(context.sentPublicRaw.map(\.channel) == [.mesh, Self.geoChannel])
        #expect(context.publicSystemMessages.map(\.channel) == [.mesh, Self.geoChannel])
    }

    @Test func anEmoteInADMScopeGoesPrivateWhileAPublicTimelineIsSelected() {
        let context = MockScopedCommandContext()
        context.peersByChannel[.mesh] = ["bob": Self.bob]
        let transport = MockTransport()
        transport.peerNicknames[Self.bob] = "bob"

        _ = makeProcessor(context, transport: transport)
            .process("/hug bob", in: ConversationTarget(channel: .mesh, privatePeer: Self.bob))

        #expect(transport.sentPrivateMessages.map(\.peerID) == [Self.bob])
        #expect(context.sentPublicRaw.isEmpty)
        #expect(context.publicSystemMessages.isEmpty)
    }

    @Test func anEmoteToAStaleGeohashSendsNothingAndEchoesNothing() {
        let context = MockScopedCommandContext()
        context.peersByChannel[Self.geoChannel] = ["carol": Self.geoDM]
        context.refusedPublicChannels = [Self.geoChannel]

        let result = makeProcessor(context).process("/hug carol", in: .publicChannel(Self.geoChannel))

        #expect(message(of: result) == nil)
        #expect(context.sentPublicRaw.isEmpty)
        #expect(context.publicSystemMessages.isEmpty)
    }

    // MARK: /msg

    @Test func msgResolvesInTheScopeAndTheNewDMKeepsIt() {
        let context = MockScopedCommandContext()
        context.activeChannel = .mesh
        context.peersByChannel[Self.geoChannel] = ["carol#cdcd": Self.geoDM]
        let processor = makeProcessor(context)

        _ = processor.process("/msg @carol#cdcd hi there", in: .publicChannel(Self.geoChannel))

        #expect(context.lookups.map(\.scope) == [Self.geoChannel])
        #expect(context.startedPrivateChats == [Self.geoDM])
        #expect(context.sentPrivateMessages.count == 1)
        #expect(context.sentPrivateMessages.first?.peerID == Self.geoDM)
        #expect(context.sentPrivateMessages.first?.scope == Self.geoChannel)

        // #mesh never resolves the geohash's people.
        let result = processor.process("/msg carol#cdcd", in: .mesh)
        #expect(message(of: result) == "'carol#cdcd' not found")
        #expect(context.lookups.last?.scope == .mesh)
    }

    // MARK: /group

    @Test func groupCommandsActOnTheScopesGroup() {
        let context = MockScopedCommandContext()
        // A group is open elsewhere; #mesh's command must not manage it.
        context.selectedPrivateChatPeer = Self.group
        let processor = makeProcessor(context)

        _ = processor.process("/group invite bob", in: .mesh)
        _ = processor.process("/group leave", in: ConversationTarget(channel: .mesh, privatePeer: Self.group))
        _ = processor.process("/group create trail", in: .mesh)

        #expect(context.groupCalls.map(\.subcommand) == ["invite", "leave", "create"])
        #expect(context.groupCalls[0].scope == .mesh)
        #expect(context.groupCalls[1].scope == ConversationTarget(channel: .mesh, privatePeer: Self.group))
    }

    @Test func meshOnlyCommandsAreGatedByTheScopeNotTheSelection() {
        let context = MockScopedCommandContext()
        let processor = makeProcessor(context)

        // A geohash scope refuses them while #mesh is selected...
        context.activeChannel = .mesh
        let groupResult = processor.process("/group list", in: .publicChannel(Self.geoChannel))
        #expect(message(of: groupResult) == "groups are only for mesh peers in #mesh")
        let favResult = processor.process("/fav alice", in: .publicChannel(Self.geoChannel))
        #expect(message(of: favResult) == "favorites are only for mesh peers in #mesh")
        #expect(context.groupCalls.isEmpty)

        // ...and a mesh scope allows them while a geohash is selected.
        context.activeChannel = Self.geoChannel
        let freshPeer = PeerID(str: "f00df00df00df00d")
        context.peersByChannel[.mesh] = ["fresh": freshPeer]
        _ = processor.process("/group list", in: .mesh)
        let addResult = processor.process("/fav fresh", in: .mesh)
        #expect(context.groupCalls.map(\.subcommand) == ["list"])
        #expect(message(of: addResult) == "added fresh to favorites")
        #expect(context.toggledFavorites == [freshPeer])
    }

    // MARK: /block

    @Test func blockResolvesAndListsInTheScope() {
        let context = MockScopedCommandContext()
        context.activeChannel = Self.geoChannel
        context.peersByChannel[.mesh] = ["troll": Self.bob]
        let transport = MockTransport()
        transport.peerFingerprints[Self.bob] = "fp-troll"
        let identityManager = MockIdentityManager(MockKeychain())
        let processor = makeProcessor(context, transport: transport, identityManager: identityManager)

        _ = processor.process("/block troll", in: .mesh)
        #expect(context.lookups.map(\.scope) == [.mesh])
        #expect(identityManager.isBlocked(fingerprint: "fp-troll"))

        _ = processor.process("/block", in: .publicChannel(Self.geoChannel))
        #expect(context.participantQueries == [Self.geoChannel])
    }

    @Test func blockAndUnblockByNameReachOnlyTheScopesGeohashPeople() {
        let context = MockScopedCommandContext()
        // carol is a participant of the selected geohash, and no mesh peer.
        context.activeChannel = Self.geoChannel
        let carol = String(repeating: "c", count: 64)
        context.geoPubkeysByChannel[Self.geoChannel] = ["carol": carol]
        let identityManager = MockIdentityManager(MockKeychain())
        let processor = makeProcessor(context, identityManager: identityManager)

        // Typed in #mesh beside the geohash: carol is nobody there.
        let blockFromMesh = processor.process("/block carol", in: .mesh)
        #expect(message(of: blockFromMesh) == "cannot block carol: not found or unable to verify identity")
        #expect(!identityManager.isNostrBlocked(pubkeyHexLowercased: carol))

        // Typed in the geohash, she is blocked there...
        let blockInGeohash = processor.process("/block carol", in: .publicChannel(Self.geoChannel))
        #expect(message(of: blockInGeohash) == "blocked carol in geohash chats")
        #expect(identityManager.isNostrBlocked(pubkeyHexLowercased: carol))

        // ...and #mesh can't unblock her either.
        let unblockFromMesh = processor.process("/unblock carol", in: .mesh)
        #expect(message(of: unblockFromMesh) == "cannot unblock carol: not found")
        #expect(identityManager.isNostrBlocked(pubkeyHexLowercased: carol))

        #expect(context.geoPubkeyLookups.map(\.scope) == [.mesh, Self.geoChannel, .mesh])
        #expect(context.geohashBlockListChangeCount == 1)
    }

    // MARK: /pay

    @Test func payPostsInTheScope() {
        let context = MockScopedCommandContext()
        context.activeChannel = Self.geoChannel
        context.selectedPrivateChatPeer = Self.alice
        let processor = makeProcessor(context)
        let token = Self.validToken

        _ = processor.process("/pay \(token) public", in: .mesh)
        #expect(context.sentPublicMessages.map(\.channel) == [.mesh])
        #expect(context.sentPrivateMessages.isEmpty)

        _ = processor.process("/pay \(token)", in: ConversationTarget(channel: .mesh, privatePeer: Self.bob))
        #expect(context.sentPrivateMessages.map(\.peerID) == [Self.bob])

        // A stale geohash refuses the public post; no "sent" claim follows.
        context.refusedPublicChannels = [Self.geoChannel]
        let refused = processor.process("/pay \(token) public", in: .publicChannel(Self.geoChannel))
        #expect(message(of: refused) == nil)
        #expect(context.sentPublicMessages.map(\.channel) == [.mesh])
    }

    // MARK: /ping

    @Test func pingOutputGoesToTheScopeItWasTypedIn() async {
        let context = MockScopedCommandContext()
        context.peersByChannel[.mesh] = ["alice": Self.alice]
        let transport = MockTransport()
        transport.meshPingResult = MeshPingResult(rttMs: 12, hops: 1)
        let processor = makeProcessor(context, transport: transport)
        let origin = ConversationTarget(channel: .mesh, privatePeer: Self.bob)

        // Typed in bob's DM while #mesh public is selected, and the
        // selection moves again before the pong.
        _ = processor.process("/ping alice", in: origin)
        context.selectedPrivateChatPeer = Self.alice

        let landed = await TestHelpers.waitUntil({ !context.commandOutputs.isEmpty }, timeout: TestConstants.settleTimeout)
        #expect(landed)
        #expect(context.commandOutputs.map(\.target) == [origin])
    }

    /// 21-sat single-mint V3 token (proofs of 1+4+16).
    private static let validToken: String = {
        let json: [String: Any] = [
            "token": [[
                "mint": "https://mint.example.com",
                "proofs": [1, 4, 16].map { ["amount": $0, "id": "009a1f293253e41e", "secret": "s", "C": "02c"] }
            ]],
            "unit": "sat"
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        let b64 = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "cashuA" + b64
    }()
}
