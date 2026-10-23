//
// PanicGestureSettings.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// What a triple-tap on the `bitchat/` logo does.
///
/// The gesture sits on the same 18pt text whose single tap opens App Info, so
/// it is easy to fire by accident — and it destroys identity, keys, and every
/// message. It is also the fastest way to wipe a phone that is about to be
/// taken from you. Those two facts pull in opposite directions, and which one
/// dominates depends on the person holding the device, so it is theirs to set.
///
/// The settings-pane panic button is unaffected by this preference: it always
/// confirms, and it works in every mode.
enum PanicGestureMode: String, CaseIterable, Identifiable {
    /// The third tap wipes, no questions asked.
    case instant
    /// The third tap raises the same confirmation the settings button shows.
    case confirm
    /// The gesture does nothing; only the settings button can wipe.
    case off

    var id: String { rawValue }
}

/// Persistence for `PanicGestureMode`.
enum PanicGestureSettings {
    static let storageKey = "panic.gestureMode"

    /// What a fresh install gets. Confirm-first, because that is the behavior
    /// the app ships with today — a preference nobody has set must not quietly
    /// re-arm an instant wipe on someone who never asked for one.
    static let installDefault: PanicGestureMode = .confirm

    /// What a panic wipe leaves behind. Deliberately *not* `installDefault`:
    /// someone who just wiped under duress is on the seizure path, and the
    /// next wipe should not cost them a dialog.
    static let postWipeMode: PanicGestureMode = .instant

    static var mode: PanicGestureMode {
        get { mode(in: .standard) }
        set { setMode(newValue, in: .standard) }
    }

    /// Store-injecting forms, so tests can assert every mode without touching
    /// the shared preferences other tests read.
    ///
    /// A missing or unrecognized value reads as `installDefault`: a preference
    /// written by an older build, half-written, or edited by hand must not
    /// silently disarm the confirmation.
    static func mode(in defaults: UserDefaults) -> PanicGestureMode {
        guard let raw = defaults.string(forKey: storageKey),
              let mode = PanicGestureMode(rawValue: raw) else {
            return installDefault
        }
        return mode
    }

    static func setMode(_ mode: PanicGestureMode, in defaults: UserDefaults) {
        defaults.set(mode.rawValue, forKey: storageKey)
    }

    /// Panic-wipe hook. This *writes* `postWipeMode` rather than removing the
    /// key: clearing it would fall back to `installDefault` (confirm), and a
    /// device that was just wiped under duress should come back with the
    /// gesture armed, not asking. Nothing about the pre-wipe choice survives —
    /// the value written is a constant, not whatever was there before.
    static func resetForPanicWipe(in defaults: UserDefaults = .standard) {
        setMode(postWipeMode, in: defaults)
    }
}
