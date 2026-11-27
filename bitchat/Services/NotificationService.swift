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

final class NotificationService {
    struct Dependencies {
        var requestAuthorization: (UNAuthorizationOptions, @escaping (Bool, Error?) -> Void) -> Void
        var deliver: (UNNotificationRequest) -> Void
        var setCategories: (Set<UNNotificationCategory>) -> Void
        var removeAllDelivered: () -> Void
        var removeAllPending: () -> Void

        static let noop = Dependencies(
            requestAuthorization: { _, completion in completion(false, nil) },
            deliver: { _ in },
            setCategories: { _ in },
            removeAllDelivered: {},
            removeAllPending: {}
        )

        static func system(center: UNUserNotificationCenter = .current()) -> Dependencies {
            Dependencies(
                requestAuthorization: { options, completion in
                    center.requestAuthorization(options: options, completionHandler: completion)
                },
                deliver: { request in
                    Task {
                        try? await center.add(request)
                    }
                },
                setCategories: { categories in
                    center.setNotificationCategories(categories)
                },
                removeAllDelivered: {
                    center.removeAllDeliveredNotifications()
                },
                removeAllPending: {
                    center.removeAllPendingNotificationRequests()
                }
            )
        }
    }

    static let shared = NotificationService()

    /// Category for the "bitchatters nearby" notification, carrying the wave quick action.
    static let nearbyCategoryID = "chat.bitchat.category.nearby"
    static let waveActionID = "chat.bitchat.action.wave"

    /// Copy used when `NotificationPrivacySettings.hideMessagePreviews` is on.
    /// These say that something arrived without naming who sent it, quoting it,
    /// or disclosing which geohash it came from.
    private enum Redacted {
        static var directMessageTitle: String {
            String(localized: "notification.redacted.dm.title", defaultValue: "🔒 new dm", comment: "Lock-screen notification title for a received direct message when message previews are hidden; deliberately names neither the sender nor the content")
        }
        static var mentionTitle: String {
            String(localized: "notification.redacted.mention.title", defaultValue: "🫵 you were mentioned", comment: "Lock-screen notification title telling someone they were mentioned when message previews are hidden; deliberately omits who mentioned them")
        }
        static var geohashActivityTitle: String {
            String(localized: "notification.redacted.geohash.title", defaultValue: "📍 new activity nearby", comment: "Lock-screen notification title for activity in a location channel when message previews are hidden; deliberately omits the geohash")
        }
        static var verificationTitle: String {
            String(localized: "notification.redacted.verification.title", defaultValue: "✅ peer verified", comment: "Lock-screen notification title for peer verification when message previews are hidden; deliberately omits the peer nickname")
        }
        static var body: String {
            String(localized: "notification.redacted.body", defaultValue: "open bitchat to read", comment: "Lock-screen notification body shown in place of the message text when message previews are hidden")
        }
    }

    /// Whether delivered alerts must withhold sender, content, and geohash.
    ///
    /// Injected rather than read from the preference directly so tests state
    /// which behavior they are asserting instead of inheriting whatever the
    /// shared preference happens to hold when they run.
    private let hidePreviewsProvider: () -> Bool

    private var hidePreviews: Bool {
        hidePreviewsProvider()
    }

    private let isRunningTestsProvider: () -> Bool
    private let dependencies: Dependencies

    /// Returns true if running in test environment (XCTest, Swift Testing, or CI)
    private var isRunningTests: Bool {
        isRunningTestsProvider()
    }

    private init() {
        self.hidePreviewsProvider = { NotificationPrivacySettings.hideMessagePreviews }
        self.isRunningTestsProvider = { TestEnvironment.isRunningTests }
        self.dependencies = TestEnvironment.isRunningTests ? .noop : .system()
    }

    internal init(
        isRunningTestsProvider: @escaping () -> Bool = { TestEnvironment.isRunningTests },
        dependencies: Dependencies = .noop,
        hidePreviewsProvider: @escaping () -> Bool = { NotificationPrivacySettings.hideMessagePreviews }
    ) {
        self.isRunningTestsProvider = isRunningTestsProvider
        self.dependencies = dependencies
        self.hidePreviewsProvider = hidePreviewsProvider
    }

    /// Panic-wipe hook: removes all delivered and pending local notifications
    /// from Notification Center so sender names, previews, and routing metadata
    /// cannot linger on a seized device after a wipe.
    func clearAllNotificationsForPanic() {
        guard !isRunningTests else { return }
        dependencies.removeAllPending()
        dependencies.removeAllDelivered()
    }

    func requestAuthorization() {
        guard !isRunningTests else { return }
        registerCategories()
        dependencies.requestAuthorization([.alert, .sound, .badge]) { _, _ in }
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
        dependencies.setCategories([nearby])
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

        dependencies.deliver(request)
    }

    func sendMentionNotification(from sender: String, message: String) {
        let title = hidePreviews ? Redacted.mentionTitle : "🫵 you were mentioned by \(sender)"
        let body = hidePreviews ? Redacted.body : message
        let identifier = "mention-\(UUID().uuidString)"

        sendLocalNotification(title: title, body: body, identifier: identifier)
    }

    func sendPrivateMessageNotification(from sender: String, message: String, peerID: PeerID) {
        let title = hidePreviews ? Redacted.directMessageTitle : "🔒 DM from \(sender)"
        let body = hidePreviews ? Redacted.body : message
        let identifier = "private-\(UUID().uuidString)"
        // Routing payload, not display copy: `userInfo` never reaches the lock
        // screen, and the conversation to open still has to be identifiable.
        let userInfo = ["peerID": peerID.id, "senderName": sender]

        sendLocalNotification(title: title, body: body, identifier: identifier, userInfo: userInfo)
    }

    // Geohash public chat notification with deep link to a specific geohash
    func sendGeohashActivityNotification(geohash: String, titlePrefix: String = "#", bodyPreview: String) {
        // The geohash itself is location data, so hiding previews withholds it
        // from the alert while leaving the deep link intact for the tap.
        let title = hidePreviews ? Redacted.geohashActivityTitle : "\(titlePrefix)\(geohash)"
        let body = hidePreviews ? Redacted.body : bodyPreview
        let identifier = "geo-activity-\(geohash)-\(Date().timeIntervalSince1970)"
        let deeplink = "bitchat://geohash/\(geohash)"
        let userInfo: [String: Any] = ["deeplink": deeplink]
        sendLocalNotification(title: title, body: body, identifier: identifier, userInfo: userInfo)
    }

    func sendVerificationNotification(title: String, body: String, identifier: String) {
        let resolvedTitle = hidePreviews ? Redacted.verificationTitle : title
        let resolvedBody = hidePreviews ? Redacted.body : body
        sendLocalNotification(title: resolvedTitle, body: resolvedBody, identifier: identifier)
    }

    func sendNetworkAvailableNotification(peerCount: Int) {
        let title = String(localized: "notification.nearby.title", defaultValue: "👥 bitchatters nearby!", comment: "Title of the local notification when mesh peers come into range")
        let body = peerCount == 1
            ? String(localized: "notification.nearby.body_one", defaultValue: "1 person around", comment: "Body of the nearby notification for exactly one peer")
            : String(format: String(localized: "notification.nearby.body_many", defaultValue: "%lld people around", comment: "Body of the nearby notification; placeholder is the peer count"), locale: .current, peerCount)
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
