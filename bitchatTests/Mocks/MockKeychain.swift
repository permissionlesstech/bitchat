//
// MockKeychain.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import BitFoundation
@testable import bitchat

final class MockKeychain: KeychainManagerProtocol {
    private var storage: [String: Data] = [:]
    private var serviceStorage: [String: [String: Data]] = [:]

    // BCH-01-009: Configurable error simulation for testing
    var simulatedReadError: KeychainReadResult?
    var simulatedReadErrorKeys: Set<String>?
    var simulatedSaveError: KeychainSaveResult?
    var simulatedGenericReadError: KeychainReadResult?
    var simulatedDeleteAllResult = true
    private(set) var deleteAllCallCount = 0
    private(set) var saveIdentityKeyCallCount = 0
    private(set) var getIdentityKeyCallCount = 0
    private(set) var loadCallCount = 0

    func saveIdentityKey(_ keyData: Data, forKey key: String) -> Bool {
        saveIdentityKeyCallCount += 1
        storage[key] = keyData
        return true
    }

    func getIdentityKey(forKey key: String) -> Data? {
        getIdentityKeyCallCount += 1
        if simulatedReadError != nil,
           simulatedReadErrorKeys == nil || simulatedReadErrorKeys?.contains(key) == true {
            return nil
        }
        return storage[key]
    }

    func deleteIdentityKey(forKey key: String) -> Bool {
        storage.removeValue(forKey: key)
        return true
    }

    func deleteAllKeychainData() -> Bool {
        deleteAllCallCount += 1
        guard simulatedDeleteAllResult else { return false }
        storage.removeAll()
        serviceStorage.removeAll()
        return true
    }

    func secureClear(_ data: inout Data) {
        data = Data()
    }

    func verifyIdentityKeyExists() -> Bool {
        storage["identity_noiseStaticKey"] != nil
    }

    // BCH-01-009: New methods with proper error classification
    func getIdentityKeyWithResult(forKey key: String) -> KeychainReadResult {
        getIdentityKeyCallCount += 1
        if let simulated = simulatedReadError,
           simulatedReadErrorKeys == nil || simulatedReadErrorKeys?.contains(key) == true {
            return simulated
        }
        if let data = storage[key] {
            return .success(data)
        }
        return .itemNotFound
    }

    func saveIdentityKeyWithResult(_ keyData: Data, forKey key: String) -> KeychainSaveResult {
        saveIdentityKeyCallCount += 1
        if let simulated = simulatedSaveError {
            return simulated
        }
        storage[key] = keyData
        return .success
    }

    // MARK: - Generic Data Storage (consolidated from KeychainHelper)

    func save(key: String, data: Data, service: String, accessible: CFString?) {
        if serviceStorage[service] == nil {
            serviceStorage[service] = [:]
        }
        serviceStorage[service]?[key] = data
    }

    func load(key: String, service: String) -> Data? {
        loadCallCount += 1
        if simulatedGenericReadError != nil {
            return nil
        }
        return serviceStorage[service]?[key]
    }

    func loadWithResult(key: String, service: String) -> KeychainReadResult {
        loadCallCount += 1
        if let simulatedGenericReadError {
            return simulatedGenericReadError
        }
        if let data = serviceStorage[service]?[key] {
            return .success(data)
        }
        return .itemNotFound
    }

    func delete(key: String, service: String) {
        serviceStorage[service]?.removeValue(forKey: key)
    }

    func deleteAll(service: String) {
        serviceStorage.removeValue(forKey: service)
    }
}

/// Typealias for backwards compatibility with tests using MockKeychainHelper
typealias MockKeychainHelper = MockKeychain

/// Mock keychain that tracks secureClear calls for testing DH secret clearing
final class TrackingMockKeychain: KeychainManagerProtocol {
    private var storage: [String: Data] = [:]
    private var serviceStorage: [String: [String: Data]] = [:]

    /// Thread-safe counter for secureClear calls
    private let lock = NSLock()
    private var _secureClearDataCallCount = 0

    // BCH-01-009: Configurable error simulation for testing
    var simulatedReadError: KeychainReadResult?
    var simulatedSaveError: KeychainSaveResult?

    var secureClearDataCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _secureClearDataCallCount
    }

    var totalSecureClearCallCount: Int {
        return secureClearDataCallCount
    }

    func resetCounts() {
        lock.lock()
        defer { lock.unlock() }
        _secureClearDataCallCount = 0
    }

    func saveIdentityKey(_ keyData: Data, forKey key: String) -> Bool {
        storage[key] = keyData
        return true
    }

    func getIdentityKey(forKey key: String) -> Data? {
        storage[key]
    }

    func deleteIdentityKey(forKey key: String) -> Bool {
        storage.removeValue(forKey: key)
        return true
    }

    func deleteAllKeychainData() -> Bool {
        storage.removeAll()
        serviceStorage.removeAll()
        return true
    }

    func secureClear(_ data: inout Data) {
        lock.lock()
        _secureClearDataCallCount += 1
        lock.unlock()
        data = Data()
    }

    func verifyIdentityKeyExists() -> Bool {
        storage["identity_noiseStaticKey"] != nil
    }

    // BCH-01-009: New methods with proper error classification
    func getIdentityKeyWithResult(forKey key: String) -> KeychainReadResult {
        if let simulated = simulatedReadError {
            return simulated
        }
        if let data = storage[key] {
            return .success(data)
        }
        return .itemNotFound
    }

    func saveIdentityKeyWithResult(_ keyData: Data, forKey key: String) -> KeychainSaveResult {
        if let simulated = simulatedSaveError {
            return simulated
        }
        storage[key] = keyData
        return .success
    }

    func save(key: String, data: Data, service: String, accessible: CFString?) {
        if serviceStorage[service] == nil {
            serviceStorage[service] = [:]
        }
        serviceStorage[service]?[key] = data
    }

    func load(key: String, service: String) -> Data? {
        serviceStorage[service]?[key]
    }

    func delete(key: String, service: String) {
        serviceStorage[service]?.removeValue(forKey: key)
    }

    func deleteAll(service: String) {
        serviceStorage.removeValue(forKey: service)
    }
}
