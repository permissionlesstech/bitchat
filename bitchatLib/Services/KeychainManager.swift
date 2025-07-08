//
// KeychainManager.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Security

class KeychainManager {
    static let shared = KeychainManager()
    
    private let service = "com.bitchat.passwords"
    private let accessGroup: String? = nil // Set this if using app groups
    
    private init() {}
    
    // MARK: - Channel Passwords
    
    func saveChannelPassword(_ password: String, for channel: String) -> Bool {
        let key = "channel_\(channel)"
        return save(password, forKey: key)
    }
    
    func getChannelPassword(for channel: String) -> String? {
        let key = "channel_\(channel)"
        return retrieve(forKey: key)
    }
    
    func deleteChannelPassword(for channel: String) -> Bool {
        let key = "channel_\(channel)"
        return delete(forKey: key)
    }
    
    func getAllChannelPasswords() -> [String: String] {
        var passwords: [String: String] = [:]
        
        // Query all items
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
    
    // MARK: - Identity Keys
    
    func saveIdentityKey(_ keyData: Data, forKey key: String) -> Bool {
        return saveData(keyData, forKey: "identity_\(key)")
    }
    
    func getIdentityKey(forKey key: String) -> Data? {
        return retrieveData(forKey: "identity_\(key)")
    }
    
    // MARK: - Generic Operations
    
    private func save(_ value: String, forKey key: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        return saveData(data, forKey: key)
    }
    
    private func saveData(_ data: Data, forKey key: String) -> Bool {
        // First try to update existing
        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        
        var mutableUpdateQuery = updateQuery
        if let accessGroup = accessGroup {
            mutableUpdateQuery[kSecAttrAccessGroup as String] = accessGroup
        }
        
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
        var status = SecItemUpdate(mutableUpdateQuery as CFDictionary, updateAttributes as CFDictionary)
        
        if status == errSecItemNotFound {
            // Item doesn't exist, create it
            var createQuery = mutableUpdateQuery
            createQuery[kSecValueData as String] = data
            createQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            
            status = SecItemAdd(createQuery as CFDictionary, nil)
        }
        
        return status == errSecSuccess
    }
    
    private func retrieve(forKey key: String) -> String? {
        guard let data = retrieveData(forKey: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    
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
    
    // MARK: - Cleanup
    
    func deleteAllPasswords() -> Bool {
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