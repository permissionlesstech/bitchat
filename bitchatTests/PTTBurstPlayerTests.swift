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

@MainActor
private final class StubAudioSession: SessionApplying {
    var setCategoryError: Error?

    func setCategory(_ category: AudioSessionCoordinator.Category) throws {
        if let error = setCategoryError {
            setCategoryError = nil
            throw error
        }
    }

    func setActive(_ active: Bool, notifyOthersOnDeactivation: Bool) throws {}
}

private struct StubSessionError: Error {}

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
        let player = try #require(PTTBurstPlayer(coordinator: coordinator, makeEngine: {
            let engine = MockPlaybackEngine()
            box.engines.append(engine)
            return engine
        }))
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

    // MARK: - Talk-over (bidirectional)

    @Test func categoryEscalationRestartsEngineAndKeepsStreaming() throws {
        let coordinator = AudioSessionCoordinator(session: StubAudioSession())
        let (player, engines) = try makePlayer(coordinator: coordinator)

        let frames = try encodeSineFrames()
        player.enqueue(frames)
        #expect(engines().count == 1)
        #expect(engines()[0].startCount == 1)
        #expect(!engines()[0].scheduledBuffers.isEmpty)
        #expect(player.isPlaying)

        // Push-to-talk pressed while the burst plays: capture escalates the
        // session category. The playback engine must restart under the new
        // configuration, not die.
        let capture = try coordinator.acquire(.capture) {}
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

    @Test func realInterruptionStillStopsPlayback() throws {
        let coordinator = AudioSessionCoordinator(session: StubAudioSession())
        let (player, engines) = try makePlayer(coordinator: coordinator)

        let frames = try encodeSineFrames()
        player.enqueue(frames)
        #expect(player.isPlaying)

        // A system interruption (phone call) is not an escalation: stop.
        coordinator.handleInterruptionBegan()
        #expect(!player.isPlaying)
        #expect(engines().count == 1)
        #expect(engines()[0].stopCount == 1)

        // A stopped burst stays stopped.
        let before = engines()[0].scheduledBuffers.count
        player.enqueue(frames)
        #expect(engines()[0].scheduledBuffers.count == before)
    }

    // MARK: - Session acquire failure

    @Test func sessionAcquireFailureDoesNotStartUnregisteredPlayback() throws {
        let session = StubAudioSession()
        let coordinator = AudioSessionCoordinator(session: session)
        let (player, engines) = try makePlayer(coordinator: coordinator)

        // Playing without a registered holder would leave the engine exposed
        // to another holder's last-release deactivating the session under it.
        session.setCategoryError = StubSessionError()
        let frames = try encodeSineFrames()
        player.enqueue(frames)

        #expect(engines().count == 1)
        #expect(engines()[0].startCount == 0)
        #expect(!player.isPlaying)

        // The failed start latched the player off; later frames are ignored.
        player.enqueue(frames)
        #expect(engines()[0].scheduledBuffers.isEmpty)
        #expect(!player.isPlaying)
    }
}
