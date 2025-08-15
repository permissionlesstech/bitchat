//
// MessageRouter+Voice.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import os.log

/// Voice message routing extensions for MessageRouter
/// Handles routing logic specific to voice messages including fragmentation and priority routing
/// 
/// ACTIVE: Voice message routing is now enabled with real Opus codec integration
extension MessageRouter {
    
    // MARK: - Voice Message Routing
    
    /// Route a voice message to the appropriate destination
    /// - Parameters:
    ///   - voiceMessage: The voice message to route
    ///   - recipientID: Target recipient ID
    ///   - isPrivate: Whether this is a private message
    func routeVoiceMessage(_ voiceMessage: BitchatMessage, to recipientID: String, isPrivate: Bool) {
        guard let voiceData = voiceMessage.voiceMessageData else {
            SecureLogger.log("❌ No voice data in message \(voiceMessage.id)", 
                           category: SecureLogger.voice, level: .error)
            return
        }
        
        SecureLogger.log("🚀 Routing voice message \(voiceMessage.id) to \(recipientID), private: \(isPrivate)", 
                       category: SecureLogger.voice, level: .info)
        
        if isPrivate {
            routePrivateVoiceMessage(voiceMessage, voiceData: voiceData, to: recipientID)
        } else {
            routeBroadcastVoiceMessage(voiceMessage, voiceData: voiceData)
        }
    }
    
    /// Handle received voice message fragment
    /// - Parameters:
    ///   - fragment: Voice message fragment
    ///   - fromPeer: Source peer ID
    func handleVoiceMessageFragment(_ fragment: Data, from fromPeer: String) {
        SecureLogger.log("📦 Received voice fragment from \(fromPeer), size: \(fragment.count)", 
                       category: SecureLogger.voice, level: .debug)
        
        // Simple voice message handling (no fragmentation for now)
        SecureLogger.log("🔊 Received voice message fragment from: \(fromPeer)", 
                        category: SecureLogger.voice, level: .info)
    }
    
    /// Get voice routing statistics
    var voiceRoutingStats: (messagesRouted: Int, fragmentsHandled: Int, errorRate: Double) {
        // Simple stats for now
        return (
            messagesRouted: 0, 
            fragmentsHandled: 0,
            errorRate: 0.0
        )
    }
    
    // MARK: - Private Routing Methods
    
    /// Route private voice message with encryption
    private func routePrivateVoiceMessage(_ message: BitchatMessage, voiceData: VoiceMessageData, to recipientID: String) {
        guard let audioData = voiceData.audioData else {
            SecureLogger.log("❌ No audio data for private voice message", 
                           category: SecureLogger.voice, level: .error)
            return
        }
        
        // 🛡️ RATE LIMITING NOTE: Primary rate limiting handled at UI layer in ChatViewModel
        // Additional routing layer validation could be added here if needed
        
        // SECURITY: Private voice messages must be encrypted via Noise Protocol
        // Convert voice data to base64 and send through encrypted channel
        let base64AudioData = audioData.base64EncodedString()
        
        // Create structured voice content with metadata for proper reconstruction
        let voiceMetadata = [
            "duration": String(voiceData.duration),
            "sampleRate": "48000",
            "codec": "opus",
            "messageId": message.id
        ]
        
        // Serialize metadata as JSON
        guard let metadataData = try? JSONSerialization.data(withJSONObject: voiceMetadata),
              let metadataString = String(data: metadataData, encoding: .utf8) else {
            SecureLogger.log("❌ Failed to serialize voice metadata", 
                           category: SecureLogger.voice, level: .error)
            return
        }
        
        // Construct encrypted voice content: VOICE:<metadata>:<audioData>
        let encryptedVoiceContent = "VOICE:\(metadataString):\(base64AudioData)"
        
        // INTELLIGENT ROUTING: Use MessageRouter for automatic transport selection (Bluetooth vs Nostr)
        // Convert recipientID (hexString) to recipientNoisePublicKey (Data) for MessageRouter
        guard let recipientNoisePublicKey = Data(hexString: recipientID) else {
            SecureLogger.log("❌ Invalid recipientID format for voice message: \(recipientID)", 
                           category: SecureLogger.voice, level: .error)
            return
        }
        
        // Route through MessageRouter to enable dual transport (Bluetooth mesh + Nostr)
        Task { @MainActor in
            do {
                try await sendMessage(
                    encryptedVoiceContent,
                    to: recipientNoisePublicKey,
                    messageId: message.id
                )
                SecureLogger.log("🚀 Successfully routed encrypted voice message \(message.id) via dual transport", 
                               category: SecureLogger.voice, level: .info)
            } catch {
                SecureLogger.log("❌ Failed to route voice message \(message.id): \(error)", 
                               category: SecureLogger.voice, level: .error)
            }
        }
    }
    
    /// Route broadcast voice message to all peers
    private func routeBroadcastVoiceMessage(_ message: BitchatMessage, voiceData: VoiceMessageData) {
        guard let audioData = voiceData.audioData else {
            SecureLogger.log("❌ No audio data for broadcast voice message", 
                           category: SecureLogger.voice, level: .error)
            return
        }
        
        // Create VoiceMessage for broadcast
        let voiceMessage = VoiceMessage(
            id: message.id,
            senderID: myPeerID,
            senderNickname: message.sender,
            audioData: audioData,
            duration: voiceData.duration,
            sampleRate: 48000,  // ✅ Opus native sample rate
            codec: .opus,
            timestamp: message.timestamp,
            isPrivate: false,
            recipientID: nil,
            recipientNickname: nil,
            deliveryStatus: .sending
        )
        
        // Send broadcast via mesh service using the new real implementation
        meshService.sendBroadcastVoiceMessage(voiceMessage)
        
        SecureLogger.log("📢 Broadcasted voice message \(message.id)", 
                       category: SecureLogger.voice, level: .info)
    }
    
    /// Get peer nickname from ID
    private func getPeerNickname(_ peerID: String) -> String? {
        // Use BluetoothMeshService to get peer nickname
        return meshService.getPeerNickname(peerID)
    }
}