//
// KeychainManager.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Security

/// A concurrency-safe keychain manager for storing and retrieving passwords and encryption keys.
final class KeychainManager: @unchecked Sendable {
    // MARK: Lifecycle

    private init() {}

    // MARK: Internal

    static let shared = KeychainManager()

    // MARK: - Channel Passwords

    /// Saves a channel password to the keychain.
    func saveChannelPassword(_ password: String, for channel: String) -> Bool {
        queue.sync(flags: .barrier) {
            let key = "channel_\(channel)"
            return save(password, forKey: key)
        }
    }

    /// Retrieves a password for the specified channel.
    func getChannelPassword(for channel: String) -> String? {
        queue.sync {
            let key = "channel_\(channel)"
            return retrieve(forKey: key)
        }
    }

    /// Deletes a stored password for the given channel.
    func deleteChannelPassword(for channel: String) -> Bool {
        queue.sync(flags: .barrier) {
            let key = "channel_\(channel)"
            return delete(forKey: key)
        }
    }

    /// Returns all stored channel passwords as [channel: password] dictionary.
    func getAllChannelPasswords() -> [String: String] {
        queue.sync {
            var passwords: [String: String] = [:]

            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecMatchLimit as String: kSecMatchLimitAll,
                kSecReturnAttributes as String: true,
                kSecReturnData as String: true,
            ]

            if let accessGroup {
                query[kSecAttrAccessGroup as String] = accessGroup
            }

            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)

            if status == errSecSuccess, let items = result as? [[String: Any]] {
                for item in items {
                    if let account = item[kSecAttrAccount as String] as? String,
                        account.hasPrefix("channel_"),
                        let data = item[kSecValueData as String] as? Data,
                        let password = String(data: data, encoding: .utf8)
                    {
                        let channel = String(account.dropFirst(8))
                        passwords[channel] = password
                    }
                }
            }

            return passwords
        }
    }

    // MARK: - Identity Keys

    /// Saves an encryption key to the keychain under the given key name.
    func saveIdentityKey(_ keyData: Data, forKey key: String) -> Bool {
        queue.sync(flags: .barrier) {
            saveData(keyData, forKey: "identity_\(key)")
        }
    }

    /// Retrieves a stored encryption key from the keychain.
    func getIdentityKey(forKey key: String) -> Data? {
        queue.sync {
            retrieveData(forKey: "identity_\(key)")
        }
    }

    // MARK: - Cleanup

    /// Deletes all stored keychain passwords.
    func deleteAllPasswords() -> Bool {
        queue.sync(flags: .barrier) {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ]

            if let accessGroup {
                query[kSecAttrAccessGroup as String] = accessGroup
            }

            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
    }

    // MARK: Private

    private let service = "com.bitchat.passwords"
    private let accessGroup: String? = nil
    private let queue = DispatchQueue(
        label: "com.bitchat.keychain.queue",
        attributes: .concurrent
    )

    // MARK: - Private Helpers

    private func save(_ value: String, forKey key: String) -> Bool {
        guard let data = value.data(using: .utf8) else {
            return false
        }
        return saveData(data, forKey: key)
    }

    private func saveData(_ data: Data, forKey key: String) -> Bool {
        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        var mutableQuery = updateQuery
        if let accessGroup {
            mutableQuery[kSecAttrAccessGroup as String] = accessGroup
        }

        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String:
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        var status = SecItemUpdate(
            mutableQuery as CFDictionary,
            updateAttributes as CFDictionary
        )

        if status == errSecItemNotFound {
            var createQuery = mutableQuery
            createQuery[kSecValueData as String] = data
            createQuery[kSecAttrAccessible as String] =
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(createQuery as CFDictionary, nil)
        }

        return status == errSecSuccess
    }

    private func retrieve(forKey key: String) -> String? {
        guard let data = retrieveData(forKey: key) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func retrieveData(forKey key: String) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess, let data = result as? Data {
            return data
        }

        return nil
    }

    private func delete(forKey key: String) -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
