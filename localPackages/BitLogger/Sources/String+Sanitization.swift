//
// String+Sanitization.swift
// BitLogger
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

extension String {
    /// Sanitize strings to remove potentially sensitive data
    func sanitized() -> String {
        let key = self as NSString
        
        // Check cache first
        if let cached = Self.queue.sync(execute: { Self.cache.object(forKey: key) }) {
            return cached as String
        }
        
        var sanitized = self
        
        // Remove full fingerprints (keep first 8 chars for debugging)
        let fingerprintPattern = #/[a-fA-F0-9]{64}/#
        sanitized = sanitized.replacing(fingerprintPattern) { match in
            let fingerprint = String(match.output)
            return String(fingerprint.prefix(8)) + "..."
        }
        
        // Remove base64 encoded data that might be keys
        let base64Pattern = #/[A-Za-z0-9+/]{40,}={0,2}/#
        sanitized = sanitized.replacing(base64Pattern) { _ in
            "<base64-data>"
        }
        
        // Remove potential passwords (assuming they're in quotes or after "password:")
        let passwordPattern = #/password["\s:=]+["']?[^"'\s]+["']?/#
        sanitized = sanitized.replacing(passwordPattern) { _ in
            "password: <redacted>"
        }
        
        // Truncate peer IDs to first 8 characters
        let peerIDPattern = #/peerID: ([a-zA-Z0-9]{8})[a-zA-Z0-9]+/#
        sanitized = sanitized.replacing(peerIDPattern) { match in
            "peerID: \(match.1)..."
        }
        
        // Cache the result
        Self.queue.sync {
            Self.cache.setObject(sanitized as NSString, forKey: key)
        }
        
        return sanitized
    }
}

// MARK: - Cache Helpers

private extension String {
    static let queue = DispatchQueue(label: "chat.bitchat.securelogger.cache", attributes: .concurrent)

    static let cache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 100 // Keep last 100 sanitized strings
        return cache
    }()
}
