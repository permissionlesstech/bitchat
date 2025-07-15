//
// NoiseIdentityPersistenceTests.swift
// bitchatTests
//
// Tests for Noise Protocol identity key persistence
//

import XCTest
@testable import bitchat

class NoiseIdentityPersistenceTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        // Clean up any existing test data
        cleanupTestData()
    }
    
    override func tearDown() {
        // Clean up after tests
        cleanupTestData()
        super.tearDown()
    }
    
    private func cleanupTestData() {
        // Clear any existing identity keys
        _ = KeychainManager.shared.deleteIdentityKey(forKey: "noiseStaticKey")
        _ = KeychainManager.shared.deleteIdentityKey(forKey: "messageRetentionKey")
        
        // Clear any UserDefaults that might interfere
        UserDefaults.standard.removeObject(forKey: "bitchat.noiseIdentityKey")
        UserDefaults.standard.removeObject(forKey: "bitchat.messageRetentionKey")
        UserDefaults.standard.synchronize()
    }
    
    // MARK: - Identity Persistence Tests
    
    func testIdentityPersistsAcrossInstances() {
        // Create first instance
        let service1 = NoiseEncryptionService()
        let fingerprint1 = service1.getIdentityFingerprint()
        let publicKey1 = service1.getStaticPublicKeyData()
        
        XCTAssertFalse(fingerprint1.isEmpty, "Fingerprint should not be empty")
        XCTAssertEqual(publicKey1.count, 32, "Public key should be 32 bytes")
        
        // Create second instance
        let service2 = NoiseEncryptionService()
        let fingerprint2 = service2.getIdentityFingerprint()
        let publicKey2 = service2.getStaticPublicKeyData()
        
        // Verify same identity
        XCTAssertEqual(fingerprint1, fingerprint2, "Fingerprint should persist across instances")
        XCTAssertEqual(publicKey1, publicKey2, "Public key should persist across instances")
    }
    
    func testIdentityNotStoredInUserDefaults() {
        // Create service to generate identity
        _ = NoiseEncryptionService()
        
        // Verify identity is NOT in UserDefaults
        let userDefaultsData = UserDefaults.standard.data(forKey: "bitchat.noiseIdentityKey")
        XCTAssertNil(userDefaultsData, "Identity key should NOT be stored in UserDefaults")
    }
    
    func testIdentityStoredInKeychain() {
        // Create service to generate identity
        _ = NoiseEncryptionService()
        
        // Verify identity IS in Keychain
        let keychainData = KeychainManager.shared.getIdentityKey(forKey: "noiseStaticKey")
        XCTAssertNotNil(keychainData, "Identity key should be stored in Keychain")
        XCTAssertEqual(keychainData?.count, 32, "Identity key should be 32 bytes")
    }
    
    func testPanicModeClearsIdentity() {
        // Create service and get initial fingerprint
        let service1 = NoiseEncryptionService()
        let fingerprint1 = service1.getIdentityFingerprint()
        
        // Clear identity (panic mode)
        service1.clearPersistentIdentity()
        
        // Create new service and verify new identity
        let service2 = NoiseEncryptionService()
        let fingerprint2 = service2.getIdentityFingerprint()
        
        XCTAssertNotEqual(fingerprint1, fingerprint2, "New identity should be created after panic mode")
    }
    
    func testMultipleRapidInstantiations() {
        // Create multiple services rapidly
        var fingerprints: [String] = []
        
        for _ in 0..<10 {
            let service = NoiseEncryptionService()
            fingerprints.append(service.getIdentityFingerprint())
        }
        
        // Verify all fingerprints are the same
        let firstFingerprint = fingerprints[0]
        for fingerprint in fingerprints {
            XCTAssertEqual(fingerprint, firstFingerprint, "All instances should have same identity")
        }
    }
    
    func testKeychainAccessFailureHandling() {
        // This test would require mocking KeychainManager, but we can at least
        // verify the service initializes even if keychain is problematic
        let service = NoiseEncryptionService()
        XCTAssertFalse(service.getIdentityFingerprint().isEmpty, "Service should initialize with valid identity")
    }
    
    // MARK: - Message Retention Key Tests
    
    func testMessageRetentionKeyPersistence() {
        // Create first instance
        _ = MessageRetentionService.shared
        
        // Get key from keychain
        let keyData1 = KeychainManager.shared.getIdentityKey(forKey: "messageRetentionKey")
        XCTAssertNotNil(keyData1, "Message retention key should be stored")
        
        // Simulate app restart by clearing the singleton
        // (In real app, this would be a new process)
        
        // Get key again
        let keyData2 = KeychainManager.shared.getIdentityKey(forKey: "messageRetentionKey")
        XCTAssertEqual(keyData1, keyData2, "Message retention key should persist")
    }
    
    func testMessageRetentionKeyNotInUserDefaults() {
        // Ensure service is initialized
        _ = MessageRetentionService.shared
        
        // Verify key is NOT in UserDefaults
        let userDefaultsData = UserDefaults.standard.data(forKey: "bitchat.messageRetentionKey")
        XCTAssertNil(userDefaultsData, "Message retention key should NOT be in UserDefaults")
    }
    
    // MARK: - Keychain Service Name Tests
    
    func testKeychainServiceName() {
        // Verify we're using the correct service name
        let expectedService = "chat.bitchat"
        
        // Save a test item
        let testKey = "test_service_verification"
        let testData = "test".data(using: .utf8)!
        _ = KeychainManager.shared.saveIdentityKey(testData, forKey: testKey)
        
        // Query directly to verify service name
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: expectedService,
            kSecAttrAccount as String: "identity_\(testKey)",
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        XCTAssertEqual(status, errSecSuccess, "Should find item with expected service name")
        XCTAssertNotNil(result as? Data, "Should retrieve data")
        
        // Clean up
        _ = KeychainManager.shared.deleteIdentityKey(forKey: testKey)
    }
    
    // MARK: - Legacy Cleanup Tests
    
    func testLegacyKeychainCleanup() {
        // Create some legacy items with old service names
        let legacyServices = [
            "com.bitchat.passwords",
            "com.bitchat.noise.identity",
            "bitchat.keychain"
        ]
        
        // Add test items with legacy service names
        for service in legacyServices {
            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: "test_legacy_item",
                kSecValueData as String: "test".data(using: .utf8)!
            ]
            
            // Add item (ignore if already exists)
            _ = SecItemAdd(addQuery as CFDictionary, nil)
        }
        
        // Run aggressive cleanup
        let deletedCount = KeychainManager.shared.aggressiveCleanupLegacyItems()
        
        // Verify items were deleted
        XCTAssertGreaterThan(deletedCount, 0, "Should delete at least some legacy items")
        
        // Verify legacy items are gone
        for service in legacyServices {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            
            XCTAssertEqual(status, errSecItemNotFound, "Legacy service '\(service)' should be deleted")
        }
    }
    
    // MARK: - Performance Tests
    
    func testIdentityLoadPerformance() {
        // Ensure identity exists
        _ = NoiseEncryptionService()
        
        measure {
            // Measure how long it takes to load identity
            _ = NoiseEncryptionService()
        }
    }
}