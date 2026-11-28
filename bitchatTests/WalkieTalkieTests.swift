//
// WalkieTalkieTests.swift
// bitchatTests
//
// Focused unit coverage for walkie-talkie ergonomics: tap-to-hint, hands-free
// lock-to-talk, live audio metering reset, DM live-talker reporting, and
// one-tap speaker mute.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation
import Testing
@testable import bitchat

@MainActor
private final class StubVoiceCaptureSession: VoiceCaptureSession {
    let isLive: Bool
    var onAudioLevel: (@Sendable (Float) -> Void)?
    var permissionDelayNanoseconds: UInt64 = 0
    var finishURL: URL?
    private(set) var cancelCount = 0
    private(set) var finishCount = 0

    init(isLive: Bool = true, finishURL: URL? = nil) {
        self.isLive = isLive
        self.finishURL = finishURL
    }

    func requestPermission() async -> Bool {
        if permissionDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: permissionDelayNanoseconds)
        }
        return true
    }

    func start() async throws {}

    func finish() async -> URL? {
        finishCount += 1
        return finishURL
    }

    func cancel() async {
        cancelCount += 1
    }

    func panicCancelSynchronously() {
        cancelCount += 1
    }
}

@MainActor
private final class StubWalkieLiveContext: ChatLiveVoiceContext {
    var nickname = "me"
    var myPeerID = PeerID(str: "0102030405060708")
    var selectedPrivateChatPeer: PeerID?
    var isViewingPublicMeshTimeline = false

    var authorizedGroupID: Data?
    var authorizedGroupPeerID: PeerID?
    var authorizedSenderPeerID: PeerID?
    private(set) var appendedGroupMessages: [(message: BitchatMessage, groupPeerID: PeerID)] = []
    private(set) var publicTalker: String?
    private(set) var directTalker: LiveVoiceTalker?

    func isPeerBlocked(_ peerID: PeerID) -> Bool { false }
    func resolveNickname(for peerID: PeerID) -> String { "alice" }
    func handlePrivateMessage(_ message: BitchatMessage) {}
    func appendPublicMeshMessage(_ message: BitchatMessage) {}
    func upsertPrivateMessage(_ message: BitchatMessage, in peerID: PeerID) {}
    func upsertPublicMeshMessage(_ message: BitchatMessage) {}
    @discardableResult
    func removePrivateMessage(withID messageID: String) -> BitchatMessage? { nil }
    func hasSentReadReceipt(_ messageID: String) -> Bool { false }
    @discardableResult
    func markReadReceiptSent(_ messageID: String) -> Bool { true }
    func sendMeshReadReceipt(_ receipt: ReadReceipt, to peerID: PeerID) {}
    func removeMessage(withID messageID: String, cleanupFile: Bool) {}

    func setActivePublicVoiceTalker(_ nickname: String?) {
        publicTalker = nickname
    }

    func setActiveDirectVoiceTalker(_ talker: LiveVoiceTalker?) {
        directTalker = talker
    }

    func resolveAuthorizedGroupPeerID(forGroupID groupID: Data, senderPeerID: PeerID) -> PeerID? {
        guard groupID == authorizedGroupID, senderPeerID == authorizedSenderPeerID else { return nil }
        return authorizedGroupPeerID
    }

    func appendGroupLiveVoiceMessage(_ message: BitchatMessage, to groupPeerID: PeerID) {
        appendedGroupMessages.append((message, groupPeerID))
    }
}

@Suite("Walkie-Talkie Ergonomics", .serialized)
@MainActor
struct WalkieTalkieTests {

    @Test("Quick tap surfaces brief hold hint instead of silent no-op")
    func test_quickTapShowsBriefHint() async {
        let vm = VoiceRecordingViewModel()
        let stub = StubVoiceCaptureSession(isLive: true)
        stub.permissionDelayNanoseconds = 200_000_000
        vm.sessionProvider = { stub }

        vm.start(shouldShow: true, target: .publicMesh)
        #expect(vm.state == .requestingPermission)

        // Release immediately before recording begins.
        vm.finish { _, _ in }

        #expect(vm.state == .idle)
        #expect(vm.briefHint != nil)
        #expect(vm.isLockedRecording == false)
        #expect(vm.audioLevel == 0)
    }

    @Test("Locking a recording latches hands-free until stopLockedRecording or panic")
    func test_lockRecordingLifecycle() async {
        let vm = VoiceRecordingViewModel()
        let stub = StubVoiceCaptureSession(isLive: true)
        vm.sessionProvider = { stub }

        vm.start(shouldShow: true, target: .publicMesh)
        // Wait for async start to enter .recording
        for _ in 0..<40 {
            if case .recording = vm.state { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard case .recording = vm.state else {
            Issue.record("Expected recording state, got \(vm.state)")
            return
        }

        vm.lockRecording()
        #expect(vm.isLockedRecording == true)

        // Live audio level callback propagates while active.
        stub.onAudioLevel?(0.75)
        for _ in 0..<20 {
            if vm.audioLevel > 0.5 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(vm.audioLevel > 0.5)

        // Cancel clears lock and resets metering.
        vm.cancel()
        #expect(vm.state == .idle)
        #expect(vm.isLockedRecording == false)
        #expect(vm.audioLevel == 0)
    }

    @Test("Direct message live burst publishes activeDirectVoiceTalker and clears on cancel")
    func test_directTalkerIndicatorTracksActiveBurst() {
        let context = StubWalkieLiveContext()
        let peer = PeerID(str: "aaaabbbbcccc0001")
        context.selectedPrivateChatPeer = peer

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WalkieTalkieTests-\(UUID().uuidString)", isDirectory: true)
        let store = BLEIncomingFileStore(baseDirectory: tempDir)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let coordinator = ChatLiveVoiceCoordinator(
            context: context,
            fileStore: store,
            sweepsOnInit: false
        )
        coordinator.liveVoiceEnabled = { true }

        let burstID = Data(repeating: 0x42, count: VoiceBurstPacket.burstIDSize)
        guard let startPacket = VoiceBurstPacket(burstID: burstID, seq: 0, kind: .start(codec: .aacLC16kMono)),
              let cancelPacket = VoiceBurstPacket(burstID: burstID, seq: 1, kind: .canceled) else {
            Issue.record("Failed to build voice burst packets")
            return
        }

        coordinator.handleVoiceFramePayload(from: peer, payload: startPacket.encode(), timestamp: Date())
        #expect(context.directTalker == LiveVoiceTalker(peerID: peer, nickname: "alice"))
        #expect(context.publicTalker == nil)

        // Mute active playback does not cancel the live assembly or indicator.
        coordinator.muteActivePlayback()
        #expect(context.directTalker == LiveVoiceTalker(peerID: peer, nickname: "alice"))

        coordinator.handleVoiceFramePayload(from: peer, payload: cancelPacket.encode(), timestamp: Date())
        #expect(context.directTalker == nil)
    }

    @Test("Group-scoped VoiceBurstPacket round-trips and fits single-frame budget")
    func test_groupScopedVoiceBurstPacketRoundTrip() {
        let burstID = Data(repeating: 0xAA, count: VoiceBurstPacket.burstIDSize)
        let groupID = Data(repeating: 0xBB, count: BitchatGroup.groupIDLength)
        let frame = Data(repeating: 0x55, count: 130)

        let start = VoiceBurstPacket(burstID: burstID, seq: 0, kind: .start(codec: .aacLC16kMono), groupID: groupID)!
        let decodedStart = VoiceBurstPacket.decode(start.encode())
        #expect(decodedStart == start)
        #expect(decodedStart?.groupID == groupID)

        let end = VoiceBurstPacket(burstID: burstID, seq: 2, kind: .end(totalDataPackets: 1, durationMs: 64), groupID: groupID)!
        #expect(VoiceBurstPacket.decode(end.encode()) == end)

        let canceled = VoiceBurstPacket(burstID: burstID, seq: 3, kind: .canceled, groupID: groupID)!
        #expect(VoiceBurstPacket.decode(canceled.encode()) == canceled)

        var packetizer = VoiceBurstPacketizer(burstID: burstID, groupID: groupID)
        _ = packetizer.add(frame)
        let packets = packetizer.flush()
        #expect(packets.count == 1)
        #expect(packets[0].count <= TransportConfig.pttMaxBurstContentBytes)
        let decodedData = VoiceBurstPacket.decode(packets[0])
        #expect(decodedData?.groupID == groupID)
        #expect(decodedData?.kind == .frames([frame]))
    }

    @Test("Group live voice routes to authorized group and drops unauthorized sender")
    func test_groupLiveVoiceAuthorizationAndRouting() {
        let context = StubWalkieLiveContext()
        let sender = PeerID(str: "aaaabbbbcccc0002")
        let intruder = PeerID(str: "deadbeefcafe0003")
        let groupID = Data(repeating: 0x77, count: BitchatGroup.groupIDLength)
        let groupPeerID = PeerID(groupID: groupID)
        context.authorizedGroupID = groupID
        context.authorizedGroupPeerID = groupPeerID
        context.authorizedSenderPeerID = sender
        context.selectedPrivateChatPeer = groupPeerID

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WalkieGroupTests-\(UUID().uuidString)", isDirectory: true)
        let store = BLEIncomingFileStore(baseDirectory: tempDir)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let coordinator = ChatLiveVoiceCoordinator(
            context: context,
            fileStore: store,
            sweepsOnInit: false
        )
        coordinator.liveVoiceEnabled = { true }

        let burstID = Data(repeating: 0x33, count: VoiceBurstPacket.burstIDSize)
        let startPacket = VoiceBurstPacket(burstID: burstID, seq: 0, kind: .start(codec: .aacLC16kMono), groupID: groupID)!

        // Unauthorized peer is rejected before creating a bubble or talker banner.
        coordinator.handleVoiceFramePayload(from: intruder, payload: startPacket.encode(), timestamp: Date())
        #expect(context.appendedGroupMessages.isEmpty)
        #expect(context.directTalker == nil)

        // Authorized group member routes directly into the group timeline.
        coordinator.handleVoiceFramePayload(from: sender, payload: startPacket.encode(), timestamp: Date())
        #expect(context.appendedGroupMessages.count == 1)
        #expect(context.appendedGroupMessages.first?.groupPeerID == groupPeerID)
        #expect(context.directTalker == LiveVoiceTalker(peerID: groupPeerID, nickname: "alice"))
    }

    @Test("Per-chat auto-listen rules isolate public #mesh from trusted DMs and groups")
    func test_perChatAutoListenRules() {
        let suite = "bitchat.tests.autolisten.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // Public Nearby auto-play defaults OFF even when Live Voice is ON.
        #expect(!PTTSettings.publicAutoPlayEnabled(in: defaults))
        #expect(
            !PTTSettings.shouldAutoPlayInbound(
                isPublicMesh: true,
                chatKey: nil,
                isChatMuted: false,
                liveEnabled: true,
                publicAutoPlay: PTTSettings.publicAutoPlayEnabled(in: defaults),
                isSpeakerMuted: false,
                defaults: defaults
            )
        )

        // Trusted DM auto-plays by default unless chat is muted or overridden to .never.
        #expect(
            PTTSettings.shouldAutoPlayInbound(
                isPublicMesh: false,
                chatKey: "fp-alice",
                isChatMuted: false,
                liveEnabled: true,
                publicAutoPlay: false,
                isSpeakerMuted: false,
                defaults: defaults
            )
        )
        #expect(
            !PTTSettings.shouldAutoPlayInbound(
                isPublicMesh: false,
                chatKey: "fp-alice",
                isChatMuted: true,
                liveEnabled: true,
                publicAutoPlay: false,
                isSpeakerMuted: false,
                defaults: defaults
            )
        )

        // Per-chat .always overrides muted chat; .never blocks unmuted chat.
        PTTSettings.setChatAutoListenPolicy(.always, for: "fp-alice", in: defaults)
        #expect(
            PTTSettings.shouldAutoPlayInbound(
                isPublicMesh: false,
                chatKey: "fp-alice",
                isChatMuted: true,
                liveEnabled: true,
                publicAutoPlay: false,
                isSpeakerMuted: false,
                defaults: defaults
            )
        )

        PTTSettings.setChatAutoListenPolicy(.never, for: "fp-alice", in: defaults)
        #expect(
            !PTTSettings.shouldAutoPlayInbound(
                isPublicMesh: false,
                chatKey: "fp-alice",
                isChatMuted: false,
                liveEnabled: true,
                publicAutoPlay: false,
                isSpeakerMuted: false,
                defaults: defaults
            )
        )

        // Panic reset restores defaults.
        PTTSettings.setPublicAutoPlayEnabled(true, in: defaults)
        PTTSettings.reset(in: defaults)
        #expect(!PTTSettings.publicAutoPlayEnabled(in: defaults))
        #expect(PTTSettings.chatAutoListenPolicy(for: "fp-alice", in: defaults) == .automatic)
    }

    #if os(iOS)
    @Test("SystemPTTChannelInfo generates deterministic distinct UUIDs per channel")
    func test_systemPTTChannelDeterministicUUIDAndLifecycle() {
        let nearby1 = SystemPTTChannelInfo(channelKey: "mesh.public", displayName: "Nearby (#mesh)", target: .publicMesh)
        let nearby2 = SystemPTTChannelInfo(channelKey: "mesh.public", displayName: "Nearby (#mesh)", target: .publicMesh)
        let dm = SystemPTTChannelInfo(channelKey: "fp-alice", displayName: "@alice", target: .privateChat(PeerID(str: "aaaabbbbcccc0001")))

        #expect(nearby1.channelUUID == nearby2.channelUUID)
        #expect(nearby1.channelUUID != dm.channelUUID)

        let manager = SystemPTTChannelManager.shared
        manager.joinChannel(nearby1)
        #expect(manager.isActive)
        #expect(manager.activeChannel == nearby1)
        manager.leaveCurrentChannel()
        #expect(!manager.isActive)
        #expect(manager.activeChannel == nil)
    }
    #endif
}
