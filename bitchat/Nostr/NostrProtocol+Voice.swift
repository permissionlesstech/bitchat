//
// NostrProtocol+Voice.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import CryptoKit

/// Voice message extensions for NostrProtocol
/// Implements NIP-17 gift-wrapped voice messages for metadata privacy
extension NostrProtocol {
    
    // MARK: - Voice Message Creation
    
    /// Create a NIP-17 gift-wrapped voice message event
    /// - Parameters:
    ///   - voiceMessage: VoiceMessage object with audio data
    ///   - recipientPubkey: Recipient's Nostr public key (hex)
    /// - Returns: Gift-wrapped NostrEvent ready for relay transmission
    /// - Throws: NostrError if encryption or event creation fails
    func createVoiceMessageEvent(
        voiceMessage: VoiceMessage,
        recipientPubkey: String
    ) throws -> NostrEvent {
        
        // Validate input
        guard !voiceMessage.audioData.isEmpty else {
            throw NostrError.invalidEvent
        }
        
        guard recipientPubkey.count == 64 else {
            throw NostrError.invalidEvent
        }
        
        // Create structured voice content following BitChat format
        let audioDataBase64 = voiceMessage.audioData.base64EncodedString()
        let voiceContent = "VOICE:\(voiceMessage.id):\(audioDataBase64):\(voiceMessage.duration):\(voiceMessage.codec.rawValue)"
        
        SecureLogger.log("📤 Creating Nostr voice message for \(recipientPubkey.prefix(8))... using REAL NIP-17 encryption", 
                        category: SecureLogger.voice, level: .info)
        
        // Get current user's Nostr identity
        guard let identity = try? NostrIdentityBridge.getCurrentNostrIdentity() else {
            throw NostrError.signingFailed
        }
        
        // ✅ USE REAL NIP-17 IMPLEMENTATION: Delegate to proven NostrProtocol.createPrivateMessage
        // This replaces the stub implementation with the real, tested encryption
        return try NostrProtocol.createPrivateMessage(
            content: voiceContent,
            recipientPubkey: recipientPubkey,
            senderIdentity: identity
        )
    }
    
    /// Create a voice message event with audio data and duration
    func createVoiceMessageEvent(
        voiceData: Data,
        duration: TimeInterval,
        recipientPubkey: String?
    ) throws -> NostrEvent {
        
        guard let recipientKey = recipientPubkey else {
            throw NostrError.invalidEvent
        }
        
        // Create VoiceMessage object for structured creation
        let voiceMessage = VoiceMessage(
            id: UUID().uuidString,
            senderID: UUID().uuidString, // Temporary ID - will be updated with actual key
            senderNickname: "BitChat User", // Default nickname
            audioData: voiceData,
            duration: duration,
            sampleRate: 16000,
            codec: .opus,
            timestamp: Date(),
            isPrivate: true,
            recipientID: recipientKey,
            recipientNickname: nil,
            deliveryStatus: .sending
        )
        
        // ✅ This now delegates to the corrected createVoiceMessageEvent with real NIP-17 encryption
        return try createVoiceMessageEvent(voiceMessage: voiceMessage, recipientPubkey: recipientKey)
    }
    
    // MARK: - Voice Message Parsing
    
    /// Parse voice message from NIP-17 gift-wrapped event
    /// - Parameter event: Gift-wrapped NostrEvent (kind 1059)
    /// - Returns: Tuple with voice data and metadata, or nil if not a voice message
    func parseVoiceMessage(from event: NostrEvent) -> (voiceMessage: VoiceMessage, senderPubkey: String)? {
        do {
            // Get current user's identity for decryption
            guard let identity = try? NostrIdentityBridge.getCurrentNostrIdentity() else {
                return nil
            }
            
            // ✅ USE REAL NIP-17 IMPLEMENTATION: Delegate to proven NostrProtocol.decryptPrivateMessage
            let (content, senderPubkey) = try NostrProtocol.decryptPrivateMessage(
                giftWrap: event,
                recipientIdentity: identity
            )
            
            // Check if this is a voice message
            guard content.hasPrefix("VOICE:") else {
                return nil
            }
            
            // Parse voice content: "VOICE:<messageID>:<base64AudioData>:<duration>:<codec>"
            let components = content.components(separatedBy: ":")
            guard components.count >= 5,
                  components[0] == "VOICE" else {
                SecureLogger.log("❌ Invalid voice message format", 
                               category: SecureLogger.voice, level: .error)
                return nil
            }
            
            let messageID = components[1]
            let audioDataBase64 = components[2]
            let durationString = components[3]
            let codecString = components[4]
            
            // Validate and parse components
            guard let audioData = Data(base64Encoded: audioDataBase64),
                  let duration = TimeInterval(durationString),
                  let codec = VoiceMessage.VoiceCodec(rawValue: codecString == "1" ? "opus" : "pcm") else {
                SecureLogger.log("❌ Failed to parse voice message components", 
                               category: SecureLogger.voice, level: .error)
                return nil
            }
            
            // Create VoiceMessage object
            let voiceMessage = VoiceMessage(
                id: messageID,
                senderID: senderPubkey,
                senderNickname: "Nostr User", // Will be updated from favorites if available
                audioData: audioData,
                duration: duration,
                sampleRate: 16000,
                codec: codec,
                timestamp: Date(), // Use current time since we have decrypted content
                isPrivate: true,
                recipientID: "temp-recipient-id", // Will be set properly from context
                recipientNickname: nil,
                deliveryStatus: .delivered(to: "nostr", at: Date())
            )
            
            SecureLogger.log("🎤 Parsed Nostr voice message with REAL decryption: \(duration)s, \(audioData.count) bytes", 
                           category: SecureLogger.voice, level: .info)
            
            return (voiceMessage: voiceMessage, senderPubkey: senderPubkey)
            
        } catch {
            SecureLogger.log("❌ Failed to parse voice message: \(error)", 
                           category: SecureLogger.voice, level: .error)
            return nil
        }
    }
    
    // MARK: - Private Helper Methods  
    // Note: All NIP-17 encryption/decryption now delegates to NostrProtocol's proven implementation
    // This eliminates duplicate code and ensures we use the tested, real encryption functions
    
    /// Randomize timestamp for metadata privacy (±1 minute)
    private func randomizedTimestamp() -> Int64 {
        let now = Date().timeIntervalSince1970
        let randomOffset = Double.random(in: -60...60) // ±1 minute
        return Int64(now + randomOffset)
    }
}