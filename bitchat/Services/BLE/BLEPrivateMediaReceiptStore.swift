import BitLogger
import Foundation

enum BLEPrivateMediaReceiptState: Equatable {
    /// No durable receiver decision exists for this stable message ID.
    case absent
    /// The payload is durably mapped to a file that still exists.
    case accepted(URL)
    /// The user explicitly deleted the payload; retries must not resurrect it.
    case tombstoned
    /// Durable state could not be read safely. Callers must fail closed and
    /// must not save, deliver, or acknowledge the payload.
    case unavailable
}

/// Durable receiver ledger for stable private-media message IDs.
///
/// Stored as a single atomic JSON snapshot (`files/.private-media-ledger.json`),
/// making both single-ID accepts and multi-ID explicit deletions atomic in one
/// write without per-ID files or a separate deletion journal. On first load,
/// any legacy `files/.private-media-receipts/` directory is migrated once into
/// the snapshot and removed.
final class BLEPrivateMediaReceiptStore: @unchecked Sendable {
    typealias DataReader = (_ url: URL) throws -> Data
    typealias DataWriter = (
        _ data: Data,
        _ url: URL,
        _ options: Data.WritingOptions
    ) throws -> Void
    typealias PayloadRemover = (_ url: URL) throws -> Void

    static let ledgerFileName = ".private-media-ledger.json"
    private static let legacyReceiptDirectoryName = ".private-media-receipts"
    private static let legacyDeletionJournalFileName = ".deletion-journal.json"
    private static let legacyQuarantinePathExtension = "corrupt"
    private static let currentVersion = 2
    private static let maximumDeletionPathsPerMessage = 2

    private struct ReceiptRecord: Codable, Equatable {
        enum Kind: String, Codable {
            case accepted
            case tombstone
        }

        let kind: Kind
        /// Path below `files/` for `.accepted` records. Tombstones keep this `nil`.
        var relativePath: String?
        /// Incoming payload paths awaiting unlink retry after an atomic tombstone commit.
        var pendingUnlinkPaths: [String]?
        let recordedAt: Date
    }

    private struct LedgerSnapshot: Codable, Equatable {
        var version: Int = BLEPrivateMediaReceiptStore.currentVersion
        var records: [String: ReceiptRecord] = [:]
        var quarantined: Set<String> = []
    }

    // Legacy on-disk migration fixtures.
    private struct LegacyReceiptRecord: Codable {
        let kind: ReceiptRecord.Kind
        let relativePath: String?
        let recordedAt: Date
    }

    private struct LegacyDeletionJournalEntry: Codable {
        let relativePaths: [String]
        let recordedAt: Date
    }

    private struct LegacyDeletionJournal: Codable {
        let version: Int
        let entries: [String: LegacyDeletionJournalEntry]
    }

    private final class Runtime: @unchecked Sendable {
        let lock = NSLock()
        var snapshot: LedgerSnapshot?
        var cachedFilesRoot: URL?
        var cachedIncomingDirectoryPaths: Set<String> = []
    }

    private let fileManager: FileManager
    private let baseDirectory: URL?
    private let capacity: Int
    private let ttl: TimeInterval
    private let now: () -> Date
    private let dataReader: DataReader?
    private let dataWriter: DataWriter
    private let payloadRemover: PayloadRemover
    private let runtime = Runtime()

    init(
        fileManager: FileManager = .default,
        baseDirectory: URL? = nil,
        capacity: Int = TransportConfig.privateMediaReceivedLedgerCapacity,
        ttl: TimeInterval = TransportConfig.privateMediaReceivedLedgerTTLSeconds,
        now: @escaping () -> Date = Date.init,
        dataReader: DataReader? = nil,
        dataWriter: @escaping DataWriter = { try $0.write(to: $1, options: $2) },
        payloadRemover: PayloadRemover? = nil
    ) {
        self.fileManager = fileManager
        self.baseDirectory = baseDirectory
        self.capacity = max(1, capacity)
        self.ttl = max(0, ttl)
        self.now = now
        self.dataReader = dataReader
        self.dataWriter = dataWriter
        self.payloadRemover = payloadRemover ?? { try fileManager.removeItem(at: $0) }
    }

    /// Drops cached decisions after the enclosing media directory has been
    /// panic-wiped so subsequent lookups rebuild from disk.
    func resetForPanic() {
        runtime.lock.lock()
        runtime.snapshot = nil
        runtime.cachedFilesRoot = nil
        runtime.cachedIncomingDirectoryPaths.removeAll(keepingCapacity: false)
        runtime.lock.unlock()
    }

    func state(for messageID: String) -> BLEPrivateMediaReceiptState {
        guard PrivateMediaMessageIdentity.isStableID(messageID) else {
            return .absent
        }

        runtime.lock.lock()
        defer { runtime.lock.unlock() }

        let date = now()
        guard let ledgerURL = resolvedLedgerURL(),
              loadSnapshotIfNeeded(ledgerURL: ledgerURL, at: date),
              var snapshot = runtime.snapshot else {
            return .unavailable
        }

        retryPendingUnlinks(in: &snapshot, ledgerURL: ledgerURL)
        if snapshot.quarantined.contains(messageID) {
            return .unavailable
        }
        guard let record = snapshot.records[messageID] else {
            return .absent
        }

        let retainsAcceptedPath =
            record.kind == .accepted
                && record.relativePath.flatMap(existingPayload) != nil
        let hasPendingUnlinks = !(record.pendingUnlinkPaths ?? []).isEmpty
        if isExpired(record.recordedAt, at: date),
           !retainsAcceptedPath,
           !hasPendingUnlinks {
            var updated = snapshot
            updated.records.removeValue(forKey: messageID)
            guard persist(updated, to: ledgerURL) else {
                return record.kind == .tombstone ? .tombstoned : .unavailable
            }
            runtime.snapshot = updated
            return .absent
        }

        switch record.kind {
        case .tombstone:
            return .tombstoned
        case .accepted:
            guard let relativePath = record.relativePath,
                  let existingURL = existingPayload(relativePath: relativePath) else {
                // Quota eviction is not explicit deletion; prune the stale
                // receipt so a sender retry can restore the payload.
                var updated = snapshot
                updated.records.removeValue(forKey: messageID)
                guard persist(updated, to: ledgerURL) else {
                    return .unavailable
                }
                runtime.snapshot = updated
                return .absent
            }
            return .accepted(existingURL)
        }
    }

    /// Records an accepted ID only after the payload is on disk.
    func commitAccepted(messageID: String, storedURL: URL) -> Bool {
        guard PrivateMediaMessageIdentity.isStableID(messageID) else {
            return false
        }

        runtime.lock.lock()
        defer { runtime.lock.unlock() }

        guard validExistingPayload(storedURL) != nil,
              let relativePath = relativePath(for: storedURL) else {
            return false
        }

        let date = now()
        guard let ledgerURL = resolvedLedgerURL(),
              loadSnapshotIfNeeded(ledgerURL: ledgerURL, at: date),
              var snapshot = runtime.snapshot else {
            return false
        }

        retryPendingUnlinks(in: &snapshot, ledgerURL: ledgerURL)
        guard !snapshot.quarantined.contains(messageID) else {
            return false
        }
        // Reject cross-ID path reuse or pending-unlink path collision.
        if snapshot.records.contains(where: { otherID, record in
            if record.pendingUnlinkPaths?.contains(relativePath) == true {
                return true
            }
            return otherID != messageID && record.relativePath == relativePath
        }) {
            return false
        }
        if let existing = snapshot.records[messageID],
           existing.kind == .tombstone,
           (!isExpired(existing.recordedAt, at: date)
               || !(existing.pendingUnlinkPaths ?? []).isEmpty) {
            return false
        }
        if snapshot.records[messageID]?.kind != .accepted,
           snapshot.records.values.lazy.filter({ $0.kind == .accepted }).count >= capacity {
            return false
        }

        var updated = snapshot
        updated.records[messageID] = ReceiptRecord(
            kind: .accepted,
            relativePath: relativePath,
            pendingUnlinkPaths: nil,
            recordedAt: date
        )
        guard persist(updated, to: ledgerURL) else {
            return false
        }
        runtime.snapshot = updated
        return true
    }

    /// Atomically commits explicit deletion for every stable ID in `messageIDs`
    /// in a single snapshot write, then unlinks the associated payloads.
    func recordDeleted(
        messageIDs: [String],
        payloadRelativePaths: [String: String] = [:]
    ) -> Bool {
        let stableIDs = Array(
            Set(messageIDs.filter(PrivateMediaMessageIdentity.isStableID))
        ).sorted()
        guard !stableIDs.isEmpty else { return true }
        guard stableIDs.count <= capacity else { return false }

        runtime.lock.lock()
        defer { runtime.lock.unlock() }

        let date = now()
        guard let ledgerURL = resolvedLedgerURL(),
              loadSnapshotIfNeeded(ledgerURL: ledgerURL, at: date),
              var snapshot = runtime.snapshot else {
            return false
        }

        retryPendingUnlinks(in: &snapshot, ledgerURL: ledgerURL)

        let newIDs = stableIDs.filter { messageID in
            if let current = snapshot.records[messageID],
               current.kind == .tombstone,
               (!isExpired(current.recordedAt, at: date)
                   || !(current.pendingUnlinkPaths ?? []).isEmpty) {
                return false
            }
            return true
        }
        guard !newIDs.isEmpty else { return true }

        let stableIDSet = Set(stableIDs)
        var updated = snapshot
        for messageID in newIDs {
            let relativePaths = Array(Set([
                snapshot.records[messageID]?.relativePath,
                payloadRelativePaths[messageID]
            ].compactMap { $0 })).sorted()

            guard !relativePaths.isEmpty,
                  relativePaths.count <= Self.maximumDeletionPathsPerMessage,
                  relativePaths.allSatisfy({ isSafeDeletionTarget(relativePath: $0) }),
                  !snapshot.records.contains(where: { otherID, record in
                      otherID != messageID
                          && !stableIDSet.contains(otherID)
                          && (record.relativePath.map(relativePaths.contains) == true
                              || !(Set(record.pendingUnlinkPaths ?? []).isDisjoint(with: relativePaths)))
                  }) else {
                return false
            }

            updated.records[messageID] = ReceiptRecord(
                kind: .tombstone,
                relativePath: nil,
                pendingUnlinkPaths: relativePaths,
                recordedAt: date
            )
        }

        // Enforce tombstone capacity by evicting oldest tombstones outside this batch.
        enforceTombstoneCapacity(in: &updated, preserving: stableIDSet)

        // Single atomic write commits the entire deletion batch.
        guard persist(updated, to: ledgerURL) else {
            return false
        }
        runtime.snapshot = updated
        retryPendingUnlinks(in: &updated, ledgerURL: ledgerURL)
        return true
    }

    func recordDeleted(messageID: String) -> Bool {
        guard PrivateMediaMessageIdentity.isStableID(messageID) else {
            return false
        }
        return recordDeleted(messageIDs: [messageID])
    }

    /// Returns whether `relativePath` is owned by an accepted receipt or a
    /// pending tombstone unlink, or `nil` when the ledger cannot be read.
    func isPayloadOwned(relativePath: String) -> Bool? {
        runtime.lock.lock()
        defer { runtime.lock.unlock() }

        let date = now()
        guard let ledgerURL = resolvedLedgerURL(),
              loadSnapshotIfNeeded(ledgerURL: ledgerURL, at: date),
              var snapshot = runtime.snapshot else {
            return nil
        }

        retryPendingUnlinks(in: &snapshot, ledgerURL: ledgerURL)
        return snapshot.records.values.contains { record in
            record.relativePath == relativePath
                || (record.pendingUnlinkPaths?.contains(relativePath) == true)
        }
    }

    // MARK: - Loading & Legacy Migration

    private func loadSnapshotIfNeeded(ledgerURL: URL, at date: Date) -> Bool {
        if runtime.snapshot != nil { return true }

        var snapshot: LedgerSnapshot
        var needsPersist = false

        if fileManager.fileExists(atPath: ledgerURL.path) {
            do {
                let data = try dataReader?(ledgerURL) ?? Data(contentsOf: ledgerURL)
                let decoded = try JSONDecoder().decode(LedgerSnapshot.self, from: data)
                guard isStructurallyValid(decoded) else {
                    SecureLogger.error("❌ Invalid private-media receipt ledger", category: .session)
                    return false
                }
                snapshot = decoded
            } catch {
                SecureLogger.error("❌ Failed to read private-media receipt ledger: \(error)", category: .session)
                return false
            }
        } else if let legacyDirectory = resolvedLegacyReceiptDirectory(),
                  fileManager.fileExists(atPath: legacyDirectory.path) {
            guard let migrated = migrateLegacyDirectory(legacyDirectory) else {
                return false
            }
            snapshot = migrated
            needsPersist = true
        } else {
            snapshot = LedgerSnapshot()
        }

        if pruneExpiredAndOverflow(in: &snapshot, at: date) {
            needsPersist = true
        }

        if needsPersist {
            guard persist(snapshot, to: ledgerURL) else {
                return false
            }
            if let legacyDirectory = resolvedLegacyReceiptDirectory(),
               fileManager.fileExists(atPath: legacyDirectory.path) {
                try? fileManager.removeItem(at: legacyDirectory)
            }
        }

        runtime.snapshot = snapshot
        retryPendingUnlinks(in: &snapshot, ledgerURL: ledgerURL)
        return true
    }

    /// One-time migration from the pre-consolidation per-ID receipt directory
    /// and `.deletion-journal.json` into a single `LedgerSnapshot`.
    private func migrateLegacyDirectory(_ directory: URL) -> LedgerSnapshot? {
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            )
        } catch {
            SecureLogger.error("❌ Failed to enumerate legacy private-media receipts: \(error)", category: .session)
            return nil
        }

        var snapshot = LedgerSnapshot()

        for url in urls {
            if url.pathExtension == Self.legacyQuarantinePathExtension {
                let messageID = url
                    .deletingPathExtension()
                    .deletingPathExtension()
                    .lastPathComponent
                if PrivateMediaMessageIdentity.isStableID(messageID) {
                    snapshot.quarantined.insert(messageID)
                }
                continue
            }
            guard url.pathExtension == "json",
                  url.lastPathComponent != Self.legacyDeletionJournalFileName else {
                continue
            }
            let messageID = url.deletingPathExtension().lastPathComponent
            guard PrivateMediaMessageIdentity.isStableID(messageID) else {
                continue
            }
            do {
                let data = try dataReader?(url) ?? Data(contentsOf: url)
                let legacy = try JSONDecoder().decode(LegacyReceiptRecord.self, from: data)
                let migrated: ReceiptRecord
                switch legacy.kind {
                case .accepted:
                    guard let path = legacy.relativePath,
                          candidatePayload(relativePath: path) != nil else {
                        snapshot.quarantined.insert(messageID)
                        continue
                    }
                    migrated = ReceiptRecord(
                        kind: .accepted,
                        relativePath: path,
                        pendingUnlinkPaths: nil,
                        recordedAt: legacy.recordedAt
                    )
                case .tombstone:
                    if let path = legacy.relativePath,
                       candidatePayload(relativePath: path) == nil {
                        snapshot.quarantined.insert(messageID)
                        continue
                    }
                    // Pre-journal pathful tombstones carried ambiguous basenames;
                    // drop the path without unlinking any current file.
                    migrated = ReceiptRecord(
                        kind: .tombstone,
                        relativePath: nil,
                        pendingUnlinkPaths: nil,
                        recordedAt: legacy.recordedAt
                    )
                }
                snapshot.records[messageID] = migrated
            } catch {
                snapshot.quarantined.insert(messageID)
            }
        }

        let journalURL = directory.appendingPathComponent(
            Self.legacyDeletionJournalFileName,
            isDirectory: false
        )
        if fileManager.fileExists(atPath: journalURL.path) {
            do {
                let data = try dataReader?(journalURL) ?? Data(contentsOf: journalURL)
                let journal = try JSONDecoder().decode(LegacyDeletionJournal.self, from: data)
                guard journal.version == 1,
                      journal.entries.count <= capacity,
                      journal.entries.allSatisfy({ id, entry in
                          PrivateMediaMessageIdentity.isStableID(id)
                              && !entry.relativePaths.isEmpty
                              && entry.relativePaths.count <= Self.maximumDeletionPathsPerMessage
                              && Set(entry.relativePaths).count == entry.relativePaths.count
                              && entry.relativePaths.allSatisfy { candidatePayload(relativePath: $0) != nil }
                      }) else {
                    SecureLogger.error("❌ Invalid legacy private-media deletion journal", category: .session)
                    return nil
                }
                for (messageID, entry) in journal.entries {
                    // Committed journal deletion outranks quarantine.
                    snapshot.quarantined.remove(messageID)
                    snapshot.records[messageID] = ReceiptRecord(
                        kind: .tombstone,
                        relativePath: nil,
                        pendingUnlinkPaths: entry.relativePaths,
                        recordedAt: entry.recordedAt
                    )
                }
            } catch {
                SecureLogger.error("❌ Failed to read legacy private-media deletion journal: \(error)", category: .session)
                return nil
            }
        }

        for id in snapshot.quarantined {
            snapshot.records.removeValue(forKey: id)
        }
        return snapshot
    }

    // MARK: - Maintenance & Persistence

    private func retryPendingUnlinks(in snapshot: inout LedgerSnapshot, ledgerURL: URL) {
        var changed = false
        for (messageID, var record) in snapshot.records {
            guard record.kind == .tombstone,
                  let paths = record.pendingUnlinkPaths,
                  !paths.isEmpty else {
                continue
            }
            let remaining = paths.filter { !removePayload(atRelativePath: $0) }
            if remaining != paths {
                record.pendingUnlinkPaths = remaining.isEmpty ? nil : remaining
                snapshot.records[messageID] = record
                changed = true
            }
        }
        if changed, persist(snapshot, to: ledgerURL) {
            runtime.snapshot = snapshot
        }
    }

    private func pruneExpiredAndOverflow(in snapshot: inout LedgerSnapshot, at date: Date) -> Bool {
        var changed = false
        for (messageID, record) in snapshot.records {
            let retainsAccepted = record.kind == .accepted
                && record.relativePath.flatMap(existingPayload) != nil
            let hasPendingUnlinks = !(record.pendingUnlinkPaths ?? []).isEmpty
            if isExpired(record.recordedAt, at: date), !retainsAccepted, !hasPendingUnlinks {
                snapshot.records.removeValue(forKey: messageID)
                changed = true
            }
        }

        for kind in [ReceiptRecord.Kind.accepted, .tombstone] {
            let allMatching = snapshot.records.filter { $0.value.kind == kind }
            let overflow = allMatching.count - capacity
            guard overflow > 0 else { continue }
            let eligible = allMatching.filter { _, record in
                if kind == .accepted {
                    return record.relativePath.flatMap(existingPayload) == nil
                }
                return (record.pendingUnlinkPaths ?? []).isEmpty
            }
            let victims = eligible.sorted { lhs, rhs in
                lhs.value.recordedAt == rhs.value.recordedAt
                    ? lhs.key < rhs.key
                    : lhs.value.recordedAt < rhs.value.recordedAt
            }.prefix(overflow).map(\.key)
            for victim in victims {
                snapshot.records.removeValue(forKey: victim)
                changed = true
            }
        }
        return changed
    }

    private func enforceTombstoneCapacity(
        in snapshot: inout LedgerSnapshot,
        preserving preservedIDs: Set<String>
    ) {
        let tombstones = snapshot.records.filter { $0.value.kind == .tombstone }
        let overflow = tombstones.count - capacity
        guard overflow > 0 else { return }
        let victims = tombstones
            .filter { !preservedIDs.contains($0.key) && ($0.value.pendingUnlinkPaths ?? []).isEmpty }
            .sorted { lhs, rhs in
                lhs.value.recordedAt == rhs.value.recordedAt
                    ? lhs.key < rhs.key
                    : lhs.value.recordedAt < rhs.value.recordedAt
            }
            .prefix(overflow)
            .map(\.key)
        for victim in victims {
            snapshot.records.removeValue(forKey: victim)
        }
    }

    private func isStructurallyValid(_ snapshot: LedgerSnapshot) -> Bool {
        guard snapshot.version == Self.currentVersion else { return false }
        for id in snapshot.quarantined where !PrivateMediaMessageIdentity.isStableID(id) {
            return false
        }
        for (id, record) in snapshot.records {
            guard PrivateMediaMessageIdentity.isStableID(id) else { return false }
            switch record.kind {
            case .accepted:
                guard let path = record.relativePath,
                      candidatePayload(relativePath: path) != nil,
                      record.pendingUnlinkPaths == nil else {
                    return false
                }
            case .tombstone:
                guard record.relativePath == nil else { return false }
                if let pending = record.pendingUnlinkPaths {
                    guard pending.count <= Self.maximumDeletionPathsPerMessage,
                          pending.allSatisfy({ candidatePayload(relativePath: $0) != nil }) else {
                        return false
                    }
                }
            }
        }
        return true
    }

    private func isExpired(_ recordedAt: Date, at date: Date) -> Bool {
        date.timeIntervalSince(recordedAt) > ttl
    }

    private func persist(_ snapshot: LedgerSnapshot, to ledgerURL: URL) -> Bool {
        do {
            try fileManager.createDirectory(
                at: ledgerURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            let data = try JSONEncoder().encode(snapshot)
            var options: Data.WritingOptions = [.atomic]
            #if os(iOS)
            options.insert(.completeFileProtectionUntilFirstUserAuthentication)
            #endif
            try dataWriter(data, ledgerURL, options)
            return true
        } catch {
            SecureLogger.error("❌ Failed to persist private-media receipt ledger: \(error)", category: .session)
            return false
        }
    }

    // MARK: - Path Validation & Payload Unlink

    @discardableResult
    private func removePayload(atRelativePath relativePath: String) -> Bool {
        guard let payload = candidatePayload(relativePath: relativePath),
              fileManager.fileExists(atPath: payload.path) else {
            return true
        }
        guard (try? payload.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            SecureLogger.warning("⚠️ Refusing to remove non-file private-media payload", category: .session)
            return false
        }
        do {
            try payloadRemover(payload)
            return !fileManager.fileExists(atPath: payload.path)
        } catch {
            SecureLogger.warning("⚠️ Failed to remove explicitly deleted private media: \(error)", category: .session)
            return false
        }
    }

    private func isSafeDeletionTarget(relativePath: String) -> Bool {
        guard let payload = candidatePayload(relativePath: relativePath) else {
            return false
        }
        guard fileManager.fileExists(atPath: payload.path) else {
            return true
        }
        return (try? payload.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private func validExistingPayload(_ url: URL) -> URL? {
        let standardized = url.standardizedFileURL
        guard isInsideIncomingMediaDirectory(standardized) else {
            return nil
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }
        return standardized
    }

    private func relativePath(for url: URL) -> String? {
        guard let filesRoot = try? filesDirectory().standardizedFileURL else {
            return nil
        }
        let prefix = filesRoot.path + "/"
        let standardized = url.standardizedFileURL
        guard standardized.path.hasPrefix(prefix) else { return nil }
        let relativePath = String(standardized.path.dropFirst(prefix.count))
        return relativePath.isEmpty ? nil : relativePath
    }

    private func existingPayload(relativePath: String) -> URL? {
        guard let candidate = candidatePayload(relativePath: relativePath) else {
            return nil
        }
        return validExistingPayload(candidate)
    }

    private func candidatePayload(relativePath: String) -> URL? {
        guard !relativePath.isEmpty,
              let filesRoot = try? filesDirectory().standardizedFileURL else {
            return nil
        }
        let candidate = filesRoot
            .appendingPathComponent(relativePath, isDirectory: false)
            .standardizedFileURL
        guard isInsideIncomingMediaDirectory(candidate) else { return nil }
        return candidate
    }

    private func isInsideIncomingMediaDirectory(_ url: URL) -> Bool {
        guard (try? filesDirectory()) != nil else {
            return false
        }
        let parentPath = url.standardizedFileURL.deletingLastPathComponent().path
        return runtime.cachedIncomingDirectoryPaths.contains(parentPath)
    }

    private func resolvedLedgerURL() -> URL? {
        try? filesDirectory().appendingPathComponent(Self.ledgerFileName, isDirectory: false)
    }

    private func resolvedLegacyReceiptDirectory() -> URL? {
        try? filesDirectory().appendingPathComponent(Self.legacyReceiptDirectoryName, isDirectory: true)
    }

    private func filesDirectory() throws -> URL {
        if let cached = runtime.cachedFilesRoot {
            return cached
        }
        let root = try baseDirectory ?? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let files = root.appendingPathComponent("files", isDirectory: true)
        try fileManager.createDirectory(at: files, withIntermediateDirectories: true, attributes: nil)
        let standardizedFiles = files.standardizedFileURL
        runtime.cachedFilesRoot = standardizedFiles
        runtime.cachedIncomingDirectoryPaths = Set([
            "voicenotes/incoming",
            "images/incoming",
            "files/incoming"
        ].map {
            standardizedFiles.appendingPathComponent($0, isDirectory: true).standardizedFileURL.path
        })
        return standardizedFiles
    }
}
