//
// BridgeDropDedupStore.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import Foundation

/// ID set with per-entry timestamps: entries expire after `lifetime` and the
/// oldest are evicted past `capacity`. The bridge's dedup caches use this
/// instead of `BoundedIDSet` because their contents persist across relaunches
/// and must age out with the 24h drop window they guard.
struct ExpiringIDSet {
    private var cache: BoundedCache<String, Date>

    var entries: [String: Date] { cache.allValues }

    init(capacity: Int, lifetime: TimeInterval, entries: [String: Date] = [:], now: Date = Date()) {
        var cache = BoundedCache<String, Date>(capacity: capacity, ttl: lifetime)
        // Insert persisted entries in chronological order so oldest age out first.
        for (id, recorded) in entries.sorted(by: { $0.value < $1.value })
        where now.timeIntervalSince(recorded) <= lifetime {
            cache.set(id, value: recorded, now: recorded, refreshOrder: true)
        }
        cache.pruneExpired(now: now)
        self.cache = cache
    }

    func contains(_ id: String, now: Date) -> Bool {
        cache.contains(id, now: now)
    }

    /// Returns false when the ID was already present (and unexpired).
    @discardableResult
    mutating func insert(_ id: String, now: Date) -> Bool {
        guard !contains(id, now: now) else { return false }
        cache.set(id, value: now, now: now, refreshOrder: true)
        return true
    }

    /// Releases a previously inserted ID so it can be re-added later (e.g. a
    /// queued drop evicted before it ever published must become retryable).
    mutating func remove(_ id: String) {
        cache.remove(id)
    }
}

/// Disk persistence for the bridge courier's drop-dedup record. Relays hold
/// drops for the full 24h NIP-40 window and redeliver them on every launch,
/// and the 120s outbox sweep re-deposits anything undelivered — so with
/// in-memory-only dedup every relaunch republished the same message as a
/// fresh drop (fresh throwaway seal, undeduplicatable downstream) and every
/// gateway relaunch re-delivered the whole backlog. Field-verified: ~20
/// copies of one DM delivered in 40ms fed the storm behind a permanent
/// device freeze. Persisting both sides caps this at one drop per
/// recipient/message pair per 24h regardless of relaunch count.
///
/// Contents are opaque hashes and relay event IDs — no plaintext or peer
/// identities — so until-first-unlock protection matches
/// `NostrProcessedEventStore`, and the file must load during a
/// locked-background restoration relaunch. Wiped on panic with the rest of
/// the courier state.
final class BridgeDropDedupStore {
    struct Snapshot: Codable {
        var publishedDropKeys: [String: Date]
        var seenDropEventIDs: [String: Date]
    }

    private let fileStore: AppSupportFileStore

    /// - Parameter fileURL: Overrides the on-disk location (tests). Ignored
    ///   when `persistsToDisk` is false.
    init(persistsToDisk: Bool = true, fileURL: URL? = nil) {
        self.fileStore = AppSupportFileStore(
            persistsToDisk: persistsToDisk,
            fileURL: fileURL,
            subdirectory: "courier",
            fileName: "bridge-drop-dedup.json",
            protection: .untilFirstUserAuthentication
        )
    }

    func load() -> Snapshot {
        (try? fileStore.loadJSON(Snapshot.self))
            ?? Snapshot(publishedDropKeys: [:], seenDropEventIDs: [:])
    }

    func save(_ snapshot: Snapshot) {
        do {
            try fileStore.saveJSON(
                snapshot,
                isEmpty: snapshot.publishedDropKeys.isEmpty && snapshot.seenDropEventIDs.isEmpty
            )
        } catch {
            SecureLogger.error("Failed to persist bridge drop dedup record: \(error)", category: .session)
        }
    }

    /// Panic wipe: forget which drops we published or handled.
    func wipe() {
        fileStore.removeIgnoringErrors()
    }
}
