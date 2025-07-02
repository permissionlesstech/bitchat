import Foundation
import AVFoundation

class AudioRecordingService: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var recordingTime: TimeInterval = 0
    
    private var audioRecorder: AVAudioRecorder?
    private var recordingTimer: Timer?
    private var recordingStartTime: Date?
    private let maxDuration: TimeInterval = 10.0
    
    override init() {
        super.init()
        setupAudioSession()
    }
    
    private func setupAudioSession() {
        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .default)
            try audioSession.setActive(true)
        } catch {
            print("[AUDIO] Failed to set up audio session: \(error)")
        }
        #endif
    }
    
    func startRecording(completion: @escaping (Result<URL, Error>) -> Void) {
        guard !isRecording else { return }
        
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let audioFilename = documentsPath.appendingPathComponent("voice_note_\(Date().timeIntervalSince1970).m4a")
        
        let settings = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000, // Lower sample rate for smaller files
            AVNumberOfChannelsKey: 1, // Mono for voice
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            AVEncoderBitRateKey: 32000 // 32 kbps for voice
        ]
        
        do {
            audioRecorder = try AVAudioRecorder(url: audioFilename, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.record()
            
            isRecording = true
            recordingStartTime = Date()
            recordingTime = 0
            
            // Start timer to update recording time and enforce max duration
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self = self, let startTime = self.recordingStartTime else { return }
                self.recordingTime = Date().timeIntervalSince(startTime)
                
                if self.recordingTime >= self.maxDuration {
                    self.stopRecording { result in
                        completion(result)
                    }
                }
            }
            
        } catch {
            completion(.failure(error))
        }
    }
    
    func stopRecording(completion: @escaping (Result<URL, Error>) -> Void) {
        guard isRecording, let recorder = audioRecorder else {
            completion(.failure(AudioError.notRecording))
            return
        }
        
        recorder.stop()
        isRecording = false
        recordingTimer?.invalidate()
        recordingTimer = nil
        
        let url = recorder.url
        let _ = recordingTime
        
        // Reset for next recording
        audioRecorder = nil
        recordingTime = 0
        recordingStartTime = nil
        
        // Verify file exists and has content
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let fileSize = attributes[.size] as? Int, fileSize > 0 {
                completion(.success(url))
            } else {
                completion(.failure(AudioError.emptyRecording))
            }
        } catch {
            completion(.failure(error))
        }
    }
    
    func cancelRecording() {
        guard isRecording, let recorder = audioRecorder else { return }
        
        recorder.stop()
        recorder.deleteRecording()
        
        isRecording = false
        recordingTimer?.invalidate()
        recordingTimer = nil
        audioRecorder = nil
        recordingTime = 0
        recordingStartTime = nil
    }
    
    enum AudioError: LocalizedError {
        case notRecording
        case emptyRecording
        
        var errorDescription: String? {
            switch self {
            case .notRecording:
                return "Not currently recording"
            case .emptyRecording:
                return "Recording produced no audio data"
            }
        }
    }
}

extension AudioRecordingService: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            print("[AUDIO] Recording finished unsuccessfully")
        }
    }
}