//
// LocationNotesSettings.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// User preference for location notes (dead drops): leaving notes pinned to
/// nearby places with /drop and surfacing notes others left here. On by
/// default, but everything it powers additionally requires location
/// permission — the toggle in app info is the kill switch.
enum LocationNotesSettings {
    private static let enabledKey = "locationNotes.enabled"

    /// Fired on every toggle write so live consumers (the nearby-notes
    /// counter) can drop or restart their relay subscription immediately.
    static let didChangeNotification = Notification.Name("bitchat.locationNotesSettingsDidChange")

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }
}
