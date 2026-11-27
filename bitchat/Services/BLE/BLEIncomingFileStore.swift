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
        fileStore: BLEIncomingFileStore = .shared,
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
    /// Shared production store so `BLEService`, `PanicRecoveryOperations`,
    /// `ChatLiveVoiceCoordinator`, and startup maintenance operate on a single
    /// receipt cache and directory cache.
    static let shared = BLEIncomingFileStore()

    enum PanicRecoveryError: Error {
        case externalMarkerCommitFailed
        case markerWriteFailed(Error)
        case markerWriteAndMediaWipeFailed(
            markerError: Error,
            mediaError: Error
        )
    }

    private final class PendingDeliveryTracker: @unchecked Sendable {
        let lock = NSLock()
        var pendingDeliveryCounts: [String: Int] = [:]

        func removeAll() {
            lock.lock()
            defer { lock.unlock() }
            pendingDeliveryCounts.removeAll(keepingCapacity: false)
        }

        func beginPendingDelivery(path: String) {
            lock.lock()
            defer { lock.unlock() }
            pendingDeliveryCounts[path, default: 0] += 1
        }

        func finishPendingDelivery(path: String) {
            lock.lock()
            defer { lock.unlock() }
            if let count = pendingDeliveryCounts[path] {
                if count <= 1 {
                    pendingDeliveryCounts.removeValue(forKey: path)
                } else {
                    pendingDeliveryCounts[path] = count - 1
                }
            }
        }

        func pendingDeliveryPathsSnapshot() -> Set<String> {
            lock.lock()
            defer { lock.unlock() }
            return Set(pendingDeliveryCounts.keys)
        }
    }

    private static let defaultQuotaBytes: Int64 = 100 * 1024 * 1024
    /// How long managed media may stay on disk. Bounds by age what the quota
    /// only bounds by size; see `expireAgedMedia(retention:)`.
    static let defaultMediaRetention: TimeInterval = 7 * 24 * 60 * 60
    /// Kept outside `files/` so deleting the media tree cannot erase the
    /// fail-closed startup decision before the full panic has committed.
    private static let panicRecoveryPendingMarkerFileName = ".panic-recovery-pending"
    private static let legacyPanicRecoveryPendingMarkerFileName = ".panic-media-wipe-pending"
    private static let mediaSubdirectories = [
        "voicenotes/incoming",
        "voicenotes/outgoing",
        "images/incoming",
        "images/outgoing",
        "files/incoming",
        "files/outgoing"
    ]
    private static let incomingSubdirectories = [
        "voicenotes/incoming",
        "images/incoming",
        "files/incoming"
    ]
    private static let invalidFilenameCharacters =
        CharacterSet(charactersIn: "<>:\"|?*\0").union(.controlCharacters)
    /// Name prefix of in-flight live voice captures (progressively written by
    /// `ChatLiveVoiceCoordinator`). Quota eviction skips them by pattern —
    /// deleting one mid-stream unlinks the inode under an open `FileHandle`
    /// and kills playback — and the coordinator's startup sweep deletes any
    /// orphans a previous session left behind.
    static let liveCapturePrefix = "voice_live_"

    static var mediaProtectionAttributes: [FileAttributeKey: Any]? {
        #if os(iOS)
        return [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #else
        return nil
        #endif
    }

    /// Exposed so callers that write progressively into the store's
    /// directories (live voice captures) share the same file manager.
    let fileManager: FileManager
    private let baseDirectory: URL?
    private let dateProvider: () -> Date
    private let panicMarkerWriter: (Data, URL) throws -> Void
    private let quotaBytes: Int64
    private let privateMediaReceipts: BLEPrivateMediaReceiptStore
    private let pendingDeliveryTracker: PendingDeliveryTracker

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
        self.pendingDeliveryTracker = PendingDeliveryTracker()
    }

    /// Panic-wipe every managed incoming and outgoing media artifact before
    /// returning. Recreating the directory tree keeps later capture/receive
    /// paths usable without allowing a detached cleanup task to race them.
    func panicWipe(hasDurablePendingMarker: Bool = false) throws {
        defer {
            privateMediaReceipts.resetForPanic()
            pendingDeliveryTracker.removeAll()
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
                    at: filesDirectory.appendingPathComponent(subdirectory, isDirectory: true),
                    withIntermediateDirectories: true,
                    attributes: Self.mediaProtectionAttributes
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
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: Self.mediaProtectionAttributes)
        return directory
    }

    /// Writes an incoming payload to a globally unique `<uuid>_<sanitizedName>`
    /// file so distinct transfers, retries, and post-eviction arrivals never
    /// collide on a shared basename.
    func save(
        data: Data,
        preferredName: String?,
        subdirectory: String,
        fallbackExtension: String?,
        defaultPrefix: String
    ) -> URL? {
        do {
            let base = try filesDirectory().appendingPathComponent(subdirectory, isDirectory: true)
            try fileManager.createDirectory(at: base, withIntermediateDirectories: true, attributes: Self.mediaProtectionAttributes)
            let sanitized = sanitizedFileName(
                preferredName,
                defaultName: "\(defaultPrefix)_\(Self.timestampString(from: dateProvider()))",
                fallbackExtension: fallbackExtension
            )
            let destination = uniqueFileURL(in: base, sanitizedName: sanitized)
            var options: Data.WritingOptions = [.atomic]
            #if os(iOS)
            options.insert(.completeFileProtectionUntilFirstUserAuthentication)
            #endif
            try data.write(to: destination, options: options)
            return destination
        } catch {
            SecureLogger.error("❌ Failed to persist incoming media: \(error)", category: .session)
            return nil
        }
    }

    func resetPrivateMediaReceiptsForPanic() {
        privateMediaReceipts.resetForPanic()
        pendingDeliveryTracker.removeAll()
    }

    /// Marks an incoming file as awaiting asynchronous UI delivery so quota
    /// eviction and age-based retention cannot unlink it before the UI receives
    /// the message. Ref-counted per standardized path.
    func beginPendingDelivery(at url: URL) {
        pendingDeliveryTracker.beginPendingDelivery(path: url.standardizedFileURL.path)
    }

    func finishPendingDelivery(at url: URL) {
        pendingDeliveryTracker.finishPendingDelivery(path: url.standardizedFileURL.path)
    }

    func privateMediaReceiptState(messageID: String) -> BLEPrivateMediaReceiptState {
        privateMediaReceipts.state(for: messageID)
    }

    func commitPrivateMediaFile(messageID: String, storedURL: URL) -> Bool {
        privateMediaReceipts.commitAccepted(messageID: messageID, storedURL: storedURL)
    }

    func commitPrivateMediaDeletion(
        messageIDs: [String],
        payloadRelativePaths: [String: String]
    ) -> Bool {
        privateMediaReceipts.recordDeleted(
            messageIDs: messageIDs,
            payloadRelativePaths: payloadRelativePaths
        )
    }

    /// Explicit deletion of a legacy (non-stable-ID) incoming payload.
    /// Deletes only regular files directly inside an incoming media directory
    /// that are not owned by any stable receipt.
    @discardableResult
    func removeLegacyIncomingFile(relativePath: String) -> Bool {
        guard let payload = incomingPayloadURL(relativePath: relativePath),
              privateMediaReceipts.isPayloadOwned(relativePath: relativePath) == false else {
            return false
        }
        guard fileManager.fileExists(atPath: payload.path),
              (try? payload.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
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

    /// Best-effort rollback for a payload whose durable receipt commit failed
    /// or whose raw delivery was rejected.
    func removeIncomingFile(at storedURL: URL) {
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
    /// fits under the quota. In-flight `voice_live_*` captures and files
    /// awaiting UI delivery are never evicted but still count toward usage.
    ///
    /// Public arrivals (`isPrivate == false`) can never evict committed private
    /// media received from contacts; private arrivals evict public files first
    /// before touching older private files.
    func enforceQuota(reservingBytes: Int, isPrivate: Bool = false) {
        do {
            let base = try filesDirectory()
            var allFiles: [(url: URL, size: Int64, modified: Date, isPrivateOwned: Bool)] = []

            for subdirectory in Self.incomingSubdirectories {
                let dir = base.appendingPathComponent(subdirectory, isDirectory: true)
                guard fileManager.fileExists(atPath: dir.path),
                      let contents = try? fileManager.contentsOfDirectory(
                          at: dir,
                          includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                          options: [.skipsHiddenFiles]
                      ) else { continue }

                for fileURL in contents {
                    guard let attrs = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                          let size = attrs.fileSize,
                          let modified = attrs.contentModificationDate else { continue }
                    let relativePath = "\(subdirectory)/\(fileURL.lastPathComponent)"
                    // Fail closed if the receipt ledger is temporarily unreadable so
                    // public arrivals cannot evict committed private media.
                    let isPrivateOwned = privateMediaReceipts.isPayloadOwned(relativePath: relativePath) ?? true
                    allFiles.append((url: fileURL, size: Int64(size), modified: modified, isPrivateOwned: isPrivateOwned))
                }
            }

            let currentUsage = allFiles.reduce(0) { $0 + $1.size }
            let targetUsage = quotaBytes - Int64(reservingBytes)
            guard currentUsage > targetUsage else { return }

            let needToFree = currentUsage - targetUsage
            let protectedPaths = pendingDeliveryTracker.pendingDeliveryPathsSnapshot()
            let candidates = allFiles
                .filter { isPrivate || !$0.isPrivateOwned }
                .sorted { lhs, rhs in
                    if lhs.isPrivateOwned != rhs.isPrivateOwned {
                        return !lhs.isPrivateOwned
                    }
                    return lhs.modified < rhs.modified
                }
            var freedSpace: Int64 = 0
            for file in candidates {
                guard freedSpace < needToFree else { break }
                guard !file.url.lastPathComponent.hasPrefix(Self.liveCapturePrefix),
                      !protectedPaths.contains(file.url.standardizedFileURL.path) else { continue }
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
    /// outgoing directories, skipping in-flight live captures.
    @discardableResult
    func expireAgedMedia(retention: TimeInterval = Self.defaultMediaRetention) -> Int {
        guard retention > 0 else { return 0 }

        let cutoff = dateProvider().addingTimeInterval(-retention)
        let protectedPaths = pendingDeliveryTracker.pendingDeliveryPathsSnapshot()
        var removed = 0
        do {
            let base = try filesDirectory()
            for subdirectory in Self.mediaSubdirectories {
                let dir = base.appendingPathComponent(subdirectory, isDirectory: true)
                guard fileManager.fileExists(atPath: dir.path),
                      let contents = try? fileManager.contentsOfDirectory(
                          at: dir,
                          includingPropertiesForKeys: [.contentModificationDateKey],
                          options: [.skipsHiddenFiles]
                      ) else { continue }

                for fileURL in contents {
                    guard let modified = try? fileURL.resourceValues(
                        forKeys: [.contentModificationDateKey]
                    ).contentModificationDate,
                          modified < cutoff,
                          !fileURL.lastPathComponent.hasPrefix(Self.liveCapturePrefix),
                          !protectedPaths.contains(fileURL.standardizedFileURL.path) else {
                        continue
                    }

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
            SecureLogger.warning("⚠️ Could not expire aged media: \(error)", category: .security)
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

    /// Stamps media directories and resident payloads with the explicit
    /// protection class, leaving stronger classes untouched.
    @discardableResult
    func migrateFileProtectionIfNeeded() -> Int {
        #if os(iOS)
        guard let attributes = Self.mediaProtectionAttributes else { return 0 }
        var stamped = 0
        guard let base = try? filesDirectory() else { return 0 }
        for subdirectory in Self.mediaSubdirectories {
            let dir = base.appendingPathComponent(subdirectory, isDirectory: true)
            guard fileManager.fileExists(atPath: dir.path) else { continue }
            let files = (try? fileManager.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileProtectionKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            stamped += stampProtectionIfWeaker(dir, requireRegularFile: false, attributes: attributes)
            for fileURL in files {
                guard !fileURL.lastPathComponent.hasPrefix(Self.liveCapturePrefix) else { continue }
                stamped += stampProtectionIfWeaker(fileURL, requireRegularFile: true, attributes: attributes)
            }
        }
        return stamped
        #else
        return 0
        #endif
    }

    #if os(iOS)
    private func stampProtectionIfWeaker(
        _ itemURL: URL,
        requireRegularFile: Bool,
        attributes: [FileAttributeKey: Any]
    ) -> Int {
        let values = try? itemURL.resourceValues(
            forKeys: [.isRegularFileKey, .isDirectoryKey, .fileProtectionKey]
        )
        if requireRegularFile {
            guard values?.isRegularFile == true else { return 0 }
        } else {
            guard values?.isDirectory == true else { return 0 }
        }
        if let current = values?.fileProtection,
           current != .none,
           current != .completeUntilFirstUserAuthentication {
            return 0
        }
        do {
            try fileManager.setAttributes(attributes, ofItemAtPath: itemURL.path)
            return 1
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return 0
        } catch {
            SecureLogger.warning("⚠️ Failed to migrate media file protection: \(error)", category: .security)
            return 0
        }
    }
    #endif

    // MARK: - Helpers

    private func incomingPayloadURL(relativePath: String) -> URL? {
        guard !relativePath.isEmpty,
              let base = try? filesDirectory().standardizedFileURL else {
            return nil
        }
        let candidate = base
            .appendingPathComponent(relativePath, isDirectory: false)
            .standardizedFileURL
        let parentPath = candidate.deletingLastPathComponent().path
        guard Self.incomingSubdirectories.contains(where: { relativeDirectory in
            base.appendingPathComponent(
                relativeDirectory,
                isDirectory: true
            ).standardizedFileURL.path == parentPath
        }) else {
            return nil
        }
        return candidate
    }

    private func filesDirectory() throws -> URL {
        let filesDir = try rootDirectory().appendingPathComponent("files", isDirectory: true)
        try fileManager.createDirectory(at: filesDir, withIntermediateDirectories: true, attributes: Self.mediaProtectionAttributes)
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
        try rootDirectory().appendingPathComponent(Self.panicRecoveryPendingMarkerFileName, isDirectory: false)
    }

    private func panicRecoveryMarkerURLs() throws -> [URL] {
        let root = try rootDirectory()
        return [
            root.appendingPathComponent(Self.panicRecoveryPendingMarkerFileName, isDirectory: false),
            root.appendingPathComponent(Self.legacyPanicRecoveryPendingMarkerFileName, isDirectory: false)
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

        candidate = candidate.components(separatedBy: Self.invalidFilenameCharacters).joined(separator: "_").trimmed
        if candidate.isEmpty { candidate = defaultName }
        if candidate.hasPrefix(".") { candidate = "_" + candidate }

        // Reserve room for the 37-character "<uuid>_" prefix within a 120-char cap.
        let maxSanitizedLength = 80
        if candidate.count > maxSanitizedLength {
            let ext = (candidate as NSString).pathExtension
            let base = (candidate as NSString).deletingPathExtension
            candidate = ext.isEmpty
                ? String(candidate.prefix(maxSanitizedLength))
                : String(base.prefix(max(10, maxSanitizedLength - ext.count - 1))) + "." + ext
        }

        if let fallbackExtension, (candidate as NSString).pathExtension.isEmpty {
            candidate += ".\(fallbackExtension)"
        }

        return candidate.isEmpty ? defaultName : candidate
    }

    private func uniqueFileURL(in directory: URL, sanitizedName: String) -> URL {
        let directoryPath = directory.standardizedFileURL.path
        let uniqueName = "\(UUID().uuidString)_\(sanitizedName)"
        let candidate = directory.appendingPathComponent(uniqueName, isDirectory: false)
        guard candidate.standardizedFileURL.path.hasPrefix(directoryPath + "/") else {
            SecureLogger.warning("⚠️ Path traversal blocked: \(sanitizedName)", category: .security)
            return directory.appendingPathComponent("blocked_\(UUID().uuidString)", isDirectory: false)
        }
        return candidate
    }

    private static func timestampString(from date: Date) -> String {
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        return String(
            format: "%04d%02d%02d_%02d%02d%02d",
            locale: Locale(identifier: "en_US_POSIX"),
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0,
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0
        )
    }
}
