import BitLogger
import BitFoundation
import Foundation

struct BLEIncomingFileStore {
    private static let quotaBytes: Int64 = 100 * 1024 * 1024

    private let fileManager: FileManager
    private let baseDirectory: URL?
    private let dateProvider: () -> Date

    init(fileManager: FileManager = .default, baseDirectory: URL? = nil, dateProvider: @escaping () -> Date = Date.init) {
        self.fileManager = fileManager
        self.baseDirectory = baseDirectory
        self.dateProvider = dateProvider
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
        let root = try baseDirectory ?? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let filesDir = root.appendingPathComponent("files", isDirectory: true)
        try fileManager.createDirectory(at: filesDir, withIntermediateDirectories: true, attributes: nil)
        return filesDir
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
