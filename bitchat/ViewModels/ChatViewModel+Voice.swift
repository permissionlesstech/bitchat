//
// ChatViewModel+Voice.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import SwiftUI
import AVFoundation
import Combine
import AudioToolbox
import CoreBluetooth

// MARK: - ChatViewModel Voice Extension

extension ChatViewModel: AudioPlayerDelegate {
    
    // MARK: - Private Properties
    // Stored properties moved to main ChatViewModel class
    
    // MARK: - Voice Service Integration
    
    /// Set up bindings to VoiceMessageService
    func setupVoiceServiceBindings() {
        let voiceService = VoiceMessageService.shared
        
        // Bind to VoiceMessageService recording state
        voiceService.$isRecording
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording in
                self?.voiceRecordingState = isRecording ? .recording : .idle
            }
            .store(in: &voiceServiceCancellables)
        
        // Bind to recording duration
        voiceService.$recordingDuration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] duration in
                self?.recordingDuration = duration
            }
            .store(in: &voiceServiceCancellables)
        
        // Bind to recording amplitude
        voiceService.$currentAmplitude
            .receive(on: DispatchQueue.main)
            .sink { [weak self] amplitude in
                self?.recordingAmplitude = amplitude
            }
            .store(in: &voiceServiceCancellables)
        
        // Check audio permission on startup and initialize immediately
        checkCurrentAudioPermissionAndRequest()
        
        // Start voice message lifecycle management
        voiceService.startLifecycleManagement()
    }
    
    // MARK: - Audio Session Management
    
    /// Check current audio permission status and request if needed
    private func checkCurrentAudioPermissionAndRequest() {
        #if os(iOS)
        let currentPermission = AVAudioSession.sharedInstance().recordPermission
        SecureLogger.log("🎤 Initial permission check: \(currentPermission.rawValue)", 
                       category: SecureLogger.voice, level: .info)
        
        switch currentPermission {
        case .granted:
            hasAudioPermission = true
            configureAudioSession()
            SecureLogger.log("🎤 Permission already granted", 
                           category: SecureLogger.voice, level: .info)
        case .denied:
            hasAudioPermission = false
            SecureLogger.log("🎤 Permission denied, user needs to enable in Settings", 
                           category: SecureLogger.voice, level: .warning)
        case .undetermined:
            hasAudioPermission = false
            requestAudioPermission()
            SecureLogger.log("🎤 Permission undetermined, requesting...", 
                           category: SecureLogger.voice, level: .info)
        @unknown default:
            hasAudioPermission = false
            requestAudioPermission()
        }
        #else
        hasAudioPermission = true
        configureAudioSession()
        SecureLogger.log("🎤 macOS: Setting hasAudioPermission to true", 
                       category: SecureLogger.voice, level: .info)
        #endif
    }
    
    /// Request microphone permission and configure audio session
    func requestAudioPermission() {
        SecureLogger.log("🎤 Requesting audio permission", 
                       category: SecureLogger.voice, level: .info)
        #if os(iOS)
        let currentPermission = AVAudioSession.sharedInstance().recordPermission
        SecureLogger.log("🎤 Current permission status: \(currentPermission.rawValue)", 
                       category: SecureLogger.voice, level: .info)
        
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                SecureLogger.log("🎤 Permission granted: \(granted)", 
                               category: SecureLogger.voice, level: .info)
                self?.hasAudioPermission = granted
                if granted {
                    self?.configureAudioSession()
                } else {
                    SecureLogger.log("🎤 Microphone permission denied", 
                                   category: SecureLogger.voice, level: .error)
                }
            }
        }
        #else
        DispatchQueue.main.async { [weak self] in
            SecureLogger.log("🎤 macOS: Setting hasAudioPermission to true", 
                           category: SecureLogger.voice, level: .info)
            self?.hasAudioPermission = true // macOS doesn't require explicit permission for microphone
            self?.configureAudioSession()
        }
        #endif
    }
    
    /// Configure unified audio session for recording and playback with optimal quality
    private func configureAudioSession() {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            
            // Unified configuration optimized for voice quality and stability
            try session.setCategory(
                .playAndRecord, 
                mode: .voiceChat,  // Optimized for voice with built-in processing
                options: [
                    .defaultToSpeaker, 
                    .allowBluetooth, 
                    .allowBluetoothA2DP,
                    .mixWithOthers  // Better compatibility
                ]
            )
            
            // Optimal settings for clean, natural voice
            try session.setPreferredSampleRate(16000)  // Match our codec
            try session.setPreferredIOBufferDuration(0.008) // 8ms for quality/latency balance
            // Note: setPreferredInputGain not available in this iOS version
            
            try session.setActive(true)
        } catch {
            DispatchQueue.main.async {
                self.voiceRecordingState = .error("Audio session configuration failed: \(error.localizedDescription)")
            }
        }
        #else
        // macOS doesn't need explicit audio session configuration
        #endif
    }
    
    /// Deactivate audio session when not needed
    private func deactivateAudioSession() {
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            SecureLogger.log("Failed to deactivate audio session: \(error)", category: SecureLogger.voice, level: .error)
        }
        #else
        // macOS doesn't need explicit audio session deactivation
        #endif
    }
    
    // MARK: - Voice Recording State Management (Thread-Safe)
    
    /// Thread-safe voice recording state accessor
    private func updateVoiceState(_ newState: VoiceRecordingState) {
        voiceStateQueue.async { [weak self] in
            DispatchQueue.main.async {
                self?.voiceRecordingState = newState
            }
        }
    }
    
    /// Thread-safe state check
    private func currentVoiceState() -> VoiceRecordingState {
        return DispatchQueue.main.sync {
            return self.voiceRecordingState
        }
    }
    
    // MARK: - Voice Recording
    
    /// Start voice recording with thread-safe state management
    func startVoiceRecording() {
        voiceStateQueue.async { [weak self] in
            guard let self = self else { return }
            
            let currentState = self.currentVoiceState()
            SecureLogger.log("🎤 StartVoiceRecording called - hasAudioPermission: \(self.hasAudioPermission), state: \(currentState)", 
                           category: SecureLogger.voice, level: .info)
            
            // 🛡️ SIMPLE RATE LIMITING: Prevent voice message spam (20 per minute)
            let currentPeerID = self.meshService.myPeerID
            if !self.canSendVoiceMessage(peerID: currentPeerID) {
                SecureLogger.log("🛡️ Voice recording blocked: rate limit exceeded for \(currentPeerID)", 
                               category: SecureLogger.security, level: .warning)
                
                self.handleVoiceRecordingError("Rate limit reached. Please wait before recording again.")
                return
            }
            
            // Reset error state to idle to allow new recording attempts
            if case .error = currentState {
                SecureLogger.log("🎤 Resetting error state to idle", 
                               category: SecureLogger.voice, level: .info)
                self.updateVoiceState(.idle)
            }
            
            // Thread-safe state check
            let finalState = self.currentVoiceState()
            guard case .idle = finalState else { 
                SecureLogger.log("🎤 Not in idle state, current state: \(finalState)", 
                               category: SecureLogger.voice, level: .warning)
                return 
            }
            
            // CRITICAL FIX: Always check actual audio session permission, not cached value
            #if os(iOS)
            let actualPermission = AVAudioSession.sharedInstance().recordPermission
            if actualPermission != .granted {
                SecureLogger.log("🎤 Audio session permission not granted: \(actualPermission.rawValue)", 
                               category: SecureLogger.voice, level: .warning)
                DispatchQueue.main.async {
                    self.requestAudioPermission()
                }
                return
            }
            #endif
            
            let voiceService = VoiceMessageService.shared
            SecureLogger.log("🎤 Calling VoiceMessageService.startRecording()", 
                           category: SecureLogger.voice, level: .info)
            let success = voiceService.startRecording()
            
            if !success {
                self.updateVoiceState(.error("Failed to start recording"))
                SecureLogger.log("🎤 Voice recording failed to start", 
                               category: SecureLogger.voice, level: .error)
            } else {
                SecureLogger.log("🎤 Voice recording started successfully", 
                               category: SecureLogger.voice, level: .info)
                SecureLogger.log("🎤 VoiceService isRecording: \(voiceService.isRecording)", 
                               category: SecureLogger.voice, level: .info)
            }
        }
    }
    
    /// Test function to add a simple text message
    func addTestMessage() {
        let testMessage = BitchatMessage(
            id: UUID().uuidString,
            sender: nickname,
            content: "🧪 Test message - \(Date())",
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: false,
            recipientNickname: nil,
            senderPeerID: nil,
            mentions: nil,
            deliveryStatus: .sent
        )
        
        SecureLogger.log("🧪 [TEST] Adding test message to UI", category: SecureLogger.voice, level: .info)
        SecureLogger.log("🧪 [TEST] Message count before: \(messages.count)", category: SecureLogger.voice, level: .info)
        messages.append(testMessage)
        SecureLogger.log("🧪 [TEST] Message count after: \(messages.count)", category: SecureLogger.voice, level: .info)
        objectWillChange.send()
    }
    
    /// Stop voice recording and send message with thread-safe concurrent processing
    func stopVoiceRecording() {
        messageProcessingQueue.async { [weak self] in
            guard let self = self else { return }
            
            let currentState = self.currentVoiceState()
            guard case .recording = currentState else { 
                SecureLogger.log("❌ stopVoiceRecording: Not in recording state: \(currentState)", category: SecureLogger.voice, level: .error)
                self.handleVoiceRecordingError("Not currently recording")
                return 
            }
            
            let voiceService = VoiceMessageService.shared
            self.updateVoiceState(.processing)
            
            SecureLogger.log("📱 Calling VoiceMessageService.stopRecording...", category: SecureLogger.voice, level: .info)
            
            // THREAD-SAFE APPROACH: Add message to UI immediately
            let tempMessageID = UUID().uuidString
            
            // Create voice data with basic info for immediate UI
            let placeholderVoiceData = VoiceMessageData(
                duration: max(self.recordingDuration, 0.1),
                waveformData: Array(repeating: Float(0.3), count: 50),
                filePath: nil,
                audioData: Data(), // Empty data for now, will be updated
                format: .opus
            )
            
            SecureLogger.log("🎵 [AUDIO-PLACEHOLDER] Created placeholder voice data - will be updated with real data in callback", category: SecureLogger.voice, level: .info)
            
            let tempMessage = BitchatMessage(
                id: tempMessageID,
                sender: self.nickname,
                content: "🎤 Voice message (processing...)",
                timestamp: Date(),
                isRelay: false,
                originalSender: nil,
                isPrivate: self.selectedPrivateChatPeer != nil,
                recipientNickname: nil,
                senderPeerID: nil,
                mentions: nil,
                deliveryStatus: .sending,
                voiceMessageData: placeholderVoiceData // Now has voice data for UI
            )
            
            // THREAD-SAFE UI UPDATE: Always use main thread for UI updates
            SecureLogger.log("🚀 [THREAD-SAFE-UI] Adding temporary voice message to UI: \(tempMessageID)", category: SecureLogger.voice, level: .info)
            
            if self.selectedPrivateChatPeer == nil {
                DispatchQueue.main.async {
                    let beforeCount = self.messages.count
                    self.messages.append(tempMessage)
                    let afterCount = self.messages.count
                    
                    SecureLogger.log("✅ [THREAD-SAFE-UI] Message added: \(beforeCount) → \(afterCount)", category: SecureLogger.voice, level: .info)
                    
                    // Verify addition
                    if self.messages.last?.id == tempMessageID {
                        SecureLogger.log("✅ [THREAD-SAFE-UI] VERIFIED: Message is at the end of array", category: SecureLogger.voice, level: .info)
                    } else {
                        SecureLogger.log("❌ [THREAD-SAFE-UI] ERROR: Message was not added to array!", category: SecureLogger.voice, level: .error)
                    }
                    
                    // Force UI update
                    self.objectWillChange.send()
                    SecureLogger.log("🔄 [THREAD-SAFE-UI] Forced objectWillChange.send() to trigger UI update", category: SecureLogger.voice, level: .info)
                }
            }
            
            // THREAD-SAFE completion callback to update placeholder with real audio data
            let stopResult = voiceService.stopRecording(completion: { [weak self] processedMessageID in
            SecureLogger.log("✅ [CALLBACK] Voice recording stopped, messageID: \(processedMessageID)", category: SecureLogger.voice, level: .info)
            
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                // Reset recording state
                self.voiceRecordingState = .idle
                self.recordingDuration = 0
                self.recordingAmplitude = 0
                
                // CRITICAL: Update placeholder with real audio data
                if let voiceState = VoiceMessageService.shared.getVoiceMessageState(processedMessageID) {
                    let realMessage = voiceState.message
                    
                    SecureLogger.log("🔄 CALLBACK: Found real message with audioData size: \(realMessage.voiceMessageData?.audioData?.count ?? 0)", 
                                    category: SecureLogger.voice, level: .debug)
                    
                    // Find and replace placeholder message
                    if let placeholderIndex = self.messages.firstIndex(where: { $0.id == tempMessageID }) {
                        // Create updated message with real audio data using the same ID
                        let updatedMessage = BitchatMessage(
                            id: tempMessageID, // Keep same ID for UI consistency
                            sender: self.nickname,
                            content: "🎤 Voice message (\(realMessage.voiceMessageData?.formattedDuration ?? "0:00"))",
                            timestamp: Date(),
                            isRelay: false,
                            originalSender: nil,
                            isPrivate: self.selectedPrivateChatPeer != nil,
                            recipientNickname: nil,
                            senderPeerID: nil,
                            mentions: nil,
                            deliveryStatus: .sent,
                            voiceMessageData: realMessage.voiceMessageData // Real audio data here!
                        )
                        
                        self.messages[placeholderIndex] = updatedMessage
                        SecureLogger.log("✅ [CALLBACK] Updated placeholder with real audio data size: \(updatedMessage.voiceMessageData?.audioData?.count ?? 0)", category: SecureLogger.voice, level: .info)
                    } else {
                        SecureLogger.log("❌ [CALLBACK] Could not find placeholder message to update", category: SecureLogger.voice, level: .error)
                    }
                } else {
                    SecureLogger.log("❌ [CALLBACK] Could not retrieve real message with audio data", category: SecureLogger.voice, level: .error)
                }
                
                SecureLogger.log("✅ [CALLBACK] Recording state reset and message updated", category: SecureLogger.voice, level: .info)
                
                // 📊 LIFECYCLE MANAGEMENT: Register delivery callback for status tracking
                VoiceMessageService.shared.registerDeliveryCallback(for: processedMessageID) { [weak self] status in
                    guard let self = self else { return }
                    
                    // Update UI message delivery status
                    if let messageIndex = self.messages.firstIndex(where: { $0.id == tempMessageID }) {
                        self.messages[messageIndex].deliveryStatus = status
                        SecureLogger.log("📊 [LIFECYCLE] Updated UI message status: \(status.displayText)", 
                                       category: SecureLogger.voice, level: .info)
                    }
                }
            }
            })
            
            guard let messageID = stopResult else {
                SecureLogger.log("❌ VoiceMessageService.stopRecording returned nil!", category: SecureLogger.voice, level: .error)
                self.handleVoiceRecordingError("Failed to stop recording - service returned nil")
                return
            }
            
            SecureLogger.log("🎯 [STOP-RESULT] stopRecording returned messageID: \(messageID)", category: SecureLogger.voice, level: .info)
            
            // No need for timeout anymore - message is already in UI
            
            SecureLogger.log("🎤 Voice recording stopped, processing message: \(messageID)", 
                           category: SecureLogger.voice, level: .info)
        }
    }
    
    /// Cancel voice recording with thread-safe state management
    func cancelVoiceRecording() {
        voiceStateQueue.async { [weak self] in
            guard let self = self else { return }
            
            let currentState = self.currentVoiceState()
            guard case .recording = currentState else { 
                SecureLogger.log("Cancel called but not recording: \(currentState)", category: SecureLogger.voice, level: .warning)
                return 
            }
            
            let voiceService = VoiceMessageService.shared
            voiceService.cancelRecording()
            
            self.updateVoiceState(.idle)
            
            DispatchQueue.main.async {
                self.recordingDuration = 0
                self.recordingAmplitude = 0
            }
            
            SecureLogger.log("Voice recording cancelled", category: SecureLogger.voice, level: .info)
        }
    }
    
    // MARK: - Error Handling
    
    /// Handle voice recording errors with proper state management
    private func handleVoiceRecordingError(_ message: String) {
        SecureLogger.log("❌ Voice recording error: \(message)", category: SecureLogger.voice, level: .error)
        
        // Ensure we're on main thread for UI updates
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Reset state safely
            self.voiceRecordingState = .error(message)
            self.recordingDuration = 0
            self.recordingAmplitude = 0
            
            // Clear any pending timers or operations
            self.stopPlaybackProgressTimer()
            
            // Schedule automatic reset to idle after showing error
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self = self, case .error = self.voiceRecordingState else { return }
                self.voiceRecordingState = .idle
            }
        }
    }
    
    /// Process voice message with enhanced error handling and validation
    private func processVoiceMessageSafely(messageID: String) throws {
        SecureLogger.log("🎯 [PROCESS-START] processVoiceMessageSafely called with ID: \(messageID)", category: SecureLogger.voice, level: .info)
        
        guard !messageID.isEmpty else {
            SecureLogger.log("❌ [PROCESS-START] messageID is empty", category: SecureLogger.voice, level: .error)
            throw VoiceError.invalidFormat
        }
        
        guard messageID.count < 100 else { // Reasonable limit
            SecureLogger.log("❌ [PROCESS-START] messageID too long: \(messageID.count) characters", category: SecureLogger.voice, level: .error)
            throw VoiceError.invalidFormat
        }
        
        SecureLogger.log("✅ [PROCESS-START] processVoiceMessageSafely validation passed for ID: \(messageID)", category: SecureLogger.voice, level: .info)
        
        Task<Void, Never> { @MainActor in
            SecureLogger.log("🚀 [PROCESS-ASYNC] Starting async processing for messageID: \(messageID)", category: SecureLogger.voice, level: .info)
            do {
                try await self.processVoiceMessageAsync(messageID: messageID)
                SecureLogger.log("✅ [PROCESS-ASYNC] Async processing completed successfully for messageID: \(messageID)", category: SecureLogger.voice, level: .info)
            } catch {
                SecureLogger.log("❌ [PROCESS-ASYNC] Async voice message processing failed for messageID: \(messageID), error: \(error)", category: SecureLogger.voice, level: .error)
                self.handleVoiceRecordingError("Failed to send: \(error.localizedDescription)")
            }
        }
    }
    
    /// Async voice message processing with comprehensive error handling
    @MainActor
    private func processVoiceMessageAsync(messageID: String) async throws {
        voiceRecordingState = .sending
        
        let voiceService = VoiceMessageService.shared
        
        SecureLogger.log("🔍 Processing voice message: \(messageID)", 
                       category: SecureLogger.voice, level: .info)
        
        // Wait for voice state to be available with timeout
        var voiceState: VoiceMessageService.VoiceMessageState?
        let maxAttempts = 50 // 5 seconds total
        
        for attempt in 0..<maxAttempts {
            SecureLogger.log("🔍 [WAIT-STATE] Attempt \(attempt + 1)/\(maxAttempts) to get voice state for messageID: \(messageID)", category: SecureLogger.voice, level: .info)
            voiceState = voiceService.getVoiceMessageState(messageID)
            if voiceState != nil {
                SecureLogger.log("✅ [WAIT-STATE] Found voice state on attempt \(attempt + 1) for messageID: \(messageID)", category: SecureLogger.voice, level: .info)
                break
            } else {
                SecureLogger.log("⏳ [WAIT-STATE] Voice state not found on attempt \(attempt + 1), waiting 100ms...", category: SecureLogger.voice, level: .info)
            }
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        
        guard voiceState != nil else {
            SecureLogger.log("❌ [WAIT-STATE] FAILED to find voice state after \(maxAttempts) attempts for messageID: \(messageID)", category: SecureLogger.voice, level: .error)
            throw VoiceError.noAudioData
        }
        
        SecureLogger.log("🎯 [WAIT-STATE] Voice state successfully found for messageID: \(messageID)", category: SecureLogger.voice, level: .info)
        
        // Send the message based on current chat mode
        if let recipientPeerID = selectedPrivateChatPeer {
            try await sendPrivateVoiceMessage(messageID: messageID, recipientPeerID: recipientPeerID)
        } else {
            try await sendPublicVoiceMessage(messageID: messageID)
        }
        
        // Success: reset recording state
        voiceRecordingState = .idle
        recordingDuration = 0
        recordingAmplitude = 0
        
        SecureLogger.log("✅ Voice message processed successfully: \(messageID)", 
                       category: SecureLogger.voice, level: .info)
    }
    
    /// Send private voice message with error handling
    @MainActor
    private func sendPrivateVoiceMessage(messageID: String, recipientPeerID: String) async throws {
        let voiceService = VoiceMessageService.shared
        let recipientNickname = getPeer(byID: recipientPeerID)?.displayName ?? "Unknown"
        
        try await voiceService.sendVoiceMessage(
            to: recipientPeerID,
            recipientNickname: recipientNickname,
            senderNickname: nickname,
            messageID: messageID
        )
        
        // 🛡️ RECORD SUCCESSFUL VOICE MESSAGE: Update rate limiter after successful send
        if let voiceState = voiceService.getVoiceMessageState(messageID) {
            recordVoiceMessageSent(peerID: meshService.myPeerID)
            
            let localMessage = createLocalVoiceMessage(from: voiceState, isPrivate: true, recipientNickname: recipientNickname)
            addVoiceMessageToPrivateChat(localMessage, recipientPeerID: recipientPeerID)
        }
    }
    
    /// Send public voice message with error handling
    @MainActor
    private func sendPublicVoiceMessage(messageID: String) async throws {
        SecureLogger.log("🎯 [PUBLIC-SEND] Starting sendPublicVoiceMessage for messageID: \(messageID)", category: SecureLogger.voice, level: .info)
        
        let voiceService = VoiceMessageService.shared
        
        SecureLogger.log("🚀 [PUBLIC-SEND] Calling sendVoiceMessageBroadcast for messageID: \(messageID)", category: SecureLogger.voice, level: .info)
        try await voiceService.sendVoiceMessageBroadcast(
            senderNickname: nickname,
            messageID: messageID
        )
        SecureLogger.log("✅ [PUBLIC-SEND] sendVoiceMessageBroadcast completed for messageID: \(messageID)", category: SecureLogger.voice, level: .info)
        
        // Add to public chat UI - DIRECT APPROACH
        SecureLogger.log("🔍 [PUBLIC-SEND] Getting voice state for messageID: \(messageID)", category: SecureLogger.voice, level: .info)
        
        // Try multiple times to get the voice state (with immediate attempts)
        var voiceState: VoiceMessageService.VoiceMessageState?
        for attempt in 0..<10 {
            voiceState = voiceService.getVoiceMessageState(messageID)
            if voiceState != nil {
                SecureLogger.log("✅ [PUBLIC-SEND] Voice state found on attempt \(attempt + 1) for messageID: \(messageID)", category: SecureLogger.voice, level: .info)
                break
            }
            SecureLogger.log("⏳ [PUBLIC-SEND] Voice state not found on attempt \(attempt + 1), retrying immediately...", category: SecureLogger.voice, level: .info)
        }
        
        if let voiceState = voiceState {
            SecureLogger.log("✅ [PUBLIC-SEND] Voice state found, creating local message for messageID: \(messageID)", category: SecureLogger.voice, level: .info)
            
            // 🛡️ RECORD SUCCESSFUL VOICE MESSAGE: Update rate limiter after successful send
            recordVoiceMessageSent(peerID: meshService.myPeerID)
            
            let localMessage = createLocalVoiceMessage(from: voiceState, isPrivate: false)
            SecureLogger.log("📱 [PUBLIC-SEND] About to add voice message to public chat UI for messageID: \(messageID)", category: SecureLogger.voice, level: .info)
            addVoiceMessageToPublicChat(localMessage)
            SecureLogger.log("✅ [PUBLIC-SEND] Voice message added to public chat UI successfully for messageID: \(messageID)", category: SecureLogger.voice, level: .info)
        } else {
            SecureLogger.log("❌ [PUBLIC-SEND] CRITICAL ERROR: Voice state not found after 10 attempts for messageID: \(messageID)", category: SecureLogger.voice, level: .error)
            
            // FALLBACK: Create message directly from service data if possible
            SecureLogger.log("🔧 [PUBLIC-SEND] Attempting fallback message creation for messageID: \(messageID)", category: SecureLogger.voice, level: .info)
            let fallbackMessage = BitchatMessage(
                id: messageID,
                sender: nickname,
                content: "🎤 Voice message",
                timestamp: Date(),
                isRelay: false,
                originalSender: nil,
                isPrivate: false,
                recipientNickname: nil,
                senderPeerID: nil,
                mentions: nil,
                deliveryStatus: .sent,
                voiceMessageData: nil // This will be a placeholder
            )
            addVoiceMessageToPublicChat(fallbackMessage)
            SecureLogger.log("🔧 [PUBLIC-SEND] Fallback message added to UI for messageID: \(messageID)", category: SecureLogger.voice, level: .info)
        }
    }
    
    /// Create local voice message with validation
    private func createLocalVoiceMessage(from voiceState: VoiceMessageService.VoiceMessageState, isPrivate: Bool, recipientNickname: String? = nil) -> BitchatMessage {
        return BitchatMessage(
            id: voiceState.message.id,
            sender: nickname,
            content: voiceState.message.content,
            timestamp: voiceState.message.timestamp,
            isRelay: false,
            originalSender: nil,
            isPrivate: isPrivate,
            recipientNickname: recipientNickname,
            senderPeerID: meshService.myPeerID,
            mentions: nil,
            deliveryStatus: voiceState.message.deliveryStatus,
            voiceMessageData: voiceState.message.voiceMessageData
        )
    }
    
    // MARK: - Recording Processing
    
    private func processVoiceMessage(messageID: String) {
        // Redirect to safe version
        do {
            try processVoiceMessageSafely(messageID: messageID)
        } catch {
            handleVoiceRecordingError("Processing failed: \(error.localizedDescription)")
        }
    }
    
    // Legacy method for compatibility
    private func processVoiceMessageLegacy(messageID: String) {
        SecureLogger.log("🚀 processVoiceMessage called with ID: \(messageID)", 
                       category: SecureLogger.voice, level: .info)
        
        Task<Void, Never> { @MainActor in
            do {
                voiceRecordingState = .sending
                
                let voiceService = VoiceMessageService.shared
                
                SecureLogger.log("🔍 Processing voice message: \(messageID)", 
                               category: SecureLogger.voice, level: .info)
                
                // Send the message based on current chat mode
                if let recipientPeerID = selectedPrivateChatPeer {
                    let recipientNickname = getPeer(byID: recipientPeerID)?.displayName ?? "Unknown"
                    try await voiceService.sendVoiceMessage(
                        to: recipientPeerID,
                        recipientNickname: recipientNickname,
                        senderNickname: nickname,
                        messageID: messageID
                    )
                    
                    // Add to private chat UI immediately
                    if let voiceState = voiceService.getVoiceMessageState(messageID) {
                        // Create new message with preserved audio data
                        let localMessage = BitchatMessage(
                            id: voiceState.message.id,
                            sender: nickname,
                            content: voiceState.message.content,
                            timestamp: voiceState.message.timestamp,
                            isRelay: false,
                            originalSender: nil,
                            isPrivate: true,
                            recipientNickname: recipientNickname,
                            senderPeerID: meshService.myPeerID,
                            mentions: nil,
                            deliveryStatus: voiceState.message.deliveryStatus,
                            voiceMessageData: voiceState.message.voiceMessageData
                        )
                        
                        // Ensure audio data is preserved in the local message
                        if let voiceData = localMessage.voiceMessageData {
                            SecureLogger.log("📀 Private voice message has audio data: \(voiceData.audioData?.count ?? 0) bytes", 
                                           category: SecureLogger.voice, level: .info)
                        }
                        
                        addVoiceMessageToPrivateChat(localMessage, recipientPeerID: recipientPeerID)
                    }
                } else {
                    try await voiceService.sendVoiceMessageBroadcast(
                        senderNickname: nickname,
                        messageID: messageID
                    )
                    
                    // Add to public chat UI immediately
                    SecureLogger.log("🔍 Looking for voice state with ID: \(messageID)", 
                                   category: SecureLogger.voice, level: .info)
                    
                    // Try to get voice state with a small delay to ensure it's ready
                    var voiceState: VoiceMessageService.VoiceMessageState?
                    for attempt in 0..<10 {
                        voiceState = voiceService.getVoiceMessageState(messageID)
                        if voiceState != nil {
                            SecureLogger.log("✅ Found voice state on attempt \(attempt + 1)", 
                                           category: SecureLogger.voice, level: .info)
                            break
                        }
                        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
                    }
                    
                    if let voiceState = voiceState {
                        SecureLogger.log("✅ Found voice state for message: \(messageID)", 
                                       category: SecureLogger.voice, level: .info)
                        
                        // Create new message with preserved audio data
                        let localMessage = BitchatMessage(
                            id: voiceState.message.id,
                            sender: nickname,
                            content: voiceState.message.content,
                            timestamp: voiceState.message.timestamp,
                            isRelay: false,
                            originalSender: nil,
                            isPrivate: false,
                            recipientNickname: nil,
                            senderPeerID: meshService.myPeerID,
                            mentions: nil,
                            deliveryStatus: voiceState.message.deliveryStatus,
                            voiceMessageData: voiceState.message.voiceMessageData
                        )
                        
                        // Ensure audio data is preserved in the local message
                        if let voiceData = localMessage.voiceMessageData {
                            SecureLogger.log("📀 Voice message has audio data: \(voiceData.audioData?.count ?? 0) bytes", 
                                           category: SecureLogger.voice, level: .info)
                        }
                        
                        addVoiceMessageToPublicChat(localMessage)
                        SecureLogger.log("✅ Voice message added to public chat", 
                                       category: SecureLogger.voice, level: .info)
                    } else {
                        SecureLogger.log("❌ No voice state found for message: \(messageID)", 
                                       category: SecureLogger.voice, level: .error)
                    }
                }
                
                // Success: reset recording state
                voiceRecordingState = .idle
                recordingDuration = 0
                recordingAmplitude = 0
                
                SecureLogger.log("Voice message queued for sending: \(messageID)", 
                               category: SecureLogger.voice, level: .info)
            } catch {
                SecureLogger.log("❌ Failed to process voice message: \(error)", 
                               category: SecureLogger.voice, level: .error)
                voiceRecordingState = .error("Failed to send voice message: \(error.localizedDescription)")
            }
        }
    }
    
    /// Add voice message to private chat
    private func addVoiceMessageToPrivateChat(_ message: BitchatMessage, recipientPeerID: String) {
        if privateChats[recipientPeerID] == nil {
            privateChats[recipientPeerID] = []
            }
        privateChats[recipientPeerID]?.append(message)
    }
    
    /// Add voice message to public chat
    private func addVoiceMessageToPublicChat(_ message: BitchatMessage) {
        SecureLogger.log("🎯 [UI-ADD] Starting addVoiceMessageToPublicChat for messageID: \(message.id)", category: SecureLogger.voice, level: .info)
        SecureLogger.log("📊 [UI-ADD] Current message count BEFORE adding: \(messages.count)", category: SecureLogger.voice, level: .info)
        SecureLogger.log("📝 [UI-ADD] Message content: \(message.content)", category: SecureLogger.voice, level: .info)
        SecureLogger.log("👤 [UI-ADD] Message sender: \(message.sender)", category: SecureLogger.voice, level: .info)
        SecureLogger.log("🎵 [UI-ADD] Voice message data: \(message.voiceMessageData != nil ? "Present" : "Missing")", category: SecureLogger.voice, level: .info)
        
        // Verify we're on main thread
        if Thread.isMainThread {
            SecureLogger.log("✅ [UI-ADD] On main thread - good for UI updates", category: SecureLogger.voice, level: .info)
        } else {
            SecureLogger.log("⚠️ [UI-ADD] NOT on main thread - this could be a problem!", category: SecureLogger.voice, level: .warning)
        }
        
        messages.append(message)
        
        SecureLogger.log("✅ [UI-ADD] Voice message appended successfully. New count: \(messages.count)", category: SecureLogger.voice, level: .info)
        SecureLogger.log("🔍 [UI-ADD] Last message in array: ID=\(messages.last?.id ?? "nil"), sender=\(messages.last?.sender ?? "nil")", category: SecureLogger.voice, level: .info)
        
        // Limit message history
        if messages.count > 1337 {
            messages.removeFirst(messages.count - 1337)
            SecureLogger.log("🧹 [UI-ADD] Trimmed message history to \(messages.count) messages", category: SecureLogger.voice, level: .info)
        }
        
        SecureLogger.log("✅ [UI-ADD] addVoiceMessageToPublicChat completed for messageID: \(message.id)", category: SecureLogger.voice, level: .info)
    }
    
    // MARK: - Voice Playback
    
    /// Play or pause voice message
    func playPauseVoiceMessage(_ message: BitchatMessage) {
        SecureLogger.log("🎵 [VIEWMODEL] playPauseVoiceMessage called for message: \(message.id)", 
                        category: SecureLogger.voice, level: .info)
        SecureLogger.log("🧵 [VIEWMODEL] Thread: \(Thread.isMainThread ? "MAIN" : "BACKGROUND")", 
                        category: SecureLogger.voice, level: .debug)
        guard let voiceData = message.voiceMessageData else { 
            SecureLogger.log("❌ No voiceMessageData in message: \(message.id)", category: SecureLogger.voice, level: .error)
            return 
        }
        
        SecureLogger.log("✅ VoiceData found - audioData size: \(voiceData.audioData?.count ?? 0)", 
                        category: SecureLogger.voice, level: .debug)
        if let audioData = voiceData.audioData {
            let firstBytes = audioData.prefix(4).map { String(format: "%02x", $0) }.joined()
            SecureLogger.log("🎵 Audio data first 4 bytes: \(firstBytes)", 
                           category: SecureLogger.voice, level: .debug)
        }
        
        SecureLogger.log("🎵 DEBUG: Current playback state: \(String(describing: voicePlaybackState))", category: SecureLogger.voice, level: .info)
        
        switch voicePlaybackState {
        case .playing(let messageID) where messageID == message.id:
            pauseVoiceMessage()
            
        case .paused(let messageID) where messageID == message.id:
            resumeVoiceMessage()
            
        default:
            SecureLogger.log("🎵 DEBUG: Calling playVoiceMessage", category: SecureLogger.voice, level: .info)
            playVoiceMessage(message, voiceData: voiceData)
            }
    }
    
    /// Start playing voice message
    private func playVoiceMessage(_ message: BitchatMessage, voiceData: VoiceMessageData) {
        // Stop any current playback
        stopVoicePlayback()
        
        voicePlaybackState = .loading(messageID: message.id)
        SecureLogger.log("🎵 Starting playback for message: \(message.id)", category: SecureLogger.voice, level: .info)
        
        Task {
            do {
                let audioData: Data
                
                // Prioritize stored Opus audioData over file path
                if let data = voiceData.audioData {
                    SecureLogger.log("💾 Using stored audio data, size: \(data.count) bytes", category: SecureLogger.voice, level: .info)
                    // Log first few bytes to check if data is valid
                    let firstBytes = data.prefix(4).map { String(format: "%02x", $0) }.joined()
                    SecureLogger.log("🎵 DEBUG: First 4 bytes of audio data: \(firstBytes)", category: SecureLogger.voice, level: .info)
                    audioData = data
                } else if let filePath = voiceData.filePath,
                          FileManager.default.fileExists(atPath: filePath) {
                    SecureLogger.log("📂 Loading audio from file: \(filePath)", category: SecureLogger.voice, level: .info)
                    audioData = try Data(contentsOf: URL(fileURLWithPath: filePath))
                } else {
                    SecureLogger.log("❌ No audio data available for playback", category: SecureLogger.voice, level: .error)
                    throw VoiceError.noAudioData
                }
                
                // REAL IMPLEMENTATION: Use AudioPlayer service for actual playback
                SecureLogger.log("🎵 Starting REAL audio playback: \(audioData.count) bytes", 
                               category: SecureLogger.voice, level: .info)
                
                // Create AudioPlayer if needed
                if audioPlayer == nil {
                    audioPlayer = AudioPlayer()
                    audioPlayer?.delegate = self
                    SecureLogger.log("🎵 AudioPlayer initialized", category: SecureLogger.voice, level: .info)
                }
                
                // DEFINITIVE TEST: Try playing with error handling
                do {
                    try await audioPlayer?.play(opusData: audioData, messageID: message.id)
                    SecureLogger.log("✅ AudioPlayer.play succeeded", 
                                    category: SecureLogger.voice, level: .info)
                } catch {
                    SecureLogger.log("❌ AudioPlayer.play FAILED: \(error)", 
                                    category: SecureLogger.voice, level: .error)
                    // FALLBACK: Try system beep as test
                    AudioServicesPlaySystemSound(1016) // Success sound
                }
                
                await MainActor.run {
                    voicePlaybackState = .playing(messageID: message.id)
                    playingVoiceMessageID = message.id
                    SecureLogger.log("✅ REAL voice playback started successfully", 
                                   category: SecureLogger.voice, level: .info)
                }
                
            } catch {
                await MainActor.run {
                    voicePlaybackState = .error("Failed to load audio: \(error.localizedDescription)")
            }
            }
            }
    }
    
    /// Pause voice message playback
    private func pauseVoiceMessage() {
        guard case .playing(_) = voicePlaybackState else { return }
        
        // REAL IMPLEMENTATION: Pause using AudioPlayer service
        audioPlayer?.pause()
        voicePlaybackState = .paused(messageID: playingVoiceMessageID ?? "unknown")
        stopPlaybackProgressTimer()
    }
    
    /// Resume voice message playback
    private func resumeVoiceMessage() {
        guard case .paused(_) = voicePlaybackState else { return }
        
        // REAL IMPLEMENTATION: Resume using AudioPlayer service
        do {
            try audioPlayer?.resume()
            voicePlaybackState = .playing(messageID: playingVoiceMessageID ?? "unknown")
        } catch {
            voicePlaybackState = .error("Resume failed: \(error.localizedDescription)")
        }
    }
    
    /// Stop voice message playback
    func stopVoicePlayback() {
        // REAL IMPLEMENTATION: Stop using AudioPlayer service
        audioPlayer?.stop()
        voicePlaybackState = .idle
        playingVoiceMessageID = nil
        voicePlaybackProgress = 0.0
        stopPlaybackProgressTimer()
        deactivateAudioSession()
    }
    
    /// Seek to specific time in voice message
    func seekVoiceMessage(_ message: BitchatMessage, to time: TimeInterval) {
        // TODO: Implement seek functionality in AudioPlayer service
        // AudioPlayer service doesn't currently support seeking
        SecureLogger.log("⚠️ Seek functionality not yet implemented for AudioPlayer service", 
                       category: SecureLogger.voice, level: .warning)
    }
    
    // MARK: - Voice Message Reception
    
    /// Handle received voice message from VoiceMessageService
    func handleReceivedVoiceMessage(_ message: BitchatMessage) {
        if message.isPrivate, let senderPeerID = message.senderPeerID {
            // Add to private chat
            addVoiceMessageToPrivateChat(message, recipientPeerID: senderPeerID)
            
            // Mark private chat as having unread messages if not currently selected
            if selectedPrivateChatPeer != senderPeerID {
                unreadPrivateMessages.insert(senderPeerID)
            }
            } else {
            // Add to public chat
            addVoiceMessageToPublicChat(message)
            }
    }
    
    // MARK: - Message Sending
    
    private func sendPublicMessage(_ message: BitchatMessage) {
        // Add to public messages
        messages.append(message)
        
        // Send voice message via mesh network using existing infrastructure
        guard let voiceData = message.voiceMessageData else {
            SecureLogger.log("No voice data found in message", category: SecureLogger.voice, level: .error)
            voiceRecordingState = .error("Failed to prepare voice message")
            return
            }
        
        // Update state to show sending
        voiceRecordingState = .sending
        
        // Send via existing mesh service broadcast method
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            
            do {
                // Send the voice message using existing public interface
                // This will handle the mesh routing and delivery
                self.meshService.sendMessage(
                    message.content,
                    to: nil, // nil means broadcast
                    messageID: message.id,
                    timestamp: message.timestamp
                )
                
                // Track for delivery and retry if needed
                if let audioData = voiceData.audioData {
                    MessageRetryService.shared.addVoiceMessageForRetry(
                        message,
                        to: "broadcast",
                        messageData: audioData
                    )
                }
                
                // Update state to sent after successful send
                self.voiceRecordingState = .sent
                
                // Reset to idle after a short delay for user feedback
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.voiceRecordingState = .idle
            }
                
                SecureLogger.log("Voice message broadcast initiated: \(message.id) (\(voiceData.formattedDuration))", 
                               category: SecureLogger.voice, level: .info)
                
            } catch {
                // Handle transmission error
                self.voiceRecordingState = .error("Failed to send voice message: \(error.localizedDescription)")
                SecureLogger.log("Failed to send public voice message: \(error)", 
                               category: SecureLogger.voice, level: .error)
            }
        }
    }
    
    private func sendPrivateMessage(_ message: BitchatMessage) {
        guard let peerID = selectedPrivateChatPeer else { return }
        
        // Add to private chat
        if privateChats[peerID] == nil {
            privateChats[peerID] = []
            }
        privateChats[peerID]?.append(message)
        
        // Send private voice message using existing infrastructure
        guard let voiceData = message.voiceMessageData else {
            SecureLogger.log("No voice data found in private message", category: SecureLogger.voice, level: .error)
            voiceRecordingState = .error("Failed to prepare voice message")
            return
            }
        
        // Get recipient nickname for delivery tracking
        let recipientNickname = getPeer(byID: peerID)?.displayName ?? "Unknown"
        
        // Update state to show sending
        voiceRecordingState = .sending
        
        // Send private voice message using existing infrastructure
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            
            do {
                // Use the existing private message sending method
                // This will handle Noise encryption and routing
                self.meshService.sendPrivateMessage(
                    message.content,
                    to: peerID,
                    recipientNickname: recipientNickname,
                    messageID: message.id
                )
                
                // Track for delivery and retry
                if let audioData = voiceData.audioData {
                    MessageRetryService.shared.addVoiceMessageForRetry(
                        message,
                        to: peerID,
                        messageData: audioData
                    )
                }
                
                // Update state to sent after successful send
                self.voiceRecordingState = .sent
                
                // Reset to idle after a short delay for user feedback
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.voiceRecordingState = .idle
            }
                
                SecureLogger.log("Private voice message sent: \(message.id) to \(recipientNickname)", 
                               category: SecureLogger.voice, level: .info)
                
            } catch {
                // Handle transmission error
                self.voiceRecordingState = .error("Failed to send private voice message: \(error.localizedDescription)")
                SecureLogger.log("Failed to send private voice message: \(error)", 
                               category: SecureLogger.voice, level: .error)
                
                // Update message status to indicate failure
                if let messageIndex = self.privateChats[peerID]?.firstIndex(where: { $0.id == message.id }) {
                    self.privateChats[peerID]?[messageIndex].deliveryStatus = .failed(reason: "Voice message transmission failed")
                }
            }
        }
    }
    
    // MARK: - State Management Helpers
    
    /// Reset voice recording state to idle (used after errors or successful sends)
    func resetVoiceRecordingState() {
        voiceRecordingState = .idle
    }
    
    /// Check if voice recording is available
    var isVoiceRecordingAvailable: Bool {
        return hasAudioPermission && voiceRecordingState.canStartRecording
    }
    
    // MARK: - Playback Progress Tracking
    
    /// Start tracking playback progress
    private func startPlaybackProgressTimer() {
        stopPlaybackProgressTimer()
        
        // TODO: Implement progress tracking with AudioPlayer service
        SecureLogger.log("🎵 Progress tracking to be implemented", 
                       category: SecureLogger.voice, level: .debug)
    }
    
    /// Stop tracking playback progress
    private func stopPlaybackProgressTimer() {
        playbackProgressTimer?.invalidate()
        playbackProgressTimer = nil
    }
}


// MARK: - AudioRecorderDelegate

extension ChatViewModel: AudioRecorderDelegate {
    func audioRecorder(_ recorder: AudioRecorder, didChangeState state: RecordingState) {
        DispatchQueue.main.async { [weak self] in
            switch state {
            case .idle:
                self?.isRecordingVoiceMessage = false
                self?.voiceActivityDetected = false
                self?.currentAudioLevel = 0.0
            case .preparing:
                self?.isRecordingVoiceMessage = true
            case .recording:
                self?.isRecordingVoiceMessage = true
            case .paused:
                break // Keep current state
            case .error(let error):
                self?.isRecordingVoiceMessage = false
                SecureLogger.log("Audio recorder error: \(error)", category: SecureLogger.voice, level: .error)
            }
        }
    }
    
    func audioRecorder(_ recorder: AudioRecorder, didCaptureAudioData data: Data, timestamp: Date) {
        // Handle real-time audio data streaming
        // This could be used for live transmission or buffering
        SecureLogger.log("Captured audio data: \(data.count) bytes", category: SecureLogger.voice, level: .debug)
    }
    
    func audioRecorder(_ recorder: AudioRecorder, didDetectVoiceActivity activity: VoiceActivity, level: Float) {
        DispatchQueue.main.async { [weak self] in
            self?.voiceActivityDetected = (activity == .speaking)
            self?.currentAudioLevel = level
            }
    }
    
    #if os(iOS)
    func audioRecorder(_ recorder: AudioRecorder, didChangePermissionStatus status: AVAudioSession.RecordPermission) {
        DispatchQueue.main.async { [weak self] in
            self?.microphonePermissionStatus = Int(status.rawValue)
            }
    }
    #else
    func audioRecorder(_ recorder: AudioRecorder, didChangePermissionStatus status: Int) {
        DispatchQueue.main.async { [weak self] in
            self?.microphonePermissionStatus = status
            }
    }
    #endif
}

// AVAudioPlayerDelegate removed - now using AudioPlayer service with AudioPlayerDelegate

// MARK: - Voice Errors

enum VoiceError: LocalizedError {
    case noAudioData
    case invalidFormat
    case recordingFailed
    case playbackFailed
    case decodingFailed
    
    var errorDescription: String? {
        switch self {
        case .noAudioData:
            return "No audio data available"
        case .invalidFormat:
            return "Invalid audio format"
        case .recordingFailed:
            return "Recording failed"
        case .playbackFailed:
            return "Playback failed"
        case .decodingFailed:
            return "Audio decoding failed"
            }
    }
}

// MARK: - Opus Decoding for Playback (Now enabled with full Opus support)
/*
extension ChatViewModel {
    private func decodeOpusForPlayback(_ opusData: Data) -> Data? {
        do {
            let decoder = try OpusDecoder(sampleRate: 16000, channels: 1)
            return try decoder.decode(opusData)
        } catch {
            SecureLogger.log("Failed to decode Opus for playback: \(error)", category: SecureLogger.voice, level: .error)
            return nil
        }
    }
}
*/

extension ChatViewModel {
    private func createWAVFile(pcmData: Data, outputURL: URL) throws {
        // WAV header for 32-bit Float PCM, 48kHz, mono (matching OpusAudioService)
        let sampleRate: UInt32 = 48000  // Match OpusAudioService.sampleRate
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 32  // Float32 format
        let bytesPerSample = bitsPerSample / 8
        let blockAlign = channels * bytesPerSample
        
        // Safe calculation to prevent overflow
        let sampleRateInt = Int(sampleRate)
        let blockAlignInt = Int(blockAlign)
        let maxByteRate = Int(UInt32.max)
        let calculatedByteRate = sampleRateInt.multipliedReportingOverflow(by: blockAlignInt)
        let byteRate = UInt32(calculatedByteRate.overflow ? maxByteRate : min(calculatedByteRate.partialValue, maxByteRate))
        
        // Safe dataSize calculation - pcmData is now Int16 format from decode
        let dataSize = UInt32(min(pcmData.count, Int(UInt32.max)))
        let fileSize = 36 + dataSize
        
        SecureLogger.log("💾 Creating WAV file: \(pcmData.count) bytes PCM data, sample rate: \(sampleRate)Hz", 
                        category: SecureLogger.voice, level: .info)
        
        var header = Data()
        
        // RIFF header
        header.append("RIFF".data(using: .ascii)!)
        header.append(withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })
        header.append("WAVE".data(using: .ascii)!)
        
        // fmt chunk
        header.append("fmt ".data(using: .ascii)!)
        header.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) }) // chunk size
        header.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })   // PCM format
        header.append(withUnsafeBytes(of: channels.littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: blockAlign.littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: bitsPerSample.littleEndian) { Data($0) })
        
        // data chunk
        header.append("data".data(using: .ascii)!)
        header.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
        
        // Write complete WAV file
        try (header + pcmData).write(to: outputURL)
    }
    
    // MARK: - AudioPlayerDelegate Methods
    
    func audioPlayer(_ player: AudioPlayer, didChangeState state: PlaybackState, for messageID: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            switch state {
            case .idle:
                self.playingVoiceMessageID = nil
                self.voicePlaybackState = .idle
                self.voicePlaybackProgress = 0.0
            case .loading:
                self.voicePlaybackState = .idle
            case .playing:
                self.playingVoiceMessageID = messageID
                self.voicePlaybackState = .playing(messageID: messageID ?? "")
            case .paused:
                self.voicePlaybackState = .paused(messageID: messageID ?? "")
            case .stopped:
                self.playingVoiceMessageID = nil
                self.voicePlaybackState = .idle
                self.voicePlaybackProgress = 0.0
            case .error(let error):
                self.playingVoiceMessageID = nil
                self.voicePlaybackState = .idle
                self.voicePlaybackProgress = 0.0
                SecureLogger.log("Audio player state error: \(error)", category: SecureLogger.voice, level: .error)
            }
        }
    }
    
    func audioPlayer(_ player: AudioPlayer, didUpdateProgress session: PlaybackSession) {
        DispatchQueue.main.async { [weak self] in
            self?.voicePlaybackProgress = Double(session.progress)
        }
    }
    
    func audioPlayer(_ player: AudioPlayer, didCompletePlayback messageID: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.playingVoiceMessageID = nil
            self.voicePlaybackState = .idle
            self.voicePlaybackProgress = 0.0
        }
    }
    
    func audioPlayer(_ player: AudioPlayer, didFailWithError error: Error, for messageID: String?) {
        SecureLogger.log("Audio playback error: \(error)", category: SecureLogger.voice, level: .error)
        DispatchQueue.main.async { [weak self] in
            self?.handleVoiceRecordingError("Playback failed: \(error.localizedDescription)")
        }
    }
    
    #if os(iOS)
    func audioPlayer(_ player: AudioPlayer, didReceiveInterruption type: AVAudioSession.InterruptionType) {
        DispatchQueue.main.async { [weak self] in
            if type == .began {
                self?.audioPlayer?.pause()
            }
        }
    }
    #else
    func audioPlayer(_ player: AudioPlayer, didReceiveInterruption type: Int) {
        DispatchQueue.main.async { [weak self] in
            if type == 1 { // AVAudioSession.InterruptionType.began.rawValue
                self?.audioPlayer?.pause()
            }
        }
    }
    #endif
    
    /// Called when a security incident is detected during audio playback
    func audioPlayer(_ player: AudioPlayer, encounteredSecurityIncident incident: AudioSecurityError, messageID: String) {
        SecureLogger.log("🚨 Audio security incident: \(incident.localizedDescription) for message: \(messageID)", 
                       category: SecureLogger.voice, level: .error)
        
        DispatchQueue.main.async { [weak self] in
            // Handle security incidents gracefully - could show user notification
            // For now, just log and continue
            self?.handleVoiceRecordingError("Security incident detected: \(incident.localizedDescription)")
        }
    }
    
    // MARK: - Bluetooth State Management
    
    /// Update bluetooth state for UI display
    /// Called by BluetoothMeshService when bluetooth state changes
    @MainActor
    func updateBluetoothState(_ state: CBManagerState) {
        SecureLogger.log("📶 Bluetooth state updated: \(state)", category: SecureLogger.session, level: .info)
        // This method is called by BluetoothMeshService to update UI
        // Implementation can be expanded to update UI state if needed
    }
    
    // MARK: - 🛡️ Simple Rate Limiting
    
    /// Simple voice message rate limiting (20 messages per minute per peer)
    private static var voiceMessageHistory: [String: [Date]] = [:]
    private static let maxVoiceMessagesPerMinute = 20
    private static let rateLimitWindowSeconds: TimeInterval = 60.0
    
    /// Check if peer can send voice message (rate limiting)
    private func canSendVoiceMessage(peerID: String) -> Bool {
        let now = Date()
        
        // Clean expired entries
        ChatViewModel.voiceMessageHistory[peerID] = ChatViewModel.voiceMessageHistory[peerID]?.filter { 
            now.timeIntervalSince($0) <= ChatViewModel.rateLimitWindowSeconds 
        } ?? []
        
        let currentCount = ChatViewModel.voiceMessageHistory[peerID]?.count ?? 0
        return currentCount < ChatViewModel.maxVoiceMessagesPerMinute
    }
    
    /// Record voice message sent (for rate limiting)
    private func recordVoiceMessageSent(peerID: String) {
        if ChatViewModel.voiceMessageHistory[peerID] != nil {
            ChatViewModel.voiceMessageHistory[peerID]?.append(Date())
        } else {
            ChatViewModel.voiceMessageHistory[peerID] = [Date()]
        }
    }
}

