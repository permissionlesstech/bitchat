//
// AppSupportFileStore.swift
// bitchat
//
// Shared Application Support JSON/binary file persistence helper with
// explicit per-store iOS FileProtectionType.
// This is free and unencumbered software released into the public domain.
//

import BitLogger
import Foundation

enum AppSupportFileProtection {
    case untilFirstUserAuthentication

    var writingOptions: Data.WritingOptions {
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        switch self {
        case .untilFirstUserAuthentication:
            options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        }
        #endif
        return options
    }

    #if os(iOS)
    var fileProtectionType: FileProtectionType {
        switch self {
        case .untilFirstUserAuthentication:
            return .completeUntilFirstUserAuthentication
        }
    }
    #endif
}

struct AppSupportFileStore {
    private static let ioQueue = DispatchQueue(
        label: "chat.bitchat.appSupportFileStore.io",
        qos: .utility
    )

    let fileURL: URL?
    let protection: AppSupportFileProtection

    init(
        persistsToDisk: Bool = true,
        fileURL: URL? = nil,
        subdirectory: String,
        fileName: String,
        protection: AppSupportFileProtection
    ) {
        self.fileURL = persistsToDisk
            ? (fileURL ?? Self.defaultURL(subdirectory: subdirectory, fileName: fileName))
            : nil
        self.protection = protection
    }

    static func defaultURL(subdirectory: String, fileName: String) -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return nil }
        return base
            .appendingPathComponent(subdirectory, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// Waits for any in-flight background writes enqueued from the main thread.
    static func drainPendingWrites() {
        ioQueue.sync {}
    }

    func writeRaw(
        _ data: Data,
        write: (Data, URL, Data.WritingOptions) throws -> Void = { try $0.write(to: $1, options: $2) }
    ) throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try write(data, fileURL, protection.writingOptions)
    }

    /// Writes raw bytes off the main thread when invoked from the main thread,
    /// or synchronously when already on a background queue. An optional
    /// `shouldExecute` predicate is checked on `ioQueue` right before writing so
    /// a panic wipe can cancel in-flight writes enqueued before the wipe.
    func writeRawOffMain(
        _ data: Data,
        shouldExecute: (@Sendable () -> Bool)? = nil
    ) throws {
        guard fileURL != nil else { return }
        if Thread.isMainThread {
            let store = self
            Self.ioQueue.async {
                if let shouldExecute, !shouldExecute() {
                    return
                }
                do {
                    try store.writeRaw(data)
                } catch {
                    SecureLogger.error("Background file write failed: \(error)", category: .session)
                }
            }
            return
        }
        if let shouldExecute, !shouldExecute() {
            return
        }
        try writeRaw(data)
    }

    func saveJSON<T: Encodable>(_ value: T, isEmpty: Bool = false) throws {
        guard let fileURL else { return }
        let encoded: Data? = isEmpty ? nil : try JSONEncoder().encode(value)
        if Thread.isMainThread {
            let store = self
            Self.ioQueue.async {
                if let encoded {
                    do {
                        try store.writeRaw(encoded)
                    } catch {
                        SecureLogger.error("Background JSON save failed: \(error)", category: .session)
                    }
                } else {
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }
            return
        }
        if let encoded {
            try writeRaw(encoded)
        } else {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    func loadJSON<T: Decodable>(
        _ type: T.Type,
        readData: (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) throws -> T? {
        Self.drainPendingWrites()
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let data = try readData(fileURL)
        return try JSONDecoder().decode(type, from: data)
    }

    /// Reads and decodes JSON on the background I/O queue so cold-launch
    /// restores never perform synchronous file I/O on the main thread.
    func loadJSONAsync<T: Decodable>(
        _ type: T.Type,
        completion: @escaping (Result<T?, Error>) -> Void
    ) {
        guard let fileURL else {
            completion(.success(nil))
            return
        }
        Self.ioQueue.async {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                completion(.success(nil))
                return
            }
            do {
                let data = try Data(contentsOf: fileURL)
                let decoded = try JSONDecoder().decode(T.self, from: data)
                completion(.success(decoded))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// Reads raw bytes on the background I/O queue, returning `nil` when the
    /// file does not exist.
    func readRawAsync(completion: @escaping (Result<Data?, Error>) -> Void) {
        guard let fileURL else {
            completion(.success(nil))
            return
        }
        Self.ioQueue.async {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                completion(.success(nil))
                return
            }
            do {
                let data = try Data(contentsOf: fileURL)
                completion(.success(data))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// Removes the file off the main thread when called on main; use
    /// `removeIgnoringErrors()` for synchronous panic-wipe deletion.
    func removeOffMain(shouldExecute: (@Sendable () -> Bool)? = nil) {
        guard let fileURL else { return }
        if Thread.isMainThread {
            Self.ioQueue.async {
                if let shouldExecute, !shouldExecute() {
                    return
                }
                try? FileManager.default.removeItem(at: fileURL)
            }
            return
        }
        if let shouldExecute, !shouldExecute() {
            return
        }
        try? FileManager.default.removeItem(at: fileURL)
    }

    func removeIgnoringErrors() {
        Self.drainPendingWrites()
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    func migrateProtectionIfNeeded(logContext: String) {
        #if os(iOS)
        guard let fileURL else { return }
        do {
            try FileManager.default.setAttributes(
                [.protectionKey: protection.fileProtectionType],
                ofItemAtPath: fileURL.path
            )
        } catch {
            SecureLogger.warning("Failed to migrate \(logContext) file protection: \(error)", category: .session)
        }
        #endif
    }

    static func isMissingFileError(_ error: Error) -> Bool {
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
}
