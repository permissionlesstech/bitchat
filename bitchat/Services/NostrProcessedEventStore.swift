//
// NostrProcessedEventStore.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import Foundation

/// Disk persistence for processed gift-wrap event IDs. NIP-59 randomizes
/// gift-wrap timestamps, so DM subscriptions must look back generously (24h)
/// and relays redeliver the same events on every launch — without a
/// cross-launch record, each relaunch reprocesses old PMs and acks
/// (re-sent DELIVERED bursts, "delivered ack for unknown mid" noise).
///
/// Contents are event IDs already visible to every relay, so
/// until-first-unlock file protection is the right at-rest posture — the
/// file must also load during a locked-background restoration relaunch.
/// Wiped on panic via the dedup service's clear paths.
final class NostrProcessedEventStore {
    private let fileURL: URL?
    // All file access is serialized here: appends are read-modify-write, and
    // overlapping debounced flushes would otherwise race and drop IDs.
    private let ioQueue = DispatchQueue(label: "chat.bitchat.nostr-processed-events", qos: .utility)

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    /// Processed event IDs, oldest first (insertion order).
    func load() -> [String] {
        ioQueue.sync { loadLocked() }
    }

    /// Merge new IDs onto the persisted record, oldest-first, trimming from
    /// the front past `cap`. Append-merge (not snapshot-overwrite) so the
    /// in-memory cache being cleared transiently (channel switches) can
    /// never shrink the on-disk record.
    func append(_ newIDs: [String], cap: Int) {
        guard !newIDs.isEmpty else { return }
        ioQueue.async { [self] in
            var merged = loadLocked()
            var known = Set(merged)
            for id in newIDs where !known.contains(id) {
                merged.append(id)
                known.insert(id)
            }
            if merged.count > cap {
                merged.removeFirst(merged.count - cap)
            }
            saveLocked(merged)
        }
    }

    func wipe() {
        ioQueue.async { [self] in
            guard let fileURL else { return }
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private func loadLocked() -> [String] {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let ids = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return ids
    }

    private func saveLocked(_ eventIDs: [String]) {
        guard let fileURL else { return }
        guard !eventIDs.isEmpty else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(eventIDs)
            var options: Data.WritingOptions = [.atomic]
            #if os(iOS)
            options.insert(.completeFileProtectionUntilFirstUserAuthentication)
            #endif
            try data.write(to: fileURL, options: options)
        } catch {
            SecureLogger.error("Failed to persist processed Nostr events: \(error)", category: .session)
        }
    }

    private static func defaultFileURL() -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return base
            .appendingPathComponent("nostr", isDirectory: true)
            .appendingPathComponent("processed-events.json")
    }
}
