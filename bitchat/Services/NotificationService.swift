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

final class NotificationService {
    static let shared = NotificationService()

    /// Returns true if running in test environment (XCTest, Swift Testing, or CI)
    private var isRunningTests: Bool {
        let env = ProcessInfo.processInfo.environment
        return NSClassFromString("XCTestCase") != nil ||
               env["XCTestConfigurationFilePath"] != nil ||
               env["XCTestBundlePath"] != nil ||
               env["GITHUB_ACTIONS"] != nil ||
               env["CI"] != nil
    }

    private init() {}

    func requestAuthorization() {
        guard !isRunningTests else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                // Permission granted
            } else {
                // Permission denied
            }
        }
    }
    
    func sendLocalNotification(
        title: String,
        body: String,
        identifier: String,
        userInfo: [String: Any]? = nil,
        interruptionLevel: UNNotificationInterruptionLevel = .active
    ) {
        guard !isRunningTests else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = interruptionLevel

        if let userInfo = userInfo {
            content.userInfo = userInfo
        }

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request)
    }
    
    func sendMentionNotification(from sender: String, message: String) {
        let title = "🫵 you were mentioned by \(sender)"
        let body = message
        let identifier = "mention-\(UUID().uuidString)"
        
        sendLocalNotification(title: title, body: body, identifier: identifier)
    }
    
    func sendPrivateMessageNotification(from sender: String, message: String, peerID: PeerID) {
        let title = "🔒 DM from \(sender)"
        let body = message
        let identifier = "private-\(UUID().uuidString)"
        let userInfo = ["peerID": peerID.id, "senderName": sender]
        
        sendLocalNotification(title: title, body: body, identifier: identifier, userInfo: userInfo)
    }
    
    // Geohash public chat notification with deep link to a specific geohash
    func sendGeohashActivityNotification(geohash: String, titlePrefix: String = "#", bodyPreview: String) {
        let title = "\(titlePrefix)\(geohash)"
        let identifier = "geo-activity-\(geohash)-\(Date().timeIntervalSince1970)"
        let deeplink = "bitchat://geohash/\(geohash)"
        let userInfo: [String: Any] = ["deeplink": deeplink]
        sendLocalNotification(title: title, body: bodyPreview, identifier: identifier, userInfo: userInfo)
    }

    func sendNetworkAvailableNotification(peerCount: Int) {
        let title = "👥 bitchatters nearby!"
        let body = peerCount == 1 ? "1 person around" : "\(peerCount) people around"
        // Fixed identifier so iOS updates the existing notification instead of creating new ones
        let identifier = "network-available"

        sendLocalNotification(
            title: title,
            body: body,
            identifier: identifier,
            interruptionLevel: .timeSensitive
        )
    }
}
