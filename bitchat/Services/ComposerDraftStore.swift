//
// ComposerDraftStore.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Persists unfinished composer text per conversation so switching mesh /
/// geohash / DM channels does not silently discard what someone was typing.
///
/// Drafts are plain text in UserDefaults (same trust boundary as nickname and
/// theme). Panic wipe clears the whole map so a seized phone does not keep
/// half-written messages.
enum ComposerDraftStore {
    static let storageKey = "composer.drafts.v1"
    /// Cap each draft so a pasted novel cannot bloat preferences forever.
    static let maxDraftLength = 8_000
    /// Cap how many conversations keep a draft; oldest keys fall off first.
    static let maxDraftCount = 64

    enum Key: Hashable, Equatable {
        case mesh
        case location(geohash: String)
        case privatePeer(PeerID)

        var storageString: String {
            switch self {
            case .mesh:
                return "mesh"
            case .location(let geohash):
                return "geo:\(geohash.lowercased())"
            case .privatePeer(let peerID):
                return "dm:\(peerID.id)"
            }
        }

        static func from(peerID: PeerID?, channel: ChannelID) -> Key {
            if let peerID {
                return .privatePeer(peerID)
            }
            switch channel {
            case .mesh:
                return .mesh
            case .location(let ch):
                return .location(geohash: ch.geohash)
            }
        }
    }

    static func load(_ key: Key, in defaults: UserDefaults = .standard) -> String {
        let map = readMap(in: defaults)
        return map[key.storageString] ?? ""
    }

    static func save(_ text: String, for key: Key, in defaults: UserDefaults = .standard) {
        var map = readMap(in: defaults)
        let trimmed = String(text.prefix(maxDraftLength))
        if trimmed.isEmpty {
            map.removeValue(forKey: key.storageString)
        } else {
            map[key.storageString] = trimmed
            if map.count > maxDraftCount {
                // Drop an arbitrary surplus key that is not the one just written.
                let surplus = map.keys.filter { $0 != key.storageString }.prefix(map.count - maxDraftCount)
                for doomed in surplus {
                    map.removeValue(forKey: doomed)
                }
            }
        }
        writeMap(map, in: defaults)
    }

    static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }

    private static func readMap(in defaults: UserDefaults) -> [String: String] {
        defaults.dictionary(forKey: storageKey) as? [String: String] ?? [:]
    }

    private static func writeMap(_ map: [String: String], in defaults: UserDefaults) {
        if map.isEmpty {
            defaults.removeObject(forKey: storageKey)
        } else {
            defaults.set(map, forKey: storageKey)
        }
    }
}
