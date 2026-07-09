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

/// The engine operations behind live-burst playback, abstracted so the
/// player's lifecycle (jitter start, category-escalation restart, stop) is
/// unit-testable without real audio hardware.
@MainActor
protocol PTTPlaybackEngine: AnyObject {
    /// The object `AVAudioEngineConfigurationChange` notifications are posted
    /// for (nil for mocks — no observer is registered).
    var configChangeObject: AnyObject? { get }
    func start() throws
    func play()
    func stop()
    func schedule(_ buffer: AVAudioPCMBuffer, completionHandler: @escaping @Sendable () -> Void)
}

/// One `AVAudioEngine` + `AVAudioPlayerNode` pair. Created fresh per (re)start:
/// an engine instantiated against an earlier audio-session configuration keeps
/// rendering to the stale route (same class of failure as the capture side's
/// fresh-engine-per-press rule).
@MainActor
private final class SystemPTTPlaybackEngine: PTTPlaybackEngine {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()

    init(format: AVAudioFormat) {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    var configChangeObject: AnyObject? { engine }

    func start() throws {
        engine.prepare()
        try engine.start()
    }

    func play() {
        node.play()
    }

    func stop() {
        node.stop()
        engine.stop()
    }

    func schedule(_ buffer: AVAudioPCMBuffer, completionHandler: @escaping @Sendable () -> Void) {
        node.scheduleBuffer(buffer, completionHandler: completionHandler)
    }
}

/// Plays one inbound live voice burst with a small jitter buffer.
///
/// Frames are decoded and scheduled back-to-back on an `AVAudioPlayerNode`;
/// an underrun (missing/late packets) simply pauses output until the next
/// buffer arrives, which self-heals timing without explicit silence
/// insertion. Playback starts once `TransportConfig.pttJitterBufferSeconds`
/// of audio is queued or `pttJitterDeadlineSeconds` has elapsed.
///
/// Talk-over is bidirectional: when push-to-talk capture starts while this
/// burst plays, the session category escalates underneath the engine — the
/// player rebuilds a fresh engine against the new configuration and keeps
/// streaming instead of dying. Real interruptions (phone call, route device
/// gone) still stop it; the burst keeps assembling to file either way.
@MainActor
final class PTTBurstPlayer {
    /// Restart-on-reconfigure ceiling: a burst is at most ~2 minutes, so a
    /// handful of category/route changes is plenty — beyond it something is
    /// thrashing and stopping cleanly beats an engine-rebuild loop.
    private static let maxEngineRestarts = 8

    private let makeEngine: @MainActor () -> PTTPlaybackEngine
    private var engine: PTTPlaybackEngine
    private let decoder: PTTFrameDecoder
    private let coordinator: AudioSessionCoordinator

    private var queuedBuffers: [AVAudioPCMBuffer] = []
    private var queuedDuration: TimeInterval = 0
    private var scheduledCount = 0
    /// Bumped on every engine rebuild so schedule-completion callbacks from a
    /// torn-down engine can't decrement the new engine's counter.
    private var engineGeneration = 0
    private var engineRestarts = 0
    private var engineStarted = false
    private var finished = false
    private var stopped = false
    private var deadlineTask: Task<Void, Never>?
    private var sessionToken: AudioSessionCoordinator.Token?
    private var configChangeObserver: NSObjectProtocol?

    private(set) var isPlaying = false

    init?(
        coordinator: AudioSessionCoordinator? = nil,
        makeEngine: (@MainActor () -> PTTPlaybackEngine)? = nil
    ) {
        guard let format = PTTAudioFormat.pcmFormat, let decoder = PTTFrameDecoder() else { return nil }
        self.decoder = decoder
        self.coordinator = coordinator ?? .shared
        let factory = makeEngine ?? { SystemPTTPlaybackEngine(format: format) }
        self.makeEngine = factory
        self.engine = factory()

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

    /// Immediate stop (cancel, another playback taking over, interruption,
    /// teardown).
    func stop() {
        guard !stopped else { return }
        stopped = true
        deadlineTask?.cancel()
        removeConfigObserver()
        queuedBuffers = []
        if engineStarted {
            engine.stop()
        }
        isPlaying = false
        releaseSessionToken()
        VoiceNotePlaybackCoordinator.shared.deactivate(self)
    }

    private func startIfReady(force: Bool) {
        guard !engineStarted, !stopped, !queuedBuffers.isEmpty else { return }
        guard force || queuedDuration >= TransportConfig.pttJitterBufferSeconds else { return }

        do {
            sessionToken = try coordinator.acquire(
                .playback,
                onInterrupted: { [weak self] in self?.stop() },
                onCategoryEscalated: { [weak self] in self?.restartEngine() }
            )
        } catch {
            SecureLogger.error("PTT playback session activation failed: \(error)", category: .session)
            // Playing unregistered would leave the engine exposed: another
            // holder's last release deactivates the session mid-play, and no
            // interruption/escalation fan-out ever reaches us. Bail like the
            // engine-start failure below; the burst still assembles to file.
            stopped = true
            deadlineTask?.cancel()
            queuedBuffers = []
            return
        }

        // Observe reconfiguration before starting so nothing lands between.
        registerConfigObserver()
        do {
            try engine.start()
        } catch {
            SecureLogger.error("PTT playback engine failed to start: \(error)", category: .session)
            removeConfigObserver()
            stopped = true
            releaseSessionToken()
            return
        }
        engineStarted = true
        isPlaying = true
        VoiceNotePlaybackCoordinator.shared.activate(self)
        engine.play()

        let buffered = queuedBuffers
        queuedBuffers = []
        queuedDuration = 0
        for buffer in buffered {
            schedule(buffer)
        }
    }

    /// The audio session was reconfigured underneath the running engine
    /// (category escalation for talk-over, or an engine configuration
    /// change): rebuild a fresh engine against the new configuration and
    /// keep streaming. Buffers already handed to the old engine are dropped
    /// (an at-most-jitter-buffer blip); frames still arriving schedule onto
    /// the new engine, and the file capture is unaffected.
    private func restartEngine() {
        guard engineStarted, !stopped else { return }
        engineRestarts += 1
        guard engineRestarts <= Self.maxEngineRestarts else {
            SecureLogger.warning("PTT playback: engine reconfigured \(engineRestarts) times in one burst — stopping", category: .session)
            stop()
            return
        }

        removeConfigObserver()
        engine.stop()
        engineGeneration += 1
        scheduledCount = 0
        engine = makeEngine()
        registerConfigObserver()
        do {
            try engine.start()
        } catch {
            SecureLogger.error("PTT playback engine failed to restart after session reconfigure: \(error)", category: .session)
            stop()
            return
        }
        engine.play()
        SecureLogger.info("PTT playback: engine restarted after session reconfigure", category: .session)
        // A finished burst whose tail was on the old engine has nothing left
        // to wait for.
        stopIfDrained()
    }

    private func registerConfigObserver() {
        guard let object = engine.configChangeObject else { return }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: object,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.restartEngine()
            }
        }
    }

    private func removeConfigObserver() {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
    }

    private func schedule(_ buffer: AVAudioPCMBuffer) {
        scheduledCount += 1
        let generation = engineGeneration
        engine.schedule(buffer) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.engineGeneration == generation else { return }
                self.scheduledCount -= 1
                self.stopIfDrained()
            }
        }
    }

    private func stopIfDrained() {
        guard finished, scheduledCount <= 0 else { return }
        stop()
    }

    private func releaseSessionToken() {
        sessionToken.map(coordinator.release)
        sessionToken = nil
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
