//
// PanicFileDeletion.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import Foundation

/// Missing files succeed; unresolved persistent locations and removal errors fail.
enum PanicFileDeletion {
    static func remove(_ fileURL: inout URL?, resolvingWith resolve: () -> URL?) -> Bool {
        // Retry a failed lookup and retain the recovered location for later persistence.
        if fileURL == nil { fileURL = resolve() }
        return remove(fileURL)
    }

    static func remove(_ fileURL: URL?) -> Bool {
        guard let fileURL else { return false }
        do {
            try FileManager.default.removeItem(at: fileURL)
            return true
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
                return true
            }
            SecureLogger.error("Panic metadata deletion failed: \(error)", category: .security)
            return false
        }
    }
}
