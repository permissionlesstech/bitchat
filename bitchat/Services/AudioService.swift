import Foundation
import AVFoundation
import Combine

class AudioService: NSObject, ObservableObject {
    static let shared = AudioService()
    
    @Published var isRecording = false
    @Published var isPlaying = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var playbackProgress: TimeInterval = 0
    @Published var recordingError: String?
    
    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVAudioPlayer?
    private var recordingTimer: Timer?
    private var playbackTimer: Timer?
    private var recordingStartTime: Date?
    
    // Audio settings optimized for voice and BLE transmission
    // More aggressive compression for longer recordings
    private let audioSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,  // AAC compression
        AVSampleRateKey: 12000,              // Reduced from 16kHz to 12kHz
        AVNumberOfChannelsKey: 1,            // Mono
        AVEncoderAudioQualityKey: AVAudioQuality.low.rawValue,  // Low quality for size
        AVEncoderBitRateKey: 12000           // 12 kbps bitrate
    ]
    
    // Protocol limit - leave some headroom for protocol overhead
    internal let maxCompressedSize = 60000  // 60KB (UInt16 max is ~64KB)
    
    override init() {
        super.init()
        setupAudioSession()
    }
    
    private func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try audioSession.setActive(true)
        } catch {
            print("[AUDIO] Failed to setup audio session: \(error)")
        }
    }
    
    // MARK: - Recording
    
    func startRecording() -> Bool {
        guard !isRecording else { return false }
        
        // Clear any previous error
        recordingError = nil
        
        // Request microphone permission
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                if granted {
                    self?.beginRecording()
                } else {
                    print("[AUDIO] Microphone permission denied")
                    self?.recordingError = "Microphone permission required"
                }
            }
        }
        
        return true
    }
    
    private func beginRecording() {
        // Create temporary file for recording
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let audioFilename = documentsPath.appendingPathComponent("temp_voice_\(UUID().uuidString).m4a")
        
        do {
            audioRecorder = try AVAudioRecorder(url: audioFilename, settings: audioSettings)
            audioRecorder?.delegate = self
            audioRecorder?.prepareToRecord()
            audioRecorder?.record()
            
            isRecording = true
            recordingDuration = 0
            recordingStartTime = Date()
            
            // Start recording timer
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self = self, let startTime = self.recordingStartTime else { return }
                self.recordingDuration = Date().timeIntervalSince(startTime)
                
                // Auto-stop after 2 minutes to prevent oversized files
                if self.recordingDuration >= 120 {
                    self.recordingError = "Recording too long - maximum 2 minutes"
                    _ = self.stopRecording()
                }
            }
            
        } catch {
            print("[AUDIO] Failed to start recording: \(error)")
            isRecording = false
            recordingError = "Failed to start recording"
        }
    }
    
    func stopRecording() -> Data? {
        guard isRecording, let recorder = audioRecorder else { return nil }
        
        recorder.stop()
        isRecording = false
        recordingTimer?.invalidate()
        recordingTimer = nil
        
        // Read recorded data
        if let recordedData = try? Data(contentsOf: recorder.url) {
            // Clean up temp file
            try? FileManager.default.removeItem(at: recorder.url)
            
            // Validate and compress the audio
            return validateAndCompressAudio(recordedData)
        }
        
        return nil
    }
    
    private func validateAndCompressAudio(_ data: Data) -> Data? {
        // First, try to compress the audio
        guard let compressedData = compressAudioData(data) else {
            recordingError = "Failed to compress audio"
            return nil
        }
        
        // Check if compressed size exceeds protocol limit
        if compressedData.count > maxCompressedSize {
            let sizeMB = Double(compressedData.count) / 1024.0 / 1024.0
            let maxMB = Double(maxCompressedSize) / 1024.0 / 1024.0
            recordingError = String(format: "Recording too large (%.1fMB). Max: %.1fMB. Try shorter recording.", sizeMB, maxMB)
            print("[AUDIO] Recording too large: \(compressedData.count) bytes (max: \(maxCompressedSize))")
            return nil
        }
        
        return compressedData
    }
    
    func cancelRecording() {
        guard isRecording, let recorder = audioRecorder else { return }
        
        recorder.stop()
        isRecording = false
        recordingDuration = 0
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingError = nil
        
        // Clean up temp file
        try? FileManager.default.removeItem(at: recorder.url)
    }
    
    // MARK: - Playback
    
    func playAudio(_ audioData: Data, duration: TimeInterval) {
        guard !isPlaying else { return }
        
        // Stop any current playback
        stopPlayback()
        
        // Create temporary file for playback
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let tempFile = documentsPath.appendingPathComponent("temp_playback_\(UUID().uuidString).m4a")
        
        do {
            try audioData.write(to: tempFile)
            
            audioPlayer = try AVAudioPlayer(contentsOf: tempFile)
            audioPlayer?.delegate = self
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
            
            isPlaying = true
            playbackProgress = 0
            
            // Start playback timer
            playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self = self, let player = self.audioPlayer else { return }
                
                self.playbackProgress = player.currentTime
                
                if !player.isPlaying {
                    self.stopPlayback()
                }
            }
            
        } catch {
            print("[AUDIO] Failed to play audio: \(error)")
            // Clean up temp file
            try? FileManager.default.removeItem(at: tempFile)
        }
    }
    
    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        playbackProgress = 0
        playbackTimer?.invalidate()
        playbackTimer = nil
    }
    
    func pausePlayback() {
        audioPlayer?.pause()
        isPlaying = false
    }
    
    func resumePlayback() {
        audioPlayer?.play()
        isPlaying = true
    }
    
    // MARK: - Utility
    
    func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    // Compress audio data for efficient transmission
    func compressAudioData(_ data: Data) -> Data? {
        // Audio is already compressed with AAC, but we can apply additional compression
        guard let compressedData = CompressionUtil.compress(data) else {
            return nil
        }
        
        // Store original size as first 4 bytes for decompression
        var result = Data()
        var originalSize = UInt32(data.count)
        result.append(Data(bytes: &originalSize, count: 4))
        result.append(compressedData)
        
        print("[AUDIO] Compressed audio: \(data.count) -> \(result.count) bytes (\(String(format: "%.1f", Double(result.count)/Double(data.count)*100))% of original)")
        
        return result
    }
    
    func decompressAudioData(_ data: Data) -> Data? {
        guard data.count > 4 else { return nil }
        
        // Extract original size from first 4 bytes
        let originalSizeData = data.prefix(4)
        let originalSize = originalSizeData.withUnsafeBytes { $0.load(as: UInt32.self) }
        
        // Extract compressed data
        let actualCompressedData = data.dropFirst(4)
        
        return CompressionUtil.decompress(actualCompressedData, originalSize: Int(originalSize))
    }
    
    // Get estimated file size for current recording duration
    func getEstimatedSize() -> Int {
        // 12 kbps = 1500 bytes per second (approximately)
        return Int(recordingDuration * 1500)
    }
}

// MARK: - AVAudioRecorderDelegate

extension AudioService: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        isRecording = false
        recordingTimer?.invalidate()
        recordingTimer = nil
        
        if !flag {
            print("[AUDIO] Recording failed")
            recordingError = "Recording failed"
        }
    }
    
    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        print("[AUDIO] Recording encode error: \(error?.localizedDescription ?? "Unknown")")
        isRecording = false
        recordingError = "Recording error: \(error?.localizedDescription ?? "Unknown")"
    }
}

// MARK: - AVAudioPlayerDelegate

extension AudioService: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        playbackProgress = 0
        playbackTimer?.invalidate()
        playbackTimer = nil
        
        // Clean up temp file
        try? FileManager.default.removeItem(at: player.url!)
    }
    
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        print("[AUDIO] Playback decode error: \(error?.localizedDescription ?? "Unknown")")
        stopPlayback()
    }
} 
