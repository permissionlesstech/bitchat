//
// PanicWipeSettings.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Controls how the undiscoverable `bitchat/` logo triple-tap behaves.
///
/// The shortcut exists for the seizure path — someone taking the phone out of
/// your hand — so it defaults to an **instant** wipe. People who fear
/// accidental taps can opt into a confirmation step, or turn the gesture off
/// entirely (the settings panic button still wipes after its own confirm).
///
/// One type, one `reset()`, one danger-zone control — do not split this across
/// parallel settings enums.
enum PanicWipeSettings {
    private static let modeKey = "panic.logoShortcutMode"
    /// Legacy keys from the confirm-only (#1509) and enable-only (#1575) shapes.
    private static let legacyConfirmKey = "panic.confirmLogoShortcut"
    private static let legacyEnabledKey = "panic.logoShortcutEnabled"

    enum LogoShortcutMode: String, CaseIterable, Identifiable {
        case instant
        case confirm
        case off

        var id: String { rawValue }
    }

    static var logoShortcutMode: LogoShortcutMode {
        get { logoShortcutMode(in: .standard) }
        set { setLogoShortcutMode(newValue, in: .standard) }
    }

    static func logoShortcutMode(in defaults: UserDefaults) -> LogoShortcutMode {
        if let raw = defaults.string(forKey: modeKey),
           let mode = LogoShortcutMode(rawValue: raw) {
            return mode
        }
        // Migrate older single-boolean shapes without losing the person's choice.
        if defaults.object(forKey: legacyEnabledKey) as? Bool == false {
            return .off
        }
        if defaults.object(forKey: legacyConfirmKey) as? Bool == true {
            return .confirm
        }
        return .instant
    }

    static func setLogoShortcutMode(_ mode: LogoShortcutMode, in defaults: UserDefaults) {
        defaults.set(mode.rawValue, forKey: modeKey)
        defaults.removeObject(forKey: legacyConfirmKey)
        defaults.removeObject(forKey: legacyEnabledKey)
    }

    /// Panic-wipe hook. Removing the keys restores the instant default.
    static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: modeKey)
        defaults.removeObject(forKey: legacyConfirmKey)
        defaults.removeObject(forKey: legacyEnabledKey)
    }
}
