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

    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "chat.bitchat.ptt.capture", qos: .userInitiated)

    // Capture-queue-confined state.
    private var resampler: PTTInputResampler?
    private var encoder: PTTFrameEncoder?
    private var file: AVAudioFile?
    private var fileURL: URL?
    private var encodedFrameCount = 0
    private var running = false
    private var captureStart = Date()

    /// Called on the capture queue with each batch of encoded AAC frames.
    var onFrames: (([Data]) -> Void)?

    enum CaptureError: Error {
        case audioSetupFailed
    }

    func start(outputURL: URL) throws {
        #if os(iOS)
        try Self.configureAudioSession()
        #endif

        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
              let resampler = PTTInputResampler(inputFormat: inputFormat),
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
            engine.inputNode.removeTap(onBus: 0)
            queue.sync { self.teardown(deleteFile: true) }
            throw error
        }
    }

    /// Stops capture and finalizes the `.m4a`. Returns the file URL and the
    /// number of encoded AAC frames (each `PTTAudioFormat.frameDuration` long).
    func stop() -> (url: URL?, encodedFrames: Int) {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let result: (URL?, Int) = queue.sync {
            let url = fileURL
            let frames = encodedFrameCount
            teardown(deleteFile: false)
            return (url, frames)
        }
        #if os(iOS)
        Self.deactivateAudioSession()
        #endif
        return result
    }

    func cancel() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        queue.sync { teardown(deleteFile: true) }
        #if os(iOS)
        Self.deactivateAudioSession()
        #endif
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

    // MARK: - Audio session (iOS)

    #if os(iOS)
    private static func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        #if targetEnvironment(simulator)
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        #else
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP, .allowBluetoothHFP])
        #endif
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private static func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    #endif
}
