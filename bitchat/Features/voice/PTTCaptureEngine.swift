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

/// Captures microphone audio for a live push-to-talk burst, producing both:
/// - live AAC frames via `onFrames` (called on the capture queue), and
/// - a finalized `.m4a` voice note on `stop()` — the same artifact
///   `VoiceRecorder` produces, so the existing voice-note send pipeline
///   handles delivery to receivers that missed the live stream.
final class PTTCaptureEngine {
    /// Hard cap matching `VoiceRecorder.maxRecordingDuration`: past it the
    /// engine keeps running (the UI owns the gesture) but stops encoding.
    private static let maxCaptureDuration: TimeInterval = 120

    /// Recreated on every `start()`: an engine whose input unit was
    /// instantiated against an earlier (playback-only or inactive) audio
    /// session keeps reporting a dead 0 Hz / 2 ch input format and fails to
    /// enable the mic (AURemoteIO -10851, observed on iPhone field tests).
    private var engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "chat.bitchat.ptt.capture", qos: .userInitiated)

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
    @MainActor private var sessionToken: AudioSessionCoordinator.Token?
    @MainActor private var configChangeObserver: NSObjectProtocol?

    /// Called on the capture queue with each batch of encoded AAC frames.
    var onFrames: (([Data]) -> Void)?

    enum CaptureError: Error {
        case inputUnavailable
        case audioSetupFailed
    }

    @MainActor
    func start(outputURL: URL) throws {
        sessionToken = try AudioSessionCoordinator.shared.acquire(.capture) { [weak self] in
            self?.handleInterruption()
        }
        do {
            try beginCapture(outputURL: outputURL)
        } catch {
            releaseSessionToken()
            throw error
        }
    }

    @MainActor
    private func beginCapture(outputURL: URL) throws {
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
            self?.queue.async { self?.process(buffer) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            SecureLogger.error("PTT: capture engine failed to start (input: \(Int(inputFormat.sampleRate)) Hz, \(inputFormat.channelCount) ch): \(error)", category: .session)
            engine.inputNode.removeTap(onBus: 0)
            queue.sync { self.teardown(deleteFile: true) }
            throw error
        }
        engineStarted = true
        // Route/category changes reconfigure the engine underneath the tap;
        // stop and finalize cleanly — the .m4a captured so far still sends.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleInterruption()
            }
        }
        SecureLogger.info("PTT: capture engine running (input: \(Int(inputFormat.sampleRate)) Hz, \(inputFormat.channelCount) ch)", category: .session)
    }

    /// Stops capture and finalizes the `.m4a`. Returns the file URL and the
    /// number of encoded AAC frames (each `PTTAudioFormat.frameDuration` long).
    @MainActor
    func stop() -> (url: URL?, encodedFrames: Int) {
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
        stopEngineIfStarted()
        queue.sync { teardown(deleteFile: true) }
        releaseSessionToken()
    }

    /// Audio session interrupted (call, Siri) or the engine was reconfigured
    /// mid-capture: behave like `stop()` — finalize the `.m4a` container but
    /// keep `fileURL`/`encodedFrameCount` so the caller's pending `stop()`
    /// still returns the note for delivery.
    @MainActor
    private func handleInterruption() {
        guard engineStarted else { return }
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
        sessionToken.map(AudioSessionCoordinator.shared.release)
        sessionToken = nil
    }

    // MARK: - Capture queue

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard running,
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
