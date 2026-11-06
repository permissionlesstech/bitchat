//
// SpamFilterSettings.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// The user's on/off choice for `SpamFilter.shared`, on by default.
enum SpamFilterSettings {
    private static let enabledKey = "spamFilter.enabled"

    static var isEnabled: Bool {
        get { isEnabled(in: .standard) }
        set { setEnabled(newValue, in: .standard, filter: .shared) }
    }

    /// Store-injecting forms, so tests can assert the default and both settings
    /// without touching the shared preferences other tests read.
    static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    static func setEnabled(_ enabled: Bool, in defaults: UserDefaults, filter: SpamFilter) {
        guard isEnabled(in: defaults) != enabled || filter.enabled != enabled else { return }
        defaults.set(enabled, forKey: enabledKey)
        filter.enabled = enabled
        // Start from a clean slate so budgets don't carry over from before the toggle.
        filter.reset()
    }

    /// Panic-wipe hook: restores the default and forgets the recent message
    /// text and sender keys the filter keeps for its repeat checks.
    static func reset(in defaults: UserDefaults = .standard, filter: SpamFilter = .shared) {
        defaults.removeObject(forKey: enabledKey)
        filter.enabled = isEnabled(in: defaults)
        filter.reset()
    }
}
