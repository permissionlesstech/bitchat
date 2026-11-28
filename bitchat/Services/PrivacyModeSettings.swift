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
    static let migrationCompletedKey = "bitchat.privacyMode.migrationV2Completed"
    static let didChangeNotification = Notification.Name("bitchat.privacyModeDidChange")

    /// Pre-2.0 keys written on every 1.x launch or user session. Presence of any
    /// of these while `modeKey` is absent proves this container is an upgrade from
    /// 1.x (where Tor defaulted ON and private timelines were RAM-only), not a
    /// fresh 2.0 install.
    static let legacyInstallIndicatorKeys: [String] = [
        "keychain.installLifecycleMarker.present",
        "bitchat.nickname",
        NetworkActivationService.torPreferenceKey,
        "appInfo.selectedPane",
        "bitchat.favorites",
        "locationChannels.bookmarkedGeohashes",
        "locationChannels.selectedChannel",
        "notifications.hideMessagePreviews"
    ]

    /// Runs once at app launch (before `KeychainManager`, `ChatViewModel`, or
    /// `NetworkActivationService` touch `UserDefaults` or open any socket) so an
    /// upgrading 1.x user never silently loses Tor routing or RAM-only history
    /// before choosing a 2.0 privacy mode.
    ///
    /// - 1.x upgrade with unset or `true` Tor preference → pins `userTorEnabled = true`,
    ///   sets `.stealth` mode, and keeps `persistPrivateHistory = false` (RAM-only,
    ///   triple-tap wipe armed) until the user explicitly chooses Everyday Mode.
    /// - 1.x upgrade with explicit `false` Tor preference → keeps `userTorEnabled = false`
    ///   and keeps `persistPrivateHistory = false` (RAM-only) until the user chooses.
    /// - Fresh 2.0 install (no legacy keys) → marks migration complete and leaves
    ///   2.0's `.everyday` defaults intact.
    @discardableResult
    static func migrateLegacyInstallIfNeeded(
        in defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) -> Bool {
        if defaults.string(forKey: modeKey) != nil || defaults.bool(forKey: migrationCompletedKey) {
            return false
        }

        let hasLegacyState = legacyInstallIndicatorKeys.contains { key in
            defaults.object(forKey: key) != nil
        }

        defer {
            defaults.set(true, forKey: migrationCompletedKey)
        }

        guard hasLegacyState else {
            return false
        }

        let explicitLegacyTor = defaults.object(forKey: NetworkActivationService.torPreferenceKey) as? Bool
        if explicitLegacyTor == false {
            // User explicitly opted out of Tor in 1.x: preserve direct relays,
            // keep 1.x's RAM-only history until they opt in to Everyday Mode.
            defaults.set(PrivacyMode.everyday.rawValue, forKey: modeKey)
            defaults.set(false, forKey: persistHistoryKey)
        } else {
            // User relied on 1.x's Tor-on default (unset or explicit true):
            // pin Tor ON fail-closed and keep Stealth Mode (RAM-only + triple-tap)
            // until the user explicitly chooses Everyday Mode.
            defaults.set(true, forKey: NetworkActivationService.torPreferenceKey)
            defaults.set(PrivacyMode.stealth.rawValue, forKey: modeKey)
            defaults.set(false, forKey: persistHistoryKey)
        }

        notificationCenter.post(name: didChangeNotification, object: nil)
        return true
    }

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
        let previousMode = currentMode(in: defaults)
        let hasExplicitTorPreference = defaults.object(forKey: NetworkActivationService.torPreferenceKey) != nil
        setMode(newMode, in: defaults)
        switch newMode {
        case .everyday:
            // Turn Tor off when switching away from Stealth or on initial setup,
            // but preserve an explicit user Tor toggle if already in Everyday Mode.
            if previousMode == .stealth || !hasExplicitTorPreference {
                activation.setUserTorEnabled(false)
            }
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

    /// Panic-wipe reset: clears persisted history preferences while preserving
    /// Stealth/Tor posture for users who triggered panic wipe from Stealth Mode
    /// (so wiping never unexpectedly turns disk persistence on or disarms
    /// triple-tap wipe) and keeping the v2 migration marker set so relaunch
    /// does not misclassify the wiped container.
    static func resetForPanic(
        in defaults: UserDefaults = .standard,
        wasTorEnabled: Bool? = nil,
        notificationCenter: NotificationCenter = .default
    ) {
        let wasStealthOrTor = currentMode(in: defaults) == .stealth
            || (wasTorEnabled ?? NetworkActivationService.persistedTorPreference(in: defaults))
        defaults.removeObject(forKey: modeKey)
        defaults.removeObject(forKey: persistHistoryKey)
        defaults.set(true, forKey: migrationCompletedKey)
        if wasStealthOrTor {
            defaults.set(true, forKey: NetworkActivationService.torPreferenceKey)
            defaults.set(PrivacyMode.stealth.rawValue, forKey: modeKey)
            defaults.set(false, forKey: persistHistoryKey)
        }
        notificationCenter.post(name: didChangeNotification, object: nil)
    }
}
