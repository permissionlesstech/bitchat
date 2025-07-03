import Foundation
import AVFoundation

class AudioPlaybackService: NSObject, ObservableObject {
    @Published var isPlaying = false
    @Published var currentPlayingMessageID: String?
    @Published var playbackProgress: Double = 0
    
    private var audioPlayer: AVAudioPlayer?
    private var playbackTimer: Timer?
    private var audioFiles: [String: URL] = [:] // messageID -> temporary file URL
    
    override init() {
        super.init()
        setupAudioSession()
    }
    
    private func setupAudioSession() {
        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playback, mode: .default)
            try audioSession.setActive(true)
        } catch {
            print("[AUDIO] Failed to set up audio session: \(error)")
        }
        #endif
    }
    
    func playVoiceNote(messageID: String, audioData: Data, completion: @escaping (Result<Void, Error>) -> Void) {
        // Stop any current playback
        stopPlayback()
        
        print("[AUDIO] Attempting to play voice note with data size: \(audioData.count) bytes")
        
        // Create temporary file for audio data
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("voice_note_\(messageID).m4a")
        
        do {
            // Ensure directory exists
            try FileManager.default.createDirectory(at: tempURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            
            // Write audio data
            try audioData.write(to: tempURL)
            audioFiles[messageID] = tempURL
            
            print("[AUDIO] Written audio file to: \(tempURL.path), size: \(try FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] ?? 0)")
            
            audioPlayer = try AVAudioPlayer(contentsOf: tempURL)
            audioPlayer?.delegate = self
            audioPlayer?.prepareToPlay()
            
            if audioPlayer?.play() == true {
                isPlaying = true
                currentPlayingMessageID = messageID
                playbackProgress = 0
                
                // Start progress timer
                playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    guard let self = self, let player = self.audioPlayer else { return }
                    self.playbackProgress = player.currentTime / player.duration
                }
                
                completion(.success(()))
            } else {
                completion(.failure(AudioError.playbackFailed))
            }
            
        } catch {
            completion(.failure(error))
        }
    }
    
    func stopPlayback() {
        audioPlayer?.stop()
        isPlaying = false
        currentPlayingMessageID = nil
        playbackProgress = 0
        playbackTimer?.invalidate()
        playbackTimer = nil
    }
    
    func togglePlayback(messageID: String, audioData: Data, completion: @escaping (Result<Void, Error>) -> Void) {
        if isPlaying && currentPlayingMessageID == messageID {
            stopPlayback()
            completion(.success(()))
        } else {
            playVoiceNote(messageID: messageID, audioData: audioData, completion: completion)
        }
    }
    
    func cleanupTemporaryFiles() {
        for (_, url) in audioFiles {
            try? FileManager.default.removeItem(at: url)
        }
        audioFiles.removeAll()
    }
    
    deinit {
        cleanupTemporaryFiles()
    }
    
    enum AudioError: LocalizedError {
        case playbackFailed
        
        var errorDescription: String? {
            switch self {
            case .playbackFailed:
                return "Failed to start audio playback"
            }
        }
    }
}

extension AudioPlaybackService: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        stopPlayback()
    }
}