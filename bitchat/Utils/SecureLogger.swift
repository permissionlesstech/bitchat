//
// SecureLogger.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import os.log

/// Centralized security-aware logging framework
/// Provides safe logging that filters sensitive data and security events
final class SecureLogger {
    
    // MARK: - Timestamp Formatter
    
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        formatter.timeZone = TimeZone.current
        return formatter
    }()
    
    // MARK: - Cached Regex Patterns
    
    private static let fingerprintPattern = #/[a-fA-F0-9]{64}/#
    private static let base64Pattern = #/[A-Za-z0-9+/]{40,}={0,2}/#
    private static let passwordPattern = #/password["\s:=]+["']?[^"'\s]+["']?/#
    private static let peerIDPattern = #/peerID: ([a-zA-Z0-9]{8})[a-zA-Z0-9]+/#
    
    // MARK: - Sanitization Cache
    
    private static let sanitizationCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 100 // Keep last 100 sanitized strings
        return cache
    }()
    private static let cacheQueue = DispatchQueue(label: "chat.bitchat.securelogger.cache", attributes: .concurrent)
    
    // MARK: - Log Levels
    
    enum LogLevel {
        case debug
        case info
        case warning
        case error
        case fault
        
        fileprivate var order: Int {
            switch self {
            case .debug: return 0
            case .info: return 1
            case .warning: return 2
            case .error: return 3
            case .fault: return 4
            }
        }
        
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

    // MARK: - Global Threshold

    /// Minimum level that will be logged. Defaults to .info. Override via env BITCHAT_LOG_LEVEL.
    private static let minimumLevel: LogLevel = {
        let env = ProcessInfo.processInfo.environment["BITCHAT_LOG_LEVEL"]?.lowercased()
        switch env {
        case "debug": return .debug
        case "warning": return .warning
        case "error": return .error
        case "fault": return .fault
        default: return .info
        }
    }()

    private static func shouldLog(_ level: LogLevel) -> Bool {
        return level.order >= minimumLevel.order
    }
    
    // MARK: - Security Event Types
    
    enum SecurityEvent {
        case handshakeStarted(peerID: String)
        case handshakeCompleted(peerID: String)
        case handshakeFailed(peerID: String, error: String)
        case sessionExpired(peerID: String)
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
            case .authenticationFailed(let peerID):
                return "Authentication failed for peer: \(sanitize(peerID))"
            }
        }
    }
    
    // MARK: - Public Logging Methods
    
    static func debug(_ message: @autoclosure () -> String, category: OSLog = .noise,
                      file: String = #file, line: Int = #line, function: String = #function) {
        log(message(), category: category, level: .debug, file: file, line: line, function: function)
    }
    
    static func info(_ message: @autoclosure () -> String, category: OSLog = .noise,
                     file: String = #file, line: Int = #line, function: String = #function) {
        log(message(), category: category, level: .info, file: file, line: line, function: function)
    }
    
    static func warning(_ message: @autoclosure () -> String, category: OSLog = .noise,
                        file: String = #file, line: Int = #line, function: String = #function) {
        log(message(), category: category, level: .warning, file: file, line: line, function: function)
    }
    
    static func error(_ message: @autoclosure () -> String, category: OSLog = .noise,
                      file: String = #file, line: Int = #line, function: String = #function) {
        log(message(), category: category, level: .error, file: file, line: line, function: function)
    }
    
    // MARK: Security Event Logging
    
    static func debug(_ event: SecurityEvent, file: String = #file, line: Int = #line, function: String = #function) {
        logSecurityEvent(event, level: .debug, file: file, line: line, function: function)
    }
    
    static func info(_ event: SecurityEvent, file: String = #file, line: Int = #line, function: String = #function) {
        logSecurityEvent(event, level: .info, file: file, line: line, function: function)
    }
    
    static func warning(_ event: SecurityEvent, file: String = #file, line: Int = #line, function: String = #function) {
        logSecurityEvent(event, level: .warning, file: file, line: line, function: function)
    }
    
    static func error(_ event: SecurityEvent, file: String = #file, line: Int = #line, function: String = #function) {
        logSecurityEvent(event, level: .error, file: file, line: line, function: function)
    }
    
    /// Log errors with context
    static func error(_ error: Error, context: @autoclosure () -> String, category: OSLog = .noise,
                      file: String = #file, line: Int = #line, function: String = #function) {
        let location = formatLocation(file: file, line: line, function: function)
        let sanitized = sanitize(context())
        let errorDesc = sanitize(error.localizedDescription)
        
        #if DEBUG
        os_log("%{public}@ Error in %{public}@: %{public}@", log: category, type: .error, location, sanitized, errorDesc)
        #else
        os_log("%{private}@ Error in %{private}@: %{private}@", log: category, type: .error, location, sanitized, errorDesc)
        #endif
    }
    
    // MARK: - Private Helpers
    
    /// Log general messages with automatic sensitive data filtering
    private static func log(_ message: @autoclosure () -> String, category: OSLog, level: LogLevel,
                                file: String, line: Int, function: String) {
        guard shouldLog(level) else { return }
        let location = formatLocation(file: file, line: line, function: function)
        let sanitized = sanitize("\(location) \(message())")
        
        #if DEBUG
        os_log("%{public}@", log: category, type: level.osLogType, sanitized)
        #else
        // In release builds, only log non-debug messages
        if level != .debug {
            os_log("%{private}@", log: category, type: level.osLogType, sanitized)
        }
        #endif
    }
    
    /// Log a security event
    private static func logSecurityEvent(_ event: SecurityEvent, level: LogLevel = .info,
                                         file: String, line: Int, function: String) {
        guard shouldLog(level) else { return }
        let location = formatLocation(file: file, line: line, function: function)
        let message = "\(location) \(event.message)"
        
        #if DEBUG
        os_log("%{public}@", log: .security, type: level.osLogType, message)
        #else
        // In release, use private logging to prevent sensitive data exposure
        os_log("%{private}@", log: .security, type: level.osLogType, message)
        #endif
    }
    
    /// Format location information for logging
    private static func formatLocation(file: String, line: Int, function: String) -> String {
        let fileName = (file as NSString).lastPathComponent
        let timestamp = timestampFormatter.string(from: Date())
        return "[\(timestamp)] [\(fileName):\(line) \(function)]"
    }
    
    /// Sanitize strings to remove potentially sensitive data
    private static func sanitize(_ input: String) -> String {
        let key = input as NSString
        
        // Check cache first
        var cachedValue: String?
        cacheQueue.sync {
            cachedValue = sanitizationCache.object(forKey: key) as String?
        }
        
        if let cached = cachedValue {
            return cached
        }
        
        // Perform sanitization
        var sanitized = input
        
        // Remove full fingerprints (keep first 8 chars for debugging)
        sanitized = sanitized.replacing(fingerprintPattern) { match in
            let fingerprint = String(match.output)
            return String(fingerprint.prefix(8)) + "..."
        }
        
        // Remove base64 encoded data that might be keys
        sanitized = sanitized.replacing(base64Pattern) { _ in
            "<base64-data>"
        }
        
        // Remove potential passwords (assuming they're in quotes or after "password:")
        sanitized = sanitized.replacing(passwordPattern) { _ in
            "password: <redacted>"
        }
        
        // Truncate peer IDs to first 8 characters
        sanitized = sanitized.replacing(peerIDPattern) { match in
            "peerID: \(match.1)..."
        }
        
        // Cache the result
        cacheQueue.async(flags: .barrier) {
            sanitizationCache.setObject(sanitized as NSString, forKey: key)
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

extension SecureLogger {
    
    /// Log key management operations
    static func logKeyOperation(_ operation: String, keyType: String, success: Bool = true,
                               file: String = #file, line: Int = #line, function: String = #function) {
        let level: LogLevel = success ? .debug : .error
        log("Key operation '\(operation)' for \(keyType) \(success ? "succeeded" : "failed")", 
            category: .keychain, level: level, file: file, line: line, function: function)
    }
}

// MARK: - Migration Helper

/// Helper to migrate from print statements to SecureLogger
/// Usage: Replace print(...) with secureLog(...)
func secureLog(_ items: Any..., separator: String = " ", terminator: String = "\n",
               file: String = #file, line: Int = #line, function: String = #function) {
    #if DEBUG
    let message = items.map { String(describing: $0) }.joined(separator: separator)
    SecureLogger.debug(message, file: file, line: line, function: function)
    #endif
}
