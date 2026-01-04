import Foundation
import AVFoundation

/// Manages audio capture for mesh voice notes with predictable encoding settings.
/// Recording runs on an internal serial queue to avoid AVAudioSession contention.
final class VoiceRecorder: NSObject, AVAudioRecorderDelegate {
    enum RecorderError: Error {
        case microphoneAccessDenied
        case recorderInitializationFailed
        case recordingInProgress
    }

    static let shared = VoiceRecorder()

    private let queue = DispatchQueue(label: "com.bitchat.voice-recorder")
    private let paddingInterval: TimeInterval = 0.5
    private let maxRecordingDuration: TimeInterval = 120

    private var recorder: AVAudioRecorder?
    private var currentURL: URL?
    private var stopWorkItem: DispatchWorkItem?

    private override init() {
        super.init()
    }

    // MARK: - Permissions

    @discardableResult
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

    func startRecording() throws -> URL {
        try queue.sync {
            if recorder?.isRecording == true {
                throw RecorderError.recordingInProgress
            }

            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            guard session.recordPermission == .granted else {
                throw RecorderError.microphoneAccessDenied
            }
            #if targetEnvironment(simulator)
            // allowBluetoothHFP is not available on iOS Simulator
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetoothA2DP]
            )
            #else
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetoothA2DP, .allowBluetoothHFP]
            )
            #endif
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            #endif
            #if os(macOS)
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                throw RecorderError.microphoneAccessDenied
            }
            #endif

            let outputURL = try makeOutputURL()
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 16_000
            ]

            let audioRecorder = try AVAudioRecorder(url: outputURL, settings: settings)
            audioRecorder.delegate = self
            audioRecorder.isMeteringEnabled = true
            audioRecorder.prepareToRecord()
            audioRecorder.record(forDuration: maxRecordingDuration)

            recorder = audioRecorder
            currentURL = outputURL
            stopWorkItem?.cancel()
            stopWorkItem = nil
            return outputURL
        }
    }

    func stopRecording(completion: @escaping (URL?) -> Void) {
        queue.async { [weak self] in
            guard let self = self, let recorder = self.recorder, recorder.isRecording else {
                completion(self?.currentURL)
                return
            }

            let item = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                recorder.stop()
                self.cleanupSession()
                let url = self.currentURL
                self.recorder = nil
                self.currentURL = url
                completion(url)
            }
            self.stopWorkItem = item
            self.queue.asyncAfter(deadline: .now() + self.paddingInterval, execute: item)
        }
    }

    func cancelRecording() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.stopWorkItem?.cancel()
            self.stopWorkItem = nil
            if let recorder = self.recorder, recorder.isRecording {
                recorder.stop()
            }
            self.cleanupSession()
            if let url = self.currentURL {
                try? FileManager.default.removeItem(at: url)
            }
            self.recorder = nil
            self.currentURL = nil
        }
    }

    // MARK: - Metering

    func currentAveragePower() -> Float {
        queue.sync {
            recorder?.updateMeters()
            return recorder?.averagePower(forChannel: 0) ?? -160
        }
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

    private func cleanupSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
