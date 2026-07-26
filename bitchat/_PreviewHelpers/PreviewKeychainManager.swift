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
    private let installAccessGate: KeychainInstallAccessGate
    private let reconcileInstallAccess: () -> Bool
    private var storage: [String: Data] = [:]
    private var serviceStorage: [String: [String: Data]] = [:]

    init(
        installAccessGate: KeychainInstallAccessGate = KeychainInstallAccessGate(),
        reconcileInstallAccess: @escaping () -> Bool = { true }
    ) {
        self.installAccessGate = installAccessGate
        self.reconcileInstallAccess = reconcileInstallAccess
    }

    private func installAccessAllowed() -> Bool {
        installAccessGate.allowsAccess(reconcile: reconcileInstallAccess)
    }

    func saveIdentityKey(_ keyData: Data, forKey key: String) -> Bool {
        guard installAccessAllowed() else { return false }
        lock.lock()
        defer { lock.unlock() }
        storage[key] = keyData
        return true
    }

    func getIdentityKey(forKey key: String) -> Data? {
        guard installAccessAllowed() else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    func deleteIdentityKey(forKey key: String) -> Bool {
        guard installAccessAllowed() else { return false }
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
        guard installAccessAllowed() else { return false }
        lock.lock()
        defer { lock.unlock() }
        return storage["identity_noiseStaticKey"] != nil
    }

    // BCH-01-009: New methods with proper error classification
    func getIdentityKeyWithResult(forKey key: String) -> KeychainReadResult {
        guard installAccessAllowed() else { return .accessDenied }
        lock.lock()
        defer { lock.unlock() }
        if let data = storage[key] {
            return .success(data)
        }
        return .itemNotFound
    }

    func saveIdentityKeyWithResult(_ keyData: Data, forKey key: String) -> KeychainSaveResult {
        guard installAccessAllowed() else { return .accessDenied }
        lock.lock()
        defer { lock.unlock() }
        storage[key] = keyData
        return .success
    }

    // MARK: - Generic Data Storage (consolidated from KeychainHelper)

    func save(key: String, data: Data, service: String, accessible: CFString?) {
        guard installAccessAllowed() else { return }
        lock.lock()
        defer { lock.unlock() }
        serviceStorage[service, default: [:]][key] = data
    }

    func load(key: String, service: String) -> Data? {
        guard case .success(let data) = loadWithResult(key: key, service: service) else {
            return nil
        }
        return data
    }

    func loadWithResult(key: String, service: String) -> KeychainReadResult {
        guard installAccessAllowed() else { return .accessDenied }
        lock.lock()
        defer { lock.unlock() }
        guard let data = serviceStorage[service]?[key] else {
            return .itemNotFound
        }
        return .success(data)
    }

    func delete(key: String, service: String) {
        guard installAccessAllowed() else { return }
        lock.lock()
        defer { lock.unlock() }
        serviceStorage[service]?.removeValue(forKey: key)
    }

    func deleteAll(service: String) {
        guard installAccessAllowed() else { return }
        lock.lock()
        defer { lock.unlock() }
        serviceStorage.removeValue(forKey: service)
    }
}
