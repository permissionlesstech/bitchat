//
// VoiceMessageData.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import AVFoundation

/// Voice message data container for BitChat voice communication
/// Contains audio data, waveform visualization, and metadata
public struct VoiceMessageData: Codable, Equatable {
    
    public let duration: TimeInterval
    public let waveformData: [Float]
    public let filePath: String?
    public let audioData: Data?
    public let format: VoiceFormat
    
    /// Voice format enumeration
    public enum VoiceFormat: String, Codable, CaseIterable {
        case opus = "opus"
        case pcm = "pcm"
        case aac = "aac"
        
        var fileExtension: String {
            switch self {
            case .opus: return "opus"
            case .pcm: return "pcm"
            case .aac: return "m4a"
            }
        }
    }
    
    /// Initialize voice message data
    public init(
        duration: TimeInterval,
        waveformData: [Float],
        filePath: String? = nil,
        audioData: Data? = nil,
        format: VoiceFormat = .opus
    ) {
        self.duration = duration
        self.waveformData = waveformData
        self.filePath = filePath
        self.audioData = audioData
        self.format = format
    }
    
    /// Formatted duration string for UI display
    public var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    /// Size of audio data in bytes
    public var audioDataSize: Int {
        return audioData?.count ?? 0
    }
    
    /// Check if voice message has valid audio data
    public var hasValidAudioData: Bool {
        return audioData != nil && audioDataSize > 0
    }
    
    /// Estimated compression ratio (for Opus vs PCM)
    public var compressionRatio: Float {
        guard hasValidAudioData else { return 1.0 }
        
        switch format {
        case .opus:
            // Opus typically achieves 10:1 compression for voice at 16kHz
            return 0.1
        case .pcm:
            return 1.0
        case .aac:
            // AAC achieves around 12:1 compression
            return 0.08
        }
    }
    
    /// Generate waveform data from PCM audio data
    /// - Parameters:
    ///   - pcmData: Raw PCM audio data (16-bit samples)
    ///   - targetSamples: Number of waveform samples to generate (for UI)
    /// - Returns: Waveform data as normalized amplitude values (0.0-1.0)
    public static func generateWaveform(from pcmData: Data, targetSamples: Int = 100) -> [Float] {
        guard !pcmData.isEmpty else { return [] }
        
        let sampleCount = pcmData.count / MemoryLayout<Int16>.size
        let samplesPerSegment = max(1, sampleCount / targetSamples)
        
        var waveformData: [Float] = []
        waveformData.reserveCapacity(targetSamples)
        
        pcmData.withUnsafeBytes { bytes in
            let samples = bytes.bindMemory(to: Int16.self)
            
            for i in 0..<targetSamples {
                let startIndex = i * samplesPerSegment
                let endIndex = min(startIndex + samplesPerSegment, sampleCount)
                
                var maxAmplitude: Int16 = 0
                for j in startIndex..<endIndex {
                    let amplitude = abs(samples[j])
                    maxAmplitude = max(maxAmplitude, amplitude)
                }
                
                // Normalize to 0.0-1.0 range for UI display
                let normalizedAmplitude = Float(maxAmplitude) / Float(Int16.max)
                waveformData.append(normalizedAmplitude)
            }
        }
        
        return waveformData
    }
    
    /// Create VoiceMessageData from audio file URL
    /// - Parameters:
    ///   - url: URL to audio file
    ///   - format: Target voice format
    /// - Returns: VoiceMessageData instance
    /// - Throws: Error if file cannot be read or processed
    public static func fromAudioFile(url: URL, format: VoiceFormat = .opus) throws -> VoiceMessageData {
        let audioData = try Data(contentsOf: url)
        
        // Get audio file duration using AVAudioFile
        let audioFile = try AVAudioFile(forReading: url)
        let duration = Double(audioFile.length) / audioFile.fileFormat.sampleRate
        
        // Generate waveform from PCM data (simplified for now)
        let waveformData = generateWaveform(from: audioData, targetSamples: 100)
        
        return VoiceMessageData(
            duration: duration,
            waveformData: waveformData,
            filePath: url.path,
            audioData: audioData,
            format: format
        )
    }
    
    /// Save audio data to temporary file
    /// - Returns: URL to saved file
    /// - Throws: Error if file cannot be saved
    public func saveToTempFile() throws -> URL {
        guard let audioData = audioData else {
            throw VoiceMessageDataError.noAudioData
        }
        
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "voice_\(UUID().uuidString).\(format.fileExtension)"
        let tempURL = tempDir.appendingPathComponent(fileName)
        
        try audioData.write(to: tempURL)
        return tempURL
    }
    
    /// Decode audio data using appropriate codec
    /// - Returns: Decoded PCM data
    /// - Throws: Error if decoding fails
    public func decodeAudioData() throws -> Data {
        guard let audioData = audioData else {
            throw VoiceMessageDataError.noAudioData
        }
        
        switch format {
        case .opus:
            return try OpusSwiftWrapper.decode(opusData: audioData)
        case .pcm:
            return audioData // Already PCM
        case .aac:
            // AAC decoding would require additional implementation
            throw VoiceMessageDataError.codecNotSupported
        }
    }
    
    /// Create simple fragments for transmission (simplified for now)
    public func createSimpleFragments(messageID: String, maxFragmentSize: Int = 400) -> [Data] {
        guard let audioData = audioData, !audioData.isEmpty else { return [] }
        
        let maxDataPerFragment = maxFragmentSize - 50 // Reserve space for metadata
        var fragments: [Data] = []
        
        var offset = 0
        while offset < audioData.count {
            let endIndex = min(offset + maxDataPerFragment, audioData.count)
            let fragmentData = audioData.subdata(in: offset..<endIndex)
            fragments.append(fragmentData)
            offset = endIndex
        }
        
        return fragments
    }
}

// MARK: - VoiceMessageData Error Types

public enum VoiceMessageDataError: Error, LocalizedError {
    case noAudioData
    case invalidFormat
    case codecNotSupported
    case fileNotFound
    case decodingFailed
    
    public var errorDescription: String? {
        switch self {
        case .noAudioData:
            return "No audio data available"
        case .invalidFormat:
            return "Invalid voice message format"
        case .codecNotSupported:
            return "Voice codec not supported"
        case .fileNotFound:
            return "Voice message file not found"
        case .decodingFailed:
            return "Failed to decode voice message"
        }
    }
}

// MARK: - Extensions for BitChat Integration

extension VoiceMessageData {
    
    /// Convert to VoiceMessage for routing
    /// - Parameters:
    ///   - id: Message ID
    ///   - senderID: Sender peer ID
    ///   - senderNickname: Sender display name
    ///   - isPrivate: Whether this is a private message
    ///   - recipientID: Recipient peer ID (for private messages)
    ///   - recipientNickname: Recipient display name (for private messages)
    /// - Returns: VoiceMessage instance ready for routing
    public func toVoiceMessage(
        id: String,
        senderID: String,
        senderNickname: String,
        isPrivate: Bool = false,
        recipientID: String? = nil,
        recipientNickname: String? = nil
    ) -> VoiceMessage? {
        guard let audioData = audioData else { return nil }
        
        return VoiceMessage(
            id: id,
            senderID: senderID,
            senderNickname: senderNickname,
            audioData: audioData,
            duration: duration,
            sampleRate: 16000, // Standard for BitChat
            codec: format == .opus ? .opus : .pcm,
            timestamp: Date(),
            isPrivate: isPrivate,
            recipientID: recipientID,
            recipientNickname: recipientNickname,
            deliveryStatus: .sending
        )
    }
    
    /// Get waveform values as Float array for UI rendering
    /// - Returns: Array of normalized amplitude values (0.0 - 1.0)
    public var waveformValues: [Float] {
        return waveformData.map { Float($0) / 255.0 }
    }
    
    /// Check if this voice message is suitable for BLE transmission
    /// - Returns: True if size is acceptable for BLE mesh
    public var isSuitableForBLE: Bool {
        let maxBLESize = 50 * 1024 // 50KB reasonable limit for BLE mesh
        return audioDataSize <= maxBLESize
    }
    
    /// Get recommended fragment size for BLE transmission
    /// - Returns: Fragment size in bytes (conservative for BLE MTU)
    public var recommendedFragmentSize: Int {
        return 400 // Conservative limit under 512 byte BLE MTU
    }
}