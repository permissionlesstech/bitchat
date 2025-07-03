import Foundation
import AVFoundation

class AudioRecordingService: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var recordingTime: TimeInterval = 0
    
    private var audioRecorder: AVAudioRecorder?
    private var recordingTimer: Timer?
    private var recordingStartTime: Date?
    private let maxDuration: TimeInterval = 30.0
    private var recordingCompletion: ((Result<URL, Error>) -> Void)?
    
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
        
        #if os(iOS)
        // Request microphone permission
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            if !granted {
                completion(.failure(AudioError.microphonePermissionDenied))
                return
            }
            self.performRecording(completion: completion)
        }
        #else
        performRecording(completion: completion)
        #endif
    }
    
    private func performRecording(completion: @escaping (Result<URL, Error>) -> Void) {
        // Store completion handler for later use
        self.recordingCompletion = completion
        
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
            // Ensure audio session is properly configured
            #if os(iOS)
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try audioSession.setActive(true)
            #endif
            
            audioRecorder = try AVAudioRecorder(url: audioFilename, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.prepareToRecord() // Important: prepare before recording
            
            print("[AUDIO] Created recorder with URL: \(audioFilename)")
            print("[AUDIO] Recorder prepared: \(audioRecorder?.prepareToRecord() ?? false)")
            
            if audioRecorder?.record() == true {
                isRecording = true
                recordingStartTime = Date()
                recordingTime = 0
                print("[AUDIO] Recording started successfully")
                
                // Start timer to update recording time and enforce max duration
                recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    guard let self = self, let startTime = self.recordingStartTime else { return }
                    self.recordingTime = Date().timeIntervalSince(startTime)
                    
                    if self.recordingTime >= self.maxDuration {
                        self.stopRecording { result in
                            // Result already handled by recordingCompletion
                        }
                    }
                }
            } else {
                print("[AUDIO] Failed to start recording")
                completion(.failure(AudioError.recordingFailed))
            }
            
        } catch {
            print("[AUDIO] Error setting up recording: \(error)")
            completion(.failure(error))
        }
    }
    
    func stopRecording(completion: @escaping (Result<URL, Error>) -> Void) {
        guard isRecording, let recorder = audioRecorder else {
            completion(.failure(AudioError.notRecording))
            return
        }
        
        // Ensure minimum recording duration
        let minDuration: TimeInterval = 1.0
        if recordingTime < minDuration {
            // Continue recording until minimum duration
            DispatchQueue.main.asyncAfter(deadline: .now() + (minDuration - recordingTime)) { [weak self] in
                self?.stopRecording(completion: completion)
            }
            return
        }
        
        recorder.stop()
        isRecording = false
        recordingTimer?.invalidate()
        recordingTimer = nil
        
        let url = recorder.url
        let recordedDuration = recordingTime
        
        // Reset for next recording
        audioRecorder = nil
        recordingTime = 0
        recordingStartTime = nil
        recordingCompletion = nil
        
        // Give the recorder a moment to finalize the file
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // Verify file exists and has content
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                if let fileSize = attributes[.size] as? Int, fileSize > 1000 { // At least 1KB
                    print("[AUDIO] Recording completed successfully. File size: \(fileSize) bytes, duration: \(recordedDuration)s")
                    completion(.success(url))
                } else {
                    print("[AUDIO] Recording failed: file too small (\(attributes[.size] ?? 0) bytes)")
                    completion(.failure(AudioError.emptyRecording))
                }
            } catch {
                print("[AUDIO] Recording failed: \(error)")
                completion(.failure(error))
            }
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
        case microphonePermissionDenied
        case recordingFailed
        
        var errorDescription: String? {
            switch self {
            case .notRecording:
                return "Not currently recording"
            case .emptyRecording:
                return "Recording produced no audio data"
            case .microphonePermissionDenied:
                return "Microphone permission denied"
            case .recordingFailed:
                return "Failed to start recording"
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