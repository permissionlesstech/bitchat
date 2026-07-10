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
    /// caller invokes `VoiceRecorder.stopRecording()`.
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

        let startTask = Task { try await voiceRecorder.startRecording() }
        await waitUntil { session.activationBegan }

        await voiceRecorder.cancelRecording()
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

        let firstURL = try await voiceRecorder.startRecording()
        let firstRecorder = try #require(factory.recorders.first)
        #expect(firstRecorder.recordedDurations == [120])
        firstRecorder.simulateAutomaticStop()

        let finishedURL = await voiceRecorder.stopRecording()
        await coordinator.drain()
        #expect(finishedURL == firstURL)
        #expect(firstRecorder.stopCallCount == 0)
        #expect(FileManager.default.fileExists(atPath: firstURL.path))
        #expect(session.activationCalls == [true, false])

        let secondURL = try await voiceRecorder.startRecording()
        #expect(secondURL != firstURL)
        #expect(FileManager.default.fileExists(atPath: firstURL.path))
        #expect(factory.recorders.count == 2)
        let secondRecorder = try #require(factory.recorders.last)

        #expect(await voiceRecorder.stopRecording() == secondURL)
        await coordinator.drain()
        #expect(secondRecorder.stopCallCount == 1)
        #expect(session.activationCalls == [true, false, true, false])
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

        await #expect(throws: VoiceRecorder.RecorderError.failedToStartRecording) {
            try await voiceRecorder.startRecording()
        }
        await coordinator.drain()

        let failedRecorder = try #require(factory.recorders.first)
        let failedURL = try #require(factory.urls.first)
        #expect(failedRecorder.prepareCallCount == expectedPrepareCalls)
        #expect(failedRecorder.recordedDurations.count == expectedRecordCalls)
        #expect(!FileManager.default.fileExists(atPath: failedURL.path))
        #expect(session.activationCalls == [true, false])

        let nextURL = try await voiceRecorder.startRecording()
        #expect(FileManager.default.fileExists(atPath: nextURL.path))
        #expect(await voiceRecorder.stopRecording() == nextURL)
        await coordinator.drain()
        #expect(session.activationCalls == [true, false, true, false])
    }
}
