//
// VoiceRecorderTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Testing
@testable import bitchat

private final class VoiceRecorderTestSession: SessionApplying, @unchecked Sendable {
    private let lock = NSLock()
    private let activationGate = DispatchSemaphore(value: 0)
    private let shouldGateFirstActivation: Bool
    private var gatedFirstActivation = false
    private var _activationCalls: [Bool] = []
    private var _activationBegan = false

    init(gateFirstActivation: Bool = false) {
        self.shouldGateFirstActivation = gateFirstActivation
    }

    var activationCalls: [Bool] { lock.withLock { _activationCalls } }
    var activationBegan: Bool { lock.withLock { _activationBegan } }

    func setCategory(_ category: AudioSessionCoordinator.Category) throws {}

    func setActive(_ active: Bool, notifyOthersOnDeactivation: Bool) throws {
        let shouldWait = lock.withLock { () -> Bool in
            _activationCalls.append(active)
            guard active, shouldGateFirstActivation, !gatedFirstActivation else { return false }
            gatedFirstActivation = true
            _activationBegan = true
            return true
        }
        if shouldWait {
            activationGate.wait()
        }
    }

    func resumeActivation() {
        activationGate.signal()
    }
}

private final class TestVoiceAudioRecorder: VoiceAudioRecording {
    let prepareResult: Bool
    let recordResult: Bool

    private let lock = NSLock()
    private var _isRecording = false
    private var _isMeteringEnabled = false
    private var _prepareCallCount = 0
    private var _recordedDurations: [TimeInterval] = []
    private var _stopCallCount = 0

    init(prepareResult: Bool, recordResult: Bool) {
        self.prepareResult = prepareResult
        self.recordResult = recordResult
    }

    var isRecording: Bool { lock.withLock { _isRecording } }
    var isMeteringEnabled: Bool {
        get { lock.withLock { _isMeteringEnabled } }
        set { lock.withLock { _isMeteringEnabled = newValue } }
    }
    var prepareCallCount: Int { lock.withLock { _prepareCallCount } }
    var recordedDurations: [TimeInterval] { lock.withLock { _recordedDurations } }
    var stopCallCount: Int { lock.withLock { _stopCallCount } }

    func prepareToRecord() -> Bool {
        lock.withLock { _prepareCallCount += 1 }
        return prepareResult
    }

    func record(forDuration duration: TimeInterval) -> Bool {
        lock.withLock {
            _recordedDurations.append(duration)
            if recordResult {
                _isRecording = true
            }
        }
        return recordResult
    }

    func stop() {
        lock.withLock {
            _stopCallCount += 1
            _isRecording = false
        }
    }

    /// Models `record(forDuration:)` reaching its duration cap before the
    /// caller invokes `VoiceRecorder.stopRecording(owner:)`.
    func simulateAutomaticStop() {
        lock.withLock { _isRecording = false }
    }
}

private final class TestVoiceAudioRecorderFactory: VoiceAudioRecorderCreating {
    struct Plan {
        let prepareResult: Bool
        let recordResult: Bool

        static let success = Plan(prepareResult: true, recordResult: true)
    }

    private let lock = NSLock()
    private var plans: [Plan]
    private var _recorders: [TestVoiceAudioRecorder] = []
    private var _urls: [URL] = []

    init(plans: [Plan]) {
        self.plans = plans
    }

    var recorders: [TestVoiceAudioRecorder] { lock.withLock { _recorders } }
    var urls: [URL] { lock.withLock { _urls } }

    func makeRecorder(url: URL) throws -> any VoiceAudioRecording {
        let plan = lock.withLock { plans.isEmpty ? .success : plans.removeFirst() }
        // AVAudioRecorder creates its output during initialization. A real
        // byte on disk lets the tests distinguish preserve from delete.
        try Data([0x01]).write(to: url)
        let recorder = TestVoiceAudioRecorder(
            prepareResult: plan.prepareResult,
            recordResult: plan.recordResult
        )
        lock.withLock {
            _recorders.append(recorder)
            _urls.append(url)
        }
        return recorder
    }
}

/// One-shot async gate that proves `VoiceRecorder.stopRecording` has reached
/// its actor-reentrant padding boundary, then holds it there until the test has
/// exercised a competing owner. Unlike `Task.yield()` plus a short real sleep,
/// this remains deterministic when the full test suite saturates the executor.
private final class VoiceRecorderPaddingGate: @unchecked Sendable {
    private let lock = NSLock()
    private var _entered = false
    private var isOpen = false
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    var entered: Bool { lock.withLock { _entered } }

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock { () -> Bool in
                _entered = true
                guard !isOpen else { return true }
                openWaiters.append(continuation)
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func open() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { openWaiters.removeAll() }
            return openWaiters
        }
        waiters.forEach { $0.resume() }
    }
}

@MainActor
struct VoiceRecorderTests {
    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-recorder-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

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

    @Test func cancelWhileSessionAcquireIsInFlightNeverCreatesARecorder() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let session = VoiceRecorderTestSession(gateFirstActivation: true)
        let coordinator = AudioSessionCoordinator(session: session)
        let factory = TestVoiceAudioRecorderFactory(plans: [.success])
        let voiceRecorder = VoiceRecorder(
            sessionCoordinator: coordinator,
            recorderFactory: factory,
            permissionGranted: { true },
            paddingInterval: 0,
            outputDirectory: directory
        )
        let owner = VoiceRecorder.RecordingOwner()

        let startTask = Task { try await voiceRecorder.startRecording(owner: owner) }
        await waitUntil { session.activationBegan }

        await voiceRecorder.cancelRecording(owner: owner)
        session.resumeActivation()

        do {
            _ = try await startTask.value
            Issue.record("The canceled session acquire unexpectedly started recording")
        } catch {
            #expect(error is CancellationError)
        }
        await coordinator.drain()

        #expect(factory.recorders.isEmpty)
        #expect(session.activationCalls == [true, false])
    }

    @Test func prepareFailureCleansUpAndAllowsTheNextRecording() async throws {
        try await verifyFailedStart(
            firstPlan: .init(prepareResult: false, recordResult: true),
            expectedPrepareCalls: 1,
            expectedRecordCalls: 0
        )
    }

    @Test func recordFailureCleansUpAndAllowsTheNextRecording() async throws {
        try await verifyFailedStart(
            firstPlan: .init(prepareResult: true, recordResult: false),
            expectedPrepareCalls: 1,
            expectedRecordCalls: 1
        )
    }

    @Test func automaticStopReturnsAndPreservesFileThenNextRecordingWorks() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let session = VoiceRecorderTestSession()
        let coordinator = AudioSessionCoordinator(session: session)
        let factory = TestVoiceAudioRecorderFactory(plans: [.success, .success])
        let voiceRecorder = VoiceRecorder(
            sessionCoordinator: coordinator,
            recorderFactory: factory,
            permissionGranted: { true },
            paddingInterval: 0,
            outputDirectory: directory
        )
        let firstOwner = VoiceRecorder.RecordingOwner()

        let firstURL = try await voiceRecorder.startRecording(owner: firstOwner)
        let firstRecorder = try #require(factory.recorders.first)
        #expect(firstRecorder.recordedDurations == [120])
        firstRecorder.simulateAutomaticStop()

        let finishedURL = await voiceRecorder.stopRecording(owner: firstOwner)
        await coordinator.drain()
        #expect(finishedURL == firstURL)
        #expect(firstRecorder.stopCallCount == 0)
        #expect(FileManager.default.fileExists(atPath: firstURL.path))
        #expect(session.activationCalls == [true, false])

        let secondOwner = VoiceRecorder.RecordingOwner()
        let secondURL = try await voiceRecorder.startRecording(owner: secondOwner)
        #expect(secondURL != firstURL)
        #expect(FileManager.default.fileExists(atPath: firstURL.path))
        #expect(factory.recorders.count == 2)
        let secondRecorder = try #require(factory.recorders.last)

        #expect(await voiceRecorder.stopRecording(owner: secondOwner) == secondURL)
        await coordinator.drain()
        #expect(secondRecorder.stopCallCount == 1)
        #expect(session.activationCalls == [true, false, true, false])
        #expect(FileManager.default.fileExists(atPath: firstURL.path))
        #expect(FileManager.default.fileExists(atPath: secondURL.path))
    }

    @Test func rejectedNewHoldCancelCannotDeleteHoldFinishingDuringPadding() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let session = VoiceRecorderTestSession()
        let coordinator = AudioSessionCoordinator(session: session)
        let factory = TestVoiceAudioRecorderFactory(plans: [.success, .success])
        let paddingGate = VoiceRecorderPaddingGate()
        let voiceRecorder = VoiceRecorder(
            sessionCoordinator: coordinator,
            recorderFactory: factory,
            permissionGranted: { true },
            paddingInterval: 0.05,
            outputDirectory: directory,
            testingHooks: .init(waitForStopPadding: { _ in await paddingGate.wait() })
        )
        let finishingHold = VoiceNoteCaptureSession(recorder: voiceRecorder)
        let rejectedHold = VoiceNoteCaptureSession(recorder: voiceRecorder)

        try await finishingHold.start()
        let firstURL = try #require(factory.urls.first)
        let finishTask = Task { await finishingHold.finish() }
        await waitUntil { paddingGate.entered }

        await #expect(throws: VoiceRecorder.RecorderError.recordingInProgress) {
            try await rejectedHold.start()
        }
        // This is the view-model error path that used to globally cancel the
        // shared recorder and delete `firstURL` during the padding sleep.
        await rejectedHold.cancel()
        paddingGate.open()

        #expect(await finishTask.value == firstURL)
        await coordinator.drain()
        #expect(FileManager.default.fileExists(atPath: firstURL.path))
        #expect(factory.recorders[0].stopCallCount == 1)
        #expect(session.activationCalls == [true, false])
    }

    @Test func stalePreviousHoldCancelCannotStopNewRecording() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let session = VoiceRecorderTestSession()
        let coordinator = AudioSessionCoordinator(session: session)
        let factory = TestVoiceAudioRecorderFactory(plans: [.success, .success])
        let voiceRecorder = VoiceRecorder(
            sessionCoordinator: coordinator,
            recorderFactory: factory,
            permissionGranted: { true },
            paddingInterval: 0,
            outputDirectory: directory
        )
        let previousHold = VoiceNoteCaptureSession(recorder: voiceRecorder)
        let currentHold = VoiceNoteCaptureSession(recorder: voiceRecorder)

        try await previousHold.start()
        let firstURL = try #require(factory.urls.first)
        #expect(await previousHold.finish() == firstURL)

        try await currentHold.start()
        let secondURL = try #require(factory.urls.last)
        let secondRecorder = try #require(factory.recorders.last)
        await previousHold.cancel()

        #expect(secondRecorder.isRecording)
        #expect(FileManager.default.fileExists(atPath: secondURL.path))
        #expect(await currentHold.finish() == secondURL)
        await coordinator.drain()
        #expect(secondRecorder.stopCallCount == 1)
        #expect(FileManager.default.fileExists(atPath: firstURL.path))
        #expect(FileManager.default.fileExists(atPath: secondURL.path))
    }

    private func verifyFailedStart(
        firstPlan: TestVoiceAudioRecorderFactory.Plan,
        expectedPrepareCalls: Int,
        expectedRecordCalls: Int
    ) async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let session = VoiceRecorderTestSession()
        let coordinator = AudioSessionCoordinator(session: session)
        let factory = TestVoiceAudioRecorderFactory(plans: [firstPlan, .success])
        let voiceRecorder = VoiceRecorder(
            sessionCoordinator: coordinator,
            recorderFactory: factory,
            permissionGranted: { true },
            paddingInterval: 0,
            outputDirectory: directory
        )
        let failedOwner = VoiceRecorder.RecordingOwner()

        await #expect(throws: VoiceRecorder.RecorderError.failedToStartRecording) {
            try await voiceRecorder.startRecording(owner: failedOwner)
        }
        await coordinator.drain()

        let failedRecorder = try #require(factory.recorders.first)
        let failedURL = try #require(factory.urls.first)
        #expect(failedRecorder.prepareCallCount == expectedPrepareCalls)
        #expect(failedRecorder.recordedDurations.count == expectedRecordCalls)
        #expect(!FileManager.default.fileExists(atPath: failedURL.path))
        #expect(session.activationCalls == [true, false])

        let nextOwner = VoiceRecorder.RecordingOwner()
        let nextURL = try await voiceRecorder.startRecording(owner: nextOwner)
        #expect(FileManager.default.fileExists(atPath: nextURL.path))
        #expect(await voiceRecorder.stopRecording(owner: nextOwner) == nextURL)
        await coordinator.drain()
        #expect(session.activationCalls == [true, false, true, false])
    }
}
