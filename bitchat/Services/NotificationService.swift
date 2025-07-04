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
                // Permission granted
            } else if let error = error {
                // print("[NOTIFICATIONS] Permission error: \(error)")
            }
        }
    }
    
    func sendLocalNotification(title: String, body: String, identifier: String) {
        // Check if app is in foreground
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
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                // print("[NOTIFICATIONS] Error sending notification: \(error)")
            } else {
                // Notification sent
            }
        }
    }
    
    func sendMentionNotification(from sender: String, message: String) {
        let title = "Mentioned by \(sender)"
        let body = message
        let identifier = "mention-\(UUID().uuidString)"
        
        sendLocalNotification(title: title, body: body, identifier: identifier)
    }
    
    func sendPrivateMessageNotification(from sender: String, message: String) {
        let title = "Private message from \(sender)"
        let body = message
        let identifier = "private-\(UUID().uuidString)"
        
        sendLocalNotification(title: title, body: body, identifier: identifier)
    }
    
    func sendFavoriteOnlineNotification(nickname: String) {
        let title = "⭐ \(nickname) is online"
        let body = "wanna get in there?"
        let identifier = "favorite-online-\(UUID().uuidString)"
        
        sendLocalNotification(title: title, body: body, identifier: identifier)
    }
}