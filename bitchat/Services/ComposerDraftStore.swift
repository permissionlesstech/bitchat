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

    private struct Entry {
        var text: String
        var updatedAt: Date
    }

    private static var entries: [String: Entry] = [:]
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
        lock.lock()
        defer { lock.unlock() }
        return entries[key.storageString]?.text ?? ""
    }

    static func save(_ text: String, for key: Key) {
        lock.lock()
        defer { lock.unlock() }
        let trimmed = String(text.prefix(maxDraftLength))
        if trimmed.isEmpty {
            entries.removeValue(forKey: key.storageString)
        } else {
            entries[key.storageString] = Entry(text: trimmed, updatedAt: Date())
            evictOldestIfNeededLocked()
        }
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll(keepingCapacity: false)
    }

    /// Test helper: replace the in-memory map (and return the previous one).
    @discardableResult
    static func replaceAllForTesting(_ newEntries: [String: String] = [:]) -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        let previous = entries.mapValues(\.text)
        let now = Date()
        entries = Dictionary(uniqueKeysWithValues: newEntries.map { ($0.key, Entry(text: $0.value, updatedAt: now)) })
        return previous
    }

    static func countForTesting() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    private static func evictOldestIfNeededLocked() {
        guard entries.count > maxDraftCount else { return }
        let surplus = entries.count - maxDraftCount
        let doomed = entries
            .sorted { $0.value.updatedAt < $1.value.updatedAt }
            .prefix(surplus)
            .map(\.key)
        for key in doomed {
            entries.removeValue(forKey: key)
        }
    }
}
