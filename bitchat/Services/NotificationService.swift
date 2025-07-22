//
// NotificationService.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import UserNotifications
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

class NotificationService {
    static let shared = NotificationService()
    
    private init() {}
    
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                print("📱 Notification permission granted")
            } else {
                print("📱 Notification permission denied: \(error?.localizedDescription ?? "Unknown")")
            }
        }
    }
    
    func sendLocalNotification(title: String, body: String, identifier: String) {
        // For now, skip app state check entirely to avoid thread issues
        // The NotificationDelegate will handle foreground presentation
        DispatchQueue.main.async {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            
            let request = UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: nil // Deliver immediately
            )
            
            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    print("📱 Error sending local notification: \(error)")
                } else {
                    print("📱 Local notification sent: \(title)")
                }
            }
        }
    }
    
    func sendMentionNotification(from sender: String, message: String) {
        let title = "＠🫵 you were mentioned by \(sender)"
        let body = message
        let identifier = "mention-\(UUID().uuidString)"
        
        sendLocalNotification(title: title, body: body, identifier: identifier)
    }
    
    func sendPrivateMessageNotification(from sender: String, message: String) {
        let title = "🔒 private message from \(sender)"
        let body = message
        let identifier = "private-\(UUID().uuidString)"
        
        sendLocalNotification(title: title, body: body, identifier: identifier)
    }
    
    func sendFavoriteOnlineNotification(nickname: String) {
        print("📱 sendFavoriteOnlineNotification called for: \(nickname)")
        
        // Send directly without checking app state for favorites
        DispatchQueue.main.async {
            let content = UNMutableNotificationContent()
            content.title = "⭐ \(nickname) is online!"
            content.body = "wanna get in there?"
            content.sound = .default
            
            let request = UNNotificationRequest(
                identifier: "favorite-online-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            
            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    print("📱 Error sending favorite notification: \(error)")
                } else {
                    print("📱 Favorite notification sent successfully")
                }
            }
        }
    }
    
    func sendNetworkAvailableNotification(peerCount: Int) {
        print("📱 sendNetworkAvailableNotification called with peerCount: \(peerCount)")
        
        let title = "👥 bitchatters nearby!"
        let body = peerCount == 1 ? "1 person around" : "\(peerCount) people around"
        let identifier = "network-available-\(Date().timeIntervalSince1970)"
        
        print("📱 Sending network notification: \(body)")
        
        // For network notifications, we want to show them even in foreground
        // No app state check - let the notification delegate handle presentation
        DispatchQueue.main.async {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.interruptionLevel = .timeSensitive  // Make it more prominent
            
            let request = UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: nil // Deliver immediately
            )
            
            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    print("📱 Error sending network notification: \(error)")
                } else {
                    print("📱 Network notification sent successfully")
                }
            }
        }
    }
}
