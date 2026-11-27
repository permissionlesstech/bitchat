//
// ComposerDraftStore.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import BitFoundation

/// Holds unfinished composer text per conversation so switching mesh /
/// geohash / DM channels does not silently discard what someone was typing.
///
/// Drafts stay **in memory only** — message content must not land in
/// UserDefaults (see MessageOutboxStore: only the sealed outbox persists
/// plaintext). Losing a draft on process death is acceptable; surviving a
/// channel/DM switch is the value.
///
/// Panic wipe clears the whole map so a seized phone does not keep
/// half-written messages in RAM either.
enum ComposerDraftStore {
    /// Cap each draft so a pasted novel cannot bloat the map forever.
    static let maxDraftLength = 8_000
    /// Cap how many conversations keep a draft; oldest entries fall off first.
    static let maxDraftCount = 64

    private static var cache = BoundedCache<String, String>(capacity: maxDraftCount)
    private static let lock = NSLock()

    enum Key: Hashable, Equatable {
        case mesh
        case location(geohash: String)
        /// Mesh DM keyed by Noise fingerprint when known; falls back to the
        /// current peerID only before handshake so drafts do not orphan on
        /// peerID rotation mid-session.
        case privateChat(stableID: String)

        var storageString: String {
            switch self {
            case .mesh:
                return "mesh"
            case .location(let geohash):
                return "geo:\(geohash.lowercased())"
            case .privateChat(let stableID):
                return "dm:\(stableID.lowercased())"
            }
        }

        static func from(
            peerID: PeerID?,
            fingerprint: String?,
            channel: ChannelID
        ) -> Key {
            if let peerID {
                if let fingerprint, !fingerprint.isEmpty {
                    return .privateChat(stableID: fingerprint)
                }
                return .privateChat(stableID: peerID.id)
            }
            switch channel {
            case .mesh:
                return .mesh
            case .location(let ch):
                return .location(geohash: ch.geohash)
            }
        }
    }

    static func load(_ key: Key) -> String {
        lock.withLock { cache.value(for: key.storageString) ?? "" }
    }

    static func save(_ text: String, for key: Key) {
        lock.withLock {
            let trimmed = String(text.prefix(maxDraftLength))
            if trimmed.isEmpty {
                cache.remove(key.storageString)
            } else {
                cache.set(key.storageString, value: trimmed, refreshOrder: true)
            }
        }
    }

    static func reset() {
        lock.withLock { cache.removeAll(keepingCapacity: false) }
    }

    /// Test helper: replace the in-memory map (and return the previous one).
    @discardableResult
    static func replaceAllForTesting(_ newEntries: [String: String] = [:]) -> [String: String] {
        lock.withLock {
            let previous = cache.allValues
            cache.removeAll(keepingCapacity: false)
            for (key, value) in newEntries {
                cache.set(key, value: value, refreshOrder: true)
            }
            return previous
        }
    }

    static func countForTesting() -> Int {
        lock.withLock { cache.count }
    }
}
