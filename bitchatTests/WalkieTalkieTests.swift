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
}
