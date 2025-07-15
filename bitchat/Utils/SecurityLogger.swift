//
// SecurityLogger.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import os.log

/// Centralized security-aware logging framework
/// Provides safe logging that filters sensitive data and security events
class SecurityLogger {
    
    // MARK: - Log Categories
    
    private static let subsystem = "chat.bitchat"
    
    static let noise = OSLog(subsystem: subsystem, category: "noise")
    static let encryption = OSLog(subsystem: subsystem, category: "encryption")
    static let keychain = OSLog(subsystem: subsystem, category: "keychain")
    static let session = OSLog(subsystem: subsystem, category: "session")
    static let security = OSLog(subsystem: subsystem, category: "security")
    
    // MARK: - Log Levels
    
    enum LogLevel {
        case debug
        case info
        case warning
        case error
        case fault
        
        var osLogType: OSLogType {
            switch self {
            case .debug: return .debug
            case .info: return .info
            case .warning: return .default
            case .error: return .error
            case .fault: return .fault
            }
        }
    }
    
    // MARK: - Security Event Types
    
    enum SecurityEvent {
        case handshakeStarted(peerID: String)
        case handshakeCompleted(peerID: String)
        case handshakeFailed(peerID: String, error: String)
        case sessionExpired(peerID: String)
        case keyRotation(channel: String)
        case invalidKey(reason: String)
        case replayAttackDetected(channel: String)
        case authenticationFailed(peerID: String)
        
        var message: String {
            switch self {
            case .handshakeStarted(let peerID):
                return "Handshake started with peer: \(sanitize(peerID))"
            case .handshakeCompleted(let peerID):
                return "Handshake completed with peer: \(sanitize(peerID))"
            case .handshakeFailed(let peerID, let error):
                return "Handshake failed with peer: \(sanitize(peerID)), error: \(error)"
            case .sessionExpired(let peerID):
                return "Session expired for peer: \(sanitize(peerID))"
            case .keyRotation(let channel):
                return "Key rotation performed for channel: \(sanitize(channel))"
            case .invalidKey(let reason):
                return "Invalid key detected: \(reason)"
            case .replayAttackDetected(let channel):
                return "Replay attack detected on channel: \(sanitize(channel))"
            case .authenticationFailed(let peerID):
                return "Authentication failed for peer: \(sanitize(peerID))"
            }
        }
    }
    
    // MARK: - Public Logging Methods
    
    /// Log a security event
    static func logSecurityEvent(_ event: SecurityEvent, level: LogLevel = .info) {
        #if DEBUG
        os_log("%{public}@", log: security, type: level.osLogType, event.message)
        #else
        // In release, use private logging to prevent sensitive data exposure
        os_log("%{private}@", log: security, type: level.osLogType, event.message)
        #endif
    }
    
    /// Log general messages with automatic sensitive data filtering
    static func log(_ message: String, category: OSLog = noise, level: LogLevel = .debug) {
        let sanitized = sanitize(message)
        
        #if DEBUG
        os_log("%{public}@", log: category, type: level.osLogType, sanitized)
        #else
        // In release builds, only log non-debug messages
        if level != .debug {
            os_log("%{private}@", log: category, type: level.osLogType, sanitized)
        }
        #endif
    }
    
    /// Log errors with context
    static func logError(_ error: Error, context: String, category: OSLog = noise) {
        let sanitized = sanitize(context)
        let errorDesc = sanitize(error.localizedDescription)
        
        #if DEBUG
        os_log("Error in %{public}@: %{public}@", log: category, type: .error, sanitized, errorDesc)
        #else
        os_log("Error in %{private}@: %{private}@", log: category, type: .error, sanitized, errorDesc)
        #endif
    }
    
    // MARK: - Private Helpers
    
    /// Sanitize strings to remove potentially sensitive data
    private static func sanitize(_ input: String) -> String {
        var sanitized = input
        
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
        
        return sanitized
    }
    
    /// Sanitize individual values
    private static func sanitize<T>(_ value: T) -> String {
        let stringValue = String(describing: value)
        return sanitize(stringValue)
    }
}

// MARK: - Convenience Extensions

extension SecurityLogger {
    
    /// Log handshake events
    static func logHandshake(_ phase: String, peerID: String, success: Bool = true) {
        if success {
            log("Handshake \(phase) with peer: \(peerID)", category: session, level: .info)
        } else {
            log("Handshake \(phase) failed with peer: \(peerID)", category: session, level: .warning)
        }
    }
    
    /// Log encryption operations
    static func logEncryption(_ operation: String, success: Bool = true) {
        let level: LogLevel = success ? .debug : .error
        log("Encryption operation '\(operation)' \(success ? "succeeded" : "failed")", 
            category: encryption, level: level)
    }
    
    /// Log key management operations
    static func logKeyOperation(_ operation: String, keyType: String, success: Bool = true) {
        let level: LogLevel = success ? .info : .error
        log("Key operation '\(operation)' for \(keyType) \(success ? "succeeded" : "failed")", 
            category: keychain, level: level)
    }
}

// MARK: - Migration Helper

/// Helper to migrate from print statements to SecurityLogger
/// Usage: Replace print(...) with secureLog(...)
func secureLog(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    #if DEBUG
    let message = items.map { String(describing: $0) }.joined(separator: separator)
    SecurityLogger.log(message, level: .debug)
    #endif
}