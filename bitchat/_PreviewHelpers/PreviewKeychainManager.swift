//
// PreviewKeychainManager.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation

final class PreviewKeychainManager: KeychainManagerProtocol {
    // Locked: KeychainManager.makeDefault() hands one shared instance to
    // every default-constructed component under test, which access it from
    // arbitrary threads.
    private let lock = NSLock()
    private var storage: [String: Data] = [:]
    private var serviceStorage: [String: [String: Data]] = [:]
    init() {}

    func saveIdentityKey(_ keyData: Data, forKey key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = keyData
        return true
    }

    func getIdentityKey(forKey key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    func deleteIdentityKey(forKey key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: key)
        return true
    }

    func deleteAllKeychainData() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
        serviceStorage.removeAll()
        return true
    }

    func secureClear(_ data: inout Data) {}

    func secureClear(_ string: inout String) {}

    func verifyIdentityKeyExists() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage["identity_noiseStaticKey"] != nil
    }

    // BCH-01-009: New methods with proper error classification
    func getIdentityKeyWithResult(forKey key: String) -> KeychainReadResult {
        lock.lock()
        defer { lock.unlock() }
        if let data = storage[key] {
            return .success(data)
        }
        return .itemNotFound
    }

    func saveIdentityKeyWithResult(_ keyData: Data, forKey key: String) -> KeychainSaveResult {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = keyData
        return .success
    }

    // MARK: - Generic Data Storage (consolidated from KeychainHelper)

    func save(key: String, data: Data, service: String, accessible: CFString?) {
        lock.lock()
        defer { lock.unlock() }
        serviceStorage[service, default: [:]][key] = data
    }

    func load(key: String, service: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return serviceStorage[service]?[key]
    }

    func delete(key: String, service: String) {
        lock.lock()
        defer { lock.unlock() }
        serviceStorage[service]?.removeValue(forKey: key)
    }

    func deleteAll(service: String) {
        lock.lock()
        defer { lock.unlock() }
        serviceStorage.removeValue(forKey: service)
    }
}
