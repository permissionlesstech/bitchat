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
/// Defaults to **confirm**, which is exactly the behaviour #1509 shipped: the
/// gesture is armed and asks before wiping. That matters more than it looks —
/// the logo is also the single-tap App Info entry point, so a fumbled tap must
/// not be able to wipe the device, and an update must not silently move anyone
/// off the behaviour they already have.
///
/// People who need the seizure path — someone taking the phone out of your
/// hand — can opt into an instant wipe. Turning the gesture off entirely is
/// also allowed; the settings panic button still wipes after its own confirm.
///
/// There is no legacy-key migration: #1509 never wrote a preference key, so
/// every existing install arrives here with nothing stored and takes the
/// default.
///
/// One type, one `reset()`, one danger-zone control — do not split this across
/// parallel settings enums.
enum PanicWipeSettings {
    private static let modeKey = "panic.logoShortcutMode"

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
        guard let raw = defaults.string(forKey: modeKey),
              let mode = LogoShortcutMode(rawValue: raw) else {
            return .confirm
        }
        return mode
    }

    static func setLogoShortcutMode(_ mode: LogoShortcutMode, in defaults: UserDefaults) {
        defaults.set(mode.rawValue, forKey: modeKey)
    }

    /// Panic-wipe hook. Removing the key restores the confirm default, so a
    /// wiped device comes back with the gesture armed rather than absent.
    static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: modeKey)
    }
}
