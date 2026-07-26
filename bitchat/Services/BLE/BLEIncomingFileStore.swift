import BitLogger
import BitFoundation
import Foundation

struct PanicRecoveryIntent {
    let fileMarkerEstablished: Bool
    let externalMarkerEstablished: Bool

    var hasDurableMarker: Bool {
        fileMarkerEstablished || externalMarkerEstablished
    }
}

/// Small, dependency-injectable transaction surface used by ChatViewModel.
/// Production persists the same intent in two independent locations before
/// any application state is erased. Tests can inject an ephemeral operation
/// set without touching the developer's Application Support directory.
struct PanicRecoveryOperations {
    let isPending: () throws -> Bool
    let begin: () -> PanicRecoveryIntent
    let wipeMedia: (PanicRecoveryIntent) throws -> Void
    let complete: () throws -> Void

    static func ephemeral(
        wipeMedia: @escaping () throws -> Void = {}
    ) -> PanicRecoveryOperations {
        PanicRecoveryOperations(
            isPending: { false },
            begin: {
                PanicRecoveryIntent(
                    fileMarkerEstablished: false,
                    externalMarkerEstablished: false
                )
            },
            wipeMedia: { _ in try wipeMedia() },
            complete: {}
        )
    }

    static func live(
        fileStore: BLEIncomingFileStore = BLEIncomingFileStore(),
        defaults: UserDefaults = .standard
    ) -> PanicRecoveryOperations {
        let defaultsKey = "bitchat.panicResetPending"
        return PanicRecoveryOperations(
            isPending: {
                if defaults.bool(forKey: defaultsKey) {
                    return true
                }
                return try fileStore.isPanicRecoveryPending()
            },
            begin: {
                defaults.set(true, forKey: defaultsKey)
                let externalMarkerEstablished =
                    defaults.synchronize()
                    && defaults.bool(forKey: defaultsKey)

                let fileMarkerEstablished: Bool
                do {
                    try fileStore.markPanicRecoveryPending()
                    fileMarkerEstablished = true
                } catch {
                    fileMarkerEstablished = false
                    SecureLogger.error(
                        "Failed to persist file panic-recovery marker: \(error)",
                        category: .security
                    )
                }

                return PanicRecoveryIntent(
                    fileMarkerEstablished: fileMarkerEstablished,
                    externalMarkerEstablished: externalMarkerEstablished
                )
            },
            wipeMedia: { intent in
                try fileStore.panicWipe(
                    hasDurablePendingMarker: intent.hasDurableMarker
                )
            },
            complete: {
                // Keep the independent defaults latch until the file marker
                // has definitely cleared. Any failure therefore remains
                // visible to the next launch.
                try fileStore.completePanicRecovery()
                defaults.removeObject(forKey: defaultsKey)
                guard defaults.synchronize(),
                      !defaults.bool(forKey: defaultsKey) else {
                    throw BLEIncomingFileStore.PanicRecoveryError
                        .externalMarkerCommitFailed
                }
            }
        )
    }
}

struct BLEIncomingFileStore: @unchecked Sendable {
    enum PanicRecoveryError: Error {
        case externalMarkerCommitFailed
        case markerWriteFailed(Error)
        case markerWriteAndMediaWipeFailed(
            markerError: Error,
            mediaError: Error
        )
    }

    struct PrivateMediaDeletionReservation: Sendable {
        fileprivate let id: UUID
    }

    private final class PayloadCoordination: @unchecked Sendable {
        let lock = NSLock()
        var pendingDeliveryPaths: Set<String> = []
        var deletionReservations: [UUID: Set<String>] = [:]
    }

    private static let defaultQuotaBytes: Int64 = 100 * 1024 * 1024
    /// How long managed media may stay on disk. Bounds by age what the quota
    /// only bounds by size; see `expireAgedMedia(retention:)`.
    static let defaultMediaRetention: TimeInterval = 7 * 24 * 60 * 60
    /// Kept outside `files/` so deleting the media tree cannot erase the
    /// fail-closed startup decision before the full panic has committed.
    private static let panicRecoveryPendingMarkerFileName =
        ".panic-recovery-pending"
    /// Compatibility with a short-lived development build that used the
    /// media-specific name for the same full-transaction latch.
    private static let legacyPanicRecoveryPendingMarkerFileName =
        ".panic-media-wipe-pending"
    private static let mediaSubdirectories = [
        "voicenotes/incoming",
        "voicenotes/outgoing",
        "images/incoming",
        "images/outgoing",
        "files/incoming",
        "files/outgoing"
    ]
    /// Name prefix of in-flight live voice captures (progressively written by
    /// `ChatLiveVoiceCoordinator`). Quota eviction skips them by pattern —
    /// deleting one mid-stream unlinks the inode under an open `FileHandle`
    /// and kills playback — and the coordinator's startup sweep deletes any
    /// orphans a previous session left behind.
    static let liveCapturePrefix = "voice_live_"

    /// Exposed so callers that write progressively into the store's
    /// directories (live voice captures) share the same file manager.
    let fileManager: FileManager
    private let baseDirectory: URL?
    private let dateProvider: () -> Date
    private let panicMarkerWriter: (Data, URL) throws -> Void
    private let quotaBytes: Int64
    private let privateMediaReceipts: BLEPrivateMediaReceiptStore
    private let payloadCoordination: PayloadCoordination

    init(
        fileManager: FileManager = .default,
        baseDirectory: URL? = nil,
        dateProvider: @escaping () -> Date = Date.init,
        panicMarkerWriter: @escaping (Data, URL) throws -> Void = {
            try $0.write(to: $1, options: .atomic)
        },
        quotaBytes: Int64 = Self.defaultQuotaBytes
    ) {
        self.fileManager = fileManager
        self.baseDirectory = baseDirectory
        self.dateProvider = dateProvider
        self.panicMarkerWriter = panicMarkerWriter
        self.quotaBytes = max(0, quotaBytes)
        self.privateMediaReceipts = BLEPrivateMediaReceiptStore(
            fileManager: fileManager,
            baseDirectory: baseDirectory,
            now: dateProvider
        )
        self.payloadCoordination = PayloadCoordination()
    }

    /// Panic-wipe every managed incoming and outgoing media artifact before
    /// returning. Recreating the directory tree keeps later capture/receive
    /// paths usable without allowing a detached cleanup task to race them.
    ///
    /// Marker persistence and deletion are deliberately separate error
    /// domains: even when both durable marker channels fail, deletion is
    /// still attempted before this method reports the marker failure.
    func panicWipe(
        hasDurablePendingMarker: Bool = false
    ) throws {
        // The receipt index caches tombstones as well as accepted payloads,
        // while payload coordination retains save/delete reservations. Always
        // invalidate both on return, including partial-failure paths, so no
        // pre-panic receiver decision survives after identity reset.
        defer {
            privateMediaReceipts.resetForPanic()
            payloadCoordination.lock.lock()
            payloadCoordination.pendingDeliveryPaths.removeAll(
                keepingCapacity: false
            )
            payloadCoordination.deletionReservations.removeAll(
                keepingCapacity: false
            )
            payloadCoordination.lock.unlock()
        }

        let markerError: Error?
        do {
            try markPanicRecoveryPending()
            markerError = nil
        } catch {
            markerError = error
            SecureLogger.error(
                "Could not persist file panic-recovery marker; attempting media deletion anyway: \(error)",
                category: .security
            )
        }

        do {
            let filesDirectory = try rootDirectory()
                .appendingPathComponent("files", isDirectory: true)
            if fileManager.fileExists(atPath: filesDirectory.path) {
                try fileManager.removeItem(at: filesDirectory)
            }
            for subdirectory in Self.mediaSubdirectories {
                try fileManager.createDirectory(
                    at: filesDirectory.appendingPathComponent(
                        subdirectory,
                        isDirectory: true
                    ),
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            }
        } catch {
            if let markerError {
                throw PanicRecoveryError.markerWriteAndMediaWipeFailed(
                    markerError: markerError,
                    mediaError: error
                )
            }
            throw error
        }

        if let markerError, !hasDurablePendingMarker {
            throw PanicRecoveryError.markerWriteFailed(markerError)
        }
    }

    func markPanicRecoveryPending() throws {
        let markerURL = try panicRecoveryPendingMarkerURL()
        try fileManager.createDirectory(
            at: markerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try panicMarkerWriter(Data([1]), markerURL)
    }

    func isPanicRecoveryPending() throws -> Bool {
        try panicRecoveryMarkerURLs().contains {
            fileManager.fileExists(atPath: $0.path)
        }
    }

    func completePanicRecovery() throws {
        for markerURL in try panicRecoveryMarkerURLs()
        where fileManager.fileExists(atPath: markerURL.path) {
            try fileManager.removeItem(at: markerURL)
        }
    }

    /// Resolves (and creates) an incoming-media directory for callers that
    /// write progressively instead of via `save` (live voice captures).
    func incomingDirectory(subdirectory: String) throws -> URL {
        let directory = try filesDirectory().appendingPathComponent(subdirectory, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        return directory
    }

    func save(
        data: Data,
        preferredName: String?,
        subdirectory: String,
        fallbackExtension: String?,
        defaultPrefix: String
    ) -> URL? {
        payloadCoordination.lock.lock()
        defer { payloadCoordination.lock.unlock() }

        do {
            let base = try filesDirectory().appendingPathComponent(subdirectory, isDirectory: true)
            try fileManager.createDirectory(at: base, withIntermediateDirectories: true, attributes: nil)
            let sanitized = sanitizedFileName(
                preferredName,
                defaultName: "\(defaultPrefix)_\(Self.timestampString(from: dateProvider()))",
                fallbackExtension: fallbackExtension
            )
            let reservedPaths = privateMediaReceipts.reservedPayloadPaths()
            let deletionPaths = payloadCoordination
                .deletionReservations.values.reduce(into: Set<String>()) {
                    $0.formUnion($1)
                }
            let allocationReservations = deletionPaths.union(
                payloadCoordination.pendingDeliveryPaths
            )
            let destination = uniqueFileURL(
                in: base,
                fileName: sanitized,
                reservedPaths: (reservedPaths ?? []).union(
                    allocationReservations
                ),
                forceRandomizedName: reservedPaths == nil
            )
            try data.write(to: destination, options: .atomic)
            payloadCoordination.pendingDeliveryPaths.insert(
                destination.standardizedFileURL.path
            )
            return destination
        } catch {
            SecureLogger.error("❌ Failed to persist incoming media: \(error)", category: .session)
            return nil
        }
    }

    /// Drops THIS instance's in-memory receipt index after a panic wipe.
    ///
    /// `panicWipe` already resets the receipt store it runs on, but the
    /// production wipe runs on the `PanicRecoveryOperations.live()` file
    /// store while receipt lookups are served by `BLEService`'s own
    /// `incomingFileStore`. The service's panic path must invalidate its own
    /// cache explicitly or pre-panic decisions survive in memory.
    func resetPrivateMediaReceiptsForPanic() {
        privateMediaReceipts.resetForPanic()
    }

    func privateMediaReceiptState(
        messageID: String
    ) -> BLEPrivateMediaReceiptState {
        privateMediaReceipts.state(for: messageID)
    }

    func commitPrivateMediaFile(
        messageID: String,
        storedURL: URL
    ) -> Bool {
        privateMediaReceipts.commitAccepted(
            messageID: messageID,
            storedURL: storedURL
        )
    }

    /// Reserves every receipt/UI path before the asynchronous deletion
    /// barrier. Allocation and reservation share one lock, so either an
    /// in-flight raw arrival is observed and deletion fails closed, or the
    /// arrival is forced onto a different filename.
    func reservePrivateMediaDeletion(
        messageIDs: [String],
        payloadRelativePaths: [String: String]
    ) -> PrivateMediaDeletionReservation? {
        payloadCoordination.lock.lock()
        defer { payloadCoordination.lock.unlock() }

        guard let paths = privateMediaReceipts
            .prospectiveDeletionPayloadPaths(
                messageIDs: messageIDs,
                payloadRelativePaths: payloadRelativePaths
            ),
        paths.isDisjoint(
            with: payloadCoordination.pendingDeliveryPaths
        ) else {
            return nil
        }

        let reservation = PrivateMediaDeletionReservation(id: UUID())
        payloadCoordination.deletionReservations[reservation.id] = paths
        return reservation
    }

    func commitPrivateMediaDeletion(
        reservation: PrivateMediaDeletionReservation,
        messageIDs: [String],
        payloadRelativePaths: [String: String],
        protectedPayloadRelativePaths: Set<String>
    ) -> Bool {
        payloadCoordination.lock.lock()
        defer {
            payloadCoordination.deletionReservations.removeValue(
                forKey: reservation.id
            )
            payloadCoordination.lock.unlock()
        }
        guard payloadCoordination.deletionReservations[reservation.id] != nil
        else {
            return false
        }
        return privateMediaReceipts.recordDeleted(
            messageIDs: messageIDs,
            payloadRelativePaths: payloadRelativePaths,
            protectedPayloadRelativePaths: protectedPayloadRelativePaths
        )
    }

    /// Explicit deletion of a LEGACY (non-stable-ID) incoming payload.
    ///
    /// Legacy media has no durable receipt, so the only safe unlink is one
    /// that can prove no other owner may hold the basename: the path must
    /// not be pending delivery, must not belong to an in-flight deletion
    /// reservation, and must not be owned by a stable receipt or journal
    /// entry. When any of those hold — or receipt state cannot be read —
    /// the file stays for bounded quota cleanup (the fail-safe fallback).
    /// Returns true only when the payload was verifiably unlinked.
    @discardableResult
    func removeLegacyIncomingFile(relativePath: String) -> Bool {
        payloadCoordination.lock.lock()
        defer { payloadCoordination.lock.unlock() }

        guard let payload = incomingPayloadURL(
            relativePath: relativePath
        ) else {
            return false
        }
        let standardizedPath = payload.standardizedFileURL.path
        let reservedByDeletion = payloadCoordination.deletionReservations
            .values.contains { $0.contains(standardizedPath) }
        guard !reservedByDeletion,
              !payloadCoordination.pendingDeliveryPaths.contains(
                  standardizedPath
              ),
              let receiptOwnedPaths =
                privateMediaReceipts.reservedPayloadPaths(),
              !receiptOwnedPaths.contains(standardizedPath) else {
            return false
        }
        guard fileManager.fileExists(atPath: payload.path),
              (try? payload.resourceValues(
                  forKeys: [.isRegularFileKey]
              ).isRegularFile) == true else {
            return false
        }
        do {
            try fileManager.removeItem(at: payload)
            return !fileManager.fileExists(atPath: payload.path)
        } catch {
            SecureLogger.warning(
                "⚠️ Failed to remove explicitly deleted legacy media: \(error)",
                category: .session
            )
            return false
        }
    }

    /// Resolves a `files/`-relative path iff it lands directly inside one of
    /// the incoming media directories. Anything else is not a deletable
    /// incoming payload.
    private func incomingPayloadURL(relativePath: String) -> URL? {
        guard !relativePath.isEmpty,
              let base = try? filesDirectory().standardizedFileURL else {
            return nil
        }
        let candidate = base
            .appendingPathComponent(relativePath, isDirectory: false)
            .standardizedFileURL
        let parentPath = candidate.deletingLastPathComponent().path
        let incomingDirectories = [
            "voicenotes/incoming",
            "images/incoming",
            "files/incoming"
        ]
        guard incomingDirectories.contains(where: { relativeDirectory in
            base.appendingPathComponent(
                relativeDirectory,
                isDirectory: true
            ).standardizedFileURL.path == parentPath
        }) else {
            return nil
        }
        return candidate
    }

    /// Releases the short window between disk save and synchronous
    /// conversation insertion. Before this callback, a deletion transaction
    /// may not infer ownership from a stale bubble that names the same path.
    func finishIncomingFileDelivery(at storedURL: URL) {
        payloadCoordination.lock.lock()
        defer { payloadCoordination.lock.unlock() }
        payloadCoordination.pendingDeliveryPaths.remove(
            storedURL.standardizedFileURL.path
        )
    }

    /// Best-effort rollback for a payload whose durable receipt commit failed.
    func removeIncomingFile(at storedURL: URL) {
        payloadCoordination.lock.lock()
        defer { payloadCoordination.lock.unlock() }
        payloadCoordination.pendingDeliveryPaths.remove(
            storedURL.standardizedFileURL.path
        )
        guard isURLInsideFilesDirectory(storedURL) else { return }
        do {
            try fileManager.removeItem(at: storedURL)
        } catch {
            SecureLogger.warning(
                "⚠️ Failed to roll back uncommitted incoming media: \(error)",
                category: .session
            )
        }
    }

    /// Frees least-recently-modified incoming files until `reservingBytes`
    /// fits under the quota. Files named `voice_live_*` (in-flight live
    /// captures) are never evicted regardless of who triggers enforcement —
    /// a finalized transfer can arrive at quota while a burst is still
    /// streaming — but they still count toward usage.
    func enforceQuota(reservingBytes: Int) {
        payloadCoordination.lock.lock()
        defer { payloadCoordination.lock.unlock() }

        do {
            let base = try filesDirectory()
            let incomingDirs = [
                base.appendingPathComponent("voicenotes/incoming", isDirectory: true),
                base.appendingPathComponent("images/incoming", isDirectory: true),
                base.appendingPathComponent("files/incoming", isDirectory: true)
            ]
            var allFiles: [(url: URL, size: Int64, modified: Date)] = []

            for dir in incomingDirs where fileManager.fileExists(atPath: dir.path) {
                guard let contents = try? fileManager.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for fileURL in contents {
                    guard let attrs = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                          let size = attrs.fileSize,
                          let modified = attrs.contentModificationDate else { continue }
                    allFiles.append((url: fileURL, size: Int64(size), modified: modified))
                }
            }

            let currentUsage = allFiles.reduce(0) { $0 + $1.size }
            let targetUsage = quotaBytes - Int64(reservingBytes)
            guard currentUsage > targetUsage else { return }

            let needToFree = currentUsage - targetUsage
            let activeDeletionPaths = payloadCoordination
                .deletionReservations.values.reduce(into: Set<String>()) {
                    $0.formUnion($1)
                }
            let protectedPaths = activeDeletionPaths.union(
                payloadCoordination.pendingDeliveryPaths
            )
            var freedSpace: Int64 = 0
            for file in allFiles.sorted(by: { $0.modified < $1.modified }) {
                guard freedSpace < needToFree else { break }
                guard !file.url.lastPathComponent.hasPrefix(Self.liveCapturePrefix) else { continue }
                guard !protectedPaths.contains(
                    file.url.standardizedFileURL.path
                ) else {
                    continue
                }
                do {
                    try fileManager.removeItem(at: file.url)
                    freedSpace += file.size
                    SecureLogger.debug("🗑️ BCH-01-002: Deleted old incoming file to free space: \(file.url.lastPathComponent)", category: .security)
                } catch {
                    SecureLogger.warning("⚠️ Failed to delete old file for quota: \(error)", category: .security)
                }
            }

            if freedSpace > 0 {
                SecureLogger.info("📊 BCH-01-002: Freed \(ByteCountFormatter.string(fromByteCount: freedSpace, countStyle: .file)) to stay within incoming files quota", category: .security)
            }
        } catch {
            SecureLogger.warning("⚠️ Could not enforce storage quota: \(error)", category: .security)
        }
    }

    /// Deletes managed media older than `retention`, across both incoming and
    /// outgoing directories, and reports how many files went away.
    ///
    /// The quota sweep above only bounds *size*, and only for incoming files,
    /// so a received photo or a sent voice note could sit on disk unbounded in
    /// time — long outliving the conversation it belonged to, which is what a
    /// seized device gives up. This bounds media by age instead, on the same
    /// principle as the courier envelope and gossip archive lifetimes.
    ///
    /// Honors the same exclusions as quota eviction: in-flight live captures
    /// and files reserved by an in-progress delivery or deletion are left
    /// alone regardless of age.
    @discardableResult
    func expireAgedMedia(retention: TimeInterval = Self.defaultMediaRetention) -> Int {
        guard retention > 0 else { return 0 }

        payloadCoordination.lock.lock()
        defer { payloadCoordination.lock.unlock() }

        let cutoff = dateProvider().addingTimeInterval(-retention)
        let activeDeletionPaths = payloadCoordination
            .deletionReservations.values.reduce(into: Set<String>()) {
                $0.formUnion($1)
            }
        let protectedPaths = activeDeletionPaths.union(
            payloadCoordination.pendingDeliveryPaths
        )

        var removed = 0
        do {
            let base = try filesDirectory()
            for subdirectory in Self.mediaSubdirectories {
                let dir = base.appendingPathComponent(subdirectory, isDirectory: true)
                guard fileManager.fileExists(atPath: dir.path) else { continue }
                guard let contents = try? fileManager.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for fileURL in contents {
                    guard let modified = try? fileURL.resourceValues(
                        forKeys: [.contentModificationDateKey]
                    ).contentModificationDate else { continue }
                    guard modified < cutoff else { continue }
                    guard !fileURL.lastPathComponent.hasPrefix(Self.liveCapturePrefix) else { continue }
                    guard !protectedPaths.contains(
                        fileURL.standardizedFileURL.path
                    ) else { continue }

                    do {
                        try fileManager.removeItem(at: fileURL)
                        removed += 1
                    } catch {
                        SecureLogger.warning(
                            "⚠️ Failed to expire aged media file: \(error)",
                            category: .security
                        )
                    }
                }
            }
        } catch {
            SecureLogger.warning(
                "⚠️ Could not expire aged media: \(error)",
                category: .security
            )
            return removed
        }

        if removed > 0 {
            SecureLogger.info(
                "🗑️ Expired \(removed) media file(s) older than the retention window",
                category: .security
            )
        }
        return removed
    }

    private func filesDirectory() throws -> URL {
        let filesDir = try rootDirectory().appendingPathComponent("files", isDirectory: true)
        try fileManager.createDirectory(at: filesDir, withIntermediateDirectories: true, attributes: nil)
        return filesDir
    }

    private func rootDirectory() throws -> URL {
        try baseDirectory ?? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    private func panicRecoveryPendingMarkerURL() throws -> URL {
        try rootDirectory().appendingPathComponent(
            Self.panicRecoveryPendingMarkerFileName,
            isDirectory: false
        )
    }

    private func panicRecoveryMarkerURLs() throws -> [URL] {
        let root = try rootDirectory()
        return [
            root.appendingPathComponent(
                Self.panicRecoveryPendingMarkerFileName,
                isDirectory: false
            ),
            root.appendingPathComponent(
                Self.legacyPanicRecoveryPendingMarkerFileName,
                isDirectory: false
            )
        ]
    }

    private func isURLInsideFilesDirectory(_ url: URL) -> Bool {
        guard let filesDirectory = try? filesDirectory().standardizedFileURL else {
            return false
        }
        return url.standardizedFileURL.path.hasPrefix(filesDirectory.path + "/")
    }

    private func sanitizedFileName(_ name: String?, defaultName: String, fallbackExtension: String?) -> String {
        var candidate = (name ?? "")
            .replacingOccurrences(of: "\0", with: "")
            .precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")

        let invalid = CharacterSet(charactersIn: "<>:\"|?*\0").union(.controlCharacters)
        candidate = candidate.components(separatedBy: invalid).joined(separator: "_").trimmed
        if candidate.isEmpty { candidate = defaultName }
        if candidate.hasPrefix(".") { candidate = "_" + candidate }

        if candidate.count > 120 {
            let ext = (candidate as NSString).pathExtension
            let base = (candidate as NSString).deletingPathExtension
            candidate = ext.isEmpty
                ? String(candidate.prefix(120))
                : String(base.prefix(max(10, 120 - ext.count - 1))) + "." + ext
        }

        if let fallbackExtension, (candidate as NSString).pathExtension.isEmpty {
            candidate += ".\(fallbackExtension)"
        }

        return candidate.isEmpty ? defaultName : candidate
    }

    private func uniqueFileURL(
        in directory: URL,
        fileName: String,
        reservedPaths: Set<String>,
        forceRandomizedName: Bool
    ) -> URL {
        let directoryPath = directory.standardizedFileURL.path
        func isInsideDirectory(_ url: URL) -> Bool {
            url.standardizedFileURL.path.hasPrefix(directoryPath + "/")
        }
        func isAvailable(_ url: URL) -> Bool {
            !reservedPaths.contains(url.standardizedFileURL.path)
                && !fileManager.fileExists(atPath: url.path)
        }

        var candidate = directory.appendingPathComponent(fileName)
        guard isInsideDirectory(candidate) else {
            SecureLogger.warning("⚠️ Path traversal blocked: \(fileName)", category: .security)
            return directory.appendingPathComponent("blocked_\(UUID().uuidString)")
        }

        let baseName = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        if forceRandomizedName {
            let suffix = UUID().uuidString
            let randomizedName = ext.isEmpty
                ? "\(baseName)_\(suffix)"
                : "\(baseName)_\(suffix).\(ext)"
            return directory.appendingPathComponent(randomizedName)
        }

        if isAvailable(candidate) {
            return candidate
        }

        for counter in 1..<100 {
            let newName = ext.isEmpty ? "\(baseName) (\(counter))" : "\(baseName) (\(counter)).\(ext)"
            candidate = directory.appendingPathComponent(newName)
            guard isInsideDirectory(candidate) else {
                return directory.appendingPathComponent("blocked_\(UUID().uuidString)")
            }
            if isAvailable(candidate) {
                return candidate
            }
        }

        return directory.appendingPathComponent("\(baseName)_\(UUID().uuidString).\(ext.isEmpty ? "dat" : ext)")
    }

    private static func timestampString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: date)
    }
}
