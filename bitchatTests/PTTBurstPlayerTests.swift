//
// PTTBurstPlayerTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import AVFoundation
import Foundation
@testable import bitchat

/// Thread-safe: the coordinator invokes it on its private serial queue.
private final class StubAudioSession: SessionApplying, @unchecked Sendable {
    private let lock = NSLock()
    private var _setCategoryError: Error?

    var setCategoryError: Error? {
        get { lock.withLock { _setCategoryError } }
        set { lock.withLock { _setCategoryError = newValue } }
    }

    func setCategory(_ category: AudioSessionCoordinator.Category) throws {
        try lock.withLock {
            if let error = _setCategoryError {
                _setCategoryError = nil
                throw error
            }
        }
    }

    func setActive(_ active: Bool, notifyOthersOnDeactivation: Bool) throws {}
}

private struct StubSessionError: Error {}

/// Blocks activation until released, so a test can land events inside the
/// window where the (off-main) session acquire is still in flight.
private final class GatedAudioSession: SessionApplying, @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)

    func open() { gate.signal() }

    func setCategory(_ category: AudioSessionCoordinator.Category) throws {}

    func setActive(_ active: Bool, notifyOthersOnDeactivation: Bool) throws {
        if active { gate.wait() }
    }
}

@MainActor
private final class MockPlaybackEngine: PTTPlaybackEngine {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var scheduledBuffers: [AVAudioPCMBuffer] = []
    var startError: Error?

    // No object -> the player registers no configuration-change observer.
    var configChangeObject: AnyObject? { nil }

    func start() throws {
        if let error = startError { throw error }
        startCount += 1
    }

    func play() {}

    func stop() {
        stopCount += 1
    }

    func schedule(_ buffer: AVAudioPCMBuffer, completionHandler: @escaping @Sendable () -> Void) {
        // Completions are held, not fired: these tests exercise lifecycle,
        // not drain-out.
        scheduledBuffers.append(buffer)
    }
}

@MainActor
struct PTTBurstPlayerTests {
    private func makePlayer(
        coordinator: AudioSessionCoordinator
    ) throws -> (player: PTTBurstPlayer, engines: () -> [MockPlaybackEngine]) {
        final class EngineBox { var engines: [MockPlaybackEngine] = [] }
        let box = EngineBox()
        // Fresh exclusivity slot: parallel tests must not steal this player's
        // app-wide playback slot mid-test (the async session acquire opens
        // suspension windows the old synchronous start never had).
        let player = try #require(PTTBurstPlayer(
            coordinator: coordinator,
            exclusivity: VoiceNotePlaybackCoordinator(),
            makeEngine: {
                let engine = MockPlaybackEngine()
                box.engines.append(engine)
                return engine
            }
        ))
        return (player, { box.engines })
    }

    /// Enough encoded audio to cross `TransportConfig.pttJitterBufferSeconds`
    /// so playback starts without waiting for the deadline task.
    private func encodeSineFrames(seconds: Double = 1.0) throws -> [Data] {
        let encoder = try #require(PTTFrameEncoder())
        let format = try #require(PTTAudioFormat.pcmFormat)
        let totalFrames = AVAudioFrameCount(seconds * PTTAudioFormat.sampleRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames))
        buffer.frameLength = totalFrames
        let channel = try #require(buffer.floatChannelData?[0])
        for i in 0..<Int(totalFrames) {
            channel[i] = sinf(2 * .pi * 440 * Float(i) / Float(PTTAudioFormat.sampleRate)) * 0.5
        }
        return encoder.encode(buffer)
    }

    /// The jitter-buffered start now acquires the session asynchronously
    /// (its blocking IPC runs off the main actor), so tests await the
    /// condition instead of asserting right after `enqueue`.
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

    // MARK: - Talk-over (bidirectional)

    @Test func categoryEscalationRestartsEngineAndKeepsStreaming() async throws {
        let coordinator = AudioSessionCoordinator(session: StubAudioSession())
        let (player, engines) = try makePlayer(coordinator: coordinator)

        let frames = try encodeSineFrames()
        player.enqueue(frames)
        await waitUntil { player.isPlaying }
        #expect(engines().count == 1)
        #expect(engines()[0].startCount == 1)
        #expect(!engines()[0].scheduledBuffers.isEmpty)

        // Push-to-talk pressed while the burst plays: capture escalates the
        // session category. The playback engine must restart under the new
        // configuration, not die. (Escalation fan-out is delivered before
        // acquire returns, so no waiting is needed here.)
        let capture = try await coordinator.acquire(.capture) {}
        #expect(engines().count == 2)
        #expect(engines()[0].stopCount == 1)
        #expect(engines()[1].startCount == 1)
        #expect(player.isPlaying)

        // Frames arriving after the restart keep playing on the new engine.
        player.enqueue(frames)
        #expect(!engines()[1].scheduledBuffers.isEmpty)

        coordinator.release(capture)
        player.stop()
        #expect(!player.isPlaying)
    }

    @Test func realInterruptionStillStopsPlayback() async throws {
        let coordinator = AudioSessionCoordinator(session: StubAudioSession())
        let (player, engines) = try makePlayer(coordinator: coordinator)

        let frames = try encodeSineFrames()
        player.enqueue(frames)
        await waitUntil { player.isPlaying }

        // A system interruption (phone call) is not an escalation: stop.
        await coordinator.handleInterruptionBegan()
        #expect(!player.isPlaying)
        #expect(engines().count == 1)
        #expect(engines()[0].stopCount == 1)

        // A stopped burst stays stopped.
        let before = engines()[0].scheduledBuffers.count
        player.enqueue(frames)
        #expect(engines()[0].scheduledBuffers.count == before)
    }

    // MARK: - Burst END racing the async session acquire

    @Test func burstEndDuringSessionAcquireStillPlays() async throws {
        let session = GatedAudioSession()
        let coordinator = AudioSessionCoordinator(session: session)
        let (player, engines) = try makePlayer(coordinator: coordinator)

        let frames = try encodeSineFrames()
        player.enqueue(frames)
        // END lands while activation is still blocked on the session queue.
        // With nothing scheduled yet, the drain check must not mistake the
        // not-yet-started burst for a played-out one and drop all its audio.
        player.finishAfterDrain()
        #expect(!player.stopped)

        session.open()
        await waitUntil { player.isPlaying }
        #expect(engines()[0].startCount == 1)
        #expect(!engines()[0].scheduledBuffers.isEmpty)
        player.stop()
    }

    // MARK: - Session acquire failure

    @Test func sessionAcquireFailureDoesNotStartUnregisteredPlayback() async throws {
        let session = StubAudioSession()
        let coordinator = AudioSessionCoordinator(session: session)
        let (player, engines) = try makePlayer(coordinator: coordinator)

        // Playing without a registered holder would leave the engine exposed
        // to another holder's last-release deactivating the session under it.
        session.setCategoryError = StubSessionError()
        let frames = try encodeSineFrames()
        player.enqueue(frames)
        await waitUntil { player.stopped }

        #expect(engines().count == 1)
        #expect(engines()[0].startCount == 0)
        #expect(!player.isPlaying)

        // The failed start latched the player off; later frames are ignored.
        player.enqueue(frames)
        #expect(engines()[0].scheduledBuffers.isEmpty)
        #expect(!player.isPlaying)
    }
}
