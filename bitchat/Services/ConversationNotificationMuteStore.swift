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

        /// Stable DM key: fingerprint when known, otherwise the routing peer ID.
        static func direct(fingerprint: String?, peerID: String) -> Scope {
            let key = fingerprint?.trimmedOrNilIfEmpty ?? peerID
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
