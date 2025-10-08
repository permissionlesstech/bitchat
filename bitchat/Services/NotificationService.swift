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

@MainActor class NotificationService {
    static let shared = NotificationService()
    
    private init() {}
    
    func requestAuthorization() async {
        let _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }
    
    func sendLocalNotification(title: String, body: String, identifier: String, userInfo: [String: Any]? = nil) {
        // For now, skip app state check entirely to avoid thread issues
        // The NotificationDelegate will handle foreground presentation
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let userInfo = userInfo {
            content.userInfo = userInfo
        }
        
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil // Deliver immediately
        )
        
        Task(priority: .low) {
            try? await UNUserNotificationCenter.current().add(request)
        }
    }
    
    func sendMentionNotification(from sender: String, message: String) {
        let title = "\(sender) mentioned you"
        let body = message
        let identifier = "mention-\(UUID().uuidString)"
        
        sendLocalNotification(title: title, body: body, identifier: identifier)
    }
    
    func sendPrivateMessageNotification(from sender: String, message: String, peerID: String) {
        let title = "DM from \(sender)"
        let body = message
        let identifier = "private-\(UUID().uuidString)"
        let userInfo = ["peerID": peerID, "senderName": sender]
        
        sendLocalNotification(title: title, body: body, identifier: identifier, userInfo: userInfo)
    }
    
    func sendFavoriteOnlineNotification(nickname: String) {
        // Send directly without checking app state for favorites
        let content = UNMutableNotificationContent()
        content.title = "\(nickname) is online!"
        content.body = "wanna get in there?"
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: "favorite-online-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        
        Task(priority: .low) {
            try? await UNUserNotificationCenter.current().add(request)
        }
    }
}
