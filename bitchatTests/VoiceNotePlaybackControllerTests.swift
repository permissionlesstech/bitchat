//
// VoiceNotePlaybackControllerTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import AVFoundation
import Foundation
@testable import bitchat

/// Thread-safe: the coordinator invokes it on its private serial queue (the
/// blocking session IPC runs off the main thread) while the test reads from
/// the main actor.
private final class RecordingAudioSession: SessionApplying, @unchecked Sendable {
    private let lock = NSLock()
    private var _activationCalls: [Bool] = []
    private var _categoryCallCount = 0
    private var _categoryError: Error?

    var activationCalls: [Bool] { lock.withLock { _activationCalls } }
    var categoryCallCount: Int { lock.withLock { _categoryCallCount } }
    var categoryError: Error? {
        get { lock.withLock { _categoryError } }
        set { lock.withLock { _categoryError = newValue } }
    }

    func setCategory(_ category: AudioSessionCoordinator.Category) throws {
        try lock.withLock {
            _categoryCallCount += 1
            if let error = _categoryError {
                _categoryError = nil
                throw error
            }
        }
    }

    func setActive(_ active: Bool, notifyOthersOnDeactivation: Bool) throws {
        lock.withLock { _activationCalls.append(active) }
    }
}

private struct PlaybackSessionError: Error {}

@MainActor
struct VoiceNotePlaybackControllerTests {
    /// A short silent PCM file `AVAudioPlayer` can open on the test host.
    private func makeTempVoiceNote(seconds: Double = 0.2) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-note-test-\(UUID().uuidString).caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * 16_000)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        try file.write(from: buffer)
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

    @Test func seekWhilePausedDoesNotAcquireSession() throws {
        let session = RecordingAudioSession()
        let coordinator = AudioSessionCoordinator(session: session)
        let url = try makeTempVoiceNote()
        defer { try? FileManager.default.removeItem(at: url) }

        let controller = VoiceNotePlaybackController(
            url: url,
            sessionCoordinator: coordinator,
            exclusivity: VoiceNotePlaybackCoordinator()
        )
        controller.seek(to: 0.5)

        // The scrub position moved (the player is real and ready)...
        #expect(controller.progress > 0.25)
        // ...but nothing is audible, so the session must not be held: an
        // acquired-while-paused token on a discarded row would pin the
        // session (and any escalated category) forever.
        #expect(session.activationCalls.isEmpty)
        #expect(!controller.isPlaying)
    }

    @Test func deinitReleasesSessionAndStopsPlayback() async throws {
        let session = RecordingAudioSession()
        let coordinator = AudioSessionCoordinator(session: session)
        let url = try makeTempVoiceNote()
        defer { try? FileManager.default.removeItem(at: url) }

        // Fresh exclusivity slot: a parallel test's play() must not pause
        // this controller while its session acquire is in flight.
        var controller: VoiceNotePlaybackController? = VoiceNotePlaybackController(
            url: url,
            sessionCoordinator: coordinator,
            exclusivity: VoiceNotePlaybackCoordinator()
        )
        controller?.play()
        // The session acquire is asynchronous now (its blocking IPC runs off
        // the main thread), so await the activation instead of asserting
        // right after play().
        await waitUntil { session.activationCalls == [true] }

        // Navigating away discards the row's @StateObject mid-playback:
        // deinit must release the session hold (a fire-and-forget hop onto
        // the coordinator's queue).
        controller = nil

        await waitUntil { session.activationCalls == [true, false] }
    }

    @Test func activationFailureDoesNotStartUnregisteredPlayback() async throws {
        let session = RecordingAudioSession()
        session.categoryError = PlaybackSessionError()
        let coordinator = AudioSessionCoordinator(session: session)
        let url = try makeTempVoiceNote(seconds: 30)
        defer { try? FileManager.default.removeItem(at: url) }

        let controller = VoiceNotePlaybackController(
            url: url,
            sessionCoordinator: coordinator,
            exclusivity: VoiceNotePlaybackCoordinator()
        )
        controller.play()

        await waitUntil {
            session.categoryCallCount == 1 && !controller.isPlaybackStartPending
        }

        #expect(session.activationCalls.isEmpty)
        #expect(!controller.isPlaying)
        #expect(controller.currentTime == 0)
    }
}
