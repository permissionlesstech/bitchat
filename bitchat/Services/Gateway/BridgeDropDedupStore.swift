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
    private(set) var entries: [String: Date]
    let capacity: Int
    let lifetime: TimeInterval

    init(capacity: Int, lifetime: TimeInterval, entries: [String: Date] = [:], now: Date = Date()) {
        self.capacity = capacity
        self.lifetime = lifetime
        self.entries = entries
        prune(now: now)
    }

    func contains(_ id: String, now: Date) -> Bool {
        guard let recorded = entries[id] else { return false }
        return now.timeIntervalSince(recorded) <= lifetime
    }

    /// Returns false when the ID was already present (and unexpired).
    @discardableResult
    mutating func insert(_ id: String, now: Date) -> Bool {
        guard !contains(id, now: now) else { return false }
        entries[id] = now
        prune(now: now)
        return true
    }

    /// Releases a previously inserted ID so it can be re-added later (e.g. a
    /// queued drop evicted before it ever published must become retryable).
    mutating func remove(_ id: String) {
        entries.removeValue(forKey: id)
    }

    private mutating func prune(now: Date) {
        if entries.contains(where: { now.timeIntervalSince($0.value) > lifetime }) {
            entries = entries.filter { now.timeIntervalSince($0.value) <= lifetime }
        }
        let overflow = entries.count - capacity
        guard overflow > 0 else { return }
        for (id, _) in entries.sorted(by: { $0.value < $1.value }).prefix(overflow) {
            entries.removeValue(forKey: id)
        }
    }
}

/// Disk persistence for the bridge courier's drop-dedup record. Relays hold
/// drops for the full 24h NIP-40 window and redeliver them on every launch,
/// and the 120s outbox sweep re-deposits anything undelivered — so with
/// in-memory-only dedup every relaunch republished the same message as a
/// fresh drop (fresh throwaway seal, undeduplicatable downstream) and every
/// gateway relaunch re-delivered the whole backlog. Field-verified: ~20
/// copies of one DM delivered in 40ms fed the storm behind a permanent
/// device freeze. Persisting both sides caps this at one drop per message
/// ID per 24h regardless of relaunch count.
///
/// Contents are opaque IDs (message UUIDs, relay event IDs) — no plaintext,
/// no peer identities — so until-first-unlock protection matches
/// `NostrProcessedEventStore`, and the file must load during a
/// locked-background restoration relaunch. Wiped on panic with the rest of
/// the courier state.
final class BridgeDropDedupStore {
    struct Snapshot: Codable {
        var publishedDropKeys: [String: Date]
        var seenDropEventIDs: [String: Date]
    }

    private let fileURL: URL?

    /// - Parameter fileURL: Overrides the on-disk location (tests). Ignored
    ///   when `persistsToDisk` is false.
    init(persistsToDisk: Bool = true, fileURL: URL? = nil) {
        self.fileURL = persistsToDisk ? (fileURL ?? Self.defaultFileURL()) : nil
    }

    func load() -> Snapshot {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            return Snapshot(publishedDropKeys: [:], seenDropEventIDs: [:])
        }
        return snapshot
    }

    func save(_ snapshot: Snapshot) {
        guard let fileURL else { return }
        guard !(snapshot.publishedDropKeys.isEmpty && snapshot.seenDropEventIDs.isEmpty) else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(snapshot)
            var options: Data.WritingOptions = [.atomic]
            #if os(iOS)
            options.insert(.completeFileProtectionUntilFirstUserAuthentication)
            #endif
            try data.write(to: fileURL, options: options)
        } catch {
            SecureLogger.error("Failed to persist bridge drop dedup record: \(error)", category: .session)
        }
    }

    /// Panic wipe: forget which drops we published or handled.
    func wipe() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static func defaultFileURL() -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return base
            .appendingPathComponent("courier", isDirectory: true)
            .appendingPathComponent("bridge-drop-dedup.json")
    }
}
