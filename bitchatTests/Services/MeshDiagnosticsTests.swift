//
// MeshDiagnosticsTests.swift
// bitchatTests
//
// Tests for /ping and /trace command handling and the topology snapshot
// types backing the mesh topology map.
// This is free and unencumbered software released into the public domain.
//

import Foundation
import Testing
import BitFoundation
@testable import bitchat

@Suite(.serialized)
struct MeshDiagnosticsTests {

    // MARK: - Helpers

    @MainActor
    private func makeProcessor(
        context: DiagnosticsMockContext,
        transport: MockTransport
    ) -> CommandProcessor {
        CommandProcessor(
            contextProvider: context,
            meshService: transport,
            identityManager: MockIdentityManager(MockKeychain())
        )
    }

    /// Waits for the async ping completion (MainActor hop) to land.
    @MainActor
    private func waitForCommandOutput(_ context: DiagnosticsMockContext) async {
        for _ in 0..<100 {
            if !context.commandOutputs.isEmpty { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - /ping

    @MainActor
    @Test func pingWithoutArgumentShowsUsage() {
        let context = DiagnosticsMockContext()
        let processor = makeProcessor(context: context, transport: MockTransport())
        let result = processor.process("/ping")
        switch result {
        case .error(let message):
            #expect(message == "usage: /ping <nickname>")
        default:
            Issue.record("Expected usage error")
        }
    }

    @MainActor
    @Test func pingUnknownPeerFails() {
        let context = DiagnosticsMockContext()
        let processor = makeProcessor(context: context, transport: MockTransport())
        let result = processor.process("/ping @ghost")
        switch result {
        case .error(let message):
            #expect(message == "cannot ping ghost: not found on mesh")
        default:
            Issue.record("Expected error result")
        }
    }

    @MainActor
    @Test func pingGeoDMPeerIsRejected() {
        let context = DiagnosticsMockContext()
        context.nicknameToPeerID["alice"] = PeerID(nostr_: "aabbccddeeff00112233445566778899")
        let processor = makeProcessor(context: context, transport: MockTransport())
        let result = processor.process("/ping @alice")
        switch result {
        case .error(let message):
            #expect(message == "cannot ping alice: not found on mesh")
        default:
            Issue.record("Expected error for geo peer")
        }
    }

    @MainActor
    @Test func pingSuccessReportsRttAndHops() async {
        let context = DiagnosticsMockContext()
        let peerID = PeerID(str: "abcd1234abcd1234")
        context.nicknameToPeerID["alice"] = peerID
        let transport = MockTransport()
        transport.meshPingResult = MeshPingResult(rttMs: 42, hops: 2)
        let processor = makeProcessor(context: context, transport: transport)

        let result = processor.process("/ping @alice")
        switch result {
        case .success(let message):
            #expect(message == "pinging alice…")
        default:
            Issue.record("Expected immediate 'pinging' feedback")
        }
        #expect(transport.sentMeshPings == [peerID])

        await waitForCommandOutput(context)
        #expect(context.commandOutputs == ["pong from alice: 42 ms · 2 hops"])
    }

    @MainActor
    @Test func pingDirectPeerReportsSingleHop() async {
        let context = DiagnosticsMockContext()
        context.nicknameToPeerID["alice"] = PeerID(str: "abcd1234abcd1234")
        let transport = MockTransport()
        transport.meshPingResult = MeshPingResult(rttMs: 8, hops: 1)
        let processor = makeProcessor(context: context, transport: transport)

        _ = processor.process("/ping alice")
        await waitForCommandOutput(context)
        #expect(context.commandOutputs == ["pong from alice: 8 ms · direct (1 hop)"])
    }

    @MainActor
    @Test func pingTimeoutReportsNoReply() async {
        let context = DiagnosticsMockContext()
        context.nicknameToPeerID["alice"] = PeerID(str: "abcd1234abcd1234")
        let transport = MockTransport()
        transport.meshPingResult = nil
        let processor = makeProcessor(context: context, transport: transport)

        _ = processor.process("/ping @alice")
        await waitForCommandOutput(context)
        #expect(context.commandOutputs == ["no reply from alice"])
    }

    @MainActor
    @Test func pingOutputRoutesToConversationWhereCommandWasIssued() async {
        let context = DiagnosticsMockContext()
        let alice = PeerID(str: "abcd1234abcd1234")
        let bob = PeerID(str: "b0b0b0b0b0b0b0b0")
        context.nicknameToPeerID["alice"] = alice
        let transport = MockTransport()
        transport.meshPingResult = MeshPingResult(rttMs: 42, hops: 2)
        let processor = makeProcessor(context: context, transport: transport)

        // Issue the ping from bob's DM, then switch chats before the async
        // result lands. The output must follow the origin conversation, not
        // whatever is selected at callback time.
        context.selectedPrivateChatPeer = bob
        _ = processor.process("/ping @alice")
        context.selectedPrivateChatPeer = nil

        await waitForCommandOutput(context)
        #expect(context.commandOutputDestinations == [.privateChat(bob)])
    }

    @MainActor
    @Test func pingIssuedFromPublicTimelineRoutesToMeshTimeline() async {
        let context = DiagnosticsMockContext()
        let alice = PeerID(str: "abcd1234abcd1234")
        context.nicknameToPeerID["alice"] = alice
        let transport = MockTransport()
        transport.meshPingResult = MeshPingResult(rttMs: 7, hops: 1)
        let processor = makeProcessor(context: context, transport: transport)

        _ = processor.process("/ping @alice")
        // Opening a DM afterwards must not swallow the public-timeline result.
        context.selectedPrivateChatPeer = alice

        await waitForCommandOutput(context)
        #expect(context.commandOutputDestinations == [.meshTimeline])
    }

    // MARK: - /trace

    @MainActor
    @Test func traceDirectPeerShowsOneHop() {
        let context = DiagnosticsMockContext()
        let bob = PeerID(str: "b0b0b0b0b0b0b0b0")
        context.nicknameToPeerID["bob"] = bob
        let transport = MockTransport()
        transport.meshPaths[bob] = []
        let processor = makeProcessor(context: context, transport: transport)

        let result = processor.process("/trace @bob")
        switch result {
        case .success(let message):
            #expect(message == "estimated path: you → bob (1 hop)")
        default:
            Issue.record("Expected success result")
        }
    }

    @MainActor
    @Test func traceMultiHopUsesNicknamesWithShortIDFallback() {
        let context = DiagnosticsMockContext()
        let bob = PeerID(str: "b0b0b0b0b0b0b0b0")
        let alice = PeerID(str: "a11cea11cea11cea")
        let unknown = PeerID(str: "dead00beef001234")
        context.nicknameToPeerID["bob"] = bob
        let transport = MockTransport()
        transport.peerNicknames = [alice: "alice"]
        transport.meshPaths[bob] = [alice, unknown]
        let processor = makeProcessor(context: context, transport: transport)

        let result = processor.process("/trace bob")
        switch result {
        case .success(let message):
            #expect(message == "estimated path: you → alice → dead00be… → bob (3 hops)")
        default:
            Issue.record("Expected success result")
        }
    }

    @MainActor
    @Test func traceWithoutPathReportsNoKnownPath() {
        let context = DiagnosticsMockContext()
        context.nicknameToPeerID["bob"] = PeerID(str: "b0b0b0b0b0b0b0b0")
        let processor = makeProcessor(context: context, transport: MockTransport())

        let result = processor.process("/trace @bob")
        switch result {
        case .success(let message):
            #expect(message == "no known path to bob")
        default:
            Issue.record("Expected success result")
        }
    }

    // MARK: - Topology snapshot types

    @Test func topologyEdgeNormalizesEndpointOrder() {
        let a = PeerID(str: "aaaa000000000000")
        let b = PeerID(str: "bbbb000000000000")
        #expect(MeshTopologyEdge(a, b) == MeshTopologyEdge(b, a))
        #expect(Set([MeshTopologyEdge(a, b), MeshTopologyEdge(b, a)]).count == 1)
    }

    @Test func topologyLayoutPlacesSelfInCenter() {
        let nodes: [MeshTopologyDisplayModel.Node] = [
            .init(id: "self", label: "me", isSelf: true),
            .init(id: "a", label: "alice", isSelf: false),
            .init(id: "b", label: "bob", isSelf: false)
        ]
        let size = CGSize(width: 200, height: 200)
        let positions = MeshTopologyView.layout(nodes: nodes, in: size)

        #expect(positions["self"] == CGPoint(x: 100, y: 100))
        #expect(positions.count == 3)
        // Ring nodes sit on the same radius around the center.
        let radiusA = hypot((positions["a"]?.x ?? 0) - 100, (positions["a"]?.y ?? 0) - 100)
        let radiusB = hypot((positions["b"]?.x ?? 0) - 100, (positions["b"]?.y ?? 0) - 100)
        #expect(abs(radiusA - radiusB) < 0.001)
        #expect(radiusA > 0)
    }
}

/// Minimal CommandContextProvider for diagnostics tests; records deferred
/// command output so async /ping results can be asserted.
@MainActor
private final class DiagnosticsMockContext: CommandContextProvider {
    var nickname: String = "tester"
    var activeChannel: ChannelID = .mesh
    var selectedPrivateChatPeer: PeerID?
    var blockedUsers: Set<String> = []
    let idBridge = NostrIdentityBridge(keychain: MockKeychain())

    var nicknameToPeerID: [String: PeerID] = [:]
    private(set) var commandOutputs: [String] = []
    private(set) var commandOutputDestinations: [CommandOutputDestination] = []

    func getPeerIDForNickname(_ nickname: String) -> PeerID? {
        nicknameToPeerID[nickname]
    }

    func getVisibleGeoParticipants() -> [CommandGeoParticipant] { [] }
    func nostrPubkeyForDisplayName(_ displayName: String) -> String? { nil }
    func startPrivateChat(with peerID: PeerID) {}
    func sendPrivateMessage(_ content: String, to peerID: PeerID) {}
    func clearCurrentPublicTimeline() {}
    func clearPrivateChat(_ peerID: PeerID) {}
    func sendPublicRaw(_ content: String) {}
    func sendPublicMessage(_ content: String) {}
    func groupCreate(named name: String) -> CommandResult { .handled }
    func groupInvite(nickname: String) -> CommandResult { .handled }
    func groupRemove(nickname: String) -> CommandResult { .handled }
    func groupLeave() -> CommandResult { .handled }
    func groupList() -> CommandResult { .handled }
    func addLocalPrivateSystemMessage(_ content: String, to peerID: PeerID) {}
    func addPublicSystemMessage(_ content: String) {}
    func toggleFavorite(peerID: PeerID) {}

    func currentCommandDestination() -> CommandOutputDestination {
        if let peerID = selectedPrivateChatPeer {
            return .privateChat(peerID)
        }
        return .meshTimeline
    }

    func addCommandOutput(_ content: String, to destination: CommandOutputDestination) {
        commandOutputs.append(content)
        commandOutputDestinations.append(destination)
    }
}
