//
// PrivacyModeSettings.swift
// bitchat
//
// Coordinates the high-level Everyday vs Stealth privacy posture.
// Everyday Mode prioritizes instant startup and daily usability (fast direct
// Nostr relays, encrypted local DM/group history, standard Settings access).
// Stealth Mode activates activist/high-risk defenses (Tor routing, RAM-only
// ephemeral timelines, redacted lock-screen notifications, logo triple-tap
// panic wipe).
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

enum PrivacyMode: String, CaseIterable, Identifiable {
    case everyday
    case stealth

    var id: String { rawValue }
}

enum PrivacyModeSettings {
    static let modeKey = "bitchat.privacyMode"
    static let persistHistoryKey = "bitchat.persistPrivateHistory"
    static let didChangeNotification = Notification.Name("bitchat.privacyModeDidChange")

    /// Active privacy posture. Defaults to `.everyday` for instant, reliable
    /// daily messaging; users can switch to `.stealth` with one tap in Settings.
    static func currentMode(in defaults: UserDefaults = .standard) -> PrivacyMode {
        guard let raw = defaults.string(forKey: modeKey),
              let mode = PrivacyMode(rawValue: raw) else {
            return .everyday
        }
        return mode
    }

    static var mode: PrivacyMode {
        get { currentMode() }
        set {
            setMode(newValue)
        }
    }

    /// Whether private DM and group histories are sealed to encrypted local storage.
    /// Defaults to `true` in Everyday Mode and `false` in Stealth Mode.
    static func shouldPersistPrivateHistory(in defaults: UserDefaults = .standard) -> Bool {
        if currentMode(in: defaults) == .stealth {
            return false
        }
        if let stored = defaults.object(forKey: persistHistoryKey) as? Bool {
            return stored
        }
        return true
    }

    static var persistPrivateHistory: Bool {
        get { shouldPersistPrivateHistory() }
        set {
            setPersistPrivateHistory(newValue)
        }
    }

    static func setPersistPrivateHistory(
        _ enabled: Bool,
        in defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        defaults.set(enabled, forKey: persistHistoryKey)
        notificationCenter.post(name: didChangeNotification, object: nil)
    }

    /// Whether the hidden triple-tap panic wipe gesture on the header logo is armed.
    /// Armed in Stealth Mode; in Everyday Mode panic wipe remains available in Settings.
    static func isTripleTapPanicEnabled(in defaults: UserDefaults = .standard) -> Bool {
        currentMode(in: defaults) == .stealth
    }

    static func setMode(
        _ newMode: PrivacyMode,
        in defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        defaults.set(newMode.rawValue, forKey: modeKey)
        switch newMode {
        case .everyday:
            defaults.set(true, forKey: persistHistoryKey)
        case .stealth:
            defaults.set(false, forKey: persistHistoryKey)
        }
        notificationCenter.post(name: didChangeNotification, object: nil)
    }

    /// Applies a full mode switch across Tor routing, notification redaction,
    /// and local encrypted history persistence.
    @MainActor
    static func applyMode(
        _ newMode: PrivacyMode,
        in defaults: UserDefaults = .standard,
        networkActivation: NetworkActivationService? = nil,
        onClearPersistedHistory: (() -> Void)? = nil
    ) {
        let activation = networkActivation ?? .shared
        setMode(newMode, in: defaults)
        switch newMode {
        case .everyday:
            activation.setUserTorEnabled(false)
        case .stealth:
            activation.setUserTorEnabled(true)
            NotificationPrivacySettings.setHideMessagePreviews(true, in: defaults)
            onClearPersistedHistory?()
        }
    }

    static func reset(
        in defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        defaults.removeObject(forKey: modeKey)
        defaults.removeObject(forKey: persistHistoryKey)
        notificationCenter.post(name: didChangeNotification, object: nil)
    }
}
