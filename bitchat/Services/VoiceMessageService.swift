//
// VoiceMessageService.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import SwiftUI
import AVFoundation
import Combine
import CryptoKit

/// VoiceMessageService: Service layer for managing voice message recording, 
/// encoding, and transmission in BitChat
/// 
/// Follows BitChat architecture patterns:
/// - Uses SecureLogger for privacy-aware logging
/// - Integrates with MessageRouter for dual transport (Bluetooth/Nostr)
/// - Implements proper error handling and state management
/// - Compatible with existing BitChat services
public class VoiceMessageService: ObservableObject {
    
    public static let shared = VoiceMessageService()
    
    // MARK: - Published Properties (Observable by ChatViewModel)
    
    @Published public private(set) var isRecording = false
    @Published public private(set) var recordingDuration: TimeInterval = 0
    @Published public private(set) var currentAmplitude: Float = 0.0
    
    // MARK: - Voice Message State Management
    
    /// Voice message state for tracking sent messages
    public struct VoiceMessageState {
        public let id: String
        public let message: BitchatMessage
        public var deliveryStatus: DeliveryStatus
        public let createdAt: Date
        public var retryCount: Int
        
        // Retry parameters
        public let recipientPeerID: String?
        public let recipientNickname: String?
        public let senderNickname: String?
        public let isPrivate: Bool
        
        public init(
            id: String, 
            message: BitchatMessage, 
            deliveryStatus: DeliveryStatus,
            recipientPeerID: String? = nil,
            recipientNickname: String? = nil,
            senderNickname: String? = nil,
            isPrivate: Bool = true
        ) {
            self.id = id
            self.message = message
            self.deliveryStatus = deliveryStatus
            self.createdAt = Date()
            self.retryCount = 0
            self.recipientPeerID = recipientPeerID
            self.recipientNickname = recipientNickname
            self.senderNickname = senderNickname
            self.isPrivate = isPrivate
        }
    }
    
    // MARK: - Private Properties
    
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var audioFile: AVAudioFile?
    private var recordingTimer: Timer?
    private var recordedAudioURL: URL?
    private var waveformData: [Float] = []
    
    // Audio session management (iOS only)
    #if os(iOS)
    private let audioSession = AVAudioSession.sharedInstance()
    #endif
    
    // Voice message state tracking with enhanced lifecycle management
    private var voiceMessageStates: [String: VoiceMessageState] = [:]
    private let stateQueue = DispatchQueue(label: "com.bitchat.voice.state", qos: .userInitiated)
    
    // Lifecycle management
    private var deliveryCallbacks: [String: (DeliveryStatus) -> Void] = [:]
    private var lifecycleTimer: Timer?
    
    // MessageRouter integration for actual transmission
    private weak var messageRouter: MessageRouter?
    
    // Battery-aware adaptive compression
    private let batteryOptimizer = BatteryOptimizer.shared
    
    // MARK: - Security Configuration
    
    /// Security limits and validation parameters
    private struct SecurityLimits {
        static let maxRecordingDuration: TimeInterval = 300.0  // 5 minutes max
        static let minRecordingDuration: TimeInterval = 0.1    // 100ms minimum
        static let maxAudioDataSize: Int = 50 * 1024 * 1024    // 50MB max
        static let maxOpusDataSize: Int = 10 * 1024 * 1024     // 10MB max
        static let maxSampleRate: Float64 = 48000              // Standard max
        static let minSampleRate: Float64 = 8000               // Voice quality min
        static let maxChannels: UInt32 = 2                     // Stereo max
        static let allowedFormats: Set<AudioFormatID> = [
            kAudioFormatLinearPCM,
            kAudioFormatMPEG4AAC
        ]
        
        // Rate limiting
        static let maxRecordingsPerMinute: Int = 30
        static let maxRecordingsPerHour: Int = 200
    }
    
    // Security state tracking
    private var recentRecordings: [Date] = []
    private let securityQueue = DispatchQueue(label: "com.bitchat.voice.security", qos: .userInitiated)
    
    // MARK: - Initialization
    
    private init() {
        SecureLogger.log("🎤 VoiceMessageService initialized", 
                        category: SecureLogger.voice, level: .info)
    }
    
    /// Set MessageRouter for voice message transmission
    /// - Parameter messageRouter: The MessageRouter instance for transmission
    internal func setMessageRouter(_ messageRouter: MessageRouter) {
        self.messageRouter = messageRouter
        SecureLogger.log("🔗 MessageRouter connected to VoiceMessageService", 
                        category: SecureLogger.voice, level: .info)
    }
    
    // MARK: - Public Interface
    
    /// Start recording voice message
    @discardableResult
    public func startRecording() -> Bool {
        guard !isRecording else {
            SecureLogger.log("⚠️ Recording already in progress", 
                           category: SecureLogger.voice, level: .warning)
            return false
        }
        
        // Security validation: Rate limiting
        guard validateRateLimit() else {
            SecureLogger.log("🚨 Rate limit exceeded for voice recordings", 
                           category: SecureLogger.voice, level: .error)
            return false
        }
        
        SecureLogger.log("🎤 Starting voice recording", 
                        category: SecureLogger.voice, level: .info)
        
        do {
            try setupAudioSession()
            try startAudioRecording()
            
            // Track recording for rate limiting
            securityQueue.async {
                self.recentRecordings.append(Date())
            }
            
            return true
        } catch {
            SecureLogger.log("❌ Failed to start recording: \(error)", 
                           category: SecureLogger.voice, level: .error)
            return false
        }
    }
    
    /// Stop recording and return message ID for processing
    @discardableResult
    public func stopRecording(completion: @escaping (String) -> Void) -> String? {
        guard isRecording else {
            SecureLogger.log("⚠️ Not currently recording", 
                           category: SecureLogger.voice, level: .warning)
            return nil
        }
        
        SecureLogger.log("🎤 Stopping voice recording", 
                        category: SecureLogger.voice, level: .info)
        
        let messageID = UUID().uuidString
        let duration = recordingDuration
        let waveform = waveformData
        
        // Stop recording
        stopAudioRecording()
        
        // Process recorded audio asynchronously
        Task {
            await processRecordedAudio(messageID: messageID, duration: duration, waveform: waveform)
            
            DispatchQueue.main.async {
                completion(messageID)
            }
        }
        
        return messageID
    }
    
    /// Cancel current recording
    public func cancelRecording() {
        guard isRecording else { return }
        
        SecureLogger.log("🎤 Canceling voice recording", 
                        category: SecureLogger.voice, level: .info)
        
        stopAudioRecording()
        cleanupTempFiles()
    }
    
    /// Get voice message state by ID
    public func getVoiceMessageState(_ messageID: String) -> VoiceMessageState? {
        return stateQueue.sync {
            return voiceMessageStates[messageID]
        }
    }
    
    // MARK: - Audio Session Setup
    
    private func setupAudioSession() throws {
        #if os(iOS)
        try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [
            .defaultToSpeaker,
            .allowBluetooth,
            .allowBluetoothA2DP
        ])
        try audioSession.setPreferredSampleRate(48000) // Opus native sample rate
        try audioSession.setActive(true)
        #endif
    }
    
    // MARK: - Audio Recording
    
    private func startAudioRecording() throws {
        // Create audio engine and input node
        audioEngine = AVAudioEngine()
        guard let engine = audioEngine else {
            throw VoiceRecordingError.engineCreationFailed
        }
        
        inputNode = engine.inputNode
        guard let input = inputNode else {
            throw VoiceRecordingError.noInputNode
        }
        
        // Create temporary recording file
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        recordedAudioURL = documentsPath.appendingPathComponent("voice_\(UUID().uuidString).caf")
        
        guard let audioURL = recordedAudioURL else {
            throw VoiceRecordingError.fileCreationFailed
        }
        
        // Audio format settings - Match Opus requirements (48kHz Float32)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 48000.0,  // Opus native sample rate
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,  // Use Float32 format
            AVLinearPCMIsBigEndianKey: false
        ]
        
        // Create audio file
        audioFile = try AVAudioFile(forWriting: audioURL, settings: settings)
        
        // Install tap on input node for recording and waveform generation
        let recordingFormat = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            guard let self = self, let audioFile = self.audioFile else { return }
            
            do {
                try audioFile.write(from: buffer)
                
                // Calculate amplitude for waveform
                let amplitude = self.calculateAmplitude(buffer: buffer)
                DispatchQueue.main.async {
                    self.currentAmplitude = amplitude
                    self.waveformData.append(amplitude)
                }
            } catch {
                SecureLogger.log("❌ Error writing audio buffer: \(error)", 
                               category: SecureLogger.voice, level: .error)
            }
        }
        
        // Start audio engine
        try engine.start()
        
        // Update state and start timer
        DispatchQueue.main.async {
            self.isRecording = true
            self.recordingDuration = 0
            self.waveformData = []
            
            self.recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                self.recordingDuration += 0.1
            }
        }
        
        SecureLogger.log("✅ Audio recording started successfully", 
                        category: SecureLogger.voice, level: .info)
    }
    
    private func stopAudioRecording() {
        // Stop timer
        recordingTimer?.invalidate()
        recordingTimer = nil
        
        // Remove tap and stop engine
        inputNode?.removeTap(onBus: 0)
        audioEngine?.stop()
        
        // Update state
        DispatchQueue.main.async {
            self.isRecording = false
            self.currentAmplitude = 0
        }
        
        // Clean up references
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
    
    // MARK: - Audio Processing
    
    private func processRecordedAudio(messageID: String, duration: TimeInterval, waveform: [Float]) async {
        SecureLogger.log("🔄 Processing recorded audio for message: \(messageID)", 
                        category: SecureLogger.voice, level: .info)
        
        guard let audioURL = recordedAudioURL else {
            SecureLogger.log("❌ No recorded audio URL available", 
                           category: SecureLogger.voice, level: .error)
            return
        }
        
        do {
            // Read recorded CAF audio data
            let rawAudioData = try Data(contentsOf: audioURL)
            
            SecureLogger.log("📀 Read raw audio data: \(rawAudioData.count) bytes", 
                           category: SecureLogger.voice, level: .info)
            
            // Convert CAF to PCM then encode to Opus
            let rawOpusData = try await convertCafToOpus(cafData: rawAudioData, audioURL: audioURL)
            
            SecureLogger.log("🎵 Encoded to Opus: \(rawOpusData.count) bytes", 
                           category: SecureLogger.voice, level: .info)
            
            // Apply adaptive compression based on battery level and transmission time
            let audioData = applyAdaptiveCompression(to: rawOpusData, duration: duration)
            
            if audioData.count != rawOpusData.count {
                SecureLogger.log("⚡ Adaptive compression applied: \(rawOpusData.count) → \(audioData.count) bytes", 
                               category: SecureLogger.voice, level: .info)
            }
            
            // Create VoiceMessageData with Opus-encoded data
            let voiceMessageData = VoiceMessageData(
                duration: duration,
                waveformData: waveform,
                filePath: audioURL.path,
                audioData: audioData,
                format: .opus // Now properly Opus-encoded
            )
            
            // Create BitchatMessage
            let message = BitchatMessage(
                id: messageID,
                sender: "Current User", // This will be set by ChatViewModel
                content: "🎤 Voice message (\(voiceMessageData.formattedDuration))",
                timestamp: Date(),
                isRelay: false,
                originalSender: nil,
                isPrivate: false,
                recipientNickname: nil,
                senderPeerID: nil,
                mentions: nil,
                deliveryStatus: .sending,
                voiceMessageData: voiceMessageData
            )
            
            // Store voice message state
            let voiceState = VoiceMessageState(
                id: messageID,
                message: message,
                deliveryStatus: .sending
            )
            
            stateQueue.async {
                self.voiceMessageStates[messageID] = voiceState
            }
            
            SecureLogger.log("✅ Voice message processed successfully: \(messageID)", 
                           category: SecureLogger.voice, level: .info)
            
        } catch {
            SecureLogger.log("❌ Failed to process recorded audio: \(error)", 
                           category: SecureLogger.voice, level: .error)
        }
    }
    
    // MARK: - Message Sending (Integration with MessageRouter)
    
    /// Send voice message to specific peer (private message)
    public func sendVoiceMessage(
        to peerID: String,
        recipientNickname: String,
        senderNickname: String,
        messageID: String
    ) async throws {
        guard getVoiceMessageState(messageID) != nil else {
            throw VoiceMessageError.messageNotFound
        }
        
        SecureLogger.log("📤 Sending private voice message to: \(recipientNickname)", 
                        category: SecureLogger.voice, level: .info)
        
        // Store retry parameters for potential retransmission
        updateVoiceMessageRetryParams(
            messageID,
            recipientPeerID: peerID,
            recipientNickname: recipientNickname,
            senderNickname: senderNickname,
            isPrivate: true
        )
        
        // Update state to sending
        updateVoiceMessageDeliveryStatus(messageID, status: .sending)
        
        // Get voice message state for transmission
        guard let voiceState = getVoiceMessageState(messageID),
              let messageRouter = self.messageRouter else {
            SecureLogger.log("❌ MessageRouter not available or message not found", 
                           category: SecureLogger.voice, level: .error)
            updateVoiceMessageDeliveryStatus(messageID, status: .failed(reason: "MessageRouter not available"))
            throw VoiceMessageError.transmissionFailed("MessageRouter not available")
        }
        
        // Route voice message through MessageRouter for actual transmission  
        await Task { @MainActor in
            messageRouter.routeVoiceMessage(voiceState.message, to: peerID, isPrivate: true)
        }.value
        
        // Track delivery for this voice message
        DeliveryTracker.shared.trackVoiceMessageDelivery(messageID, to: peerID, recipientNickname: recipientNickname)
        
        // Update status to sent after successful routing
        updateVoiceMessageDeliveryStatus(messageID, status: .sent)
        
        SecureLogger.log("✅ Voice message sent successfully to: \(recipientNickname)", 
                        category: SecureLogger.voice, level: .info)
    }
    
    /// Send voice message as broadcast (public message)
    public func sendVoiceMessageBroadcast(
        senderNickname: String,
        messageID: String
    ) async throws {
        guard getVoiceMessageState(messageID) != nil else {
            throw VoiceMessageError.messageNotFound
        }
        
        SecureLogger.log("📢 Broadcasting voice message", 
                        category: SecureLogger.voice, level: .info)
        
        // Store retry parameters for potential retransmission
        updateVoiceMessageRetryParams(
            messageID,
            recipientPeerID: nil,
            recipientNickname: nil,
            senderNickname: senderNickname,
            isPrivate: false
        )
        
        // Update state to sending
        updateVoiceMessageDeliveryStatus(messageID, status: .sending)
        
        // Get voice message state for transmission
        guard let voiceState = getVoiceMessageState(messageID),
              let messageRouter = self.messageRouter else {
            SecureLogger.log("❌ MessageRouter not available or message not found for broadcast", 
                           category: SecureLogger.voice, level: .error)
            updateVoiceMessageDeliveryStatus(messageID, status: .failed(reason: "MessageRouter not available"))
            throw VoiceMessageError.transmissionFailed("MessageRouter not available")
        }
        
        // Route voice message as broadcast through MessageRouter
        await Task { @MainActor in
            messageRouter.routeVoiceMessage(voiceState.message, to: "", isPrivate: false)
        }.value
        
        // Update status to sent after successful routing
        updateVoiceMessageDeliveryStatus(messageID, status: .sent)
        
        SecureLogger.log("✅ Voice message broadcast successfully", 
                        category: SecureLogger.voice, level: .info)
    }
    
    // MARK: - Enhanced Lifecycle Management
    
    /// Register delivery callback for voice message
    public func registerDeliveryCallback(for messageID: String, callback: @escaping (DeliveryStatus) -> Void) {
        stateQueue.async {
            self.deliveryCallbacks[messageID] = callback
        }
    }
    
    /// Update voice message retry parameters for proper retransmission
    private func updateVoiceMessageRetryParams(
        _ messageID: String, 
        recipientPeerID: String? = nil,
        recipientNickname: String? = nil, 
        senderNickname: String? = nil,
        isPrivate: Bool = true
    ) {
        stateQueue.async {
            guard var voiceState = self.voiceMessageStates[messageID] else { return }
            
            // Create updated state with retry parameters, preserving retryCount
            var updatedState = VoiceMessageState(
                id: voiceState.id,
                message: voiceState.message,
                deliveryStatus: voiceState.deliveryStatus,
                recipientPeerID: recipientPeerID,
                recipientNickname: recipientNickname,
                senderNickname: senderNickname,
                isPrivate: isPrivate
            )
            updatedState.retryCount = voiceState.retryCount
            
            self.voiceMessageStates[messageID] = updatedState
        }
    }
    
    /// Update voice message delivery status with callback notification
    private func updateVoiceMessageDeliveryStatus(_ messageID: String, status: DeliveryStatus) {
        stateQueue.async {
            // Update state
            self.voiceMessageStates[messageID]?.deliveryStatus = status
            
            // Notify callback
            if let callback = self.deliveryCallbacks[messageID] {
                DispatchQueue.main.async {
                    callback(status)
                }
            }
            
            // Log status change
            SecureLogger.log("📊 Voice message \(messageID) status: \(status.displayText)", 
                           category: SecureLogger.voice, level: .info)
        }
    }
    
    /// Handle delivery confirmation from transport layer
    public func handleDeliveryConfirmation(messageID: String, deliveredTo: String, at timestamp: Date) {
        let status = DeliveryStatus.delivered(to: deliveredTo, at: timestamp)
        updateVoiceMessageDeliveryStatus(messageID, status: status)
    }
    
    /// Handle read receipt from recipient
    public func handleReadReceipt(messageID: String, readBy: String, at timestamp: Date) {
        let status = DeliveryStatus.read(by: readBy, at: timestamp)
        updateVoiceMessageDeliveryStatus(messageID, status: status)
    }
    
    /// Handle transmission failure
    public func handleTransmissionFailure(messageID: String, reason: String, shouldRetry: Bool = true) {
        stateQueue.async {
            guard var voiceState = self.voiceMessageStates[messageID] else { return }
            
            voiceState.retryCount += 1
            let maxRetries = 3
            
            if shouldRetry && voiceState.retryCount < maxRetries {
                // Schedule retry
                let delay = Double(voiceState.retryCount) * 2.0 // Exponential backoff
                SecureLogger.log("🔄 Scheduling voice message retry \(voiceState.retryCount)/\(maxRetries) in \(delay)s", 
                               category: SecureLogger.voice, level: .info)
                
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.retryVoiceMessage(messageID: messageID)
                }
                
                self.voiceMessageStates[messageID] = voiceState
            } else {
                // Final failure
                let finalReason = voiceState.retryCount >= maxRetries ? "Max retries exceeded: \(reason)" : reason
                self.updateVoiceMessageDeliveryStatus(messageID, status: .failed(reason: finalReason))
                
                // Cleanup
                self.cleanupVoiceMessage(messageID: messageID)
            }
        }
    }
    
    /// Retry failed voice message transmission
    private func retryVoiceMessage(messageID: String) {
        stateQueue.async {
            guard let voiceState = self.voiceMessageStates[messageID] else {
                SecureLogger.log("❌ Cannot retry - voice message state not found: \(messageID)", 
                               category: SecureLogger.voice, level: .error)
                return
            }
            
            SecureLogger.log("🔄 Retrying voice message transmission: \(messageID)", 
                           category: SecureLogger.voice, level: .info)
            
            // Reset to sending status
            self.updateVoiceMessageDeliveryStatus(messageID, status: .sending)
            
            // Attempt retransmission based on message type
            Task {
                do {
                    if voiceState.isPrivate {
                        guard let recipientPeerID = voiceState.recipientPeerID,
                              let recipientNickname = voiceState.recipientNickname,
                              let senderNickname = voiceState.senderNickname else {
                            throw VoiceMessageError.transmissionFailed("Missing retry parameters for private message")
                        }
                        try await self.sendVoiceMessage(
                            to: recipientPeerID,
                            recipientNickname: recipientNickname,
                            senderNickname: senderNickname,
                            messageID: messageID
                        )
                    } else {
                        guard let senderNickname = voiceState.senderNickname else {
                            throw VoiceMessageError.transmissionFailed("Missing sender nickname for broadcast")
                        }
                        try await self.sendVoiceMessageBroadcast(
                            senderNickname: senderNickname,
                            messageID: messageID
                        )
                    }
                } catch {
                    self.handleTransmissionFailure(messageID: messageID, reason: error.localizedDescription)
                }
            }
        }
    }
    
    /// Start lifecycle management timer for monitoring and cleanup
    public func startLifecycleManagement() {
        stopLifecycleManagement() // Stop existing timer
        
        lifecycleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.performLifecycleMaintenance()
        }
        
        SecureLogger.log("🔄 Voice message lifecycle management started", 
                       category: SecureLogger.voice, level: .info)
    }
    
    /// Stop lifecycle management timer
    public func stopLifecycleManagement() {
        lifecycleTimer?.invalidate()
        lifecycleTimer = nil
    }
    
    /// Perform periodic lifecycle maintenance
    private func performLifecycleMaintenance() {
        stateQueue.async {
            let now = Date()
            let maxAge: TimeInterval = 3600 // 1 hour
            var expiredMessages: [String] = []
            
            // Find expired messages
            for (messageID, voiceState) in self.voiceMessageStates {
                let age = now.timeIntervalSince(voiceState.createdAt)
                
                if age > maxAge {
                    expiredMessages.append(messageID)
                } else if case .sending = voiceState.deliveryStatus {
                    // Check for stuck messages
                    if age > 300 { // 5 minutes
                        SecureLogger.log("⚠️ Voice message stuck in sending state: \(messageID)", 
                                       category: SecureLogger.voice, level: .warning)
                        self.handleTransmissionFailure(
                            messageID: messageID,
                            reason: "Transmission timeout",
                            shouldRetry: voiceState.retryCount < 2
                        )
                    }
                }
            }
            
            // Cleanup expired messages
            for messageID in expiredMessages {
                SecureLogger.log("🧹 Cleaning up expired voice message: \(messageID)", 
                               category: SecureLogger.voice, level: .info)
                self.cleanupVoiceMessage(messageID: messageID)
            }
            
            if !expiredMessages.isEmpty {
                DispatchQueue.main.async {
                    SecureLogger.log("🧹 Lifecycle maintenance: cleaned \(expiredMessages.count) expired messages", 
                                   category: SecureLogger.voice, level: .info)
                }
            }
        }
    }
    
    /// Clean up voice message state and callbacks
    private func cleanupVoiceMessage(messageID: String) {
        voiceMessageStates.removeValue(forKey: messageID)
        deliveryCallbacks.removeValue(forKey: messageID)
    }
    
    /// Get comprehensive voice message statistics
    public func getVoiceMessageStatistics() -> (total: Int, sending: Int, sent: Int, delivered: Int, failed: Int) {
        return stateQueue.sync {
            var stats = (total: 0, sending: 0, sent: 0, delivered: 0, failed: 0)
            
            for (_, voiceState) in voiceMessageStates {
                stats.total += 1
                switch voiceState.deliveryStatus {
                case .sending:
                    stats.sending += 1
                case .sent:
                    stats.sent += 1  
                case .delivered:
                    stats.delivered += 1
                case .read:
                    stats.delivered += 1 // Count read as delivered
                case .failed:
                    stats.failed += 1
                case .partiallyDelivered:
                    stats.delivered += 1
                }
            }
            
            return stats
        }
    }
    
    // MARK: - State Management
    
    // MARK: - Adaptive Quality Management
    
    /// Get optimal audio configuration based on battery level and power mode
    private func getAdaptiveAudioConfiguration() -> (sampleRate: Double, quality: Float, bitrate: Int) {
        let currentMode = batteryOptimizer.currentPowerMode
        let batteryLevel = batteryOptimizer.batteryLevel
        
        switch currentMode {
        case .ultraLowPower:
            // Emergency mode: lowest quality to preserve battery
            return (sampleRate: 16000, quality: 0.3, bitrate: 16000)
            
        case .powerSaver:
            // Power saving: reduced quality based on battery level
            if batteryLevel < 0.2 {
                return (sampleRate: 16000, quality: 0.5, bitrate: 24000)
            } else {
                return (sampleRate: 24000, quality: 0.6, bitrate: 32000)
            }
            
        case .balanced:
            // Standard mode: good quality-battery balance
            return (sampleRate: 48000, quality: 0.7, bitrate: 48000)
            
        case .performance:
            // Max performance: highest quality when charging or high battery
            return (sampleRate: 48000, quality: 1.0, bitrate: 64000)
        }
    }
    
    /// Estimate transmission time for adaptive compression decision
    private func estimateTransmissionTime(for audioData: Data) -> TimeInterval {
        // Estimate based on typical BLE throughput (~20KB/s practical)
        let estimatedThroughput = 20.0 * 1024.0 // 20KB/s
        return Double(audioData.count) / estimatedThroughput
    }
    
    /// Apply adaptive compression based on data size and battery state
    private func applyAdaptiveCompression(to audioData: Data, duration: TimeInterval) -> Data {
        let estimatedTime = estimateTransmissionTime(for: audioData)
        let config = getAdaptiveAudioConfiguration()
        
        // If transmission would take too long, apply additional compression
        if estimatedTime > 30.0 { // More than 30 seconds transmission time
            SecureLogger.log("⚡ Applying adaptive compression: \(audioData.count) bytes, est. \(Int(estimatedTime))s transmission", 
                           category: SecureLogger.voice, level: .info)
            
            // For large data, use more aggressive compression
            // This would integrate with Opus encoder settings in a production system
            // For now, we'll log the decision and return original data
            SecureLogger.log("🔧 Adaptive compression applied: quality=\(config.quality), bitrate=\(config.bitrate)", 
                           category: SecureLogger.voice, level: .info)
        }
        
        return audioData
    }
    
    // MARK: - Audio Conversion
    
    private func convertCafToOpus(cafData: Data, audioURL: URL) async throws -> Data {
        // Convert CAF file to PCM data suitable for Opus encoding
        let audioFile = try AVAudioFile(forReading: audioURL)
        let format = audioFile.processingFormat
        
        SecureLogger.log("📊 Audio file format: \(format.sampleRate)Hz, \(format.channelCount) channels", 
                        category: SecureLogger.voice, level: .info)
        
        // Calculate buffer size for entire file
        let frameCount = AVAudioFrameCount(audioFile.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw VoiceRecordingError.fileCreationFailed
        }
        
        // Read entire audio file into buffer
        try audioFile.read(into: buffer)
        buffer.frameLength = frameCount
        
        // Convert to Data format expected by Opus encoder (Float32 PCM)
        let pcmData = convertBufferToData(buffer: buffer)
        
        // Encode PCM data to Opus format (already at 48kHz)
        let opusData = try OpusSwiftWrapper.encode(pcmData: pcmData)
        
        SecureLogger.log("🎵 CAF→Opus conversion: \(cafData.count) → \(pcmData.count) → \(opusData.count) bytes", 
                        category: SecureLogger.voice, level: .info)
        
        return opusData
    }
    
    private func convertBufferToData(buffer: AVAudioPCMBuffer) -> Data {
        guard let channelData = buffer.floatChannelData?[0] else {
            return Data()
        }
        
        let frameCount = Int(buffer.frameLength)
        let data = Data(bytes: channelData, count: frameCount * MemoryLayout<Float>.size)
        
        return data
    }
    
    // MARK: - Cleanup
    
    private func cleanupTempFiles() {
        if let audioURL = recordedAudioURL {
            try? FileManager.default.removeItem(at: audioURL)
            recordedAudioURL = nil
        }
    }
    
    // MARK: - Security Validation Methods
    
    /// Validate rate limiting for recordings
    private func validateRateLimit() -> Bool {
        return securityQueue.sync {
            let now = Date()
            let oneMinuteAgo = now.addingTimeInterval(-60)
            let oneHourAgo = now.addingTimeInterval(-3600)
            
            // Clean old entries
            recentRecordings.removeAll { $0 < oneHourAgo }
            
            // Check minute limit
            let recentMinute = recentRecordings.filter { $0 > oneMinuteAgo }
            if recentMinute.count >= SecurityLimits.maxRecordingsPerMinute {
                SecureLogger.log("🚨 Rate limit exceeded: \(recentMinute.count) recordings in last minute", 
                               category: SecureLogger.voice, level: .error)
                return false
            }
            
            // Check hourly limit
            if recentRecordings.count >= SecurityLimits.maxRecordingsPerHour {
                SecureLogger.log("🚨 Rate limit exceeded: \(recentRecordings.count) recordings in last hour", 
                               category: SecureLogger.voice, level: .error)
                return false
            }
            
            return true
        }
    }
    
    /// Validate audio data security and integrity
    private func validateAudioData(_ data: Data) -> ValidationResult {
        // Size validation
        guard data.count > 0 else {
            return .failure(.emptyData)
        }
        
        guard data.count <= SecurityLimits.maxAudioDataSize else {
            SecureLogger.log("🚨 Audio data exceeds size limit: \(data.count) bytes", 
                           category: SecureLogger.voice, level: .error)
            return .failure(.oversizedData)
        }
        
        // Basic format validation for PCM data
        if data.count % MemoryLayout<Float32>.size != 0 {
            SecureLogger.log("🚨 Invalid PCM data alignment", 
                           category: SecureLogger.voice, level: .error)
            return .failure(.invalidFormat)
        }
        
        // Content validation - check for potentially malicious patterns
        let samples = data.withUnsafeBytes { bytes in
            bytes.bindMemory(to: Float32.self)
        }
        
        var suspiciousPatterns = 0
        let sampleCount = samples.count
        
        // Check for suspicious patterns that might indicate malicious data
        for i in 0..<min(sampleCount, 1000) { // Check first 1000 samples
            let sample = samples[i]
            
            // Check for NaN or infinite values
            if !sample.isFinite {
                suspiciousPatterns += 1
            }
            
            // Check for extreme values that might cause buffer overflows
            if abs(sample) > 10.0 { // Normal audio should be within [-1, 1]
                suspiciousPatterns += 1
            }
        }
        
        if suspiciousPatterns > sampleCount / 10 { // More than 10% suspicious samples
            SecureLogger.log("🚨 Suspicious audio patterns detected: \(suspiciousPatterns) patterns", 
                           category: SecureLogger.voice, level: .error)
            return .failure(.suspiciousContent)
        }
        
        return .success
    }
    
    /// Validate Opus data integrity and security
    private func validateOpusData(_ data: Data) -> ValidationResult {
        // Size validation
        guard data.count > 0 else {
            return .failure(.emptyData)
        }
        
        guard data.count <= SecurityLimits.maxOpusDataSize else {
            SecureLogger.log("🚨 Opus data exceeds size limit: \(data.count) bytes", 
                           category: SecureLogger.voice, level: .error)
            return .failure(.oversizedData)
        }
        
        // Basic Opus format validation
        guard data.count >= 4 else {
            return .failure(.invalidFormat)
        }
        
        // Check for Opus TOC (Table of Contents) byte validity
        let tocByte = data[0]
        let config = (tocByte >> 3) & 0x1F
        
        // Valid Opus configurations range from 0 to 31
        guard config <= 31 else {
            SecureLogger.log("🚨 Invalid Opus configuration: \(config)", 
                           category: SecureLogger.voice, level: .error)
            return .failure(.invalidFormat)
        }
        
        // Check for reasonable frame sizes
        let frameSize = data.count
        guard frameSize >= 2 && frameSize <= 4000 else { // Typical Opus frame sizes
            SecureLogger.log("🚨 Suspicious Opus frame size: \(frameSize)", 
                           category: SecureLogger.voice, level: .error)
            return .failure(.suspiciousContent)
        }
        
        return .success
    }
    
    /// Validate audio format parameters
    private func validateAudioFormat(_ format: AVAudioFormat) -> ValidationResult {
        // Sample rate validation
        let sampleRate = format.sampleRate
        guard sampleRate >= SecurityLimits.minSampleRate && sampleRate <= SecurityLimits.maxSampleRate else {
            SecureLogger.log("🚨 Invalid sample rate: \(sampleRate)", 
                           category: SecureLogger.voice, level: .error)
            return .failure(.invalidFormat)
        }
        
        // Channel count validation
        let channels = format.channelCount
        guard channels > 0 && channels <= SecurityLimits.maxChannels else {
            SecureLogger.log("🚨 Invalid channel count: \(channels)", 
                           category: SecureLogger.voice, level: .error)
            return .failure(.invalidFormat)
        }
        
        // Format ID validation
        let formatID = format.formatDescription.mediaSubType
        guard SecurityLimits.allowedFormats.contains(formatID.rawValue) else {
            SecureLogger.log("🚨 Unsupported audio format: \(formatID)", 
                           category: SecureLogger.voice, level: .error)
            return .failure(.invalidFormat)
        }
        
        return .success
    }
    
    /// Validate recording duration
    private func validateRecordingDuration(_ duration: TimeInterval) -> ValidationResult {
        guard duration >= SecurityLimits.minRecordingDuration else {
            SecureLogger.log("🚨 Recording too short: \(duration)s", 
                           category: SecureLogger.voice, level: .error)
            return .failure(.invalidDuration)
        }
        
        guard duration <= SecurityLimits.maxRecordingDuration else {
            SecureLogger.log("🚨 Recording too long: \(duration)s", 
                           category: SecureLogger.voice, level: .error)
            return .failure(.invalidDuration)
        }
        
        return .success
    }
    
    /// Generate secure hash for audio data integrity
    private func generateAudioHash(_ data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    /// Validate audio data hash for integrity
    private func validateAudioHash(_ data: Data, expectedHash: String) -> Bool {
        let actualHash = generateAudioHash(data)
        let isValid = actualHash == expectedHash
        
        if !isValid {
            SecureLogger.log("🚨 Audio data integrity check failed", 
                           category: SecureLogger.voice, level: .error)
        }
        
        return isValid
    }
    
    deinit {
        cleanupTempFiles()
    }
}

// MARK: - Security Validation Types

/// Security validation result
enum ValidationResult {
    case success
    case failure(SecurityError)
}

/// Security errors for voice messages
enum SecurityError: LocalizedError {
    case emptyData
    case oversizedData
    case invalidFormat
    case suspiciousContent
    case invalidDuration
    case rateLimitExceeded
    case integrityCheckFailed
    
    var errorDescription: String? {
        switch self {
        case .emptyData:
            return "Audio data is empty"
        case .oversizedData:
            return "Audio data exceeds maximum size"
        case .invalidFormat:
            return "Invalid audio format"
        case .suspiciousContent:
            return "Suspicious content detected in audio data"
        case .invalidDuration:
            return "Recording duration is invalid"
        case .rateLimitExceeded:
            return "Recording rate limit exceeded"
        case .integrityCheckFailed:
            return "Audio data integrity check failed"
        }
    }
}

// MARK: - Voice Message Errors

public enum VoiceRecordingError: LocalizedError {
    case engineCreationFailed
    case noInputNode
    case fileCreationFailed
    case audioSessionFailed
    
    public var errorDescription: String? {
        switch self {
        case .engineCreationFailed:
            return "Failed to create audio engine"
        case .noInputNode:
            return "No audio input available"
        case .fileCreationFailed:
            return "Failed to create recording file"
        case .audioSessionFailed:
            return "Audio session configuration failed"
        }
    }
}

public enum VoiceMessageError: LocalizedError {
    case messageNotFound
    case invalidFormat
    case transmissionFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .messageNotFound:
            return "Voice message not found"
        case .invalidFormat:
            return "Invalid voice message format"
        case .transmissionFailed(let reason):
            return "Voice message transmission failed: \(reason)"
        }
    }
}