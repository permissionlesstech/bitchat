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
    private(set) var panicCancelCount = 0
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

    func panicCancelSynchronously() {
        panicCancelCount += 1
    }

    func resolveFinish(with url: URL?) {
        let continuation = finishContinuation
        finishContinuation = nil
        continuation?.resume(returning: url)
    }
}

/// Keeps the microphone permission prompt up until the test answers it.
@MainActor
private final class PermissionPromptVoiceCaptureSession: VoiceCaptureSession {
    let isLive = false
    private(set) var startCount = 0
    private var permissionContinuation: CheckedContinuation<Bool, Never>?

    var isPromptShowing: Bool { permissionContinuation != nil }

    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            permissionContinuation = continuation
        }
    }

    func answerPrompt(granted: Bool) {
        let continuation = permissionContinuation
        permissionContinuation = nil
        continuation?.resume(returning: granted)
    }

    func start() async throws {
        startCount += 1
    }

    func finish() async -> URL? { nil }
    func cancel() async {}
    func panicCancelSynchronously() {}
}

/// Keeps start() pending until the test fails it, like a capture stack
/// still spinning up.
@MainActor
private final class GatedStartVoiceCaptureSession: VoiceCaptureSession {
    let isLive = false
    private(set) var cancelCount = 0
    private var startContinuation: CheckedContinuation<Void, Error>?

    var isStarting: Bool { startContinuation != nil }

    func requestPermission() async -> Bool { true }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
        }
    }

    func failStart(with error: Error) {
        let continuation = startContinuation
        startContinuation = nil
        continuation?.resume(throwing: error)
    }

    func finish() async -> URL? { nil }

    func cancel() async {
        cancelCount += 1
    }

    func panicCancelSynchronously() {}
}

/// Hands out the given sessions in order, then fresh ones, counting every
/// hold that asked for one.
@MainActor
private final class SessionScript {
    private var queued: [VoiceCaptureSession]
    private(set) var provided = 0

    init(_ sessions: [VoiceCaptureSession]) {
        queued = sessions
    }

    func next() -> VoiceCaptureSession {
        provided += 1
        return queued.isEmpty ? GatedVoiceCaptureSession() : queued.removeFirst()
    }
}

@MainActor
struct VoiceCaptureSessionTests {
    private func waitUntil(
        _ condition: () -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(TestConstants.settleTimeout))
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

    private func makeVoiceNoteFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-note-\(UUID().uuidString).m4a")
        try Data([0x01]).write(to: url)
        return url
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

    /// A system prompt cancels the touch that raised it, so a hold can be
    /// abandoned while the permission prompt is up. Granting access then
    /// must not start a recording nobody is holding.
    @Test func holdCancelledAtThePermissionPromptNeverRecords() async {
        let session = PermissionPromptVoiceCaptureSession()
        let viewModel = VoiceRecordingViewModel()
        viewModel.sessionProvider = { session }

        viewModel.start(shouldShow: true)
        await waitUntil { session.isPromptShowing }
        #expect(viewModel.state == .requestingPermission)
        #expect(viewModel.isHoldInFlight)

        viewModel.cancelAnyHold()
        #expect(!viewModel.isHoldInFlight)

        session.answerPrompt(granted: true)
        for _ in 0..<20 {
            await Task.yield()
        }
        #expect(session.startCount == 0)
        #expect(viewModel.state == .idle)
    }

    /// A start that stands down while the previous classic note finalizes
    /// belongs to a press still held: `pressChanged` lets that press try
    /// again, and until it does, ending the press must still end the hold.
    @Test func deferredStartStaysInFlightUntilCancelled() async {
        let oldSession = GatedVoiceCaptureSession()
        let deferredSession = GatedVoiceCaptureSession(
            startError: VoiceRecorder.RecorderError.recordingInProgress
        )
        var sessions: [GatedVoiceCaptureSession] = [oldSession, deferredSession]
        let viewModel = VoiceRecordingViewModel()
        viewModel.sessionProvider = { sessions.removeFirst() }

        viewModel.start(shouldShow: true)
        await waitUntil { self.isRecording(viewModel.state) }
        viewModel.finish(completion: { _ in })
        await waitUntil { oldSession.finishStarted }
        #expect(!viewModel.isStartDeferred)

        viewModel.start(shouldShow: true)
        await waitUntil { deferredSession.cancelCount == 1 && viewModel.state == .idle }
        #expect(viewModel.isStartDeferred)
        #expect(viewModel.isHoldInFlight)

        viewModel.cancelAnyHold()
        #expect(!viewModel.isStartDeferred)
        #expect(!viewModel.isHoldInFlight)
        oldSession.resolveFinish(with: nil)
    }

    /// Only the recorder standing down marks a start deferred. A hold
    /// cancelled while it spins up stays ended, even when its start then
    /// fails the same way, so the finger still down can't restart it.
    @Test func holdCancelledWhileStartingIsNotDeferred() async {
        let session = GatedStartVoiceCaptureSession()
        let viewModel = VoiceRecordingViewModel()
        viewModel.sessionProvider = { session }

        viewModel.start(shouldShow: true)
        await waitUntil { session.isStarting }
        #expect(viewModel.state == .preparing)

        viewModel.cancelAnyHold()
        session.failStart(with: VoiceRecorder.RecorderError.recordingInProgress)
        // Once by the cancel, once by the failed start just before it
        // decides whether to stand down.
        await waitUntil { session.cancelCount == 2 }

        #expect(viewModel.state == .idle)
        #expect(!viewModel.isStartDeferred)
        #expect(!viewModel.isHoldInFlight)
    }

    // MARK: One press, one hold

    /// The drag reports every movement of a press. Only the first starts a
    /// hold, whatever phase that hold is in when the next one arrives.
    @Test func aPressStartsOneHoldHoweverOftenItMoves() async {
        let session = GatedVoiceCaptureSession()
        let script = SessionScript([session])
        let viewModel = VoiceRecordingViewModel()
        viewModel.sessionProvider = { script.next() }

        viewModel.pressChanged(shouldShow: true)
        viewModel.pressChanged(shouldShow: true)
        await waitUntil { self.isRecording(viewModel.state) }
        viewModel.pressChanged(shouldShow: true)
        viewModel.pressChanged(shouldShow: true)

        #expect(script.provided == 1)
        #expect(session.cancelCount == 0)
        #expect(isRecording(viewModel.state))
    }

    /// Something else ended the hold under a finger still down: a
    /// conversation or layout change, or the HUD's cancel. Moving that
    /// finger must not start another hold, aimed at whatever is selected
    /// now.
    @Test func aHoldEndedUnderTheFingerIsNotRestartedByIt() async {
        let session = GatedVoiceCaptureSession()
        let script = SessionScript([session])
        let viewModel = VoiceRecordingViewModel()
        viewModel.sessionProvider = { script.next() }

        viewModel.pressChanged(shouldShow: true)
        await waitUntil { self.isRecording(viewModel.state) }
        viewModel.cancelAnyHold()
        await waitUntil { session.cancelCount == 1 }

        viewModel.pressChanged(shouldShow: true)
        viewModel.pressChanged(shouldShow: true)

        #expect(script.provided == 1)
        #expect(viewModel.state == .idle)
        #expect(!viewModel.isHoldInFlight)
    }

    /// A panic ends the hold the same way. The finger still down must not
    /// open the microphone again once the wipe has run.
    @Test func aPanicEndsTheHoldButNotThePress() async {
        let session = GatedVoiceCaptureSession()
        let script = SessionScript([session])
        let viewModel = VoiceRecordingViewModel()
        viewModel.sessionProvider = { script.next() }

        viewModel.pressChanged(shouldShow: true)
        await waitUntil { self.isRecording(viewModel.state) }
        viewModel.panicWipe()
        viewModel.pressChanged(shouldShow: true)

        #expect(script.provided == 1)
        #expect(session.panicCancelCount == 1)
        #expect(viewModel.state == .idle)
    }

    /// The exception: a start that stood down while the previous classic
    /// note finalizes lets the same press try again.
    @Test func aDeferredStartLetsTheSamePressRetry() async {
        let oldSession = GatedVoiceCaptureSession()
        let deferredSession = GatedVoiceCaptureSession(
            startError: VoiceRecorder.RecorderError.recordingInProgress
        )
        let retrySession = GatedVoiceCaptureSession()
        let script = SessionScript([oldSession, deferredSession, retrySession])
        let viewModel = VoiceRecordingViewModel()
        viewModel.sessionProvider = { script.next() }

        viewModel.pressChanged(shouldShow: true)
        await waitUntil { self.isRecording(viewModel.state) }
        viewModel.pressEnded(completion: { _ in })
        await waitUntil { oldSession.finishStarted }

        // The next press lands while the previous note finalizes.
        viewModel.pressChanged(shouldShow: true)
        await waitUntil { deferredSession.cancelCount == 1 && viewModel.isStartDeferred }

        viewModel.pressChanged(shouldShow: true)
        await waitUntil { self.isRecording(viewModel.state) }
        #expect(script.provided == 3)
        oldSession.resolveFinish(with: nil)
    }

    /// The mic can go away mid-press (#mesh to a geohash channel), taking
    /// the drag's end and the press reset with it. That ends the hold, and
    /// the next press, a fresh touch-down on a mic, starts one again.
    @Test func removingTheMicEndsItsPressAndRearmsTheNext() async {
        let first = GatedVoiceCaptureSession()
        let second = GatedVoiceCaptureSession()
        let script = SessionScript([first, second])
        let viewModel = VoiceRecordingViewModel()
        viewModel.sessionProvider = { script.next() }

        viewModel.pressChanged(shouldShow: true)
        await waitUntil { self.isRecording(viewModel.state) }
        viewModel.controlRemoved()
        #expect(viewModel.state == .idle)
        await waitUntil { first.cancelCount == 1 }

        viewModel.pressChanged(shouldShow: true)
        await waitUntil { self.isRecording(viewModel.state) }
        #expect(script.provided == 2)
    }

    /// A VoiceOver toggle starts a hold with no press behind it. The mic
    /// going away must end that hold too, or a live stream would carry on
    /// behind a composer that can't stop it.
    @Test func removingTheMicEndsAToggleStartedHold() async {
        let session = GatedVoiceCaptureSession()
        let viewModel = VoiceRecordingViewModel()
        viewModel.sessionProvider = { session }

        viewModel.start(shouldShow: true)
        await waitUntil { self.isRecording(viewModel.state) }
        viewModel.controlRemoved()

        #expect(viewModel.state == .idle)
        #expect(!viewModel.isHoldInFlight)
        await waitUntil { session.cancelCount == 1 }
    }

    /// Lifting ends the press, so the next touch-down starts a hold.
    @Test func liftingThePressRearmsTheNext() async {
        let first = GatedVoiceCaptureSession()
        let second = GatedVoiceCaptureSession()
        let script = SessionScript([first, second])
        let viewModel = VoiceRecordingViewModel()
        viewModel.sessionProvider = { script.next() }

        viewModel.pressChanged(shouldShow: true)
        await waitUntil { self.isRecording(viewModel.state) }
        viewModel.pressEnded(completion: { _ in })
        await waitUntil { first.finishStarted }

        viewModel.pressChanged(shouldShow: true)
        await waitUntil { self.isRecording(viewModel.state) }
        #expect(script.provided == 2)
        first.resolveFinish(with: nil)
    }

    /// A touch the system cancels never reaches the drag's end. The press
    /// reset still ends the press, and the composer cancels the hold it
    /// left in flight, so the next touch-down starts a hold.
    @Test func aCancelledTouchRearmsTheNextPress() async {
        let first = GatedVoiceCaptureSession()
        let second = GatedVoiceCaptureSession()
        let script = SessionScript([first, second])
        let viewModel = VoiceRecordingViewModel()
        viewModel.sessionProvider = { script.next() }

        viewModel.pressChanged(shouldShow: true)
        await waitUntil { self.isRecording(viewModel.state) }
        viewModel.pressReleased()
        // What the composer does a hop later, the hold still in flight.
        viewModel.cancelAnyHold()
        await waitUntil { first.cancelCount == 1 }

        viewModel.pressChanged(shouldShow: true)
        await waitUntil { self.isRecording(viewModel.state) }
        #expect(script.provided == 2)
    }

    // MARK: A released note is delivered

    /// The next press can land in a classic note's finalize padding and
    /// stand down. The released note was bound to its conversation at the
    /// release, so it is still delivered, and the newer press keeps its
    /// retry.
    @Test func aNoteReleasedBeforeTheNextPressIsStillDelivered() async throws {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let oldSession = GatedVoiceCaptureSession()
        let deferredSession = GatedVoiceCaptureSession(
            startError: VoiceRecorder.RecorderError.recordingInProgress
        )
        let script = SessionScript([oldSession, deferredSession])
        let viewModel = VoiceRecordingViewModel(now: { clock })
        viewModel.sessionProvider = { script.next() }
        let url = try makeVoiceNoteFile()
        defer { try? FileManager.default.removeItem(at: url) }
        var delivered: [URL] = []

        viewModel.pressChanged(shouldShow: true)
        await waitUntil { self.isRecording(viewModel.state) }
        clock = clock.addingTimeInterval(3)
        viewModel.pressEnded { delivered.append($0) }
        await waitUntil { oldSession.finishStarted }

        viewModel.pressChanged(shouldShow: true)
        await waitUntil { deferredSession.cancelCount == 1 && viewModel.isStartDeferred }

        oldSession.resolveFinish(with: url)
        await waitUntil { delivered == [url] }
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(viewModel.state == .idle)
        #expect(viewModel.isStartDeferred)
    }

    /// A tap in that padding starts and ends a hold before it records. The
    /// released note survives that too.
    @Test func aTapDuringFinalizeKeepsTheReleasedNote() async throws {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let oldSession = GatedVoiceCaptureSession()
        let tapSession = GatedVoiceCaptureSession()
        let script = SessionScript([oldSession, tapSession])
        let viewModel = VoiceRecordingViewModel(now: { clock })
        viewModel.sessionProvider = { script.next() }
        let url = try makeVoiceNoteFile()
        defer { try? FileManager.default.removeItem(at: url) }
        var delivered: [URL] = []

        viewModel.pressChanged(shouldShow: true)
        await waitUntil { self.isRecording(viewModel.state) }
        clock = clock.addingTimeInterval(3)
        viewModel.pressEnded { delivered.append($0) }
        await waitUntil { oldSession.finishStarted }

        // Down and up again before the tap's hold is past its permission
        // check.
        viewModel.pressChanged(shouldShow: true)
        viewModel.pressEnded { _ in Issue.record("A tap records nothing to deliver") }
        await waitUntil { tapSession.cancelCount == 1 }

        oldSession.resolveFinish(with: url)
        await waitUntil { delivered == [url] }
        #expect(script.provided == 2)
        #expect(viewModel.state == .idle)
    }

    /// A note too short to keep doesn't alert over a newer press: that
    /// press owns the state now, and an alert would block its retry.
    @Test func aStaleTooShortNoteRaisesNoAlertOverANewerPress() async throws {
        // A clock that never moves makes every note too short.
        let clock = Date(timeIntervalSince1970: 1_000_000)
        let oldSession = GatedVoiceCaptureSession()
        let deferredSession = GatedVoiceCaptureSession(
            startError: VoiceRecorder.RecorderError.recordingInProgress
        )
        let script = SessionScript([oldSession, deferredSession])
        let viewModel = VoiceRecordingViewModel(now: { clock })
        viewModel.sessionProvider = { script.next() }
        let url = try makeVoiceNoteFile()
        defer { try? FileManager.default.removeItem(at: url) }

        viewModel.pressChanged(shouldShow: true)
        await waitUntil { self.isRecording(viewModel.state) }
        viewModel.pressEnded { _ in Issue.record("A note this short isn't delivered") }
        await waitUntil { oldSession.finishStarted }

        viewModel.pressChanged(shouldShow: true)
        await waitUntil { deferredSession.cancelCount == 1 && viewModel.isStartDeferred }

        oldSession.resolveFinish(with: url)
        await waitUntil { !FileManager.default.fileExists(atPath: url.path) }
        #expect(viewModel.state == .idle)
        #expect(viewModel.isStartDeferred)
    }

    /// With nothing after it, a note too short to keep still says so.
    @Test func aTooShortNoteOnItsOwnStillAlerts() async throws {
        let clock = Date(timeIntervalSince1970: 1_000_000)
        let session = GatedVoiceCaptureSession()
        let viewModel = VoiceRecordingViewModel(now: { clock })
        viewModel.sessionProvider = { session }
        let url = try makeVoiceNoteFile()
        defer { try? FileManager.default.removeItem(at: url) }

        viewModel.pressChanged(shouldShow: true)
        await waitUntil { self.isRecording(viewModel.state) }
        viewModel.pressEnded { _ in Issue.record("A note this short isn't delivered") }
        await waitUntil { session.finishStarted }
        session.resolveFinish(with: url)

        await waitUntil { viewModel.showAlert }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func panicSynchronouslyCancelsActiveCaptureAndResetsUI() async {
        let session = GatedVoiceCaptureSession()
        let viewModel = VoiceRecordingViewModel()
        viewModel.sessionProvider = { session }

        viewModel.start(shouldShow: true)
        await waitUntil { self.isRecording(viewModel.state) }

        viewModel.panicWipe()

        #expect(session.panicCancelCount == 1)
        #expect(viewModel.state == .idle)
        #expect(!viewModel.isLiveStreaming)
    }

    @Test func panicInvalidatesARecordingAlreadyFinalizing() async throws {
        let session = GatedVoiceCaptureSession()
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let viewModel = VoiceRecordingViewModel(now: { clock })
        viewModel.sessionProvider = { session }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-panic-\(UUID().uuidString).m4a")
        try Data([0x01]).write(to: url)
        var delivered = false

        viewModel.start(shouldShow: true)
        await waitUntil { self.isRecording(viewModel.state) }
        // Long enough to keep, so only the panic stands between this note
        // and its delivery.
        clock = clock.addingTimeInterval(3)
        viewModel.finish { _ in delivered = true }
        await waitUntil { session.finishStarted }

        viewModel.panicWipe()
        session.resolveFinish(with: url)
        await waitUntil {
            !FileManager.default.fileExists(atPath: url.path)
        }

        #expect(!delivered)
        #expect(viewModel.state == .idle)
    }

    @Test func liveSessionPanicStopsCaptureWithoutSendingControl() {
        let capture = StubPTTCapture(stopResult: (nil, 0))
        var sentPackets: [Data] = []
        let session = PTTLiveVoiceSession(
            sendPacket: { sentPackets.append($0) },
            capture: capture
        )

        session.panicCancelSynchronously()

        #expect(capture.cancelCount == 1)
        #expect(sentPackets.isEmpty)
    }
}
