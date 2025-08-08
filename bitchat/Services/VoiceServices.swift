//
// VoiceServices.swift
// bitchat
//
// Simplified voice services integration for BitChat
// This file contains the essential voice functionality needed for the UI
//

import Foundation
import AVFoundation
import Combine

// MARK: - Voice Recording State Management

public enum VoiceRecordingState: Equatable {
    case idle
    case recording
    case processing
    case sending
    case sent
    case error(String)
}

// MARK: - Simple Voice Message Service

public class SimpleVoiceMessageService: ObservableObject {
    public static let shared = SimpleVoiceMessageService()
    
    @Published public private(set) var isRecording = false
    @Published public private(set) var recordingDuration: TimeInterval = 0
    @Published public private(set) var currentAmplitude: Float = 0.0
    
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var audioFile: AVAudioFile?
    private var recordingTimer: Timer?
    private var amplitudeTimer: Timer?
    
    #if !os(macOS)
    private let audioSession = AVAudioSession.sharedInstance()
    #endif
    
    private init() {
        setupAudioSession()
    }
    
    private func setupAudioSession() {
        #if !os(macOS)
        do {
            try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .defaultToSpeaker])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("Failed to setup audio session: \(error)")
        }
        #endif
    }
    
    // MARK: - Public Interface
    
    public func startRecording() -> Bool {
        guard !isRecording else { return false }
        
        do {
            // Create audio engine
            audioEngine = AVAudioEngine()
            guard let audioEngine = audioEngine else { return false }
            
            inputNode = audioEngine.inputNode
            guard let inputNode = inputNode else { return false }
            
            // Create temporary file for recording
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let audioFilename = documentsPath.appendingPathComponent("temp_recording_\(UUID().uuidString).caf")
            
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 44100.0,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
            
            audioFile = try AVAudioFile(forWriting: audioFilename, settings: settings)
            
            // Install tap on input node
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                guard let self = self, let audioFile = self.audioFile else { return }
                
                do {
                    try audioFile.write(from: buffer)
                    
                    // Calculate amplitude for visual feedback
                    let amplitude = self.calculateAmplitude(buffer: buffer)
                    DispatchQueue.main.async {
                        self.currentAmplitude = amplitude
                    }
                } catch {
                    print("Error writing audio buffer: \(error)")
                }
            }
            
            // Start the audio engine
            try audioEngine.start()
            
            // Update state
            DispatchQueue.main.async {
                self.isRecording = true
                self.recordingDuration = 0
                
                // Start timers
                self.recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    guard let self = self else { return }
                    DispatchQueue.main.async {
                        self.recordingDuration += 0.1
                    }
                }
            }
            
            return true
            
        } catch {
            print("Failed to start recording: \(error)")
            cleanup()
            return false
        }
    }
    
    public func stopRecording() -> VoiceMessageData? {
        guard isRecording else { return nil }
        
        cleanup()
        
        // Return mock voice data for now
        let voiceData = VoiceMessageData(
            duration: recordingDuration,
            waveformData: generateMockWaveform(),
            filePath: nil,
            audioData: Data(), // Empty for now
            format: .opus
        )
        
        DispatchQueue.main.async {
            self.isRecording = false
            self.recordingDuration = 0
            self.currentAmplitude = 0
        }
        
        return voiceData
    }
    
    public func cancelRecording() {
        cleanup()
        
        DispatchQueue.main.async {
            self.isRecording = false
            self.recordingDuration = 0
            self.currentAmplitude = 0
        }
    }
    
    // MARK: - Private Methods
    
    private func cleanup() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        
        amplitudeTimer?.invalidate()
        amplitudeTimer = nil
        
        if let inputNode = inputNode {
            inputNode.removeTap(onBus: 0)
        }
        
        audioEngine?.stop()
        audioEngine = nil
        inputNode = nil
        
        audioFile = nil
    }
    
    private func calculateAmplitude(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return 0 }
        
        let frameCount = Int(buffer.frameLength)
        var sum: Float = 0
        
        for i in 0..<frameCount {
            sum += abs(channelData[i])
        }
        
        return frameCount > 0 ? sum / Float(frameCount) : 0
    }
    
    private func generateMockWaveform() -> [Float] {
        // Generate a mock waveform for visualization
        let sampleCount = Int(recordingDuration * 10) // 10 samples per second
        return (0..<sampleCount).map { _ in Float.random(in: 0.1...0.9) }
    }
}

// Note: VoiceMessageData is defined in Models/VoiceMessageData.swift