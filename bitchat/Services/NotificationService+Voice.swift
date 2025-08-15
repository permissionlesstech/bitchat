//
// NotificationService+Voice.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import UserNotifications

/// Voice notification extensions for NotificationService
extension NotificationService {
    
    /// Schedule a voice message notification
    func scheduleVoiceMessageNotification(
        from senderID: String,
        senderNickname: String,
        duration: TimeInterval,
        isPrivate: Bool
    ) {
        let content = UNMutableNotificationContent()
        content.title = isPrivate ? "Private Voice Message" : "Voice Message"
        content.body = "🎤 Voice message from \(senderNickname) (\(String(format: "%.1f", duration))s)"
        content.sound = .default
        content.categoryIdentifier = "VOICE_MESSAGE"
        
        // Add userInfo for handling
        content.userInfo = [
            "type": "voice_message",
            "senderID": senderID,
            "senderNickname": senderNickname,
            "duration": duration,
            "isPrivate": isPrivate
        ]
        
        let request = UNNotificationRequest(
            identifier: "voice_\(senderID)_\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                SecureLogger.log("Failed to schedule voice notification: \(error)", 
                               category: SecureLogger.voice, level: .error)
            }
        }
    }
    
    /// Send voice message delivered notification
    func sendVoiceMessagePartiallyDeliveredNotification(
        to recipient: String,
        progress: Float,
        messageID: String
    ) {
        let content = UNMutableNotificationContent()
        content.title = "Voice Message Sending"
        content.body = "Voice message to \(recipient) is \(Int(progress * 100))% delivered"
        content.sound = nil
        content.categoryIdentifier = "VOICE_PROGRESS"
        
        content.userInfo = [
            "type": "voice_progress",
            "recipient": recipient,
            "progress": progress,
            "messageID": messageID
        ]
        
        let request = UNNotificationRequest(
            identifier: "voice_progress_\(messageID)",
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request)
    }
    
    /// Send voice message retry notification
    func sendVoiceMessageRetryNotification(
        to recipient: String,
        attempt: Int,
        maxAttempts: Int
    ) {
        let content = UNMutableNotificationContent()
        content.title = "Voice Message Retry"
        content.body = "Retrying voice message to \(recipient) (attempt \(attempt)/\(maxAttempts))"
        content.sound = nil
        content.categoryIdentifier = "VOICE_RETRY"
        
        content.userInfo = [
            "type": "voice_retry",
            "recipient": recipient,
            "attempt": attempt,
            "maxAttempts": maxAttempts
        ]
        
        let request = UNNotificationRequest(
            identifier: "voice_retry_\(recipient)_\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request)
    }
    
    /// Send voice storage cleanup notification
    func sendVoiceStorageCleanupNotification(
        cleanedCount: Int,
        freedSpace: String
    ) {
        let content = UNMutableNotificationContent()
        content.title = "Voice Storage Cleaned"
        content.body = "Cleaned \(cleanedCount) failed voice messages, freed \(freedSpace)"
        content.sound = nil
        content.categoryIdentifier = "VOICE_CLEANUP"
        
        content.userInfo = [
            "type": "voice_cleanup",
            "cleanedCount": cleanedCount,
            "freedSpace": freedSpace
        ]
        
        let request = UNNotificationRequest(
            identifier: "voice_cleanup_\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request)
    }
    
    /// Send voice message failed notification
    func sendVoiceMessageFailedNotification(
        to recipient: String,
        reason: String
    ) {
        let content = UNMutableNotificationContent()
        content.title = "Voice Message Failed"
        content.body = "Failed to send voice message to \(recipient): \(reason)"
        content.sound = UNNotificationSound.defaultCritical
        content.categoryIdentifier = "VOICE_FAILED"
        
        content.userInfo = [
            "type": "voice_failed",
            "recipient": recipient,
            "reason": reason
        ]
        
        let request = UNNotificationRequest(
            identifier: "voice_failed_\(recipient)_\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request)
    }
    
    /// Cancel voice message receiving notification
    func cancelVoiceMessageReceivingNotification(from sender: String) {
        let identifiers = ["voice_progress_\(sender)", "voice_receiving_\(sender)"]
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    }
    
    /// Handle voice message notification response
    func handleVoiceNotificationResponse(_ response: UNNotificationResponse) {
        guard let userInfo = response.notification.request.content.userInfo as? [String: Any],
              let type = userInfo["type"] as? String else {
            return
        }
        
        switch type {
        case "voice_message":
            if let senderID = userInfo["senderID"] as? String {
                // Handle voice message tap - could open chat or start playback
                NotificationCenter.default.post(
                    name: NSNotification.Name("bitchat.voiceNotificationTapped"),
                    object: nil,
                    userInfo: ["senderID": senderID]
                )
            }
            
        case "voice_progress", "voice_retry", "voice_cleanup":
            // These are informational notifications, no action needed
            break
            
        default:
            break
        }
    }
}