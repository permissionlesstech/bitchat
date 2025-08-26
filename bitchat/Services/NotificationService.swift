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

    private var isRunningTests: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["UITests"] == "1"
    }

    private var isRealAppBundle: Bool {
        // Ensure we are running from an actual app bundle (not test host without .app)
        let url = Bundle.main.bundleURL
        return (Bundle.main.bundleIdentifier != nil) && (url.pathExtension == "app")
    }
    
    func requestAuthorization() {
        // Avoid calling notification center in unit tests or non-app bundles
        guard !isRunningTests, isRealAppBundle else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                // Permission granted
            } else {
                // Permission denied
            }
        }
    }
    
    func sendLocalNotification(title: String, body: String, identifier: String, userInfo: [String: Any]? = nil) {
        guard !isRunningTests, isRealAppBundle else { return }
        // For now, skip app state check entirely to avoid thread issues
        // The NotificationDelegate will handle foreground presentation
        DispatchQueue.main.async {
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
            
            UNUserNotificationCenter.current().add(request) { _ in
                // Notification added
            }
        }
    }
    
    func sendMentionNotification(from sender: String, message: String) {
        let title = String(format: String(localized: "notif.mention.title"), sender)
        let body = message
        let identifier = "mention-\(UUID().uuidString)"
        
        sendLocalNotification(title: title, body: body, identifier: identifier)
    }
    
    func sendPrivateMessageNotification(from sender: String, message: String, peerID: String) {
        let title = String(format: String(localized: "notif.private_message.title"), sender)
        let body = message
        let identifier = "private-\(UUID().uuidString)"
        let userInfo = ["peerID": peerID, "senderName": sender]
        
        sendLocalNotification(title: title, body: body, identifier: identifier, userInfo: userInfo)
    }
    
    func sendFavoriteOnlineNotification(nickname: String) {
        guard !isRunningTests, isRealAppBundle else { return }
        // Send directly without checking app state for favorites
        DispatchQueue.main.async {
            let content = UNMutableNotificationContent()
            content.title = String(format: String(localized: "notif.favorite_online.title"), nickname)
            content.body = String(localized: "notif.favorite_online.body")
            content.sound = .default
            
            let request = UNNotificationRequest(
                identifier: "favorite-online-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            
            UNUserNotificationCenter.current().add(request) { _ in
                // Notification added
            }
        }
    }
    
    func sendNetworkAvailableNotification(peerCount: Int) {
        guard !isRunningTests, isRealAppBundle else { return }
        let title = String(localized: "notif.network_available.title")
        let body = {
            if peerCount == 1 {
                return String(localized: "notif.network_available.body.one")
            } else {
                return String(format: String(localized: "notif.network_available.body.other"), peerCount)
            }
        }()
        let identifier = "network-available-\(Date().timeIntervalSince1970)"
        
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
            
            UNUserNotificationCenter.current().add(request) { _ in
                // Notification added
            }
        }
    }
}
