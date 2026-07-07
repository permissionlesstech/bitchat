//
// PTTBurstPlayer.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import AVFoundation
import BitLogger
import Foundation

/// Plays one inbound live voice burst with a small jitter buffer.
///
/// Frames are decoded and scheduled back-to-back on an `AVAudioPlayerNode`;
/// an underrun (missing/late packets) simply pauses output until the next
/// buffer arrives, which self-heals timing without explicit silence
/// insertion. Playback starts once `TransportConfig.pttJitterBufferSeconds`
/// of audio is queued or `pttJitterDeadlineSeconds` has elapsed.
@MainActor
final class PTTBurstPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let decoder: PTTFrameDecoder

    private var queuedBuffers: [AVAudioPCMBuffer] = []
    private var queuedDuration: TimeInterval = 0
    private var scheduledCount = 0
    private var engineStarted = false
    private var finished = false
    private var stopped = false
    private var deadlineTask: Task<Void, Never>?

    private(set) var isPlaying = false

    init?() {
        guard let format = PTTAudioFormat.pcmFormat, let decoder = PTTFrameDecoder() else { return nil }
        self.decoder = decoder
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)

        deadlineTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(TransportConfig.pttJitterDeadlineSeconds * 1_000_000_000))
            self?.startIfReady(force: true)
        }
    }

    /// Decodes and queues frames (in burst order). Starts playback when the
    /// jitter buffer fills.
    func enqueue(_ frames: [Data]) {
        guard !stopped else { return }
        for frame in frames {
            guard let pcm = decoder.decode(frame) else { continue }
            if engineStarted {
                schedule(pcm)
            } else {
                queuedBuffers.append(pcm)
                queuedDuration += Double(pcm.frameLength) / PTTAudioFormat.sampleRate
            }
        }
        startIfReady(force: false)
    }

    /// The burst ended: stop once everything scheduled has played out.
    func finishAfterDrain() {
        finished = true
        stopIfDrained()
    }

    /// Immediate stop (cancel, another playback taking over, teardown).
    func stop() {
        guard !stopped else { return }
        stopped = true
        deadlineTask?.cancel()
        queuedBuffers = []
        if engineStarted {
            node.stop()
            engine.stop()
        }
        isPlaying = false
        VoiceNotePlaybackCoordinator.shared.deactivate(self)
    }

    private func startIfReady(force: Bool) {
        guard !engineStarted, !stopped, !queuedBuffers.isEmpty else { return }
        guard force || queuedDuration >= TransportConfig.pttJitterBufferSeconds else { return }

        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers])
            try session.setActive(true, options: [])
        } catch {
            SecureLogger.error("PTT playback session activation failed: \(error)", category: .session)
        }
        #endif

        engine.prepare()
        do {
            try engine.start()
        } catch {
            SecureLogger.error("PTT playback engine failed to start: \(error)", category: .session)
            stopped = true
            return
        }
        engineStarted = true
        isPlaying = true
        VoiceNotePlaybackCoordinator.shared.activate(self)
        node.play()

        let buffered = queuedBuffers
        queuedBuffers = []
        queuedDuration = 0
        for buffer in buffered {
            schedule(buffer)
        }
    }

    private func schedule(_ buffer: AVAudioPCMBuffer) {
        scheduledCount += 1
        node.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.scheduledCount -= 1
                self.stopIfDrained()
            }
        }
    }

    private func stopIfDrained() {
        guard finished, scheduledCount <= 0 else { return }
        stop()
    }
}

extension PTTBurstPlayer: ExclusivePlayback {
    /// A live stream can't meaningfully pause; yielding the floor stops it.
    /// The burst keeps assembling to file, so nothing is lost.
    nonisolated func pauseForExclusivity() {
        Task { @MainActor [weak self] in
            self?.stop()
        }
    }
}
