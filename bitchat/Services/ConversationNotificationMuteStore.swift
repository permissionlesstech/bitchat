//
// ConversationNotificationMuteStore.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Persistent mute preferences for individual conversations (#1594).
///
/// Muted conversations still receive and store messages; only local
/// notifications are suppressed. Keys prefer stable fingerprints for DMs and
/// lowercase geohashes for location channels.
enum ConversationNotificationMuteStore {
    private static let mutedKeysDefaultsKey = "notifications.mutedConversationKeys"

    enum Scope: Hashable, Equatable {
        case direct(identityKey: String)
        case geohash(String)

        var storageKey: String {
            switch self {
            case .direct(let identityKey):
                return "dm:\(identityKey.lowercased())"
            case .geohash(let geohash):
                return "geo:\(geohash.lowercased())"
            }
        }

        /// Stable DM key, or `nil` when no fingerprint is known yet.
        ///
        /// There is deliberately no routing-peer-ID fallback. Peer IDs rotate,
        /// so a mute keyed on one would stop applying after the next rotation
        /// while the UI still showed the conversation as muted — worse than
        /// refusing to mute at all. Callers must treat `nil` as "cannot mute
        /// yet" (see `PrivateConversationModel.canToggleSelectedConversationNotificationMute`).
        ///
        /// Both the toggle and the notification path resolve the fingerprint
        /// through `stableConversationIdentity(for:)`, so the key written and
        /// the key looked up cannot disagree.
        static func direct(fingerprint: String?) -> Scope? {
            guard let key = fingerprint?.trimmedOrNilIfEmpty else { return nil }
            return .direct(identityKey: key)
        }
    }

    static func isMuted(_ scope: Scope, in defaults: UserDefaults = .standard) -> Bool {
        mutedKeys(in: defaults).contains(scope.storageKey)
    }

    static func setMuted(_ muted: Bool, for scope: Scope, in defaults: UserDefaults = .standard) {
        var keys = mutedKeys(in: defaults)
        if muted {
            keys.insert(scope.storageKey)
        } else {
            keys.remove(scope.storageKey)
        }
        defaults.set(Array(keys).sorted(), forKey: mutedKeysDefaultsKey)
    }

    static func mutedKeys(in defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: mutedKeysDefaultsKey) ?? [])
    }

    /// Panic-wipe hook: a wiped device should not inherit another person's
    /// notification preferences.
    static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: mutedKeysDefaultsKey)
    }
}
