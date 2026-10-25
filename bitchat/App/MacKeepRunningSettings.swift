//
// MacKeepRunningSettings.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

#if os(macOS)

import Foundation

/// Controls whether closing the last window quits bitchat or leaves Tor and
/// the BLE mesh relaying from the dock (#1593, #1633).
///
/// Default is off: closing the window should stop the radios, matching what
/// most people expect from a privacy-first messenger. Minimize/occlusion
/// keep-alive is handled separately via `RelayActivityAssertion`.
enum MacKeepRunningSettings {
    private static let enabledKey = "macos.keepRunningWhenWindowClosed"

    /// When true, the process survives after the last window closes.
    static var enabled: Bool {
        get { enabled(in: .standard) }
        set { setEnabled(newValue, in: .standard) }
    }

    /// Value for `applicationShouldTerminateAfterLastWindowClosed`.
    static func shouldTerminateAfterLastWindowClosed(in defaults: UserDefaults = .standard) -> Bool {
        !enabled(in: defaults)
    }

    static func enabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? false
    }

    static func setEnabled(_ enabled: Bool, in defaults: UserDefaults) {
        defaults.set(enabled, forKey: enabledKey)
    }

    /// Panic-wipe hook. Removing the key restores quit-on-close behaviour.
    static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: enabledKey)
    }
}

#endif
