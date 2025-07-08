//
// KeychainManager.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Security

    /// A thread-safe, concurrency-compliant manager for securely storing and retrieving
    /// passwords and identity keys using the iOS Keychain.
final class KeychainManager: @unchecked Sendable {
    
        /// Shared singleton instance of the keychain manager.
    static let shared = KeychainManager()
    
    private let service = "com.bitchat.passwords"
    private let accessGroup: String? = nil
    private let queue = DispatchQueue(label: "com.bitchat.keychain.queue", attributes: .concurrent)
    
    private init() {}
    
        // MARK: - Channel Passwords
    
        /// Saves a password for a specific channel into the keychain.
        /// - Parameters:
        ///   - password: The password to store.
        ///   - channel: The channel identifier.
        /// - Returns: `true` if the password was saved successfully.
    func saveChannelPassword(_ password: String, for channel: String) -> Bool {
        queue.sync(flags: .barrier) {
            let key = "channel_\(channel)"
            return save(password, forKey: key)
        }
    }
    
        /// Retrieves the password for a given channel from the keychain.
        /// - Parameter channel: The channel identifier.
        /// - Returns: The stored password if found, otherwise `nil`.
    func getChannelPassword(for channel: String) -> String? {
        queue.sync {
            let key = "channel_\(channel)"
            return retrieve(forKey: key)
        }
    }
    
        /// Deletes the password for a given channel from the keychain.
        /// - Parameter channel: The channel identifier.
        /// - Returns: `true` if the password was deleted or not found.
    func deleteChannelPassword(for channel: String) -> Bool {
        queue.sync(flags: .barrier) {
            let key = "channel_\(channel)"
            return delete(forKey: key)
        }
    }
    
        /// Retrieves all stored channel passwords.
        /// - Returns: A dictionary where the key is the channel ID and the value is the password.
    func getAllChannelPasswords() -> [String: String] {
        queue.sync {
            var passwords: [String: String] = [:]
            
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecMatchLimit as String: kSecMatchLimitAll,
                kSecReturnAttributes as String: true,
                kSecReturnData as String: true
            ]
            
            if let accessGroup = accessGroup {
                query[kSecAttrAccessGroup as String] = accessGroup
            }
            
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            
            if status == errSecSuccess, let items = result as? [[String: Any]] {
                for item in items {
                    if let account = item[kSecAttrAccount as String] as? String,
                       account.hasPrefix("channel_"),
                       let data = item[kSecValueData as String] as? Data,
                       let password = String(data: data, encoding: .utf8) {
                        let channel = String(account.dropFirst(8)) // Remove "channel_" prefix
                        passwords[channel] = password
                    }
                }
            }
            
            return passwords
        }
    }
    
        // MARK: - Identity Keys
    
        /// Saves an identity encryption key to the keychain.
        /// - Parameters:
        ///   - keyData: The raw data of the encryption key.
        ///   - key: A string identifier for the key.
        /// - Returns: `true` if the key was stored successfully.
    func saveIdentityKey(_ keyData: Data, forKey key: String) -> Bool {
        queue.sync(flags: .barrier) {
            saveData(keyData, forKey: "identity_\(key)")
        }
    }
    
        /// Retrieves an identity encryption key from the keychain.
        /// - Parameter key: The key identifier.
        /// - Returns: The stored data if found, otherwise `nil`.
    func getIdentityKey(forKey key: String) -> Data? {
        queue.sync {
            retrieveData(forKey: "identity_\(key)")
        }
    }
    
        // MARK: - Cleanup
    
        /// Deletes all stored passwords and keys in the keychain for this service.
        /// - Returns: `true` if deletion was successful or no items were found.
    func deleteAllPasswords() -> Bool {
        queue.sync(flags: .barrier) {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service
            ]
            
            if let accessGroup = accessGroup {
                query[kSecAttrAccessGroup as String] = accessGroup
            }
            
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
    }
    
        // MARK: - Private Helpers
    
        /// Saves a string value to the keychain.
    private func save(_ value: String, forKey key: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        return saveData(data, forKey: key)
    }
    
        /// Saves raw data to the keychain, updating if already exists.
    private func saveData(_ data: Data, forKey key: String) -> Bool {
        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        
        var mutableQuery = updateQuery
        if let accessGroup = accessGroup {
            mutableQuery[kSecAttrAccessGroup as String] = accessGroup
        }
        
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
        var status = SecItemUpdate(mutableQuery as CFDictionary, updateAttributes as CFDictionary)
        
        if status == errSecItemNotFound {
            var createQuery = mutableQuery
            createQuery[kSecValueData as String] = data
            createQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(createQuery as CFDictionary, nil)
        }
        
        return status == errSecSuccess
    }
    
        /// Retrieves a string value from the keychain.
    private func retrieve(forKey key: String) -> String? {
        guard let data = retrieveData(forKey: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    
        /// Retrieves raw data from the keychain for a given key.
    private func retrieveData(forKey key: String) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecSuccess, let data = result as? Data {
            return data
        }
        
        return nil
    }
    
        /// Deletes a single keychain item by key.
    private func delete(forKey key: String) -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        
        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
