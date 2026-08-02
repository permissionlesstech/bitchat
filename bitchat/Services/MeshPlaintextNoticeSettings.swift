//
// MeshPlaintextNoticeSettings.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Tracks whether the mesh plaintext notice has been dismissed (#1064).
///
/// Non-breaking security UX: #mesh stays the default channel, but people see
/// a clear reminder that mesh traffic is an unencrypted local broadcast.
enum MeshPlaintextNoticeSettings {
    private static let dismissedKey = "security.meshPlaintextNoticeDismissed"

    static var isDismissed: Bool {
        get { isDismissed(in: .standard) }
        set { setDismissed(newValue, in: .standard) }
    }

    static func isDismissed(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: dismissedKey)
    }

    static func setDismissed(_ dismissed: Bool, in defaults: UserDefaults) {
        defaults.set(dismissed, forKey: dismissedKey)
    }

    static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: dismissedKey)
    }
}
