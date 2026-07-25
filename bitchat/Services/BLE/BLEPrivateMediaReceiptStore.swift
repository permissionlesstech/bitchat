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

/// Durable, per-message receiver decisions for stable private media.
///
/// Each ID has its own atomic record so one hot lookup never rewrites or
/// decodes the entire ledger. The process-lifetime index is installed only
/// after a complete directory scan. A structural failure of the directory
/// itself (create/enumerate) — or of the single batch deletion journal —
/// remains globally fail-closed and retryable. An individual record that
/// cannot be read, decoded, or validated is quarantined instead: the file is
/// moved aside with a `.corrupt` suffix, excluded from future scans, and only
/// that ID stays fail-closed — the rest of the ledger keeps working, so one
/// damaged record can never make every inbound private media payload vanish.
final class BLEPrivateMediaReceiptStore: @unchecked Sendable {
    typealias DirectoryReader = (_ directory: URL) throws -> [URL]
    typealias DataReader = (_ url: URL) throws -> Data
    typealias DataWriter = (
        _ data: Data,
        _ url: URL,
        _ options: Data.WritingOptions
    ) throws -> Void
    typealias PayloadRemover = (_ url: URL) throws -> Void
    private static let receiptDirectoryName = ".private-media-receipts"
    private static let quarantinePathExtension = "corrupt"
    private static let deletionJournalFileName = ".deletion-journal.json"
    private static let maximumDeletionPathsPerMessage = 2

    private struct ReceiptRecord: Codable, Equatable {
        enum Kind: String, Codable {
            case accepted
            case tombstone
        }

        let kind: Kind
        /// Path below the app's `files/` root. Absolute application-container
        /// prefixes are not stable across updates, restores, or reinstalls.
        let relativePath: String?
        let recordedAt: Date
    }

    /// One atomic write of this journal is the commit point for an entire
    /// explicit-deletion batch. Per-ID records and payload unlinks are
    /// idempotent materialization performed only after that commit.
    private struct DeletionJournalEntry: Codable, Equatable {
        let relativePaths: [String]
        let recordedAt: Date
    }

    private struct DeletionJournal: Codable {
        let version: Int
        let entries: [String: DeletionJournalEntry]
    }

    private final class Runtime: @unchecked Sendable {
        let lock = NSLock()
        var records: [String: ReceiptRecord]?
        /// IDs whose durable record was quarantined as unreadable. Installed
        /// together with `records`; these IDs stay fail-closed while every
        /// other record keeps serving.
        var quarantined: Set<String> = []
        var deletionJournal: [String: DeletionJournalEntry]?
    }

    private let fileManager: FileManager
    private let baseDirectory: URL?
    private let capacity: Int
    private let ttl: TimeInterval
    private let now: () -> Date
    private let directoryReader: DirectoryReader?
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
        directoryReader: DirectoryReader? = nil,
        dataReader: DataReader? = nil,
        dataWriter: @escaping DataWriter = {
            try $0.write(to: $1, options: $2)
        },
        payloadRemover: PayloadRemover? = nil
    ) {
        self.fileManager = fileManager
        self.baseDirectory = baseDirectory
        self.capacity = max(1, capacity)
        self.ttl = max(0, ttl)
        self.now = now
        self.directoryReader = directoryReader
        self.dataReader = dataReader
        self.dataWriter = dataWriter
        self.payloadRemover = payloadRemover ?? {
            try fileManager.removeItem(at: $0)
        }
    }

    /// Drops process-lifetime decisions after the enclosing media directory
    /// has been panic-wiped. A later lookup must rebuild from the durable
    /// ledger instead of retaining an accepted receipt or tombstone whose
    /// backing files no longer exist.
    func resetForPanic() {
        runtime.lock.lock()
        runtime.records = nil
        runtime.quarantined.removeAll(keepingCapacity: false)
        runtime.deletionJournal = nil
        runtime.lock.unlock()
    }

    func state(for messageID: String) -> BLEPrivateMediaReceiptState {
        guard PrivateMediaMessageIdentity.isStableID(messageID) else {
            return .absent
        }

        runtime.lock.lock()
        defer { runtime.lock.unlock() }

        let date = now()
        guard let directory = resolvedReceiptDirectory(),
              loadDurableStateIfNeeded(from: directory, at: date) else {
            return .unavailable
        }
        _ = recoverDeletionJournal(in: directory)
        // Committed deletion intent outranks quarantine: a pending journal
        // entry proves the payload must stay deleted no matter what state
        // the per-ID record file is in.
        if runtime.deletionJournal?[messageID] != nil {
            return .tombstoned
        }
        // A quarantined record could have been an acceptance or a tombstone;
        // only this ID fails closed, so a retry can neither resurrect deleted
        // media nor double-deliver, while every other payload keeps working.
        if runtime.quarantined.contains(messageID) {
            return .unavailable
        }
        guard var records = runtime.records else { return .unavailable }
        guard var record = records[messageID] else { return .absent }

        if record.kind == .tombstone, record.relativePath != nil {
            guard scrubLegacyTombstone(
                record,
                messageID: messageID,
                in: directory,
                records: &records
            ) else {
                return .tombstoned
            }
            guard let scrubbed = records[messageID] else {
                return .unavailable
            }
            record = scrubbed
        }

        let retainsAcceptedPath =
            record.kind == .accepted
                && record.relativePath.flatMap(existingPayload) != nil
        if isExpired(record.recordedAt, at: date),
           !retainsAcceptedPath {
            guard removeRecord(
                messageID: messageID,
                from: directory
            ) else {
                return record.kind == .tombstone
                    ? .tombstoned
                    : .unavailable
            }
            records.removeValue(forKey: messageID)
            runtime.records = records
            return .absent
        }

        switch record.kind {
        case .tombstone:
            return .tombstoned

        case .accepted:
            guard let relativePath = record.relativePath,
                  let existingURL = existingPayload(relativePath: relativePath) else {
                // Quota cleanup is not explicit deletion. Remove the stale
                // receipt so a sender retry can restore the payload and bubble.
                guard removeRecord(
                    messageID: messageID,
                    from: directory
                ) else {
                    return .unavailable
                }
                records.removeValue(forKey: messageID)
                runtime.records = records
                return .absent
            }
            return .accepted(existingURL)
        }
    }

    /// Records an accepted ID only after the payload is on disk. Callers must
    /// roll the payload back and withhold UI delivery/ACK when this returns
    /// false.
    func commitAccepted(messageID: String, storedURL: URL) -> Bool {
        guard PrivateMediaMessageIdentity.isStableID(messageID),
              validExistingPayload(storedURL) != nil,
              let relativePath = relativePath(for: storedURL) else {
            return false
        }

        runtime.lock.lock()
        defer { runtime.lock.unlock() }

        let date = now()
        guard let directory = resolvedReceiptDirectory(),
              loadDurableStateIfNeeded(from: directory, at: date) else {
            return false
        }
        _ = recoverDeletionJournal(in: directory)
        guard runtime.deletionJournal?[messageID] == nil,
              !runtime.quarantined.contains(messageID),
              var records = runtime.records else {
            return false
        }
        if runtime.deletionJournal?.values.contains(where: {
            $0.relativePaths.contains(relativePath)
        }) == true {
            return false
        }
        if records.contains(where: { existingMessageID, record in
            existingMessageID != messageID
                && record.relativePath == relativePath
        }) {
            return false
        }
        if let existing = records[messageID],
           existing.kind == .tombstone,
           !isExpired(existing.recordedAt, at: date) {
            return false
        }

        let victim = capacityVictim(
            for: .accepted,
            replacing: messageID,
            in: records
        )
        if records[messageID]?.kind != .accepted,
           records.values.lazy.filter({ $0.kind == .accepted }).count >= capacity,
           victim == nil {
            return false
        }

        let record = ReceiptRecord(
            kind: .accepted,
            relativePath: relativePath,
            recordedAt: date
        )
        guard persist(record, messageID: messageID, to: directory) else {
            return false
        }

        records[messageID] = record
        if let victim, victim != messageID {
            records.removeValue(forKey: victim)
            removeRecord(messageID: victim, from: directory)
        }
        runtime.records = records
        return true
    }

    /// Atomically commits explicit deletion for every stable ID in `messageIDs`.
    ///
    /// The journal is the single batch commit point: a failed write changes
    /// neither durable nor in-memory receiver state, so callers must preserve
    /// their bubbles. Once the write succeeds, every entry is tombstoned even
    /// if the process exits before per-ID materialization or payload unlink.
    /// Recovery retries both operations on the next lookup or launch.
    func recordDeleted(
        messageIDs: [String],
        payloadRelativePaths: [String: String] = [:],
        protectedPayloadRelativePaths: Set<String> = []
    ) -> Bool {
        let stableIDs = Array(
            Set(messageIDs.filter(PrivateMediaMessageIdentity.isStableID))
        ).sorted()
        guard !stableIDs.isEmpty else { return true }
        guard stableIDs.count <= capacity else { return false }

        runtime.lock.lock()
        defer { runtime.lock.unlock() }

        let date = now()
        guard let directory = resolvedReceiptDirectory(),
              loadDurableStateIfNeeded(from: directory, at: date) else {
            return false
        }
        _ = recoverDeletionJournal(in: directory)
        guard let records = runtime.records,
              var journal = runtime.deletionJournal else {
            return false
        }

        // Quarantined IDs need no special case here: their record is never
        // indexed, so deleting one requires a caller-supplied payload path
        // (the general pathless-deletion refusal below rejects it otherwise),
        // and materialization never rewrites a quarantined ID's record.
        let pendingIDs = Set(journal.keys)
        let newIDs = stableIDs.filter { messageID in
            if pendingIDs.contains(messageID) { return false }
            if let current = records[messageID],
               current.kind == .tombstone,
               !isExpired(current.recordedAt, at: date) {
                return false
            }
            return true
        }
        guard !newIDs.isEmpty else {
            return true
        }
        guard Set(journal.keys).union(newIDs).count <= capacity else {
            return false
        }

        var newEntries: [String: DeletionJournalEntry] = [:]
        for messageID in newIDs {
            // Accepted receipts normally supply the exact stored path. The UI
            // fallback is required when that receipt aged or was capacity
            // evicted while its bubble and payload remain. They may differ
            // after a retry selected a suffixed filename, so journal both.
            // Never commit a new pathless tombstone: it could retire
            // successfully while leaving an untracked payload behind.
            let relativePaths = Array(Set([
                records[messageID]?.relativePath,
                payloadRelativePaths[messageID]
            ].compactMap { $0 })).sorted()
            guard !relativePaths.isEmpty,
                  relativePaths.count <=
                    Self.maximumDeletionPathsPerMessage,
                  relativePaths.allSatisfy({
                      isSafeDeletionTarget(relativePath: $0)
                  }),
                  protectedPayloadRelativePaths.isDisjoint(
                      with: relativePaths
                  ),
                  !records.contains(where: { otherMessageID, record in
                      otherMessageID != messageID
                          && !stableIDs.contains(otherMessageID)
                          && record.relativePath.map(
                              relativePaths.contains
                          ) == true
                  }),
                  !journal.contains(where: { otherMessageID, entry in
                      otherMessageID != messageID
                          && !stableIDs.contains(otherMessageID)
                          && !Set(entry.relativePaths).isDisjoint(
                              with: relativePaths
                          )
                  }) else {
                return false
            }
            newEntries[messageID] = DeletionJournalEntry(
                // The journal retains every owned path so payload deletion
                // remains recoverable across a crash or unlink failure.
                relativePaths: relativePaths,
                recordedAt: date
            )
        }
        journal.merge(newEntries) { _, new in new }

        // Do not install any process-local tombstone before this succeeds.
        // A failed delete must continue to resolve to its prior accepted
        // state, otherwise a retry could be falsely ACKed while UI remains.
        guard persistDeletionJournal(journal, in: directory) else {
            return false
        }

        runtime.deletionJournal = journal
        _ = recoverDeletionJournal(in: directory)
        return true
    }

    func recordDeleted(messageID: String) -> Bool {
        guard PrivateMediaMessageIdentity.isStableID(messageID) else {
            return false
        }
        return recordDeleted(messageIDs: [messageID])
    }

    /// Resolves every path a deletion transaction may target. The incoming
    /// allocator reserves this set at the journal barrier so a concurrent raw
    /// arrival cannot reuse a missing UI fallback.
    func prospectiveDeletionPayloadPaths(
        messageIDs: [String],
        payloadRelativePaths: [String: String]
    ) -> Set<String>? {
        let stableIDs = Set(
            messageIDs.filter(PrivateMediaMessageIdentity.isStableID)
        )
        guard !stableIDs.isEmpty else { return [] }

        runtime.lock.lock()
        defer { runtime.lock.unlock() }

        let date = now()
        guard let directory = resolvedReceiptDirectory(),
              loadDurableStateIfNeeded(from: directory, at: date) else {
            return nil
        }
        _ = recoverDeletionJournal(in: directory)
        guard let journal = runtime.deletionJournal,
              let records = runtime.records else {
            return nil
        }

        var paths: Set<String> = []
        for messageID in stableIDs {
            if let entry = journal[messageID] {
                paths.formUnion(entry.relativePaths)
                continue
            }
            if let relativePath = records[messageID]?.relativePath {
                paths.insert(relativePath)
            }
            if let relativePath = payloadRelativePaths[messageID] {
                paths.insert(relativePath)
            }
        }
        guard paths.allSatisfy({
            candidatePayload(relativePath: $0) != nil
        }) else {
            return nil
        }
        return Set(paths.compactMap {
            candidatePayload(relativePath: $0)?
                .standardizedFileURL.path
        })
    }

    /// Paths owned by accepted receipts, legacy pathful tombstones, or the
    /// deletion journal. Incoming allocation must not reuse any of them for a
    /// different ID. Quarantined records are unreadable, so any path they may
    /// have owned cannot be reserved; their bytes remain preserved in the
    /// `.corrupt` file for offline inspection.
    func reservedPayloadPaths() -> Set<String>? {
        runtime.lock.lock()
        defer { runtime.lock.unlock() }

        let date = now()
        guard let directory = resolvedReceiptDirectory(),
              loadDurableStateIfNeeded(from: directory, at: date) else {
            return nil
        }
        _ = recoverDeletionJournal(in: directory)
        guard let journal = runtime.deletionJournal,
              let records = runtime.records else {
            return nil
        }
        let recordPaths = records.values.compactMap(\.relativePath)
        let journalPaths = journal.values.flatMap(\.relativePaths)
        return Set((recordPaths + journalPaths).compactMap { relativePath in
            candidatePayload(relativePath: relativePath)?
                .standardizedFileURL.path
        })
    }

    private func scrubLegacyTombstone(
        _ tombstone: ReceiptRecord,
        messageID: String,
        in directory: URL,
        records: inout [String: ReceiptRecord]
    ) -> Bool {
        guard tombstone.kind == .tombstone,
              tombstone.relativePath != nil else {
            return true
        }
        // Pre-journal tombstones cannot prove that the current file is still
        // the payload they originally described. Older allocators did not
        // reserve these paths, so a raw/public arrival may have reused the
        // basename. Shed the ambiguous path without unlinking anything.
        let pathless = ReceiptRecord(
            kind: .tombstone,
            relativePath: nil,
            recordedAt: tombstone.recordedAt
        )
        guard persist(
            pathless,
            messageID: messageID,
            to: directory
        ) else {
            return false
        }
        records[messageID] = pathless
        runtime.records = records
        return true
    }

    private func loadDurableStateIfNeeded(
        from directory: URL,
        at date: Date
    ) -> Bool {
        if runtime.records != nil, runtime.deletionJournal != nil {
            return true
        }

        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            SecureLogger.error(
                "❌ Failed to create private-media receipt directory: \(error)",
                category: .session
            )
            return false
        }

        let urls: [URL]
        do {
            if let directoryReader {
                urls = try directoryReader(directory)
            } else {
                urls = try fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil,
                    options: []
                )
            }
        } catch {
            SecureLogger.error(
                "❌ Failed to enumerate private-media receipts: \(error)",
                category: .session
            )
            return false
        }

        var records: [String: ReceiptRecord] = [:]
        var scannedRecords: [String: ReceiptRecord] = [:]
        var quarantined: Set<String> = []
        var expired: [String] = []
        var tombstones: [(messageID: String, record: ReceiptRecord)] = []
        for url in urls {
            // Records quarantined by an earlier scan stay fail-closed on
            // every launch without being re-read: only their ID matters.
            if url.pathExtension == Self.quarantinePathExtension {
                let messageID = url
                    .deletingPathExtension()
                    .deletingPathExtension()
                    .lastPathComponent
                if PrivateMediaMessageIdentity.isStableID(messageID) {
                    quarantined.insert(messageID)
                }
                continue
            }
            guard url.pathExtension == "json" else { continue }
            let messageID = url.deletingPathExtension().lastPathComponent
            guard PrivateMediaMessageIdentity.isStableID(messageID) else {
                continue
            }

            let record: ReceiptRecord
            do {
                let data = try dataReader?(url) ?? Data(contentsOf: url)
                record = try JSONDecoder().decode(ReceiptRecord.self, from: data)
            } catch {
                // Never delete or silently skip an unreadable stable-ID
                // record: treating it as absent could resurrect accepted or
                // deleted media. But never let it poison the whole ledger
                // either — quarantine the file and fail only this ID closed.
                quarantine(url, messageID: messageID, reason: "\(error)")
                quarantined.insert(messageID)
                continue
            }

            guard isStructurallyValid(record) else {
                quarantine(
                    url,
                    messageID: messageID,
                    reason: "structurally invalid"
                )
                quarantined.insert(messageID)
                continue
            }
            scannedRecords[messageID] = record
            if record.kind == .tombstone {
                tombstones.append((messageID, record))
            }
            let retainsAcceptedPath =
                record.kind == .accepted
                    && record.relativePath.flatMap(existingPayload) != nil
            if isExpired(record.recordedAt, at: date),
               !retainsAcceptedPath {
                expired.append(messageID)
                continue
            }
            records[messageID] = record
        }

        // A readable duplicate of a quarantined ID must not override the
        // fail-closed decision, not even through the failed-prune restore
        // or legacy-tombstone scrub paths below.
        for messageID in quarantined {
            records.removeValue(forKey: messageID)
            scannedRecords.removeValue(forKey: messageID)
        }
        tombstones.removeAll { quarantined.contains($0.messageID) }

        let overflow = overflowVictims(in: records)
        for messageID in overflow {
            records.removeValue(forKey: messageID)
        }

        let journal: [String: DeletionJournalEntry]
        let journalURL = deletionJournalURL(in: directory)
        if fileManager.fileExists(atPath: journalURL.path) {
            do {
                let data = try dataReader?(journalURL)
                    ?? Data(contentsOf: journalURL)
                let snapshot = try JSONDecoder().decode(
                    DeletionJournal.self,
                    from: data
                )
                guard snapshot.version == 1,
                      snapshot.entries.count <= capacity,
                      snapshot.entries.allSatisfy({ messageID, entry in
                          PrivateMediaMessageIdentity.isStableID(messageID)
                              && !entry.relativePaths.isEmpty
                              && entry.relativePaths.count <=
                                Self.maximumDeletionPathsPerMessage
                              && Set(entry.relativePaths).count
                                == entry.relativePaths.count
                              && entry.relativePaths.allSatisfy {
                                  candidatePayload(relativePath: $0) != nil
                              }
                      }) else {
                    // The journal is a single batch commit file: like a
                    // directory-level failure it stays globally fail-closed
                    // and retryable, never quarantined per-ID.
                    SecureLogger.error(
                        "❌ Invalid private-media deletion journal",
                        category: .session
                    )
                    return false
                }
                journal = snapshot.entries
            } catch {
                // The journal is the all-ID commit record. It may never be
                // skipped or treated as empty when unreadable.
                SecureLogger.error(
                    "❌ Failed to read private-media deletion journal: \(error)",
                    category: .session
                )
                return false
            }
        } else {
            journal = [:]
        }

        var protectedFromPruning: Set<String> = []

        // Old per-ID tombstones may still carry a payload path from before the
        // deletion journal existed. That path is inherently ambiguous because
        // old allocators did not reserve it. Convert it to a pathless
        // tombstone without unlinking any current file.
        for (messageID, tombstone) in tombstones
        where journal[messageID] == nil
            && tombstone.relativePath != nil {
            let pathless = ReceiptRecord(
                kind: .tombstone,
                relativePath: nil,
                recordedAt: tombstone.recordedAt
            )
            guard persist(
                pathless,
                messageID: messageID,
                to: directory
            ) else {
                records[messageID] = tombstone
                protectedFromPruning.insert(messageID)
                continue
            }
            scannedRecords[messageID] = pathless
            if records[messageID] != nil {
                records[messageID] = pathless
            }
        }

        for messageID in expired + overflow {
            guard !protectedFromPruning.contains(messageID) else { continue }
            if !removeRecord(messageID: messageID, from: directory),
               let record = scannedRecords[messageID] {
                records[messageID] = record
            }
        }

        // Install caches only after every per-ID record and the batch journal
        // have been read and validated. Failed legacy cleanup remains indexed
        // and path-reserved instead of blocking unrelated media.
        runtime.records = records
        runtime.quarantined = quarantined
        runtime.deletionJournal = journal
        return true
    }

    /// Idempotently materializes the write-ahead journal. An entry leaves the
    /// journal only after its per-ID tombstone is durable and every recorded
    /// payload is absent. Any failure keeps the journal authoritative for a
    /// later lookup or process restart.
    @discardableResult
    private func recoverDeletionJournal(in directory: URL) -> Bool {
        guard let journal = runtime.deletionJournal,
              !journal.isEmpty,
              var records = runtime.records else {
            return true
        }

        let preservedMessageIDs = Set(journal.keys)
        var remaining = journal
        let orderedEntries = journal.sorted { lhs, rhs in
            if lhs.value.recordedAt == rhs.value.recordedAt {
                return lhs.key < rhs.key
            }
            return lhs.value.recordedAt < rhs.value.recordedAt
        }

        for (messageID, journalEntry) in orderedEntries {
            // Never materialize a per-ID record for a quarantined ID: the
            // scanner ignores readable duplicates of a quarantined record,
            // and quarantine is already permanently fail-closed
            // (state == .unavailable, commitAccepted refuses it), which
            // subsumes the tombstone's no-resurrection guarantee. Only the
            // payload unlinks below still need to run before the entry can
            // retire.
            if !runtime.quarantined.contains(messageID) {
                let pathlessTombstone = ReceiptRecord(
                    kind: .tombstone,
                    relativePath: nil,
                    recordedAt: journalEntry.recordedAt
                )
                if records[messageID] != pathlessTombstone {
                    let victim = capacityVictim(
                        for: .tombstone,
                        replacing: messageID,
                        in: records,
                        preserving: preservedMessageIDs
                    )
                    if records[messageID]?.kind != .tombstone,
                       records.values.lazy.filter({
                           $0.kind == .tombstone
                       }).count >= capacity,
                       victim == nil {
                        continue
                    }
                    guard persist(
                        pathlessTombstone,
                        messageID: messageID,
                        to: directory
                    ) else {
                        continue
                    }
                    records[messageID] = pathlessTombstone
                    if let victim, victim != messageID {
                        records.removeValue(forKey: victim)
                        removeRecord(messageID: victim, from: directory)
                    }
                }
            }

            // Only the journal retains the paths. Once every unlink succeeds,
            // the durable per-ID tombstone is pathless and cannot later
            // delete a different payload that reused the basename.
            let removedEveryPayload = journalEntry.relativePaths.allSatisfy {
                removePayloadRecordedByTombstone(ReceiptRecord(
                    kind: .tombstone,
                    relativePath: $0,
                    recordedAt: journalEntry.recordedAt
                ))
            }
            guard removedEveryPayload else {
                continue
            }
            remaining.removeValue(forKey: messageID)
        }

        runtime.records = records
        guard remaining != journal else { return false }

        if remaining.isEmpty {
            guard removeDeletionJournal(in: directory) else { return false }
        } else {
            guard persistDeletionJournal(remaining, in: directory) else {
                return false
            }
        }
        runtime.deletionJournal = remaining
        return remaining.isEmpty
    }

    private func persistDeletionJournal(
        _ entries: [String: DeletionJournalEntry],
        in directory: URL
    ) -> Bool {
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            let data = try JSONEncoder().encode(
                DeletionJournal(version: 1, entries: entries)
            )
            var options: Data.WritingOptions = [.atomic]
            #if os(iOS)
            options.insert(
                .completeFileProtectionUntilFirstUserAuthentication
            )
            #endif
            try dataWriter(data, deletionJournalURL(in: directory), options)
            return true
        } catch {
            SecureLogger.error(
                "❌ Failed to persist private-media deletion journal: \(error)",
                category: .session
            )
            return false
        }
    }

    private func removeDeletionJournal(in directory: URL) -> Bool {
        let url = deletionJournalURL(in: directory)
        guard fileManager.fileExists(atPath: url.path) else { return true }
        do {
            try fileManager.removeItem(at: url)
            return true
        } catch {
            SecureLogger.warning(
                "⚠️ Failed to retire private-media deletion journal: \(error)",
                category: .session
            )
            return false
        }
    }

    private func deletionJournalURL(in directory: URL) -> URL {
        directory.appendingPathComponent(
            Self.deletionJournalFileName,
            isDirectory: false
        )
    }

    /// Moves an unreadable record aside so future scans skip it while its ID
    /// stays fail-closed. The bytes are preserved for offline inspection —
    /// quarantine never deletes receiver decisions.
    private func quarantine(_ url: URL, messageID: String, reason: String) {
        SecureLogger.error(
            "❌ Quarantining unreadable private-media receipt \(messageID.prefix(12))…: \(reason)",
            category: .session
        )
        let destination = url.appendingPathExtension(
            Self.quarantinePathExtension
        )
        do {
            if fileManager.fileExists(atPath: destination.path) {
                // Same ID, already fail-closed; keep the earlier evidence.
                try fileManager.removeItem(at: url)
            } else {
                try fileManager.moveItem(at: url, to: destination)
            }
        } catch {
            // The record stays where it is and will be re-quarantined (in
            // memory at minimum) by the next scan. Still fail-closed.
            SecureLogger.warning(
                "⚠️ Failed to move corrupt private-media receipt aside: \(error)",
                category: .session
            )
        }
    }

    private func isStructurallyValid(_ record: ReceiptRecord) -> Bool {
        switch record.kind {
        case .tombstone:
            guard let relativePath = record.relativePath else { return true }
            return candidatePayload(relativePath: relativePath) != nil
        case .accepted:
            guard let relativePath = record.relativePath else { return false }
            return candidatePayload(relativePath: relativePath) != nil
        }
    }

    private func isExpired(_ recordedAt: Date, at date: Date) -> Bool {
        date.timeIntervalSince(recordedAt) > ttl
    }

    private func overflowVictims(
        in records: [String: ReceiptRecord]
    ) -> [String] {
        var victims: [String] = []
        for kind in [ReceiptRecord.Kind.accepted, .tombstone] {
            let allMatching = records.filter { $0.value.kind == kind }
            let overflow = allMatching.count - capacity
            guard overflow > 0 else { continue }
            let eligible = allMatching.filter { _, record in
                guard kind == .accepted else { return true }
                return record.relativePath.flatMap(existingPayload) == nil
            }
            victims.append(contentsOf: eligible.sorted { lhs, rhs in
                if lhs.value.recordedAt == rhs.value.recordedAt {
                    return lhs.key < rhs.key
                }
                return lhs.value.recordedAt < rhs.value.recordedAt
            }
            .prefix(overflow)
            .map(\.key))
        }
        return victims
    }

    /// Accepted receipts and tombstones have independent capacity. High media
    /// volume cannot evict explicit deletion intent, and vice versa.
    private func capacityVictim(
        for incomingKind: ReceiptRecord.Kind,
        replacing messageID: String,
        in records: [String: ReceiptRecord],
        preserving preservedMessageIDs: Set<String> = []
    ) -> String? {
        guard records[messageID]?.kind != incomingKind else { return nil }
        // During a live session an accepted receipt is the only durable owner
        // of its filename, even after quota removes the payload. Evicting it
        // here could let another ID reuse the path while the old bubble still
        // exists. The large capacity therefore acts as admission control.
        guard incomingKind != .accepted else { return nil }
        let matching = records.filter {
            $0.key != messageID
                && !preservedMessageIDs.contains($0.key)
                && $0.value.kind == incomingKind
        }
        let currentCount = records.values.lazy.filter {
            $0.kind == incomingKind
        }.count
        guard currentCount >= capacity else { return nil }
        return matching.min { lhs, rhs in
            if lhs.value.recordedAt == rhs.value.recordedAt {
                return lhs.key < rhs.key
            }
            return lhs.value.recordedAt < rhs.value.recordedAt
        }?.key
    }

    private func persist(
        _ record: ReceiptRecord,
        messageID: String,
        to directory: URL
    ) -> Bool {
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            let data = try JSONEncoder().encode(record)
            var options: Data.WritingOptions = [.atomic]
            #if os(iOS)
            options.insert(.completeFileProtectionUntilFirstUserAuthentication)
            #endif
            let url = recordURL(messageID: messageID, in: directory)
            try dataWriter(data, url, options)
            return true
        } catch {
            SecureLogger.error(
                "❌ Failed to persist private-media receipt \(messageID.prefix(12))…: \(error)",
                category: .session
            )
            return false
        }
    }

    @discardableResult
    private func removeRecord(
        messageID: String,
        from directory: URL
    ) -> Bool {
        let url = recordURL(messageID: messageID, in: directory)
        guard fileManager.fileExists(atPath: url.path) else { return true }
        do {
            try fileManager.removeItem(at: url)
            return true
        } catch {
            SecureLogger.warning(
                "⚠️ Failed to prune private-media receipt \(messageID.prefix(12))…: \(error)",
                category: .session
            )
            return false
        }
    }

    private func recordURL(messageID: String, in directory: URL) -> URL {
        directory
            .appendingPathComponent(messageID, isDirectory: false)
            .appendingPathExtension("json")
    }

    @discardableResult
    private func removePayloadRecordedByTombstone(
        _ record: ReceiptRecord
    ) -> Bool {
        guard record.kind == .tombstone,
              let relativePath = record.relativePath,
              let payload = candidatePayload(relativePath: relativePath),
              fileManager.fileExists(atPath: payload.path) else {
            return true
        }
        guard let values = try? payload.resourceValues(
            forKeys: [.isRegularFileKey]
        ),
        values.isRegularFile == true else {
            SecureLogger.warning(
                "⚠️ Refusing to remove non-file private-media payload",
                category: .session
            )
            return false
        }
        do {
            try payloadRemover(payload)
            return !fileManager.fileExists(atPath: payload.path)
        } catch {
            SecureLogger.warning(
                "⚠️ Failed to remove explicitly deleted private media: \(error)",
                category: .session
            )
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
        return (try? payload.resourceValues(
            forKeys: [.isRegularFileKey]
        ).isRegularFile) == true
    }

    private func validExistingPayload(_ url: URL) -> URL? {
        let standardized = url.standardizedFileURL
        guard isInsideIncomingMediaDirectory(standardized) else {
            return nil
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: standardized.path,
            isDirectory: &isDirectory
        ), !isDirectory.boolValue else {
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
        guard let filesRoot = try? filesDirectory().standardizedFileURL else {
            return false
        }
        let parentPath = url.standardizedFileURL
            .deletingLastPathComponent().path
        return [
            "voicenotes/incoming",
            "images/incoming",
            "files/incoming"
        ].contains { relativeDirectory in
            filesRoot.appendingPathComponent(
                relativeDirectory,
                isDirectory: true
            )
            .standardizedFileURL.path == parentPath
        }
    }

    private func resolvedReceiptDirectory() -> URL? {
        return try? filesDirectory().appendingPathComponent(
            Self.receiptDirectoryName,
            isDirectory: true
        )
    }

    private func filesDirectory() throws -> URL {
        let root = try baseDirectory ?? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let files = root.appendingPathComponent("files", isDirectory: true)
        try fileManager.createDirectory(
            at: files,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return files
    }
}
