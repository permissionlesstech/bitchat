//
// KeychainManagerProtocol.swift
// BitFoundation
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import struct Foundation.Data
import class CoreFoundation.CFString
import typealias Darwin.OSStatus

public protocol KeychainManagerProtocol {
    func saveIdentityKey(_ keyData: Data, forKey key: String) -> Bool
    func getIdentityKey(forKey key: String) -> Data?
    func deleteIdentityKey(forKey key: String) -> Bool
    func deleteAllKeychainData() -> Bool

    func secureClear(_ data: inout Data)
    func secureClear(_ string: inout String)

    func verifyIdentityKeyExists() -> Bool

    // BCH-01-009: Methods with proper error classification
    /// Get identity key with detailed result for error handling
    func getIdentityKeyWithResult(forKey key: String) -> KeychainReadResult
    /// Save identity key with detailed result for error handling
    func saveIdentityKeyWithResult(_ keyData: Data, forKey key: String) -> KeychainSaveResult

    // MARK: - Generic Data Storage (consolidated from KeychainHelper)
    /// Save data with a custom service name
    func save(key: String, data: Data, service: String, accessible: CFString?)
    /// Load data from a custom service
    func load(key: String, service: String) -> Data?
    /// Load data from a custom service while preserving Keychain status.
    /// Callers that own encrypted files need to distinguish a missing key
    /// from a temporarily inaccessible key before replacing those files.
    func loadWithResult(key: String, service: String) -> KeychainReadResult
    /// Delete data from a custom service
    func delete(key: String, service: String)
    /// Delete every item stored under a custom service
    func deleteAll(service: String)
}

public extension KeychainManagerProtocol {
    /// Source-compatible fallback for lightweight/test implementations. The
    /// production manager overrides this with the underlying OSStatus.
    func loadWithResult(key: String, service: String) -> KeychainReadResult {
        if let data = load(key: key, service: service) {
            return .success(data)
        }
        return .itemNotFound
    }
}

// MARK: - Keychain Error Types
// BCH-01-009: Proper error classification to distinguish expected states from critical failures

/// Result of a keychain read operation with proper error classification
public enum KeychainReadResult {
    case success(Data)
    case itemNotFound        // Expected: key doesn't exist yet
    case accessDenied        // Critical: app lacks keychain access
    case deviceLocked        // Recoverable: device is locked
    case authenticationFailed // Recoverable: biometric/passcode failed
    case otherError(OSStatus) // Unexpected error

    public var isRecoverableError: Bool {
        switch self {
        case .deviceLocked, .authenticationFailed:
            return true
        default:
            return false
        }
    }
}

/// Result of a keychain save operation with proper error classification
public enum KeychainSaveResult {
    case success
    case duplicateItem       // Can retry with update
    case accessDenied        // Critical: app lacks keychain access
    case deviceLocked        // Recoverable: device is locked
    case storageFull         // Critical: no space available
    case otherError(OSStatus)

    public var isRecoverableError: Bool {
        switch self {
        case .duplicateItem, .deviceLocked:
            return true
        default:
            return false
        }
    }
}
