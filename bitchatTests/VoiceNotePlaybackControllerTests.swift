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

@MainActor
private final class RecordingAudioSession: SessionApplying {
    private(set) var activationCalls: [Bool] = []

    func setCategory(_ category: AudioSessionCoordinator.Category) throws {}

    func setActive(_ active: Bool, notifyOthersOnDeactivation: Bool) throws {
        activationCalls.append(active)
    }
}

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

    @Test func seekWhilePausedDoesNotAcquireSession() throws {
        let session = RecordingAudioSession()
        let coordinator = AudioSessionCoordinator(session: session)
        let url = try makeTempVoiceNote()
        defer { try? FileManager.default.removeItem(at: url) }

        let controller = VoiceNotePlaybackController(url: url, sessionCoordinator: coordinator)
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

        var controller: VoiceNotePlaybackController? =
            VoiceNotePlaybackController(url: url, sessionCoordinator: coordinator)
        controller?.play()
        #expect(session.activationCalls == [true])

        // Navigating away discards the row's @StateObject mid-playback:
        // deinit must release the session hold (via a main-actor hop).
        controller = nil

        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while session.activationCalls.count < 2, ContinuousClock.now < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(session.activationCalls == [true, false])
    }
}
