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

struct BLEIncomingFileStore {
    enum PanicRecoveryError: Error {
        case externalMarkerCommitFailed
        case markerWriteFailed(Error)
        case markerWriteAndMediaWipeFailed(
            markerError: Error,
            mediaError: Error
        )
    }

    private static let quotaBytes: Int64 = 100 * 1024 * 1024
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

    init(
        fileManager: FileManager = .default,
        baseDirectory: URL? = nil,
        dateProvider: @escaping () -> Date = Date.init,
        panicMarkerWriter: @escaping (Data, URL) throws -> Void = {
            try $0.write(to: $1, options: .atomic)
        }
    ) {
        self.fileManager = fileManager
        self.baseDirectory = baseDirectory
        self.dateProvider = dateProvider
        self.panicMarkerWriter = panicMarkerWriter
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
        do {
            let base = try filesDirectory().appendingPathComponent(subdirectory, isDirectory: true)
            try fileManager.createDirectory(at: base, withIntermediateDirectories: true, attributes: nil)
            let sanitized = sanitizedFileName(
                preferredName,
                defaultName: "\(defaultPrefix)_\(Self.timestampString(from: dateProvider()))",
                fallbackExtension: fallbackExtension
            )
            let destination = uniqueFileURL(in: base, fileName: sanitized)
            try data.write(to: destination, options: .atomic)
            return destination
        } catch {
            SecureLogger.error("❌ Failed to persist incoming media: \(error)", category: .session)
            return nil
        }
    }

    /// Frees least-recently-modified incoming files until `reservingBytes`
    /// fits under the quota. Files named `voice_live_*` (in-flight live
    /// captures) are never evicted regardless of who triggers enforcement —
    /// a finalized transfer can arrive at quota while a burst is still
    /// streaming — but they still count toward usage.
    func enforceQuota(reservingBytes: Int) {
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
            let targetUsage = Self.quotaBytes - Int64(reservingBytes)
            guard currentUsage > targetUsage else { return }

            let needToFree = currentUsage - targetUsage
            var freedSpace: Int64 = 0
            for file in allFiles.sorted(by: { $0.modified < $1.modified }) {
                guard freedSpace < needToFree else { break }
                guard !file.url.lastPathComponent.hasPrefix(Self.liveCapturePrefix) else { continue }
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

    private func uniqueFileURL(in directory: URL, fileName: String) -> URL {
        let directoryPath = directory.standardizedFileURL.path
        func isInsideDirectory(_ url: URL) -> Bool {
            url.standardizedFileURL.path.hasPrefix(directoryPath + "/")
        }

        var candidate = directory.appendingPathComponent(fileName)
        guard isInsideDirectory(candidate) else {
            SecureLogger.warning("⚠️ Path traversal blocked: \(fileName)", category: .security)
            return directory.appendingPathComponent("blocked_\(UUID().uuidString)")
        }

        if !fileManager.fileExists(atPath: candidate.path) {
            return candidate
        }

        let baseName = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        for counter in 1..<100 {
            let newName = ext.isEmpty ? "\(baseName) (\(counter))" : "\(baseName) (\(counter)).\(ext)"
            candidate = directory.appendingPathComponent(newName)
            guard isInsideDirectory(candidate) else {
                return directory.appendingPathComponent("blocked_\(UUID().uuidString)")
            }
            if !fileManager.fileExists(atPath: candidate.path) {
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
