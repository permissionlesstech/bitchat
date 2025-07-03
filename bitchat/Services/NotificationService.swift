import Foundation
#if os(iOS)
import UIKit
import UserNotifications
#else
import UserNotifications
#endif

class NotificationService {
    static let shared = NotificationService()
    
    private init() {}
    
    func requestAuthorization() {
        #if os(iOS)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                print("[NOTIFICATIONS] Permission granted")
            } else if let error = error {
                print("[NOTIFICATIONS] Permission error: \(error)")
            }
        }
        #endif
    }
    
    func sendLocalNotification(title: String, body: String, identifier: String) {
        #if os(iOS)
        // Send notification if app is not active (background or inactive)
        guard UIApplication.shared.applicationState != .active else {
            print("[NOTIFICATIONS] App is active/foreground, skipping notification")
            return
        }
        
        print("[NOTIFICATIONS] App state: \(UIApplication.shared.applicationState.rawValue), sending notification")
        
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
                print("[NOTIFICATIONS] Error sending notification: \(error)")
            } else {
                print("[NOTIFICATIONS] Notification sent: \(title)")
            }
        }
        #endif
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
}