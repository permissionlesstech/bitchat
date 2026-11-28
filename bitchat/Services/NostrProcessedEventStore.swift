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

    private let fileStore: AppSupportFileStore
    private let saveEventIDs: (([String]) throws -> Void)?
    private let readData: (URL) throws -> Data
    // All file access is serialized here: appends are read-modify-write, and
    // overlapping debounced flushes would otherwise race and drop IDs.
    private let ioQueue = DispatchQueue(label: "chat.bitchat.nostr-processed-events", qos: .utility)

    private var cachedIDs: [String]?
    private var cachedKnown: Set<String> = []
    private var deferredIDs: [String] = []
    private var deferredKnown: Set<String> = []
    private var deferredCap = 0

    init(
        fileURL: URL? = nil,
        saveEventIDs: (([String]) throws -> Void)? = nil,
        readData: @escaping (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) {
        self.fileStore = AppSupportFileStore(
            fileURL: fileURL,
            subdirectory: "nostr",
            fileName: "processed-events.json",
            protection: .untilFirstUserAuthentication
        )
        self.saveEventIDs = saveEventIDs
        self.readData = readData
    }

    #if DEBUG
    /// Processed event IDs, oldest first (insertion order).
    func load() -> [String] {
        ioQueue.sync {
            loadAndFlushDeferredLocked()
        }
    }
    #endif

    /// Loads processed event IDs asynchronously on the utility I/O queue so
    /// cold launch does not block the main actor on disk I/O + JSON decoding.
    func loadAsync(completion: @escaping @Sendable ([String]) -> Void) {
        ioQueue.async { [self] in
            completion(loadAndFlushDeferredLocked())
        }
    }

    /// Merge new IDs onto the persisted record, oldest-first, trimming from
    /// the front past `cap`. Append-merge (not snapshot-overwrite) so the
    /// in-memory cache being cleared transiently (channel switches) can
    /// never shrink the on-disk record.
    func append(_ newIDs: [String], cap: Int) {
        guard !newIDs.isEmpty, cap > 0 else { return }
        ioQueue.async { [self] in
            switch loadBaseLocked() {
            case .transientError:
                // Never overwrite an unreadable durable file with an empty
                // baseline; hold new IDs until the file becomes readable.
                recordDeferredLocked(newIDs, cap: cap)
            case .loaded(let existing):
                _ = mergeAndSaveLocked(base: existing, additionalIDs: newIDs, cap: cap)
            }
        }
    }

    func wipe() {
        ioQueue.sync {
            cachedIDs = []
            cachedKnown.removeAll()
            clearDeferredLocked()
            fileStore.removeIgnoringErrors()
        }
    }

    private func clearDeferredLocked() {
        deferredIDs.removeAll()
        deferredKnown.removeAll()
        deferredCap = 0
    }

    private static func trim(_ ids: inout [String], known: inout Set<String>, to cap: Int) {
        guard ids.count > cap else { return }
        let overflow = ids.count - cap
        for evicted in ids.prefix(overflow) {
            known.remove(evicted)
        }
        ids.removeFirst(overflow)
    }

    private func loadAndFlushDeferredLocked() -> [String] {
        switch loadBaseLocked() {
        case .loaded(let ids):
            guard !deferredIDs.isEmpty else { return ids }
            return mergeAndSaveLocked(base: ids, additionalIDs: [], cap: deferredCap)
        case .transientError:
            return []
        }
    }

    private func recordDeferredLocked(_ ids: [String], cap: Int) {
        guard cap > 0 else {
            clearDeferredLocked()
            return
        }
        deferredCap = cap
        for id in ids where !cachedKnown.contains(id) && deferredKnown.insert(id).inserted {
            deferredIDs.append(id)
        }
        Self.trim(&deferredIDs, known: &deferredKnown, to: cap)
    }

    private func mergeAndSaveLocked(base: [String], additionalIDs: [String], cap: Int) -> [String] {
        guard cap > 0 else { return base }
        var candidate = base
        var candidateKnown = cachedKnown
        var didAdd = false
        for id in deferredIDs + additionalIDs where candidateKnown.insert(id).inserted {
            candidate.append(id)
            didAdd = true
        }
        guard didAdd else {
            clearDeferredLocked()
            return base
        }
        Self.trim(&candidate, known: &candidateKnown, to: cap)
        if saveLocked(candidate) {
            cachedIDs = candidate
            cachedKnown = candidateKnown
            clearDeferredLocked()
            return candidate
        }
        // Keep cachedIDs/cachedKnown matching confirmed disk state and prune
        // any previously deferred IDs that were already present on disk.
        let unsaved = deferredIDs + additionalIDs
        clearDeferredLocked()
        recordDeferredLocked(unsaved, cap: cap)
        return base
    }

    private func loadBaseLocked() -> LoadResult {
        if let cachedIDs {
            return .loaded(cachedIDs)
        }
        guard let fileURL = fileStore.fileURL,
              FileManager.default.fileExists(atPath: fileURL.path) else {
            cachedIDs = []
            cachedKnown = []
            return .loaded([])
        }
        let data: Data
        do {
            data = try readData(fileURL)
        } catch {
            if AppSupportFileStore.isMissingFileError(error) {
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

    private func saveLocked(_ eventIDs: [String]) -> Bool {
        guard !eventIDs.isEmpty else { return true }
        do {
            if let saveEventIDs {
                try saveEventIDs(eventIDs)
            } else {
                try fileStore.saveJSON(eventIDs, isEmpty: false)
            }
            return true
        } catch {
            SecureLogger.error("Failed to persist processed Nostr events: \(error)", category: .session)
            return false
        }
    }
}
