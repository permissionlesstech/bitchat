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
/// itself (create/enumerate) remains globally fail-closed and retryable.
/// An individual record that cannot be read, decoded, or validated is
/// quarantined instead: the file is moved aside with a `.corrupt` suffix,
/// excluded from future scans, and only that ID stays fail-closed — the rest
/// of the ledger keeps working, so one damaged record can never make every
/// inbound private media payload vanish.
final class BLEPrivateMediaReceiptStore: @unchecked Sendable {
    typealias DirectoryReader = (_ directory: URL) throws -> [URL]
    typealias DataReader = (_ url: URL) throws -> Data
    private static let receiptDirectoryName = ".private-media-receipts"
    private static let quarantinePathExtension = "corrupt"

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

    private final class Runtime: @unchecked Sendable {
        let lock = NSLock()
        var records: [String: ReceiptRecord]?
        /// IDs whose durable record was quarantined as unreadable. Installed
        /// together with `records`; these IDs stay fail-closed while every
        /// other record keeps serving.
        var quarantined: Set<String> = []
        var volatileTombstones: [String: Date] = [:]
    }

    private let fileManager: FileManager
    private let baseDirectory: URL?
    private let capacity: Int
    private let ttl: TimeInterval
    private let now: () -> Date
    private let directoryReader: DirectoryReader?
    private let dataReader: DataReader?
    private let runtime = Runtime()

    init(
        fileManager: FileManager = .default,
        baseDirectory: URL? = nil,
        capacity: Int = TransportConfig.privateMediaReceivedLedgerCapacity,
        ttl: TimeInterval = TransportConfig.privateMediaReceivedLedgerTTLSeconds,
        now: @escaping () -> Date = Date.init,
        directoryReader: DirectoryReader? = nil,
        dataReader: DataReader? = nil
    ) {
        self.fileManager = fileManager
        self.baseDirectory = baseDirectory
        self.capacity = max(1, capacity)
        self.ttl = max(0, ttl)
        self.now = now
        self.directoryReader = directoryReader
        self.dataReader = dataReader
    }

    /// Drops process-lifetime decisions after the enclosing media directory
    /// has been panic-wiped. A later lookup must rebuild from the durable
    /// ledger instead of retaining an accepted receipt or tombstone whose
    /// backing files no longer exist.
    func resetForPanic() {
        runtime.lock.lock()
        runtime.records = nil
        runtime.quarantined.removeAll(keepingCapacity: false)
        runtime.volatileTombstones.removeAll(keepingCapacity: false)
        runtime.lock.unlock()
    }

    func state(for messageID: String) -> BLEPrivateMediaReceiptState {
        guard PrivateMediaMessageIdentity.isStableID(messageID) else {
            return .absent
        }

        runtime.lock.lock()
        defer { runtime.lock.unlock() }

        let date = now()
        if let tombstonedAt = runtime.volatileTombstones[messageID] {
            if !isExpired(tombstonedAt, at: date) {
                return .tombstoned
            }
            runtime.volatileTombstones.removeValue(forKey: messageID)
        }

        guard let directory = resolvedReceiptDirectory(),
              var records = loadIndexIfNeeded(from: directory, at: date) else {
            return .unavailable
        }
        // A quarantined record could have been an acceptance or a tombstone;
        // only this ID fails closed, so a retry can neither resurrect deleted
        // media nor double-deliver, while every other payload keeps working.
        if runtime.quarantined.contains(messageID) {
            return .unavailable
        }
        guard let record = records[messageID] else { return .absent }

        if isExpired(record.recordedAt, at: date) {
            records.removeValue(forKey: messageID)
            runtime.records = records
            removeRecord(messageID: messageID, from: directory)
            return .absent
        }

        switch record.kind {
        case .tombstone:
            removePayloadRecordedByTombstone(record)
            return .tombstoned

        case .accepted:
            guard let relativePath = record.relativePath,
                  let existingURL = existingPayload(relativePath: relativePath) else {
                // Quota cleanup is not explicit deletion. Remove the stale
                // receipt so a sender retry can restore the payload and bubble.
                records.removeValue(forKey: messageID)
                runtime.records = records
                removeRecord(messageID: messageID, from: directory)
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
        if let tombstonedAt = runtime.volatileTombstones[messageID],
           !isExpired(tombstonedAt, at: date) {
            return false
        }

        guard let directory = resolvedReceiptDirectory(),
              var records = loadIndexIfNeeded(from: directory, at: date),
              !runtime.quarantined.contains(messageID) else {
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

    /// Foundation for explicit media deletion. This branch does not wire the
    /// chat-clear UI; it only makes a tombstone durable and fail closed.
    func recordDeleted(messageID: String) -> Bool {
        guard PrivateMediaMessageIdentity.isStableID(messageID) else {
            return false
        }

        runtime.lock.lock()
        defer { runtime.lock.unlock() }

        let date = now()
        addVolatileTombstone(messageID, at: date)

        guard let directory = resolvedReceiptDirectory(),
              var records = loadIndexIfNeeded(from: directory, at: date),
              !runtime.quarantined.contains(messageID) else {
            runtime.volatileTombstones.removeValue(forKey: messageID)
            return false
        }
        if let existing = records[messageID],
           existing.kind == .tombstone,
           !isExpired(existing.recordedAt, at: date) {
            runtime.volatileTombstones.removeValue(forKey: messageID)
            removePayloadRecordedByTombstone(existing)
            return true
        }

        let victim = capacityVictim(
            for: .tombstone,
            replacing: messageID,
            in: records
        )
        if records[messageID]?.kind != .tombstone,
           records.values.lazy.filter({ $0.kind == .tombstone }).count >= capacity,
           victim == nil {
            runtime.volatileTombstones.removeValue(forKey: messageID)
            return false
        }

        let tombstone = ReceiptRecord(
            kind: .tombstone,
            // Retain the accepted path so a crash between the atomic record
            // write and payload unlink can finish cleanup after relaunch.
            relativePath: records[messageID]?.relativePath,
            recordedAt: date
        )
        guard persist(tombstone, messageID: messageID, to: directory) else {
            runtime.volatileTombstones.removeValue(forKey: messageID)
            return false
        }

        records[messageID] = tombstone
        if let victim, victim != messageID {
            records.removeValue(forKey: victim)
            removeRecord(messageID: victim, from: directory)
        }
        runtime.records = records
        runtime.volatileTombstones.removeValue(forKey: messageID)
        removePayloadRecordedByTombstone(tombstone)
        return true
    }

    private func loadIndexIfNeeded(
        from directory: URL,
        at date: Date
    ) -> [String: ReceiptRecord]? {
        if let records = runtime.records {
            return records
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
            return nil
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
            return nil
        }

        var records: [String: ReceiptRecord] = [:]
        var quarantined: Set<String> = []
        var expired: [String] = []
        var tombstones: [ReceiptRecord] = []
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
            if isExpired(record.recordedAt, at: date) {
                expired.append(messageID)
                continue
            }
            records[messageID] = record
            if record.kind == .tombstone {
                tombstones.append(record)
            }
        }

        // A readable duplicate of a quarantined ID must not override the
        // fail-closed decision.
        for messageID in quarantined {
            records.removeValue(forKey: messageID)
        }

        let overflow = overflowVictims(in: records)
        for messageID in overflow {
            records.removeValue(forKey: messageID)
        }

        // Install the index only after the whole directory was scanned.
        // Cleanup cannot influence a failed scan.
        runtime.records = records
        runtime.quarantined = quarantined

        for messageID in expired + overflow {
            removeRecord(messageID: messageID, from: directory)
        }
        for tombstone in tombstones {
            removePayloadRecordedByTombstone(tombstone)
        }
        return records
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
            let matching = records.filter { $0.value.kind == kind }
            let overflow = matching.count - capacity
            guard overflow > 0 else { continue }
            victims.append(contentsOf: matching.sorted { lhs, rhs in
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
        in records: [String: ReceiptRecord]
    ) -> String? {
        guard records[messageID]?.kind != incomingKind else { return nil }
        let matching = records.filter {
            $0.key != messageID && $0.value.kind == incomingKind
        }
        guard matching.count >= capacity else { return nil }
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
            try data.write(to: url, options: options)
            return true
        } catch {
            SecureLogger.error(
                "❌ Failed to persist private-media receipt \(messageID.prefix(12))…: \(error)",
                category: .session
            )
            return false
        }
    }

    private func removeRecord(messageID: String, from directory: URL) {
        let url = recordURL(messageID: messageID, in: directory)
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            SecureLogger.warning(
                "⚠️ Failed to prune private-media receipt \(messageID.prefix(12))…: \(error)",
                category: .session
            )
        }
    }

    private func recordURL(messageID: String, in directory: URL) -> URL {
        directory
            .appendingPathComponent(messageID, isDirectory: false)
            .appendingPathExtension("json")
    }

    private func removePayloadRecordedByTombstone(_ record: ReceiptRecord) {
        guard record.kind == .tombstone,
              let relativePath = record.relativePath,
              let payload = candidatePayload(relativePath: relativePath),
              fileManager.fileExists(atPath: payload.path) else {
            return
        }
        do {
            try fileManager.removeItem(at: payload)
        } catch {
            SecureLogger.warning(
                "⚠️ Failed to remove explicitly deleted private media: \(error)",
                category: .session
            )
        }
    }

    private func addVolatileTombstone(_ messageID: String, at date: Date) {
        runtime.volatileTombstones[messageID] = date
        let overflow = runtime.volatileTombstones.count - capacity
        guard overflow > 0 else { return }
        let oldest = runtime.volatileTombstones.sorted {
            if $0.value == $1.value { return $0.key < $1.key }
            return $0.value < $1.value
        }
        for (oldMessageID, _) in oldest.prefix(overflow) {
            runtime.volatileTombstones.removeValue(forKey: oldMessageID)
        }
    }

    private func validExistingPayload(_ url: URL) -> URL? {
        let standardized = url.standardizedFileURL
        guard isInsideFilesDirectory(standardized) else { return nil }
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
        guard candidate.path.hasPrefix(filesRoot.path + "/") else { return nil }
        return candidate
    }

    private func isInsideFilesDirectory(_ url: URL) -> Bool {
        guard let filesRoot = try? filesDirectory().standardizedFileURL else {
            return false
        }
        return url.standardizedFileURL.path.hasPrefix(filesRoot.path + "/")
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
