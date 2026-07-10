//
// PTTCaptureEngine.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import AVFoundation
import BitLogger
import Foundation

/// Owns one capture token and returns it even when the capture engine's owner
/// disappears without reaching its normal stop/cancel path. The coordinator
/// retains registered tokens strongly, so relying on `Token.deinit` cannot
/// reclaim an abandoned hold.
final class PTTCaptureSessionLease: @unchecked Sendable {
    private let coordinator: AudioSessionCoordinator
    private let lock = NSLock()
    private var token: AudioSessionCoordinator.Token?

    init(coordinator: AudioSessionCoordinator) {
        self.coordinator = coordinator
    }

    func install(_ token: AudioSessionCoordinator.Token) {
        let previous = lock.withLock {
            let previous = self.token
            self.token = token
            return previous
        }
        previous.map(coordinator.release)
    }

    func release() {
        let token = lock.withLock {
            let token = self.token
            self.token = nil
            return token
        }
        token.map(coordinator.release)
    }

    deinit {
        release()
    }
}

/// Monotonic capture identity shared by main-actor lifecycle code and queued
/// engine callbacks. Removing a notification observer does not cancel a block
/// already enqueued on the main queue, so every callback must also prove it
/// still belongs to the current hold before mutating capture state.
final class PTTCaptureGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt = 0

    func begin() -> UInt {
        lock.withLock {
            value &+= 1
            return value
        }
    }

    func invalidate() {
        lock.withLock { value &+= 1 }
    }

    func invalidate(ifCurrent generation: UInt) -> Bool {
        lock.withLock {
            guard value == generation else { return false }
            value &+= 1
            return true
        }
    }

    func isCurrent(_ generation: UInt) -> Bool {
        lock.withLock { value == generation }
    }
}

/// Captures microphone audio for a live push-to-talk burst, producing both:
/// - live AAC frames via `onFrames` (called on the capture queue), and
/// - a finalized `.m4a` voice note on `stop()` — the same artifact
///   `VoiceRecorder` produces, so the existing voice-note send pipeline
///   handles delivery to receivers that missed the live stream.
/// `@unchecked Sendable`: every mutable property is confined to one executor —
/// the capture `queue` (resampler/encoder/file/counters) or the main actor
/// (`engine`, `engineStarted`, `sessionLease`, `configChangeObserver`) — so
/// weak references may cross the `@Sendable` tap/notification closures, which
/// immediately hop back to the owning executor.
final class PTTCaptureEngine: @unchecked Sendable {
    /// Hard cap matching `VoiceRecorder.maxRecordingDuration`: past it the
    /// engine keeps running (the UI owns the gesture) but stops encoding.
    private static let maxCaptureDuration: TimeInterval = 120

    /// Recreated on every `start()`: an engine whose input unit was
    /// instantiated against an earlier (playback-only or inactive) audio
    /// session keeps reporting a dead 0 Hz / 2 ch input format and fails to
    /// enable the mic (AURemoteIO -10851, observed on iPhone field tests).
    private var engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "chat.bitchat.ptt.capture", qos: .userInitiated)
    private let coordinator: AudioSessionCoordinator
    private let sessionLease: PTTCaptureSessionLease
    private let captureGeneration = PTTCaptureGeneration()

    // Capture-queue-confined state.
    private var resampler: PTTInputResampler?
    private var encoder: PTTFrameEncoder?
    private var file: AVAudioFile?
    private var fileURL: URL?
    private var encodedFrameCount = 0
    private var running = false
    private var captureStart = Date()
    /// Whether `engine.start()` succeeded for the current capture
    /// (see `stopEngineIfStarted`).
    @MainActor private var engineStarted = false
    @MainActor private var configChangeObserver: NSObjectProtocol?
    /// Called on the capture queue with each batch of encoded AAC frames.
    var onFrames: (([Data]) -> Void)?

    enum CaptureError: Error {
        case inputUnavailable
        case audioSetupFailed
    }

    init(coordinator: AudioSessionCoordinator = .shared) {
        self.coordinator = coordinator
        self.sessionLease = PTTCaptureSessionLease(coordinator: coordinator)
    }

    deinit {
        sessionLease.release()
    }

    /// Async because acquiring the session hops its blocking IPC off the main
    /// actor (a PTT press used to stall main >1 s in `setActive`); the engine
    /// itself still starts back on main once the session is configured.
    @MainActor
    func start(outputURL: URL) async throws {
        let generation = captureGeneration.begin()
        let token = try await coordinator.acquire(.capture) { [weak self] in
            self?.handleInterruption(for: generation)
        }
        // The hold ended (stop/cancel) while the session was activating:
        // starting the engine now would leave a hot mic after release.
        guard captureGeneration.isCurrent(generation) else {
            coordinator.release(token)
            throw CancellationError()
        }
        sessionLease.install(token)
        do {
            try beginCapture(outputURL: outputURL, generation: generation)
        } catch {
            releaseSessionToken()
            throw error
        }
    }

    @MainActor
    private func beginCapture(outputURL: URL, generation: UInt) throws {
        // Fresh engine per capture so its input unit binds to the session
        // that is active *now* (see `engine` doc comment).
        engine = AVAudioEngine()
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            SecureLogger.error("PTT: capture input unavailable (input reports \(Int(inputFormat.sampleRate)) Hz, \(inputFormat.channelCount) ch)", category: .session)
            throw CaptureError.inputUnavailable
        }
        guard let resampler = PTTInputResampler(inputFormat: inputFormat),
              let encoder = PTTFrameEncoder(),
              let pcmFormat = PTTAudioFormat.pcmFormat
        else { throw CaptureError.audioSetupFailed }

        let file = try AVAudioFile(
            forWriting: outputURL,
            settings: PTTAudioFormat.voiceNoteFileSettings,
            commonFormat: pcmFormat.commonFormat,
            interleaved: pcmFormat.isInterleaved
        )

        queue.sync {
            self.resampler = resampler
            self.encoder = encoder
            self.file = file
            self.fileURL = outputURL
            self.encodedFrameCount = 0
            self.captureStart = Date()
            self.running = true
        }

        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.queue.async { self?.process(buffer, generation: generation) }
        }
        // Route/category changes reconfigure the engine underneath the tap;
        // stop and finalize cleanly — the .m4a captured so far still sends.
        // Registered before start() so no reconfigure lands unobserved
        // (handleInterruption also validates this capture generation).
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleInterruption(for: generation)
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            SecureLogger.error("PTT: capture engine failed to start (input: \(Int(inputFormat.sampleRate)) Hz, \(inputFormat.channelCount) ch): \(error)", category: .session)
            if let observer = configChangeObserver {
                NotificationCenter.default.removeObserver(observer)
                configChangeObserver = nil
            }
            engine.inputNode.removeTap(onBus: 0)
            queue.sync { self.teardown(deleteFile: true) }
            throw error
        }
        engineStarted = true
        SecureLogger.info("PTT: capture engine running (input: \(Int(inputFormat.sampleRate)) Hz, \(inputFormat.channelCount) ch)", category: .session)
    }

    /// Stops capture and finalizes the `.m4a`. Returns the file URL and the
    /// number of encoded AAC frames (each `PTTAudioFormat.frameDuration` long).
    @MainActor
    func stop() -> (url: URL?, encodedFrames: Int) {
        captureGeneration.invalidate()
        stopEngineIfStarted()
        let result: (URL?, Int) = queue.sync {
            let url = fileURL
            let frames = encodedFrameCount
            teardown(deleteFile: false)
            return (url, frames)
        }
        releaseSessionToken()
        return result
    }

    @MainActor
    func cancel() {
        captureGeneration.invalidate()
        stopEngineIfStarted()
        queue.sync { teardown(deleteFile: true) }
        releaseSessionToken()
    }

    /// Audio session interrupted (call, Siri) or the engine was reconfigured
    /// mid-capture: behave like `stop()` — finalize the `.m4a` container but
    /// keep `fileURL`/`encodedFrameCount` so the caller's pending `stop()`
    /// still returns the note for delivery.
    @MainActor
    private func handleInterruption(for generation: UInt) {
        // Also invalidate a start whose acquire has registered its token but
        // has not returned to this actor yet. Without this bump the callback
        // is lost while `engineStarted == false`, and the resumed start can
        // open the mic after the stop signal.
        guard captureGeneration.invalidate(ifCurrent: generation) else { return }
        guard engineStarted else {
            releaseSessionToken()
            return
        }
        stopEngineIfStarted()
        queue.sync {
            running = false
            // Releasing the AVAudioFile finalizes the .m4a container.
            file = nil
            encoder = nil
            resampler = nil
        }
        releaseSessionToken()
        SecureLogger.info("PTT: capture interrupted — burst finalized early", category: .session)
    }

    /// Touching `inputNode` on an engine that never started instantiates its
    /// input unit against whatever session is active and spams AURemoteIO
    /// errors — a canceled-before-start hold must not touch the engine.
    @MainActor
    private func stopEngineIfStarted() {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        guard engineStarted else { return }
        engineStarted = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    @MainActor
    private func releaseSessionToken() {
        sessionLease.release()
    }

    // MARK: - Capture queue

    private func process(_ buffer: AVAudioPCMBuffer, generation: UInt) {
        guard captureGeneration.isCurrent(generation),
              running,
              Date().timeIntervalSince(captureStart) < Self.maxCaptureDuration,
              let resampled = resampler?.resample(buffer)
        else { return }

        do {
            try file?.write(from: resampled)
        } catch {
            SecureLogger.error("PTT capture file write failed: \(error)", category: .session)
        }

        guard let frames = encoder?.encode(resampled), !frames.isEmpty else { return }
        encodedFrameCount += frames.count
        onFrames?(frames)
    }

    private func teardown(deleteFile: Bool) {
        running = false
        // Releasing the AVAudioFile finalizes the .m4a container.
        file = nil
        encoder = nil
        resampler = nil
        if deleteFile, let url = fileURL {
            try? FileManager.default.removeItem(at: url)
        }
        fileURL = nil
    }
}
