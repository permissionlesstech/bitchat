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
        // Check if app is in foreground (must be on main thread)
        DispatchQueue.main.async {
            #if os(iOS)
            guard UIApplication.shared.applicationState != .active else {
                // App is active/foreground, skipping notification
                return
            }
            // App state checked, sending notification
            #elseif os(macOS)
            // On macOS, check if app is active
            guard !NSApplication.shared.isActive else {
                // App is active/foreground, skipping notification
                return
            }
            // App is not active, sending notification
            #endif
            
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            
            let request = UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: nil // Deliver immediately
            )
            
            UNUserNotificationCenter.current().add(request) { _ in
                // Notification added
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
        let title = "⭐ \(nickname) is online!"
        let body = "wanna get in there?"
        let identifier = "favorite-online-\(UUID().uuidString)"
        
        sendLocalNotification(title: title, body: body, identifier: identifier)
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
