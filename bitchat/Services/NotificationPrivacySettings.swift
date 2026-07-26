//
// NotificationPrivacySettings.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Controls how much a delivered notification says while the device is locked.
///
/// Notification content is rendered by the system on the lock screen, so it is
/// readable by anyone holding the phone without unlocking it. With previews
/// hidden, alerts still say that something arrived and stay tappable, but the
/// message body, the sender's nickname, and the geohash are withheld until the
/// app is opened.
///
/// Defaults to hidden: a locked phone lying on a table or taken at a protest
/// should not narrate conversations, and someone who wants previews can say so.
enum NotificationPrivacySettings {
    private static let hidePreviewsKey = "notifications.hideMessagePreviews"

    static var hideMessagePreviews: Bool {
        get { hideMessagePreviews(in: .standard) }
        set { setHideMessagePreviews(newValue, in: .standard) }
    }

    /// Store-injecting forms, so tests can assert the default and both settings
    /// without touching the shared preferences other tests read.
    static func hideMessagePreviews(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: hidePreviewsKey) as? Bool ?? true
    }

    static func setHideMessagePreviews(_ hide: Bool, in defaults: UserDefaults) {
        defaults.set(hide, forKey: hidePreviewsKey)
    }

    /// Panic-wipe hook. Removing the key restores the hidden default, so a
    /// wiped device cannot come back louder than a fresh install.
    static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: hidePreviewsKey)
    }
}
