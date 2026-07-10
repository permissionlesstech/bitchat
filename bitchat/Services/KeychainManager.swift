//
// KeychainManager.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import BitFoundation
import Foundation
import Security

final class KeychainManager: KeychainManagerProtocol {
    /// Default keychain for components that construct their own rather than
    /// having one injected. Under test this is an in-memory keychain: the
    /// xctest runner's code signature changes every build, so any read of a
    /// real login-keychain item triggers a macOS password prompt that
    /// "Always Allow" can never satisfy — and tests must never read or
    /// mutate the developer's real keychain (`SecItemCopyMatching` can also
    /// hang in test environments). Production behavior is unchanged.
    static func makeDefault() -> KeychainManagerProtocol {
        // PreviewKeychainManager lives in _PreviewHelpers, a development
        // asset excluded from archive builds — release code must not
        // reference it. Tests always run Debug, so the guard is lossless.
        #if DEBUG
        if TestEnvironment.isRunningTests { return sharedTestKeychain }
        #endif
        return KeychainManager()
    }

    #if DEBUG
    /// One store per process, mirroring the real keychain: separate
    /// default-constructed components (e.g. two NostrIdentityBridge
    /// instances in BoardManager's publish and delete paths) must see each
    /// other's writes, or they would derive different Nostr identities
    /// under test.
    private static let sharedTestKeychain = PreviewKeychainManager()
    #endif

    // Use consistent service name for all keychain items
    private let service = BitchatApp.bundleID
    private let appGroup = "group.\(BitchatApp.bundleID)"

    // AfterFirstUnlock, not WhenUnlocked: the mesh keeps running with the
    // device locked (identity-cache saves failed with -25308 throughout
    // locked-phone testing), and a wake-on-proximity relaunch via BLE state
    // restoration must be able to read the noise keys before the user
    // unlocks. Backup/sync semantics are unchanged (not ThisDeviceOnly).
    private static let itemAccessibility = kSecAttrAccessibleAfterFirstUnlock

    init() {
        #if os(iOS)
        migrateAccessibilityIfNeeded()
        #endif
    }

    #if os(iOS)
    /// One-time upgrade of items created under WhenUnlocked. New saves get
    /// the right class on their own (saves are delete-then-add), but the
    /// long-lived identity keys are written once and would otherwise stay
    /// unreadable while the device is locked.
    private func migrateAccessibilityIfNeeded() {
        let flag = "keychain.accessibility.afterFirstUnlock.migrated"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        let update: [String: Any] = [
            kSecAttrAccessible as String: Self.itemAccessibility
        ]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            // Nothing to migrate on a fresh install; both are terminal.
            UserDefaults.standard.set(true, forKey: flag)
            SecureLogger.info("Keychain accessibility migrated to AfterFirstUnlock (status \(status))", category: .keychain)
        default:
            // Likely errSecInteractionNotAllowed (relaunched while locked) —
            // leave the flag unset so the next launch retries.
            SecureLogger.warning("Keychain accessibility migration deferred (status \(status))", category: .keychain)
        }
    }
    #endif

    // MARK: - Identity Keys
    
    func saveIdentityKey(_ keyData: Data, forKey key: String) -> Bool {
        let fullKey = "identity_\(key)"
        let result = saveData(keyData, forKey: fullKey)
        SecureLogger.logKeyOperation(.save, keyType: key, success: result)
        return result
    }
    
    func getIdentityKey(forKey key: String) -> Data? {
        let fullKey = "identity_\(key)"
        return retrieveData(forKey: fullKey)
    }
    
    func deleteIdentityKey(forKey key: String) -> Bool {
        let result = delete(forKey: "identity_\(key)")
        SecureLogger.logKeyOperation(.delete, keyType: key, success: result)
        return result
    }

    // MARK: - BCH-01-009: Methods with Proper Error Classification

    /// Get identity key with detailed result for proper error handling
    /// Distinguishes between missing keys (expected) and critical failures
    func getIdentityKeyWithResult(forKey key: String) -> KeychainReadResult {
        let fullKey = "identity_\(key)"
        return retrieveDataWithResult(forKey: fullKey)
    }

    /// Save identity key with detailed result and retry logic for transient errors
    func saveIdentityKeyWithResult(_ keyData: Data, forKey key: String) -> KeychainSaveResult {
        let fullKey = "identity_\(key)"
        return saveDataWithResult(keyData, forKey: fullKey)
    }

    /// Internal method to save data with detailed result and retry for transient errors
    private func saveDataWithResult(_ data: Data, forKey key: String, retryCount: Int = 2) -> KeychainSaveResult {
        // Delete any existing item first to ensure clean state
        _ = delete(forKey: key)

        // Build base query
        var base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrService as String: service,
            kSecAttrAccessible as String: Self.itemAccessibility,
            kSecAttrLabel as String: "bitchat-\(key)"
        ]
        #if os(macOS)
        base[kSecAttrSynchronizable as String] = false
        #endif

        func attempt(addAccessGroup: Bool) -> OSStatus {
            var query = base
            if addAccessGroup { query[kSecAttrAccessGroup as String] = appGroup }
            return SecItemAdd(query as CFDictionary, nil)
        }

        #if os(iOS)
        var status = attempt(addAccessGroup: true)
        if status == -34018 { // Missing entitlement, retry without access group
            status = attempt(addAccessGroup: false)
        }
        #else
        let status = attempt(addAccessGroup: false)
        #endif

        // Classify the result
        let result = classifySaveStatus(status)

        // Log all outcomes consistently
        switch result {
        case .success:
            SecureLogger.debug("Keychain save succeeded for key: \(key)", category: .keychain)
        case .duplicateItem:
            SecureLogger.warning("Keychain save found duplicate for key: \(key)", category: .keychain)
        case .accessDenied:
            SecureLogger.error(NSError(domain: "Keychain", code: Int(status)),
                               context: "Keychain access denied for key: \(key)", category: .keychain)
        case .deviceLocked:
            SecureLogger.warning("Device locked during keychain save for key: \(key)", category: .keychain)
        case .storageFull:
            SecureLogger.error(NSError(domain: "Keychain", code: Int(status)),
                               context: "Keychain storage full for key: \(key)", category: .keychain)
        case .otherError(let code):
            SecureLogger.error(NSError(domain: "Keychain", code: Int(code)),
                               context: "Keychain save failed for key: \(key)", category: .keychain)
        }

        // Retry transient errors with exponential backoff
        if result.isRecoverableError && retryCount > 0 {
            let delayMs = UInt32((3 - retryCount) * 100) // 100ms, 200ms backoff
            usleep(delayMs * 1000)
            SecureLogger.debug("Retrying keychain save for key: \(key), attempts remaining: \(retryCount)", category: .keychain)
            return saveDataWithResult(data, forKey: key, retryCount: retryCount - 1)
        }

        return result
    }

    /// Internal method to retrieve data with detailed result
    private func retrieveDataWithResult(forKey key: String) -> KeychainReadResult {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        func attempt(withAccessGroup: Bool) -> OSStatus {
            var q = base
            if withAccessGroup { q[kSecAttrAccessGroup as String] = appGroup }
            return SecItemCopyMatching(q as CFDictionary, &result)
        }

        #if os(iOS)
        var status = attempt(withAccessGroup: true)
        if status == -34018 { status = attempt(withAccessGroup: false) }
        #else
        let status = attempt(withAccessGroup: false)
        #endif

        // Classify the result
        let readResult = classifyReadStatus(status, data: result as? Data)

        // Log all outcomes consistently
        switch readResult {
        case .success:
            SecureLogger.debug("Keychain read succeeded for key: \(key)", category: .keychain)
        case .itemNotFound:
            // Expected case - no logging needed for missing keys
            break
        case .accessDenied:
            SecureLogger.error(NSError(domain: "Keychain", code: Int(status)),
                               context: "Keychain access denied for key: \(key)", category: .keychain)
        case .deviceLocked:
            SecureLogger.warning("Device locked during keychain read for key: \(key)", category: .keychain)
        case .authenticationFailed:
            SecureLogger.warning("Authentication failed for keychain read of key: \(key)", category: .keychain)
        case .otherError(let code):
            SecureLogger.error(NSError(domain: "Keychain", code: Int(code)),
                               context: "Keychain read failed for key: \(key)", category: .keychain)
        }

        return readResult
    }

    /// Classify keychain read status into meaningful categories
    private func classifyReadStatus(_ status: OSStatus, data: Data?) -> KeychainReadResult {
        switch status {
        case errSecSuccess:
            if let data = data {
                return .success(data)
            }
            return .otherError(status)
        case errSecItemNotFound:
            return .itemNotFound
        case errSecInteractionNotAllowed:
            // Device is locked or in a state that doesn't allow keychain access
            return .deviceLocked
        case errSecAuthFailed:
            return .authenticationFailed
        case -34018: // errSecMissingEntitlement
            return .accessDenied
        case errSecNotAvailable:
            return .accessDenied
        default:
            return .otherError(status)
        }
    }

    /// Classify keychain save status into meaningful categories
    private func classifySaveStatus(_ status: OSStatus) -> KeychainSaveResult {
        switch status {
        case errSecSuccess:
            return .success
        case errSecDuplicateItem:
            return .duplicateItem
        case errSecInteractionNotAllowed:
            return .deviceLocked
        case -34018: // errSecMissingEntitlement
            return .accessDenied
        case errSecNotAvailable:
            return .accessDenied
        case errSecDiskFull:
            return .storageFull
        default:
            return .otherError(status)
        }
    }

    // MARK: - Generic Operations
    
    private func saveData(_ data: Data, forKey key: String) -> Bool {
        // Delete any existing item first to ensure clean state
        _ = delete(forKey: key)
        
        // Build base query
        var base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrService as String: service,
            kSecAttrAccessible as String: Self.itemAccessibility,
            kSecAttrLabel as String: "bitchat-\(key)"
        ]
        #if os(macOS)
        base[kSecAttrSynchronizable as String] = false
        #endif

        // Try with access group where it is expected to work (iOS app builds)
        var triedWithoutGroup = false
        func attempt(addAccessGroup: Bool) -> OSStatus {
            var query = base
            if addAccessGroup { query[kSecAttrAccessGroup as String] = appGroup }
            return SecItemAdd(query as CFDictionary, nil)
        }

        #if os(iOS)
        var status = attempt(addAccessGroup: true)
        if status == -34018 { // Missing entitlement, retry without access group
            triedWithoutGroup = true
            status = attempt(addAccessGroup: false)
        }
        #else
        // On macOS dev/simulator default to no access group to avoid -34018
        let status = attempt(addAccessGroup: false)
        #endif

        if status == errSecSuccess { return true }
        if status == -34018 && !triedWithoutGroup {
            SecureLogger.error(NSError(domain: "Keychain", code: -34018), context: "Missing keychain entitlement", category: .keychain)
        } else if status != errSecDuplicateItem {
            SecureLogger.error(NSError(domain: "Keychain", code: Int(status)), context: "Error saving to keychain", category: .keychain)
        }
        return false
    }
    
    private func retrieveData(forKey key: String) -> Data? {
        // Base query
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        func attempt(withAccessGroup: Bool) -> OSStatus {
            var q = base
            if withAccessGroup { q[kSecAttrAccessGroup as String] = appGroup }
            return SecItemCopyMatching(q as CFDictionary, &result)
        }

        #if os(iOS)
        var status = attempt(withAccessGroup: true)
        if status == -34018 { status = attempt(withAccessGroup: false) }
        #else
        let status = attempt(withAccessGroup: false)
        #endif

        if status == errSecSuccess { return result as? Data }
        if status == -34018 {
            SecureLogger.error(NSError(domain: "Keychain", code: -34018), context: "Missing keychain entitlement", category: .keychain)
        }
        return nil
    }
    
    private func delete(forKey key: String) -> Bool {
        // Base delete query
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: service
        ]

        func attempt(withAccessGroup: Bool) -> OSStatus {
            var q = base
            if withAccessGroup { q[kSecAttrAccessGroup as String] = appGroup }
            return SecItemDelete(q as CFDictionary)
        }

        #if os(iOS)
        var status = attempt(withAccessGroup: true)
        if status == -34018 { status = attempt(withAccessGroup: false) }
        #else
        let status = attempt(withAccessGroup: false)
        #endif
        return status == errSecSuccess || status == errSecItemNotFound
    }
    
    // MARK: - Cleanup

    // Delete ALL keychain data for panic mode
    func deleteAllKeychainData() -> Bool {
        SecureLogger.warning("Panic mode - deleting all keychain data", category: .security)
        
        var totalDeleted = 0
        
        // Search without service restriction to catch all items
        let searchQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]
        
        var result: AnyObject?
        let searchStatus = SecItemCopyMatching(searchQuery as CFDictionary, &result)
        
        if searchStatus == errSecSuccess, let items = result as? [[String: Any]] {
            for item in items {
                var shouldDelete = false
                let account = item[kSecAttrAccount as String] as? String ?? ""
                let service = item[kSecAttrService as String] as? String ?? ""
                let accessGroup = item[kSecAttrAccessGroup as String] as? String
                
                // More precise deletion criteria:
                // 1. Check for our specific app group
                // 2. OR check for our exact service name
                // 3. OR check for known legacy service names
                if accessGroup == appGroup {
                    shouldDelete = true
                } else if service == self.service {
                    shouldDelete = true
                } else if [
                    "com.bitchat.passwords",
                    "com.bitchat.deviceidentity",
                    "com.bitchat.noise.identity",
                    "chat.bitchat.passwords",
                    "bitchat.keychain",
                    "bitchat",
                    "com.bitchat"
                ].contains(service) {
                    shouldDelete = true
                }
                
                if shouldDelete {
                    // Build delete query with all available attributes for precise deletion
                    var deleteQuery: [String: Any] = [
                        kSecClass as String: kSecClassGenericPassword
                    ]
                    
                    if !account.isEmpty {
                        deleteQuery[kSecAttrAccount as String] = account
                    }
                    if !service.isEmpty {
                        deleteQuery[kSecAttrService as String] = service
                    }
                    
                    // Add access group if present
                    if let accessGroup = item[kSecAttrAccessGroup as String] as? String,
                       !accessGroup.isEmpty && accessGroup != "test" {
                        deleteQuery[kSecAttrAccessGroup as String] = accessGroup
                    }
                    
                    let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)
                    if deleteStatus == errSecSuccess {
                        totalDeleted += 1
                        SecureLogger.info("Deleted keychain item: \(account) from \(service)", category: .keychain)
                    }
                }
            }
        }
        
        // Also try to delete by known service names and app group
        // This catches any items that might have been missed above
        let knownServices = [
            self.service,  // Current service name
            "com.bitchat.passwords",
            "com.bitchat.deviceidentity", 
            "com.bitchat.noise.identity",
            "chat.bitchat.passwords",
            "chat.bitchat.nostr",
            "bitchat.keychain",
            "bitchat",
            "com.bitchat"
        ]
        
        for serviceName in knownServices {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceName
            ]
            
            let status = SecItemDelete(query as CFDictionary)
            if status == errSecSuccess {
                totalDeleted += 1
            }
        }
        
        // Also delete by app group to ensure complete cleanup
        let groupQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccessGroup as String: appGroup
        ]
        
        let groupStatus = SecItemDelete(groupQuery as CFDictionary)
        if groupStatus == errSecSuccess {
            totalDeleted += 1
        }
        
        SecureLogger.warning("Panic mode cleanup completed. Total items deleted: \(totalDeleted)", category: .keychain)
        
        return totalDeleted > 0
    }
    
    // MARK: - Security Utilities
    
    /// Securely clear sensitive data from memory
    func secureClear(_ data: inout Data) {
        _ = data.withUnsafeMutableBytes { bytes in
            // Use volatile memset to prevent compiler optimization
            memset_s(bytes.baseAddress, bytes.count, 0, bytes.count)
        }
        data = Data() // Clear the data object
    }
    
    /// Securely clear sensitive string from memory
    func secureClear(_ string: inout String) {
        // Convert to mutable data and clear
        if var data = string.data(using: .utf8) {
            secureClear(&data)
        }
        string = "" // Clear the string object
    }
    
    // MARK: - Debug

    func verifyIdentityKeyExists() -> Bool {
        let key = "identity_noiseStaticKey"
        return retrieveData(forKey: key) != nil
    }

    // MARK: - Generic Data Storage (consolidated from KeychainHelper)

    /// Save data with a custom service name
    func save(key: String, data: Data, service customService: String, accessible: CFString?) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: customService,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        if let accessible = accessible {
            query[kSecAttrAccessible as String] = accessible
        }

        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    /// Load data from a custom service
    func load(key: String, service customService: String) -> Data? {
        guard case .success(let data) = loadWithResult(key: key, service: customService) else {
            return nil
        }
        return data
    }

    /// Load custom-service data without collapsing `itemNotFound` and
    /// protected-data/keychain failures into the same nil result.
    func loadWithResult(key: String, service customService: String) -> KeychainReadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: customService,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return classifyReadStatus(status, data: result as? Data)
    }

    /// Delete data from a custom service
    func delete(key: String, service customService: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: customService,
            kSecAttrAccount as String: key
        ]

        SecItemDelete(query as CFDictionary)
    }

    /// Delete every item stored under a custom service
    func deleteAll(service customService: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: customService,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            return
        }
        for item in items {
            var deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: customService
            ]
            if let account = item[kSecAttrAccount as String] as? String {
                deleteQuery[kSecAttrAccount as String] = account
            }
            SecItemDelete(deleteQuery as CFDictionary)
        }
    }
}
