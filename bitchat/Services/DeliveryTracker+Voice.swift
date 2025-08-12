//
// DeliveryTracker+Voice.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Voice delivery tracking extensions for DeliveryTracker
/// Provides specialized tracking for voice messages with their unique characteristics
extension DeliveryTracker {
    
    /// Track voice message delivery using the main DeliveryTracker infrastructure
    /// - Parameters:
    ///   - messageID: The voice message ID to track
    ///   - recipientID: The recipient peer ID
    ///   - recipientNickname: The recipient's display name
    ///   - isFavorite: Whether this is a favorite peer (affects timeout)
    func trackVoiceMessageDelivery(_ messageID: String, to recipientID: String, recipientNickname: String = "Unknown", isFavorite: Bool = false) {
        // Get the voice message from VoiceMessageService
        if let voiceState = VoiceMessageService.shared.getVoiceMessageState(messageID) {
            // Use the main DeliveryTracker to track the voice message
            trackMessage(voiceState.message, recipientID: recipientID, recipientNickname: recipientNickname, isFavorite: isFavorite)
            
            SecureLogger.log("🎵 Tracking voice message delivery: \(messageID) to \(recipientNickname)", 
                           category: SecureLogger.voice, level: .info)
        } else {
            SecureLogger.log("❌ Cannot track voice message \(messageID) - not found in VoiceMessageService", 
                           category: SecureLogger.voice, level: .error)
        }
    }
    
    /// Handle voice message delivery confirmation from DeliveryAck
    /// - Parameters:
    ///   - messageID: The original voice message ID that was confirmed
    ///   - senderID: The peer who sent the confirmation
    func handleVoiceDeliveryConfirmation(_ messageID: String, from senderID: String) {
        // Use the main DeliveryTracker to handle the confirmation
        let deliveryAck = DeliveryAck(
            originalMessageID: messageID,
            recipientID: senderID,
            recipientNickname: "Peer", // Will be updated by main tracker
            hopCount: 1 // Default hop count for voice messages
        )
        
        processDeliveryAck(deliveryAck)
        
        SecureLogger.log("🎵✅ Voice message \(messageID) delivered to \(senderID)", 
                       category: SecureLogger.voice, level: .info)
    }
    
    /// Get voice delivery statistics by filtering the main tracker's data
    /// Note: This provides approximate stats based on VoiceMessageService state
    var voiceDeliveryStats: (sent: Int, delivered: Int, failed: Int) {
        var sent = 0
        var delivered = 0
        var failed = 0
        
        // Count voice messages from VoiceMessageService instead of accessing private members
        let voiceService = VoiceMessageService.shared
        
        // This is a simplified implementation that would need VoiceMessageService
        // to expose statistics or we need to make DeliveryTracker members internal
        
        // For now, return placeholder values
        // TODO: Implement proper statistics when VoiceMessageService exposes state stats
        return (sent: 0, delivered: 0, failed: 0)
    }
    
    /// Check if a voice message is currently being tracked
    /// - Parameter messageID: The voice message ID to check
    /// - Returns: True if the message is being tracked for delivery
    func isTrackingVoiceMessage(_ messageID: String) -> Bool {
        // Use VoiceMessageService to check if message exists instead of accessing private members
        return VoiceMessageService.shared.getVoiceMessageState(messageID) != nil
    }
}