//
// SecureStorageService.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Security

/// Service for secure storage of sensitive data using iOS Keychain
class SecureStorageService {
    
    // MARK: - Properties
    
    private let service = "com.bitchat.securestorage"
    private let accessGroup: String? = nil // Set this if using app groups
    
    // MARK: - Initialization
    
    init() {}
    
    // MARK: - Public Methods
    
    /// Stores data securely in the Keychain
    /// - Parameters:
    ///   - data: The data to store
    ///   - key: The key to associate with the data
    ///   - accessibility: The accessibility level for the stored item
    /// - Throws: SecureStorageError if the operation fails
    func storeData(_ data: Data, for key: String, accessibility: CFString = kSecAttrAccessibleWhenUnlockedThisDeviceOnly) throws {
        let status = storeDataInternal(data, forKey: key, accessibility: accessibility)
        
        guard status == errSecSuccess else {
            throw SecureStorageError.storageError(status)
        }
    }
    
    /// Retrieves data from the Keychain
    /// - Parameter key: The key associated with the data
    /// - Returns: The stored data, or nil if not found
    /// - Throws: SecureStorageError if the operation fails
    func retrieveData(for key: String) throws -> Data? {
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
        
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw SecureStorageError.retrievalError(status)
        }
    }
    
    /// Deletes data from the Keychain
    /// - Parameter key: The key associated with the data to delete
    /// - Throws: SecureStorageError if the operation fails
    func deleteData(for key: String) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        
        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        
        let status = SecItemDelete(query as CFDictionary)
        
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureStorageError.deletionError(status)
        }
    }
    
    /// Checks if data exists for a given key
    /// - Parameter key: The key to check
    /// - Returns: true if data exists, false otherwise
    func dataExists(for key: String) -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }
    
    /// Updates existing data in the Keychain
    /// - Parameters:
    ///   - data: The new data to store
    ///   - key: The key associated with the data
    ///   - accessibility: The accessibility level for the stored item
    /// - Throws: SecureStorageError if the operation fails
    func updateData(_ data: Data, for key: String, accessibility: CFString = kSecAttrAccessibleWhenUnlockedThisDeviceOnly) throws {
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
            kSecAttrAccessible as String: accessibility
        ]
        
        let status = SecItemUpdate(mutableUpdateQuery as CFDictionary, updateAttributes as CFDictionary)
        
        guard status == errSecSuccess else {
            throw SecureStorageError.updateError(status)
        }
    }
    
    /// Retrieves all keys stored by this service
    /// - Returns: Array of all keys
    /// - Throws: SecureStorageError if the operation fails
    func getAllKeys() throws -> [String] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]
        
        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        switch status {
        case errSecSuccess:
            guard let items = result as? [[String: Any]] else {
                return []
            }
            
            return items.compactMap { item in
                item[kSecAttrAccount as String] as? String
            }
        case errSecItemNotFound:
            return []
        default:
            throw SecureStorageError.retrievalError(status)
        }
    }
    
    /// Removes all data stored by this service
    /// - Throws: SecureStorageError if the operation fails
    func clearAllData() throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        
        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        
        let status = SecItemDelete(query as CFDictionary)
        
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureStorageError.deletionError(status)
        }
    }
    
    // MARK: - Private Methods
    
    private func storeDataInternal(_ data: Data, forKey key: String, accessibility: CFString) -> OSStatus {
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
            kSecAttrAccessible as String: accessibility
        ]
        
        var status = SecItemUpdate(mutableUpdateQuery as CFDictionary, updateAttributes as CFDictionary)
        
        if status == errSecItemNotFound {
            // Item doesn't exist, create it
            var createQuery = mutableUpdateQuery
            createQuery[kSecValueData as String] = data
            createQuery[kSecAttrAccessible as String] = accessibility
            
            status = SecItemAdd(createQuery as CFDictionary, nil)
        }
        
        return status
    }
}

// MARK: - Error Types

/// Errors that can occur during secure storage operations
enum SecureStorageError: Error, LocalizedError {
    case storageError(OSStatus)
    case retrievalError(OSStatus)
    case deletionError(OSStatus)
    case updateError(OSStatus)
    case invalidData
    case keyNotFound
    
    var errorDescription: String? {
        switch self {
        case .storageError(let status):
            return "Failed to store data in Keychain: \(SecCopyErrorMessageString(status, nil) ?? "Unknown error")"
        case .retrievalError(let status):
            return "Failed to retrieve data from Keychain: \(SecCopyErrorMessageString(status, nil) ?? "Unknown error")"
        case .deletionError(let status):
            return "Failed to delete data from Keychain: \(SecCopyErrorMessageString(status, nil) ?? "Unknown error")"
        case .updateError(let status):
            return "Failed to update data in Keychain: \(SecCopyErrorMessageString(status, nil) ?? "Unknown error")"
        case .invalidData:
            return "Invalid data provided for storage"
        case .keyNotFound:
            return "The specified key was not found"
        }
    }
}

// MARK: - Extensions

extension SecureStorageService {
    
    /// Convenience method to store a string
    /// - Parameters:
    ///   - string: The string to store
    ///   - key: The key to associate with the string
    ///   - accessibility: The accessibility level for the stored item
    /// - Throws: SecureStorageError if the operation fails
    func storeString(_ string: String, for key: String, accessibility: CFString = kSecAttrAccessibleWhenUnlockedThisDeviceOnly) throws {
        guard let data = string.data(using: .utf8) else {
            throw SecureStorageError.invalidData
        }
        try storeData(data, for: key, accessibility: accessibility)
    }
    
    /// Convenience method to retrieve a string
    /// - Parameter key: The key associated with the string
    /// - Returns: The stored string, or nil if not found
    /// - Throws: SecureStorageError if the operation fails
    func retrieveString(for key: String) throws -> String? {
        guard let data = try retrieveData(for: key) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
    
    /// Convenience method to store codable objects
    /// - Parameters:
    ///   - object: The codable object to store
    ///   - key: The key to associate with the object
    ///   - accessibility: The accessibility level for the stored item
    /// - Throws: SecureStorageError if the operation fails
    func storeObject<T: Codable>(_ object: T, for key: String, accessibility: CFString = kSecAttrAccessibleWhenUnlockedThisDeviceOnly) throws {
        let data = try JSONEncoder().encode(object)
        try storeData(data, for: key, accessibility: accessibility)
    }
    
    /// Convenience method to retrieve codable objects
    /// - Parameters:
    ///   - type: The type of object to retrieve
    ///   - key: The key associated with the object
    /// - Returns: The stored object, or nil if not found
    /// - Throws: SecureStorageError if the operation fails
    func retrieveObject<T: Codable>(_ type: T.Type, for key: String) throws -> T? {
        guard let data = try retrieveData(for: key) else {
            return nil
        }
        return try JSONDecoder().decode(type, from: data)
    }
}