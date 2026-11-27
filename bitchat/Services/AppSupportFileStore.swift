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
            create: true
        ) else { return nil }
        return base
            .appendingPathComponent(subdirectory, isDirectory: true)
            .appendingPathComponent(fileName)
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

    func saveJSON<T: Encodable>(_ value: T, isEmpty: Bool = false) throws {
        guard let fileURL else { return }
        if isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        let data = try JSONEncoder().encode(value)
        try writeRaw(data)
    }

    func loadJSON<T: Decodable>(
        _ type: T.Type,
        readData: (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) throws -> T? {
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let data = try readData(fileURL)
        return try JSONDecoder().decode(type, from: data)
    }

    func removeIgnoringErrors() {
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
