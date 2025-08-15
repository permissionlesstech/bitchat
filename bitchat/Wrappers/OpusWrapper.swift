//
// OpusWrapper.swift  
// bitchat
//
// Smart Opus codec implementation with YbridOpus detection
//

import Foundation
import AVFoundation
import CryptoKit

// Try to import YbridOpus, but handle gracefully if not available
#if canImport(YbridOpus)
import YbridOpus
private let isYbridOpusAvailable = true
#else
private let isYbridOpusAvailable = false
#endif

/// Smart Opus codec wrapper with automatic YbridOpus detection
public class OpusSwiftWrapper {
    
    // MARK: - Configuration
    
    private static let sampleRate: Int32 = 48000     
    private static let channels: Int32 = 1           
    private static let frameSize: Int = 960          
    private static let maxPacketSize: Int = 4000     
    
    private static var encoder: OpaquePointer?
    private static var decoder: OpaquePointer?
    private static let codecQueue = DispatchQueue(label: "com.bitchat.opus.codec")
    private static var isInitialized = false
    
    // MARK: - Security Configuration
    
    private struct SecurityLimits {
        static let maxInputSize: Int = 50 * 1024 * 1024       // 50MB max input
        static let maxOutputSize: Int = 10 * 1024 * 1024      // 10MB max output
        static let maxFrameSize: Int = 8000                   // Max Opus frame size
        static let minFrameSize: Int = 2                      // Min Opus frame size
        static let maxFramesPerSecond: Int = 200              // Rate limiting
        static let allowedSampleRates: Set<Int32> = [8000, 12000, 16000, 24000, 48000]
        static let allowedChannels: Set<Int32> = [1, 2]
    }
    
    // Security tracking
    private static var frameProcessingCount: Int = 0
    private static var lastFrameTime: Date = Date()
    private static let securityQueue = DispatchQueue(label: "com.bitchat.opus.security")
    
    // MARK: - Architecture Detection
    
    private static var canUseYbridOpus: Bool {
        #if targetEnvironment(simulator)
        // Check if we're on x86_64 simulator (YbridOpus supports) or ARM64 simulator (doesn't support)
        #if arch(x86_64)
        return isYbridOpusAvailable
        #else
        // ARM64 simulator - YbridOpus not supported
        return false
        #endif
        #else
        // Real device - YbridOpus should work
        return isYbridOpusAvailable
        #endif
    }
    
    // MARK: - Initialization
    
    private static func initializeCodec() throws {
        guard canUseYbridOpus else {
            throw OpusError.encoderCreationFailed("YbridOpus not available for this architecture")
        }
        
        #if canImport(YbridOpus)
        try codecQueue.sync {
            guard !isInitialized else { return }
            
            // Initialize encoder
            var encoderError: Int32 = 0
            encoder = opus_encoder_create(sampleRate, channels, 2049, &encoderError)
            
            if encoderError != 0 || encoder == nil {
                throw OpusError.encoderCreationFailed("Encoder creation failed: \(encoderError)")
            }
            
            // Initialize decoder
            var decoderError: Int32 = 0
            decoder = opus_decoder_create(sampleRate, channels, &decoderError)
            
            if decoderError != 0 || decoder == nil {
                if let encoder = encoder {
                    opus_encoder_destroy(encoder)
                }
                throw OpusError.decoderCreationFailed("Decoder creation failed: \(decoderError)")
            }
            
            isInitialized = true
            print("✅ REAL OPUS: YbridOpus initialized successfully!")
            SecureLogger.log("✅ REAL OPUS: YbridOpus codec ready", category: SecureLogger.voice, level: .info)
        }
        #endif
    }
    
    // MARK: - Public API
    
    /// Encode PCM audio data with smart Opus detection and security validation
    public static func encode(pcmData: Data) throws -> Data {
        // Security validation first
        try validateInputForEncoding(pcmData)
        
        guard canUseYbridOpus else {
            print("⚠️ ARCHITECTURE WARNING: YbridOpus not supported on ARM64 simulator")
            SecureLogger.log("⚠️ YbridOpus not supported on current architecture", category: SecureLogger.voice, level: .warning)
            // For ARM64 simulator, return raw data (or could use system compression)
            return pcmData
        }
        
        #if canImport(YbridOpus)
        try initializeCodec()
        
        print("🎵 PURE OPUS: Encoding \(pcmData.count) bytes with YbridOpus")
        SecureLogger.log("🎵 PURE OPUS: YbridOpus encoding", category: SecureLogger.voice, level: .info)
        
        guard let encoder = encoder else {
            throw OpusError.encoderNotInitialized
        }
        
        let result = try codecQueue.sync {
            // Pure PCM input expected
            let inputData = pcmData
            
            let floatCount = inputData.count / MemoryLayout<Float>.size
            guard floatCount >= frameSize else {
                throw OpusError.invalidData
            }
            
            var encodedData = Data()
            var offset = 0
            
            inputData.withUnsafeBytes { bytes in
                let floatSamples = bytes.bindMemory(to: Float.self)
                
                while offset + frameSize <= floatCount {
                    var outputBuffer = [UInt8](repeating: 0, count: maxPacketSize)
                    
                    let encodedBytes = opus_encode_float(
                        encoder,
                        floatSamples.baseAddress!.advanced(by: offset),
                        Int32(frameSize),
                        &outputBuffer,
                        Int32(maxPacketSize)
                    )
                    
                    if encodedBytes > 0 {
                        let frameLength = UInt16(encodedBytes)
                        withUnsafeBytes(of: frameLength) { encodedData.append(contentsOf: $0) }
                        encodedData.append(contentsOf: outputBuffer[0..<Int(encodedBytes)])
                    } else {
                        print("⚠️ OPUS: Encoding failed for frame at offset \(offset), error: \(encodedBytes)")
                    }
                    
                    offset += frameSize
                }
            }
            
            let compressionRatio = Float(inputData.count) / Float(encodedData.count)
            print("✅ PURE OPUS: Encoded \(inputData.count) → \(encodedData.count) bytes (compression: \(String(format: "%.1f", compressionRatio)):1)")
            SecureLogger.log("✅ PURE OPUS: YbridOpus compression \(compressionRatio):1", category: SecureLogger.voice, level: .info)
            
            return encodedData
        }
        
        return result
        #else
        throw OpusError.encoderCreationFailed("YbridOpus not available")
        #endif
    }
    
    /// Decode Opus audio data with smart detection and security validation
    public static func decode(opusData: Data) throws -> Data {
        // Security validation first
        try validateInputForDecoding(opusData)
        
        guard canUseYbridOpus else {
            print("⚠️ ARCHITECTURE WARNING: YbridOpus not supported on ARM64 simulator")
            // For ARM64 simulator, return raw data
            return opusData
        }
        
        #if canImport(YbridOpus)
        try initializeCodec()
        
        print("🎵 PURE OPUS: Decoding \(opusData.count) bytes with YbridOpus")
        SecureLogger.log("🎵 PURE OPUS: YbridOpus decoding", category: SecureLogger.voice, level: .info)
        
        guard let decoder = decoder else {
            throw OpusError.decoderNotInitialized
        }
        
        let result = codecQueue.sync {
            var pcmData = Data()
            var offset = 0
            var validFrames = 0
            var totalFrames = 0
            
            while offset + 2 <= opusData.count {
                totalFrames += 1
                
                // Safe reading of UInt16 to avoid alignment issues
                let frameLength = opusData.withUnsafeBytes { bytes in
                    let byte0 = UInt16(bytes[offset])
                    let byte1 = UInt16(bytes[offset + 1])
                    return byte0 | (byte1 << 8) // Little-endian
                }
                offset += 2
                
                // Validate frame length
                guard frameLength > 0 && frameLength <= 4000 else {
                    print("⚠️ OPUS: Invalid frame length: \(frameLength) at offset \(offset-2)")
                    break
                }
                
                guard offset + Int(frameLength) <= opusData.count else {
                    print("⚠️ OPUS: Frame extends beyond data boundary: \(offset + Int(frameLength)) > \(opusData.count)")
                    break
                }
                
                let frameData = opusData.subdata(in: offset..<(offset + Int(frameLength)))
                offset += Int(frameLength)
                
                var outputBuffer = [Float](repeating: 0, count: frameSize)
                
                let decodedSamples = frameData.withUnsafeBytes { bytes in
                    opus_decode_float(
                        decoder,
                        bytes.bindMemory(to: UInt8.self).baseAddress,
                        Int32(frameData.count),
                        &outputBuffer,
                        Int32(frameSize),
                        0
                    )
                }
                
                if decodedSamples > 0 {
                    validFrames += 1
                    let decodedFrameData = Data(bytes: outputBuffer, count: Int(decodedSamples) * MemoryLayout<Float>.size)
                    pcmData.append(decodedFrameData)
                } else {
                    print("⚠️ OPUS: Failed to decode frame \(totalFrames), size \(frameLength), error: \(decodedSamples)")
                }
            }
            
            print("✅ PURE OPUS: Decoded \(opusData.count) → \(pcmData.count) bytes (\(validFrames)/\(totalFrames) frames)")
            SecureLogger.log("✅ PURE OPUS: YbridOpus decoded \(validFrames)/\(totalFrames) frames", category: SecureLogger.voice, level: .info)
            
            return pcmData
        }
        
        return result
        #else
        throw OpusError.decoderCreationFailed("YbridOpus not available")
        #endif
    }
    
    /// Convert PCM formats if needed
    public static func convertPCMFormat(pcmData: Data, fromSampleRate: Double = 16000, toSampleRate: Double = 48000) -> Data {
        if fromSampleRate == toSampleRate {
            return pcmData
        }
        
        // Handle 16kHz to 48kHz upsampling
        if fromSampleRate == 16000 && toSampleRate == 48000 {
            var upsampled = Data()
            let bytesPerFloat32 = MemoryLayout<Float32>.size
            
            if pcmData.count % bytesPerFloat32 == 0 {
                let sampleCount = pcmData.count / bytesPerFloat32
                upsampled.reserveCapacity(sampleCount * 3 * bytesPerFloat32)
                
                pcmData.withUnsafeBytes { bytes in
                    let samples = bytes.bindMemory(to: Float32.self)
                    
                    for i in 0..<sampleCount {
                        var sample = samples[i]
                        upsampled.append(Data(bytes: &sample, count: bytesPerFloat32))
                        upsampled.append(Data(bytes: &sample, count: bytesPerFloat32))
                        upsampled.append(Data(bytes: &sample, count: bytesPerFloat32))
                    }
                }
                
                return upsampled
            }
        }
        
        return pcmData
    }
    
    /// Check if YbridOpus is available for current architecture
    public static var isOpusAvailable: Bool {
        return canUseYbridOpus
    }
    
    /// Reset codec state
    public static func resetCodec() {
        #if canImport(YbridOpus)
        codecQueue.sync {
            isInitialized = false
        }
        #endif
    }
    
    /// Clean up resources
    public static func cleanup() {
        #if canImport(YbridOpus)
        codecQueue.sync {
            if let encoder = encoder {
                opus_encoder_destroy(encoder)
                self.encoder = nil
            }
            
            if let decoder = decoder {
                opus_decoder_destroy(decoder)
                self.decoder = nil
            }
            
            isInitialized = false
        }
        #endif
    }
    
    // MARK: - Security Validation Methods
    
    /// Validate input data for encoding
    private static func validateInputForEncoding(_ data: Data) throws {
        // Size validation
        guard !data.isEmpty else {
            throw OpusSecurityError.emptyData
        }
        
        guard data.count <= SecurityLimits.maxInputSize else {
            SecureLogger.log("🚨 Opus encoding input exceeds size limit: \(data.count) bytes", 
                           category: SecureLogger.voice, level: .error)
            throw OpusSecurityError.oversizedInput
        }
        
        // PCM format validation
        guard data.count % MemoryLayout<Float32>.size == 0 else {
            throw OpusSecurityError.invalidPCMAlignment
        }
        
        // Rate limiting check
        try validateProcessingRate()
        
        // Sample validation
        try validatePCMSamples(data)
    }
    
    /// Validate input data for decoding
    private static func validateInputForDecoding(_ data: Data) throws {
        // Size validation
        guard !data.isEmpty else {
            throw OpusSecurityError.emptyData
        }
        
        guard data.count <= SecurityLimits.maxInputSize else {
            SecureLogger.log("🚨 Opus decoding input exceeds size limit: \(data.count) bytes", 
                           category: SecureLogger.voice, level: .error)
            throw OpusSecurityError.oversizedInput
        }
        
        // Basic Opus format validation
        guard data.count >= 4 else {
            throw OpusSecurityError.invalidOpusFormat
        }
        
        // Rate limiting check
        try validateProcessingRate()
        
        // Opus frame validation
        try validateOpusFrames(data)
    }
    
    /// Validate processing rate for DoS protection
    private static func validateProcessingRate() throws {
        var shouldThrow = false
        var frameCount = 0
        
        securityQueue.sync {
            let now = Date()
            
            // Reset counter if more than 1 second has passed
            if now.timeIntervalSince(lastFrameTime) > 1.0 {
                frameProcessingCount = 0
                lastFrameTime = now
            }
            
            frameProcessingCount += 1
            frameCount = frameProcessingCount
            
            if frameProcessingCount > SecurityLimits.maxFramesPerSecond {
                shouldThrow = true
            }
        }
        
        if shouldThrow {
            SecureLogger.log("🚨 Opus processing rate limit exceeded: \(frameCount) frames/sec", 
                           category: SecureLogger.voice, level: .error)
            throw OpusSecurityError.rateLimitExceeded
        }
    }
    
    /// Validate PCM samples for malicious content
    private static func validatePCMSamples(_ data: Data) throws {
        let samples = data.withUnsafeBytes { bytes in
            bytes.bindMemory(to: Float32.self)
        }
        
        var suspiciousCount = 0
        let sampleCount = samples.count
        let maxSamplesToCheck = min(1000, sampleCount) // Check first 1000 samples for performance
        
        for i in 0..<maxSamplesToCheck {
            let sample = samples[i]
            
            // Check for NaN or infinite values
            if !sample.isFinite {
                suspiciousCount += 1
            }
            
            // Check for extreme values that might cause overflow
            if abs(sample) > 10.0 {
                suspiciousCount += 1
            }
        }
        
        // If more than 5% of samples are suspicious, reject
        if suspiciousCount > maxSamplesToCheck / 20 {
            SecureLogger.log("🚨 Suspicious PCM samples detected: \(suspiciousCount)/\(maxSamplesToCheck)", 
                           category: SecureLogger.voice, level: .error)
            throw OpusSecurityError.suspiciousPCMData
        }
    }
    
    /// Validate Opus frame structure
    private static func validateOpusFrames(_ data: Data) throws {
        var offset = 0
        var frameCount = 0
        let maxFramesToCheck = 50 // Limit validation for performance
        
        while offset + 2 < data.count && frameCount < maxFramesToCheck {
            // Read frame length (first 2 bytes, little-endian)
            let frameLength = data.withUnsafeBytes { bytes in
                let byte0 = UInt16(bytes[offset])
                let byte1 = UInt16(bytes[offset + 1])
                return byte0 | (byte1 << 8)
            }
            
            // Validate frame length
            guard frameLength >= SecurityLimits.minFrameSize && frameLength <= SecurityLimits.maxFrameSize else {
                SecureLogger.log("🚨 Invalid Opus frame length: \(frameLength) at offset \(offset)", 
                               category: SecureLogger.voice, level: .error)
                throw OpusSecurityError.invalidFrameSize
            }
            
            offset += 2
            
            // Check if frame data exists
            guard offset + Int(frameLength) <= data.count else {
                SecureLogger.log("🚨 Opus frame extends beyond data: \(offset + Int(frameLength)) > \(data.count)", 
                               category: SecureLogger.voice, level: .error)
                throw OpusSecurityError.truncatedFrame
            }
            
            // Validate Opus TOC (Table of Contents) byte
            if offset < data.count {
                let tocByte = data[offset]
                let config = (tocByte >> 3) & 0x1F
                
                guard config <= 31 else {
                    SecureLogger.log("🚨 Invalid Opus TOC configuration: \(config)", 
                                   category: SecureLogger.voice, level: .error)
                    throw OpusSecurityError.invalidTOC
                }
            }
            
            offset += Int(frameLength)
            frameCount += 1
        }
    }
    
    /// Generate integrity hash for data validation
    private static func generateDataHash(_ data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    /// Validate data integrity with hash
    private static func validateDataIntegrity(_ data: Data, expectedHash: String) -> Bool {
        let actualHash = generateDataHash(data)
        let isValid = actualHash == expectedHash
        
        if !isValid {
            SecureLogger.log("🚨 Opus data integrity check failed", 
                           category: SecureLogger.voice, level: .error)
        }
        
        return isValid
    }
}

// MARK: - Security Errors

public enum OpusSecurityError: LocalizedError {
    case emptyData
    case oversizedInput
    case invalidPCMAlignment
    case suspiciousPCMData
    case invalidOpusFormat
    case invalidFrameSize
    case truncatedFrame
    case invalidTOC
    case rateLimitExceeded
    case integrityCheckFailed
    
    public var errorDescription: String? {
        switch self {
        case .emptyData:
            return "Input data is empty"
        case .oversizedInput:
            return "Input data exceeds maximum allowed size"
        case .invalidPCMAlignment:
            return "PCM data is not properly aligned"
        case .suspiciousPCMData:
            return "Suspicious patterns detected in PCM data"
        case .invalidOpusFormat:
            return "Invalid Opus data format"
        case .invalidFrameSize:
            return "Opus frame size is invalid"
        case .truncatedFrame:
            return "Opus frame is truncated"
        case .invalidTOC:
            return "Invalid Opus Table of Contents"
        case .rateLimitExceeded:
            return "Processing rate limit exceeded"
        case .integrityCheckFailed:
            return "Data integrity check failed"
        }
    }
}

// MARK: - Errors

public enum OpusError: LocalizedError {
    case encoderCreationFailed(String)
    case decoderCreationFailed(String)
    case encoderNotInitialized
    case decoderNotInitialized
    case encodingFailed(String)
    case decodingFailed(String)
    case invalidData
    
    public var errorDescription: String? {
        switch self {
        case .encoderCreationFailed(let msg):
            return "Failed to create Opus encoder: \(msg)"
        case .decoderCreationFailed(let msg):
            return "Failed to create Opus decoder: \(msg)"
        case .encoderNotInitialized:
            return "Opus encoder not initialized"
        case .decoderNotInitialized:
            return "Opus decoder not initialized"
        case .encodingFailed(let msg):
            return "Opus encoding failed: \(msg)"
        case .decodingFailed(let msg):
            return "Opus decoding failed: \(msg)"
        case .invalidData:
            return "Invalid audio data format"
        }
    }
}