//
// NotificationService.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation
import UserNotifications
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

protocol NotificationAuthorizing {
    func requestAuthorization(
        options: UNAuthorizationOptions,
        completionHandler: @escaping (Bool, Error?) -> Void
    )
}

protocol NotificationRequestDelivering {
    func add(_ request: UNNotificationRequest)
}

protocol NotificationCategoryRegistering {
    func setCategories(_ categories: Set<UNNotificationCategory>)
}

private final class NotificationCenterAuthorizerAdapter: NotificationAuthorizing {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter) {
        self.center = center
    }

    func requestAuthorization(
        options: UNAuthorizationOptions,
        completionHandler: @escaping (Bool, Error?) -> Void
    ) {
        center.requestAuthorization(options: options, completionHandler: completionHandler)
    }
}

private final class NotificationCenterRequestDelivererAdapter: NotificationRequestDelivering {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter) {
        self.center = center
    }

    func add(_ request: UNNotificationRequest) {
        Task {
            try? await center.add(request)
        }
    }
}

private final class NotificationCenterCategoryRegistrarAdapter: NotificationCategoryRegistering {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter) {
        self.center = center
    }

    func setCategories(_ categories: Set<UNNotificationCategory>) {
        center.setNotificationCategories(categories)
    }
}

private struct NoopNotificationAuthorizer: NotificationAuthorizing {
    func requestAuthorization(
        options: UNAuthorizationOptions,
        completionHandler: @escaping (Bool, Error?) -> Void
    ) {
        completionHandler(false, nil)
    }
}

private struct NoopNotificationRequestDeliverer: NotificationRequestDelivering {
    func add(_ request: UNNotificationRequest) {}
}

private struct NoopNotificationCategoryRegistrar: NotificationCategoryRegistering {
    func setCategories(_ categories: Set<UNNotificationCategory>) {}
}

final class NotificationService {
    static let shared = NotificationService()

    /// Category for the "bitchatters nearby" notification, carrying the wave quick action.
    static let nearbyCategoryID = "chat.bitchat.category.nearby"
    static let waveActionID = "chat.bitchat.action.wave"

    private let isRunningTestsProvider: () -> Bool
    private let authorizer: NotificationAuthorizing
    private let requestDeliverer: NotificationRequestDelivering
    private let categoryRegistrar: NotificationCategoryRegistering

    /// Returns true if running in test environment (XCTest, Swift Testing, or CI)
    private var isRunningTests: Bool {
        isRunningTestsProvider()
    }

    private init() {
        self.isRunningTestsProvider = {
            let env = ProcessInfo.processInfo.environment
            return NSClassFromString("XCTestCase") != nil ||
                   env["XCTestConfigurationFilePath"] != nil ||
                   env["XCTestBundlePath"] != nil ||
                   env["GITHUB_ACTIONS"] != nil ||
                   env["CI"] != nil
        }
        if isRunningTestsProvider() {
            self.authorizer = NoopNotificationAuthorizer()
            self.requestDeliverer = NoopNotificationRequestDeliverer()
            self.categoryRegistrar = NoopNotificationCategoryRegistrar()
        } else {
            let center = UNUserNotificationCenter.current()
            self.authorizer = NotificationCenterAuthorizerAdapter(center: center)
            self.requestDeliverer = NotificationCenterRequestDelivererAdapter(center: center)
            self.categoryRegistrar = NotificationCenterCategoryRegistrarAdapter(center: center)
        }
    }

    internal init(
        isRunningTestsProvider: @escaping () -> Bool,
        authorizer: NotificationAuthorizing,
        requestDeliverer: NotificationRequestDelivering,
        categoryRegistrar: NotificationCategoryRegistering = NoopNotificationCategoryRegistrar()
    ) {
        self.isRunningTestsProvider = isRunningTestsProvider
        self.authorizer = authorizer
        self.requestDeliverer = requestDeliverer
        self.categoryRegistrar = categoryRegistrar
    }

    func requestAuthorization() {
        guard !isRunningTests else { return }
        registerCategories()
        authorizer.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            if granted {
                // Permission granted
            } else {
                // Permission denied
            }
        }
    }

    private func registerCategories() {
        let wave = UNNotificationAction(
            identifier: Self.waveActionID,
            title: String(localized: "notification.action.wave", comment: "Title of the notification action button that sends a friendly wave back to a nearby person"),
            options: []
        )
        let nearby = UNNotificationCategory(
            identifier: Self.nearbyCategoryID,
            actions: [wave],
            intentIdentifiers: [],
            options: []
        )
        categoryRegistrar.setCategories([nearby])
    }
    
    func sendLocalNotification(
        title: String,
        body: String,
        identifier: String,
        userInfo: [String: Any]? = nil,
        interruptionLevel: UNNotificationInterruptionLevel = .active,
        categoryIdentifier: String? = nil
    ) {
        guard !isRunningTests else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = interruptionLevel
        if let categoryIdentifier = categoryIdentifier {
            content.categoryIdentifier = categoryIdentifier
        }

        if let userInfo = userInfo {
            content.userInfo = userInfo
        }

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil // Deliver immediately
        )

        requestDeliverer.add(request)
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
            interruptionLevel: .timeSensitive,
            categoryIdentifier: Self.nearbyCategoryID
        )
    }
}
