//
// PanicWipeSettings.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Controls whether the undiscoverable `bitchat/` logo triple-tap asks before
/// wiping.
///
/// The shortcut exists for the seizure path — someone taking the phone out of
/// your hand — so it defaults to an instant wipe. People who fear accidental
/// taps can opt into a confirmation step; that trade-off costs the seconds the
/// feature is built around.
enum PanicWipeSettings {
    private static let confirmLogoShortcutKey = "panic.confirmLogoShortcut"

    /// When `true`, triple-tapping the logo shows the same confirmation dialog
    /// as the settings panic button. Defaults to `false` (instant wipe).
    static var confirmLogoShortcut: Bool {
        get { confirmLogoShortcut(in: .standard) }
        set { setConfirmLogoShortcut(newValue, in: .standard) }
    }

    static func confirmLogoShortcut(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: confirmLogoShortcutKey) as? Bool ?? false
    }

    static func setConfirmLogoShortcut(_ confirm: Bool, in defaults: UserDefaults) {
        defaults.set(confirm, forKey: confirmLogoShortcutKey)
    }

    /// Panic-wipe hook. Removing the key restores the instant default.
    static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: confirmLogoShortcutKey)
    }
}
