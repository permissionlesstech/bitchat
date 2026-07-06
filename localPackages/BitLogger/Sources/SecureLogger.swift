//
// SecureLogger.swift
// BitLogger
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
#if canImport(os.log)
import os.log
#else
public struct OSLog {
    public let subsystem: String
    public let category: String

    public init(subsystem: String, category: String) {
        self.subsystem = subsystem
        self.category = category
    }
}

public struct OSLogType: CustomStringConvertible {
    private let label: String

    private init(_ label: String) {
        self.label = label
    }

    public var description: String { label }

    public static let debug = OSLogType("debug")
    public static let info = OSLogType("info")
    public static let `default` = OSLogType("default")
    public static let error = OSLogType("error")
    public static let fault = OSLogType("fault")
}

@usableFromInline
let secureLoggerFallbackFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

@usableFromInline
func os_log(_ message: StaticString, log: OSLog, type: OSLogType, _ args: CVarArg...) {
    let rawFormat = String(describing: message)
    let format = rawFormat
        .replacingOccurrences(of: "%{public}@", with: "%@")
        .replacingOccurrences(of: "%{private}@", with: "%@")
    let formatted = String(format: format, arguments: args)
    let timestamp = secureLoggerFallbackFormatter.string(from: Date())
    print("[\(timestamp)] [\(log.subsystem)::\(log.category)] [\(type.description)] \(formatted)")
}
#endif

/// Centralized security-aware logging framework
/// Provides safe logging that filters sensitive data and security events
public final class SecureLogger {
    
    // MARK: - Timestamp Formatter
    
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        formatter.timeZone = TimeZone.current
        return formatter
    }()
    
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

        /// Short uppercase label for the in-memory export buffer line prefix.
        var label: String {
            switch self {
            case .debug: return "DEBUG"
            case .info: return "INFO"
            case .warning: return "WARN"
            case .error: return "ERROR"
            case .fault: return "FAULT"
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

    /// Minimum level that will be logged. Override via env BITCHAT_LOG_LEVEL
    /// (env always wins). The default is `.debug` in DEBUG builds and `.info`
    /// otherwise: a sideloaded, tap-launched build can't receive the env var,
    /// so DEBUG must surface the `.debug` decision logs out of the box. Release
    /// emits nothing regardless (all log paths are `#if DEBUG`).
    /// Internal-settable so tests can verify level filtering; app code should not mutate it.
    internal static var minimumLevel: LogLevel = defaultMinimumLevel

    /// The level used when nothing mutates `minimumLevel`. Honors the
    /// BITCHAT_LOG_LEVEL env override; otherwise `.debug` in DEBUG builds (so a
    /// tap-launched sideload surfaces decision logs) and `.info` elsewhere.
    /// Exposed for tests.
    internal static var defaultMinimumLevel: LogLevel {
        let env = ProcessInfo.processInfo.environment["BITCHAT_LOG_LEVEL"]?.lowercased()
        switch env {
        case "debug": return .debug
        case "info": return .info
        case "warning": return .warning
        case "error": return .error
        case "fault": return .fault
        default:
            #if DEBUG
            return .debug
            #else
            return .info
            #endif
        }
    }

    private static func shouldLog(_ level: LogLevel) -> Bool {
        return level.order >= minimumLevel.order
    }
}

// MARK: - Public Logging Methods

public extension SecureLogger {
    
    // Each wrapper checks the level BEFORE evaluating the autoclosure so
    // filtered messages never pay for string interpolation — this matters on
    // hot paths that log per packet/event. Debug compiles out of release
    // builds entirely (the core log() drops .debug there anyway).
    static func debug(_ message: @autoclosure () -> String, category: OSLog = .noise,
                      file: String = #file, line: Int = #line, function: String = #function) {
        #if DEBUG
        guard shouldLog(.debug) else { return }
        log(message(), category: category, level: .debug, file: file, line: line, function: function)
        #endif
    }

    static func info(_ message: @autoclosure () -> String, category: OSLog = .noise,
                     file: String = #file, line: Int = #line, function: String = #function) {
        #if DEBUG
        guard shouldLog(.info) else { return }
        log(message(), category: category, level: .info, file: file, line: line, function: function)
        #endif
    }

    static func warning(_ message: @autoclosure () -> String, category: OSLog = .noise,
                        file: String = #file, line: Int = #line, function: String = #function) {
        #if DEBUG
        guard shouldLog(.warning) else { return }
        log(message(), category: category, level: .warning, file: file, line: line, function: function)
        #endif
    }

    static func error(_ message: @autoclosure () -> String, category: OSLog = .noise,
                      file: String = #file, line: Int = #line, function: String = #function) {
        #if DEBUG
        guard shouldLog(.error) else { return }
        log(message(), category: category, level: .error, file: file, line: line, function: function)
        #endif
    }
    
    /// Log errors with context
    static func error(_ error: Error, context: @autoclosure () -> String, category: OSLog = .noise,
                      file: String = #file, line: Int = #line, function: String = #function) {
        #if DEBUG
        let location = formatLocation(file: file, line: line, function: function)
        let sanitized = context().sanitized()
        let errorDesc = error.localizedDescription.sanitized()
        
        #if DEBUG
        os_log("%{public}@ Error in %{public}@: %{public}@", log: category, type: .error, location, sanitized, errorDesc)
        record(level: .error, message: "\(location) Error in \(sanitized): \(errorDesc)")
        #else
        os_log("%{private}@ Error in %{private}@: %{private}@", log: category, type: .error, location, sanitized, errorDesc)
        #endif
        #endif
    }
}

// MARK: Security Event Logging

public extension SecureLogger {
    
    enum SecurityEvent {
        case handshakeStarted(peerID: String)
        case handshakeCompleted(peerID: String)
        case handshakeFailed(peerID: String, error: String)
        case sessionExpired(peerID: String)
        case authenticationFailed(peerID: String)
        
        var message: String {
            switch self {
            case .handshakeStarted(let peerID):
                return "Handshake started with peer: \(peerID.sanitized())"
            case .handshakeCompleted(let peerID):
                return "Handshake completed with peer: \(peerID.sanitized())"
            case .handshakeFailed(let peerID, let error):
                return "Handshake failed with peer: \(peerID.sanitized()), error: \(error)"
            case .sessionExpired(let peerID):
                return "Session expired for peer: \(peerID.sanitized())"
            case .authenticationFailed(let peerID):
                return "Authentication failed for peer: \(peerID.sanitized())"
            }
        }
    }
    
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
}

// MARK: - Convenience Extensions

public extension SecureLogger {
    
    enum KeyOperation: String, CustomStringConvertible {
        case load
        case create
        case generate
        case delete
        case save
        
        public var description: String { rawValue }
    }
    
    /// Log key management operations
    static func logKeyOperation(_ operation: KeyOperation, keyType: String, success: Bool = true,
                                file: String = #file, line: Int = #line, function: String = #function) {
        if success {
            debug("Key operation '\(operation)' for \(keyType) succeeded", category: .keychain, file: file, line: line, function: function)
        } else {
            error("Key operation '\(operation)' for \(keyType) failed", category: .keychain, file: file, line: line, function: function)
        }
    }
}

// MARK: - Private Helpers

private extension SecureLogger {
    /// Log general messages with automatic sensitive data filtering
    static func log(_ message: @autoclosure () -> String, category: OSLog, level: LogLevel,
                    file: String, line: Int, function: String) {
        // All public wrappers are compiled out of release builds; this core
        // is gated too so no future call path can reintroduce production
        // logging. bitchat is privacy-first: release builds emit nothing.
        #if DEBUG
        guard shouldLog(level) else { return }
        let location = formatLocation(file: file, line: line, function: function)
        let sanitized = "\(location) \(message())".sanitized()
        os_log("%{public}@", log: category, type: level.osLogType, sanitized)
        record(level: level, message: sanitized)
        #endif
    }

    /// Log a security event
    static func logSecurityEvent(_ event: SecurityEvent, level: LogLevel = .info,
                                 file: String, line: Int, function: String) {
        #if DEBUG
        guard shouldLog(level) else { return }
        let location = formatLocation(file: file, line: line, function: function)
        let message = "\(location) \(event.message)"
        os_log("%{public}@", log: .security, type: level.osLogType, message)
        record(level: level, message: message)
        #endif
    }

    /// Fan a sanitized line out to the in-memory export buffer and the
    /// (opt-in, off by default) UDP network sink. DEBUG-only; both consumers
    /// are non-blocking. Same formatted text everywhere.
    static func record(level: LogLevel, message: String) {
        #if DEBUG
        let line = "[\(level.label)] \(message)"
        LogExportBuffer.shared.append(line)
        LogNetworkSink.shared.send(line)
        #endif
    }
    
    /// Format location information for logging
    static func formatLocation(file: String, line: Int, function: String) -> String {
        let fileName = (file as NSString).lastPathComponent
        let timestamp = timestampFormatter.string(from: Date())
        return "[\(timestamp)] [\(fileName):\(line) \(function)]"
    }
}

// MARK: - Migration Helper

/// Helper to migrate from print statements to SecureLogger
/// Usage: Replace print(...) with secureLog(...)
public func secureLog(_ items: Any..., separator: String = " ", terminator: String = "\n",
                      file: String = #file, line: Int = #line, function: String = #function) {
    #if DEBUG
    let message = items.map { String(describing: $0) }.joined(separator: separator)
    SecureLogger.debug(message, file: file, line: line, function: function)
    #endif
}
