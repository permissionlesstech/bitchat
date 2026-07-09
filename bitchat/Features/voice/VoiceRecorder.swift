import Foundation
import AVFoundation

/// Manages audio capture for mesh voice notes with predictable encoding settings.
actor VoiceRecorder {
    enum RecorderError: Error {
        case microphoneAccessDenied
        case recordingInProgress
    }

    static let shared = VoiceRecorder()

    private let paddingInterval: TimeInterval = 0.5
    private let maxRecordingDuration: TimeInterval = 120
    static let minRecordingDuration: TimeInterval = 1

    private var recorder: AVAudioRecorder?
    private var currentURL: URL?
    private var sessionToken: AudioSessionCoordinator.Token?

    // MARK: - Permissions

    nonisolated
    func requestPermission() async -> Bool {
        #if os(iOS)
        return await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        #elseif os(macOS)
        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
        #else
        return true
        #endif
    }

    // MARK: - Recording Lifecycle

    @discardableResult
    func startRecording() async throws -> URL {
        if recorder?.isRecording == true {
            throw RecorderError.recordingInProgress
        }

        #if os(iOS)
        guard AVAudioSession.sharedInstance().recordPermission == .granted else {
            throw RecorderError.microphoneAccessDenied
        }
        #endif
        #if os(macOS)
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw RecorderError.microphoneAccessDenied
        }
        #endif

        let token = try await MainActor.run {
            try AudioSessionCoordinator.shared.acquire(.capture) {
                Task { await VoiceRecorder.shared.handleSessionInterruption() }
            }
        }
        // Actor reentrancy: another recording may have started during the hop.
        // Guard the token too — overwriting a live one (double-fired hold
        // gesture) would leak the first holder and pin the session forever.
        if recorder?.isRecording == true || sessionToken != nil {
            await MainActor.run { AudioSessionCoordinator.shared.release(token) }
            throw RecorderError.recordingInProgress
        }
        sessionToken = token

        do {
            let outputURL = try makeOutputURL()
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 16_000
            ]

            let audioRecorder = try AVAudioRecorder(url: outputURL, settings: settings)
            audioRecorder.isMeteringEnabled = true
            audioRecorder.prepareToRecord()
            audioRecorder.record(forDuration: maxRecordingDuration)

            recorder = audioRecorder
            currentURL = outputURL
            return outputURL
        } catch {
            await releaseSessionToken()
            throw error
        }
    }

    func stopRecording() async -> URL? {
        guard let recorder, recorder.isRecording else {
            return currentURL
        }

        let sessionURL = currentURL

        try? await Task.sleep(nanoseconds: UInt64(paddingInterval * 1_000_000_000))

        recorder.stop()

        // A new session may have started during the sleep — don't touch its state
        if self.recorder === recorder {
            await releaseSessionToken()
            self.recorder = nil
            currentURL = nil
        }

        return sessionURL
    }

    func cancelRecording() async {
        if let recorder, recorder.isRecording {
            recorder.stop()
        }
        await releaseSessionToken()
        if let currentURL {
            try? FileManager.default.removeItem(at: currentURL)
        }
        recorder = nil
        currentURL = nil
    }

    /// The audio session was interrupted (call, Siri) or reconfigured: stop
    /// the recorder but keep `recorder`/`currentURL` so the caller's pending
    /// `stopRecording()` still returns the partial note.
    func handleSessionInterruption() async {
        if let recorder, recorder.isRecording {
            recorder.stop()
        }
        await releaseSessionToken()
    }

    // MARK: - Helpers

    private func makeOutputURL() throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let fileName = "voice_\(formatter.string(from: Date())).m4a"

        let baseDirectory = try applicationFilesDirectory().appendingPathComponent("voicenotes/outgoing", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true, attributes: nil)
        return baseDirectory.appendingPathComponent(fileName)
    }

    private func applicationFilesDirectory() throws -> URL {
        #if os(iOS)
        return try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("files", isDirectory: true)
        #else
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent("files", isDirectory: true)
        #endif
    }

    private func releaseSessionToken() async {
        guard let token = sessionToken else { return }
        sessionToken = nil
        await MainActor.run { AudioSessionCoordinator.shared.release(token) }
    }
}
