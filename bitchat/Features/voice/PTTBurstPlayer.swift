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
    /// Injectable so tests don't fight over the app-wide exclusive-playback
    /// slot (a parallel test's `play()` would stop this player mid-test).
    private let exclusivity: VoiceNotePlaybackCoordinator

    private var queuedBuffers: [AVAudioPCMBuffer] = []
    private var queuedDuration: TimeInterval = 0
    private var scheduledCount = 0
    /// Bumped on every engine rebuild so schedule-completion callbacks from a
    /// torn-down engine can't decrement the new engine's counter.
    private var engineGeneration = 0
    private var engineRestarts = 0
    private var engineStarted = false
    private var finished = false
    /// Latched off (internal read so tests can await the async failure path).
    private(set) var stopped = false
    /// A session acquire is in flight (it suspends off-main for the blocking
    /// session IPC); gates `startIfReady` against double acquisition.
    private var acquiringSession = false
    private var deadlineTask: Task<Void, Never>?
    private var sessionToken: AudioSessionCoordinator.Token?
    private var configChangeObserver: NSObjectProtocol?

    private(set) var isPlaying = false

    /// Fires exactly once when the player stops for good (drain-out, cancel,
    /// interruption, failure). `ChatLiveVoiceCoordinator` uses it to unpark
    /// the draining player it keeps alive after the assembly — the player's
    /// only long-lived owner — is discarded on burst END.
    var onStopped: (() -> Void)?

    init?(
        coordinator: AudioSessionCoordinator? = nil,
        exclusivity: VoiceNotePlaybackCoordinator? = nil,
        makeEngine: (@MainActor () -> PTTPlaybackEngine)? = nil
    ) {
        guard let format = PTTAudioFormat.pcmFormat, let decoder = PTTFrameDecoder() else { return nil }
        self.decoder = decoder
        self.coordinator = coordinator ?? .shared
        self.exclusivity = exclusivity ?? .shared
        let factory = makeEngine ?? { SystemPTTPlaybackEngine(format: format) }
        self.makeEngine = factory
        self.engine = factory()

        deadlineTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(TransportConfig.pttJitterDeadlineSeconds * 1_000_000_000))
            self?.startIfReady(force: true)
        }
    }

    deinit {
        // Backstop for an owner dropping the player before it stopped: the
        // session coordinator retains registered tokens strongly, so a token
        // leaked here would keep the session active (and pin any escalated
        // category) for the app's lifetime. `release` is fire-and-forget
        // onto the coordinator's queue, so it is deinit-safe.
        if let token = sessionToken {
            coordinator.release(token)
        }
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        deadlineTask?.cancel()
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
        // The complete burst is queued — no jitter left to wait for. This
        // also matters when END lands while the async session acquire is
        // still in flight: the queued audio must play out, not be treated
        // as already drained.
        startIfReady(force: true)
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
        exclusivity.deactivate(self)
        onStopped?()
    }

    private func startIfReady(force: Bool) {
        guard !engineStarted, !acquiringSession, !stopped, !queuedBuffers.isEmpty else { return }
        guard force || queuedDuration >= TransportConfig.pttJitterBufferSeconds else { return }

        // Acquiring the session suspends for its blocking IPC (off the main
        // actor); frames arriving meanwhile keep queueing and are flushed
        // onto the engine once it starts.
        acquiringSession = true
        Task { [weak self] in
            await self?.acquireSessionAndStart()
        }
    }

    private func acquireSessionAndStart() async {
        let token: AudioSessionCoordinator.Token
        do {
            token = try await coordinator.acquire(
                .playback,
                onInterrupted: { [weak self] in self?.stop() },
                onCategoryEscalated: { [weak self] in self?.restartEngine() }
            )
        } catch {
            acquiringSession = false
            SecureLogger.error("PTT playback session activation failed: \(error)", category: .session)
            // Playing unregistered would leave the engine exposed: another
            // holder's last release deactivates the session mid-play, and no
            // interruption/escalation fan-out ever reaches us. Bail like the
            // engine-start failure below; the burst still assembles to file.
            // (stop() also fires onStopped so a parked draining player is
            // unparked instead of leaking.)
            stop()
            return
        }
        acquiringSession = false
        // stop() (cancel, exclusivity, teardown) may have landed while the
        // session was activating: hand the token straight back.
        guard !stopped else {
            coordinator.release(token)
            return
        }
        sessionToken = token

        // Observe reconfiguration before starting so nothing lands between.
        registerConfigObserver()
        do {
            try engine.start()
        } catch {
            // A capture racing this start can reconfigure the session while
            // the engine spins up (its escalation fan-out no-ops on a player
            // that never started): rebuild once against the settled
            // configuration — counted against the restart cap — before
            // giving up.
            SecureLogger.warning("PTT playback engine failed to start (\(error)) — rebuilding once", category: .session)
            removeConfigObserver()
            engineRestarts += 1
            engine = makeEngine()
            registerConfigObserver()
            do {
                try engine.start()
            } catch {
                SecureLogger.error("PTT playback engine failed to start: \(error)", category: .session)
                // stop() removes the observer, hands the token back, and
                // fires onStopped for any parked draining owner.
                stop()
                return
            }
        }
        engineStarted = true
        isPlaying = true
        exclusivity.activate(self)
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
        // Started: everything scheduled has played out. Never started with
        // nothing queued or in flight (e.g. no decodable frames): nothing
        // will ever play. Otherwise the engine start is still pending (the
        // async session acquire) and the queued audio must play out first.
        guard engineStarted || (!acquiringSession && queuedBuffers.isEmpty) else { return }
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
