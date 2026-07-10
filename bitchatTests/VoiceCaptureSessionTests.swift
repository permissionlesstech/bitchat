//
// VoiceCaptureSessionTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Testing
@testable import bitchat

@MainActor
private final class StubPTTCapture: PTTCapturing {
    var onFrames: (([Data]) -> Void)?
    var stopResult: (url: URL?, encodedFrames: Int)
    var startError: Error?
    private(set) var startCount = 0
    private(set) var cancelCount = 0

    init(
        stopResult: (url: URL?, encodedFrames: Int),
        startError: Error? = nil
    ) {
        self.stopResult = stopResult
        self.startError = startError
    }

    func start(outputURL: URL) async throws {
        startCount += 1
        if let startError {
            throw startError
        }
    }

    func stop() -> (url: URL?, encodedFrames: Int) {
        stopResult
    }

    func cancel() {
        cancelCount += 1
    }
}

private final class CaptureLeaseSession: SessionApplying, @unchecked Sendable {
    private let lock = NSLock()
    private var _activationCalls: [Bool] = []

    var activationCalls: [Bool] { lock.withLock { _activationCalls } }

    func setCategory(_ category: AudioSessionCoordinator.Category) throws {}

    func setActive(_ active: Bool, notifyOthersOnDeactivation: Bool) throws {
        lock.withLock { _activationCalls.append(active) }
    }
}

@MainActor
private final class GatedVoiceCaptureSession: VoiceCaptureSession {
    let isLive = false
    private let startError: Error?
    private(set) var finishStarted = false
    private(set) var cancelCount = 0
    private var finishContinuation: CheckedContinuation<URL?, Never>?

    init(startError: Error? = nil) {
        self.startError = startError
    }

    func requestPermission() async -> Bool { true }
    func start() async throws {
        if let startError { throw startError }
    }

    func finish() async -> URL? {
        finishStarted = true
        return await withCheckedContinuation { continuation in
            finishContinuation = continuation
        }
    }

    func cancel() async {
        cancelCount += 1
    }

    func resolveFinish(with url: URL?) {
        let continuation = finishContinuation
        finishContinuation = nil
        continuation?.resume(returning: url)
    }
}

@MainActor
struct VoiceCaptureSessionTests {
    private func waitUntil(
        _ condition: () -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(condition(), sourceLocation: sourceLocation)
    }

    private func isRecording(_ state: VoiceRecordingViewModel.State) -> Bool {
        if case .recording = state { return true }
        return false
    }

    @Test func staleCaptureCallbackCannotInvalidateNewGeneration() {
        let generations = PTTCaptureGeneration()
        let old = generations.begin()
        generations.invalidate()
        let current = generations.begin()

        #expect(!generations.invalidate(ifCurrent: old))
        #expect(generations.isCurrent(current))
        #expect(generations.invalidate(ifCurrent: current))
        #expect(!generations.isCurrent(current))
    }

    @Test func coordinatorCancellationIsNotReportedAsAStartedCapture() async {
        let capture = StubPTTCapture(
            stopResult: (nil, 0),
            startError: CancellationError()
        )
        let session = PTTLiveVoiceSession(
            sendPacket: { _ in },
            capture: capture
        )

        await #expect(throws: CancellationError.self) {
            try await session.start()
        }
    }

    @Test func interruptedShortCaptureIsCanceledEvenAfterLongHold() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ptt-interrupted-test-\(UUID().uuidString).m4a")
        _ = FileManager.default.createFile(atPath: url.path, contents: Data([0x00]))
        defer { try? FileManager.default.removeItem(at: url) }

        let capture = StubPTTCapture(stopResult: (url, 1))
        var sentPackets: [Data] = []
        var now = Date()
        let session = PTTLiveVoiceSession(
            sendPacket: { sentPackets.append($0) },
            capture: capture,
            now: { now },
            burstID: Data(repeating: 0xA5, count: 8)
        )

        try await session.start()
        now = now.addingTimeInterval(2)
        let result = await session.finish()

        #expect(result == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let packet = try #require(sentPackets.last.flatMap(VoiceBurstPacket.decode))
        guard case .canceled = packet.kind else {
            Issue.record("Expected a canceled control packet for a subsecond interrupted capture")
            return
        }
    }

    @Test func droppingCaptureLeaseReturnsItsCoordinatorToken() async throws {
        let rawSession = CaptureLeaseSession()
        let coordinator = AudioSessionCoordinator(session: rawSession)
        let token = try await coordinator.acquire(.capture) {}
        var lease: PTTCaptureSessionLease? = PTTCaptureSessionLease(coordinator: coordinator)
        lease?.install(token)

        lease = nil
        await coordinator.drain()

        #expect(rawSession.activationCalls == [true, false])
    }

    @Test func rejectedNewHoldAndStaleFinalizeLeaveNewerGenerationIdle() async {
        let oldSession = GatedVoiceCaptureSession()
        let newSession = GatedVoiceCaptureSession(
            startError: VoiceRecorder.RecorderError.recordingInProgress
        )
        var sessions: [GatedVoiceCaptureSession] = [oldSession, newSession]
        let viewModel = VoiceRecordingViewModel()
        viewModel.sessionProvider = { sessions.removeFirst() }

        viewModel.start(shouldShow: true)
        await waitUntil { self.isRecording(viewModel.state) }
        viewModel.finish(completion: { _ in })
        await waitUntil { oldSession.finishStarted }

        viewModel.start(shouldShow: true)
        await waitUntil { newSession.cancelCount == 1 && viewModel.state == .idle }
        #expect(viewModel.state == .idle)

        // The older finalize now fails after the newer press has completed.
        // It must not replace the newer generation's idle state with an alert.
        oldSession.resolveFinish(with: nil)
        for _ in 0..<20 {
            await Task.yield()
        }
        #expect(viewModel.state == .idle)
    }
}
