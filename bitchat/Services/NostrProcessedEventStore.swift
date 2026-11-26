//
// NostrProcessedEventStore.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import Foundation

/// Disk persistence for processed private-envelope event IDs. BitChat
/// randomizes envelope timestamps, so DM subscriptions must look back
/// generously (24h)
/// and relays redeliver the same events on every launch — without a
/// cross-launch record, each relaunch reprocesses old PMs and acks
/// (re-sent DELIVERED bursts, "delivered ack for unknown mid" noise).
///
/// Contents are event IDs already visible to every relay, so
/// until-first-unlock file protection is the right at-rest posture — the
/// file must also load during a locked-background restoration relaunch.
/// Wiped on panic via the dedup service's clear paths.
final class NostrProcessedEventStore {
    private enum LoadResult {
        case loaded([String])
        case transientError
    }

    private let fileURL: URL?
    private let readData: (URL) throws -> Data
    // All file access is serialized here: appends are read-modify-write, and
    // overlapping debounced flushes would otherwise race and drop IDs.
    private let ioQueue = DispatchQueue(label: "chat.bitchat.nostr-processed-events", qos: .utility)

    private var cachedIDs: [String]?
    private var cachedKnown: Set<String> = []
    private var deferredIDs: [String] = []
    private var directoryCreated = false

    init(
        fileURL: URL? = nil,
        readData: @escaping (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.readData = readData
    }

    /// Processed event IDs, oldest first (insertion order).
    func load() -> [String] {
        ioQueue.sync {
            switch loadLocked() {
            case .loaded(let ids):
                return ids
            case .transientError:
                return []
            }
        }
    }

    /// Loads processed event IDs asynchronously on the utility I/O queue so
    /// cold launch does not block the main actor on disk I/O + JSON decoding.
    func loadAsync(completion: @escaping @Sendable ([String]) -> Void) {
        ioQueue.async { [self] in
            switch loadLocked() {
            case .loaded(let ids):
                completion(ids)
            case .transientError:
                completion([])
            }
        }
    }

    /// Merge new IDs onto the persisted record, oldest-first, trimming from
    /// the front past `cap`. Append-merge (not snapshot-overwrite) so the
    /// in-memory cache being cleared transiently (channel switches) can
    /// never shrink the on-disk record.
    func append(_ newIDs: [String], cap: Int) {
        guard !newIDs.isEmpty else { return }
        ioQueue.async { [self] in
            switch loadLocked() {
            case .transientError:
                // Never overwrite an unreadable durable file with an empty
                // baseline; hold new IDs until the file becomes readable.
                deferredIDs.append(contentsOf: newIDs)
                if deferredIDs.count > cap {
                    deferredIDs.removeFirst(deferredIDs.count - cap)
                }
            case .loaded(var merged):
                let pending = deferredIDs + newIDs
                deferredIDs.removeAll()
                var didAdd = false
                for id in pending where cachedKnown.insert(id).inserted {
                    merged.append(id)
                    didAdd = true
                }
                guard didAdd else { return }
                if merged.count > cap {
                    let overflow = merged.count - cap
                    for evicted in merged.prefix(overflow) {
                        cachedKnown.remove(evicted)
                    }
                    merged.removeFirst(overflow)
                }
                cachedIDs = merged
                saveLocked(merged)
            }
        }
    }

    func wipe() {
        ioQueue.sync {
            cachedIDs = []
            cachedKnown.removeAll()
            deferredIDs.removeAll()
            directoryCreated = false
            guard let fileURL else { return }
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private func loadLocked() -> LoadResult {
        if let cachedIDs {
            return .loaded(cachedIDs)
        }
        guard let fileURL else {
            cachedIDs = []
            cachedKnown = []
            return .loaded([])
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cachedIDs = []
            cachedKnown = []
            return .loaded([])
        }
        let data: Data
        do {
            data = try readData(fileURL)
        } catch {
            if Self.isMissingFileError(error) {
                cachedIDs = []
                cachedKnown = []
                return .loaded([])
            }
            // Leave cache uninitialized so later loads/appends recover the
            // durable record once file protection or transient I/O clears.
            return .transientError
        }
        guard let ids = try? JSONDecoder().decode([String].self, from: data) else {
            cachedIDs = []
            cachedKnown = []
            return .loaded([])
        }
        cachedIDs = ids
        cachedKnown = Set(ids)
        return .loaded(ids)
    }

    private static func isMissingFileError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isMissingFileError(underlying)
        }
        return false
    }

    private func saveLocked(_ eventIDs: [String]) {
        guard let fileURL else { return }
        guard !eventIDs.isEmpty else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        do {
            if !directoryCreated {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                directoryCreated = true
            }
            let data = try JSONEncoder().encode(eventIDs)
            var options: Data.WritingOptions = [.atomic]
            #if os(iOS)
            options.insert(.completeFileProtectionUntilFirstUserAuthentication)
            #endif
            try data.write(to: fileURL, options: options)
        } catch {
            directoryCreated = false
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
