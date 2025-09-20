import Foundation
#if os(iOS)
import AVFoundation
#endif

// Simple AVAudioRecorder wrapper for voice notes (.m4a AAC), ~16 kHz mono.
// Stops recording when approaching NoiseSecurityConstants.maxMessageSize.
protocol VoiceRecorderDelegate: AnyObject {
    func voiceRecorderDidStart(_ url: URL)
    func voiceRecorderDidUpdate(seconds: TimeInterval, estimatedSize: UInt64)
    func voiceRecorderDidFinish(_ url: URL)
    func voiceRecorderDidError(_ error: Error)
}

final class VoiceRecorder: NSObject {
    #if os(iOS)
    private var recorder: AVAudioRecorder?
    #endif
    private var meterTimer: Timer?
    private(set) var outputURL: URL?
    weak var delegate: VoiceRecorderDelegate?

    func start() {
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            delegate?.voiceRecorderDidError(error)
            return
        }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            AVEncoderBitRateKey: 32000 // ~32 kbps => ~4 KB/s
        ]
        do {
            let rec = try AVAudioRecorder(url: tmp, settings: settings)
            rec.isMeteringEnabled = true
            rec.delegate = self
            rec.record()
            recorder = rec
            outputURL = tmp
            delegate?.voiceRecorderDidStart(tmp)
            startMetering()
        } catch {
            delegate?.voiceRecorderDidError(error)
        }
        #else
        delegate?.voiceRecorderDidError(NSError(domain: "VoiceRecorder", code: -1, userInfo: [NSLocalizedDescriptionKey: "Voice recording is iOS-only"]))
        #endif
    }

    func stop() {
        #if os(iOS)
        meterTimer?.invalidate(); meterTimer = nil
        recorder?.stop()
        #endif
    }

    func cancel() {
        #if os(iOS)
        meterTimer?.invalidate(); meterTimer = nil
        let url = outputURL
        recorder?.stop()
        if let u = url { try? FileManager.default.removeItem(at: u) }
        outputURL = nil
        #endif
    }

    private func startMetering() {
        #if os(iOS)
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, let url = self.outputURL else { return }
            self.recorder?.updateMeters()
            let seconds = self.recorder?.currentTime ?? 0
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
            self.delegate?.voiceRecorderDidUpdate(seconds: seconds, estimatedSize: size)
            // Enforce 5MB cap
            if size >= UInt64(NoiseSecurityConstants.maxMessageSize) {
                self.stop()
            }
        }
        #endif
    }
}

#if os(iOS)
extension VoiceRecorder: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        meterTimer?.invalidate(); meterTimer = nil
        if flag, let url = outputURL {
            delegate?.voiceRecorderDidFinish(url)
        } else {
            delegate?.voiceRecorderDidError(NSError(domain: "VoiceRecorder", code: -2, userInfo: [NSLocalizedDescriptionKey: "Recording failed"]))
        }
    }
    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        meterTimer?.invalidate(); meterTimer = nil
        delegate?.voiceRecorderDidError(error ?? NSError(domain: "VoiceRecorder", code: -3, userInfo: [NSLocalizedDescriptionKey: "Encoding error"]))
    }
}
#endif
