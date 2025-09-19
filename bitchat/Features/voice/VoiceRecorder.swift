import Foundation

#if os(iOS)
import AVFoundation
import CoreGraphics

final class VoiceRecorder: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private(set) var isRecording = false

    func startRecording(to url: URL) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32000
        ]
        recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder?.delegate = self
        recorder?.isMeteringEnabled = true
        guard recorder?.record() == true else { throw NSError(domain: "VoiceRecorder", code: -1) }
        isRecording = true
    }

    func stopRecording(completion: @escaping () -> Void) {
        guard isRecording else { completion(); return }
        // Add 500ms padding to avoid clipping
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.recorder?.stop()
            self?.isRecording = false
            completion()
        }
    }

    // MARK: - Live metrics for visualizer

    /// Returns normalized amplitude [0,1] based on average power in dB.
    /// Call periodically while recording to drive a live waveform.
    func pollNormalizedAmplitude() -> CGFloat {
        guard let r = recorder, isRecording else { return 0 }
        r.updateMeters()
        // Use peak power for responsiveness, map dB [-160,0] -> linear [0,1]
        let db = r.peakPower(forChannel: 0)
        let linear = pow(10.0, db / 20.0) // 0..1
        if linear.isNaN || linear.isInfinite { return 0 }
        // Keep linear to avoid globally scaling up low amplitudes
        return CGFloat(max(0, min(1, linear)))
    }

    /// Current elapsed recording time in milliseconds.
    func currentTimeMs() -> Int {
        guard let r = recorder, isRecording else { return 0 }
        return Int(r.currentTime * 1000)
    }
}

enum VoiceRecorderPaths {
    static func outgoingURL() throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = base.appendingPathComponent("bitchat_voicenotes/outgoing", isDirectory: true)
        if !fm.fileExists(atPath: folder.path) {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let ts = ISO8601DateFormatter()
        ts.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let name = "voice_\(Int(Date().timeIntervalSince1970)).m4a"
        return folder.appendingPathComponent(name)
    }
}
#else
/// Minimal macOS-compatible stubs so the macOS target builds without AVFAudio.
final class VoiceRecorder: NSObject {
    private(set) var isRecording = false
    func startRecording(to url: URL) throws {
        // Voice recording is iOS-only in this project
        throw NSError(domain: "VoiceRecorder", code: -1, userInfo: [NSLocalizedDescriptionKey: "Voice recording is not supported on macOS in this build."])
    }
    func stopRecording(completion: @escaping () -> Void) { completion() }
}

enum VoiceRecorderPaths {
    static func outgoingURL() throws -> URL {
        throw NSError(domain: "VoiceRecorder", code: -2, userInfo: [NSLocalizedDescriptionKey: "Voice recording is not supported on macOS in this build."])
    }
}
#endif
