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
struct VoiceCaptureSessionTests {
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
}
