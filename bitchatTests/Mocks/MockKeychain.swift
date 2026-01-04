//
// MockKeychain.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
@testable import bitchat

final class MockKeychain: KeychainManagerProtocol {
    private var storage: [String: Data] = [:]
    private var serviceStorage: [String: [String: Data]] = [:]

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
        data = Data()
    }

    func secureClear(_ string: inout String) {
        string = ""
    }

    func verifyIdentityKeyExists() -> Bool {
        storage["identity_noiseStaticKey"] != nil
    }

    // MARK: - Generic Data Storage (consolidated from KeychainHelper)

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
    private var _secureClearStringCallCount = 0

    var secureClearDataCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _secureClearDataCallCount
    }

    var secureClearStringCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _secureClearStringCallCount
    }

    var totalSecureClearCallCount: Int {
        return secureClearDataCallCount + secureClearStringCallCount
    }

    func resetCounts() {
        lock.lock()
        defer { lock.unlock() }
        _secureClearDataCallCount = 0
        _secureClearStringCallCount = 0
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

    func secureClear(_ string: inout String) {
        lock.lock()
        _secureClearStringCallCount += 1
        lock.unlock()
        string = ""
    }

    func verifyIdentityKeyExists() -> Bool {
        storage["identity_noiseStaticKey"] != nil
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
}
