//
// KeychainService.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Security
import LocalAuthentication

/// Service for secure keychain operations
class KeychainService {
    private let service = "com.bitchat.keychain"
    
    enum KeychainError: LocalizedError {
        case itemNotFound
        case invalidData
        case saveError(OSStatus)
        case loadError(OSStatus)
        case deleteError(OSStatus)
        case accessControlCreationFailed
        case biometricAuthenticationFailed
        case biometricAuthenticationCanceled
        
        var errorDescription: String? {
            switch self {
            case .itemNotFound:
                return "Item not found in keychain"
            case .invalidData:
                return "Invalid data format"
            case .saveError(let status):
                return "Failed to save to keychain: \(status)"
            case .loadError(let status):
                return "Failed to load from keychain: \(status)"
            case .deleteError(let status):
                return "Failed to delete from keychain: \(status)"
            case .accessControlCreationFailed:
                return "Failed to create keychain access control"
            case .biometricAuthenticationFailed:
                return "Biometric authentication failed"
            case .biometricAuthenticationCanceled:
                return "Biometric authentication was canceled"
            }
        }
    }
    
    enum KeychainAccessibility {
        case whenUnlockedThisDeviceOnly
        case whenUnlockedThisDeviceOnlyWithBiometrics
        
        var cfString: CFString {
            switch self {
            case .whenUnlockedThisDeviceOnly:
                return kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            case .whenUnlockedThisDeviceOnlyWithBiometrics:
                return kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            }
        }
        
        var requiresBiometrics: Bool {
            switch self {
            case .whenUnlockedThisDeviceOnly:
                return false
            case .whenUnlockedThisDeviceOnlyWithBiometrics:
                return true
            }
        }
    }
    
    /// Store data in the keychain
    func storeItem(_ data: Data, key: String, accessibility: KeychainAccessibility = .whenUnlockedThisDeviceOnly) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility.cfString,
            kSecAttrSynchronizable as String: false
        ]
        
        if accessibility.requiresBiometrics {
            let accessControl = try createAccessControl()
            query[kSecAttrAccessControl as String] = accessControl
            query[kSecUseAuthenticationContext as String] = LAContext()
        }
        
        // Delete any existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        
        let status = SecItemAdd(query as CFDictionary, nil)
        
        if status != errSecSuccess {
            throw KeychainError.saveError(status)
        }
    }
    
    /// Retrieve data from the keychain
    func retrieveItem(key: String) throws -> Data {
        let context = LAContext()
        context.localizedReason = "Access secure data"
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]
        
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw KeychainError.invalidData
            }
            return data
        case errSecItemNotFound:
            throw KeychainError.itemNotFound
        case errSecUserCanceled:
            throw KeychainError.biometricAuthenticationCanceled
        case errSecAuthFailed:
            throw KeychainError.biometricAuthenticationFailed
        default:
            throw KeychainError.loadError(status)
        }
    }
    
    /// Delete an item from the keychain
    func deleteItem(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.deleteError(status)
        }
    }
    
    /// Check if an item exists in the keychain
    func itemExists(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }
    
    private func createAccessControl() throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        
        guard let accessControl = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.biometryCurrentSet, .privateKeyUsage],
            &error
        ) else {
            if let error = error?.takeRetainedValue() {
                throw error as Error
            }
            throw KeychainError.accessControlCreationFailed
        }
        
        return accessControl
    }
}