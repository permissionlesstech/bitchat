//
// KeychainIntegrationTests.swift
// bitchatTests
//
// Integration tests for keychain functionality
//

import XCTest
@testable import bitchat

class KeychainIntegrationTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        // Start with clean state
        _ = KeychainManager.shared.deleteAllKeychainData()
    }
    
    override func tearDown() {
        // Clean up test data
        _ = KeychainManager.shared.deleteAllKeychainData()
        super.tearDown()
    }
    
    // MARK: - App Lifecycle Simulation Tests
    
    func testCompleteAppLifecycle() {
        print("\n🧪 Testing Complete App Lifecycle")
        
        // 1. First app launch - create identity
        print("1️⃣ First launch...")
        let service1 = NoiseEncryptionService()
        let fingerprint1 = service1.getIdentityFingerprint()
        print("   Initial fingerprint: \(fingerprint1)")
        
        // Verify stored in keychain
        let keychainData1 = KeychainManager.shared.getIdentityKey(forKey: "noiseStaticKey")
        XCTAssertNotNil(keychainData1, "Identity should be in keychain after first launch")
        
        // 2. App goes to background and comes back
        print("2️⃣ Background/foreground cycle...")
        let service2 = NoiseEncryptionService()
        let fingerprint2 = service2.getIdentityFingerprint()
        XCTAssertEqual(fingerprint1, fingerprint2, "Identity should persist through background")
        
        // 3. App terminates and relaunches
        print("3️⃣ Terminate and relaunch...")
        // In real app this would be a new process
        let service3 = NoiseEncryptionService()
        let fingerprint3 = service3.getIdentityFingerprint()
        XCTAssertEqual(fingerprint1, fingerprint3, "Identity should persist through termination")
        
        // 4. User triggers panic mode
        print("4️⃣ Panic mode triggered...")
        service3.clearPersistentIdentity()
        
        // 5. App creates new identity
        print("5️⃣ New identity after panic...")
        let service4 = NoiseEncryptionService()
        let fingerprint4 = service4.getIdentityFingerprint()
        XCTAssertNotEqual(fingerprint1, fingerprint4, "New identity should be created after panic")
        print("   New fingerprint: \(fingerprint4)")
        
        print("✅ Lifecycle test complete\n")
    }
    
    // MARK: - Channel Password Tests
    
    func testChannelPasswordPersistence() {
        let channel1 = "#testchannel1"
        let channel2 = "#testchannel2"
        let password1 = "password123"
        let password2 = "differentpass456"
        
        // Save passwords
        XCTAssertTrue(KeychainManager.shared.saveChannelPassword(password1, for: channel1))
        XCTAssertTrue(KeychainManager.shared.saveChannelPassword(password2, for: channel2))
        
        // Retrieve passwords
        XCTAssertEqual(KeychainManager.shared.getChannelPassword(for: channel1), password1)
        XCTAssertEqual(KeychainManager.shared.getChannelPassword(for: channel2), password2)
        
        // Test getAllChannelPasswords
        let allPasswords = KeychainManager.shared.getAllChannelPasswords()
        XCTAssertEqual(allPasswords.count, 2)
        XCTAssertEqual(allPasswords[channel1], password1)
        XCTAssertEqual(allPasswords[channel2], password2)
        
        // Delete one password
        XCTAssertTrue(KeychainManager.shared.deleteChannelPassword(for: channel1))
        XCTAssertNil(KeychainManager.shared.getChannelPassword(for: channel1))
        XCTAssertEqual(KeychainManager.shared.getChannelPassword(for: channel2), password2)
    }
    
    // MARK: - Security Tests
    
    func testNoPlaintextInUserDefaults() {
        // Create services to generate keys
        _ = NoiseEncryptionService()
        _ = MessageRetentionService.shared
        
        // Check UserDefaults for any sensitive data
        let keysToCheck = [
            "bitchat.noiseIdentityKey",
            "bitchat.messageRetentionKey",
            "bitchat.channelPasswords",
            "bitchat.identityKey",
            "bitchat.staticKey"
        ]
        
        for key in keysToCheck {
            let data = UserDefaults.standard.object(forKey: key)
            XCTAssertNil(data, "UserDefaults should not contain: \(key)")
        }
    }
    
    // MARK: - Error Handling Tests
    
    func testKeychainErrorRecovery() {
        // Test that the app can recover from keychain errors
        // This is difficult to test without mocking, but we can verify
        // that multiple save attempts don't crash
        
        let testData = "test".data(using: .utf8)!
        
        // Rapid saves
        for i in 0..<10 {
            let saved = KeychainManager.shared.saveIdentityKey(testData, forKey: "rapidTest\(i)")
            XCTAssertTrue(saved, "Save \(i) should succeed")
        }
        
        // Rapid deletes
        for i in 0..<10 {
            _ = KeychainManager.shared.deleteIdentityKey(forKey: "rapidTest\(i)")
        }
    }
    
    // MARK: - Cleanup Tests
    
    func testAggressiveCleanupOnlyDeletesBitchatItems() {
        // This test verifies we don't delete other apps' keychain items
        
        // Add a non-bitchat item (simulating another app)
        let otherAppQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.otherapp.service",
            kSecAttrAccount as String: "other_app_account",
            kSecValueData as String: "other app data".data(using: .utf8)!
        ]
        
        // Clean first
        SecItemDelete(otherAppQuery as CFDictionary)
        
        // Add the item
        let addStatus = SecItemAdd(otherAppQuery as CFDictionary, nil)
        XCTAssertEqual(addStatus, errSecSuccess, "Should add other app item")
        
        // Add a bitchat legacy item
        let bitchatQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.bitchat.legacy",
            kSecAttrAccount as String: "test_account",
            kSecValueData as String: "bitchat data".data(using: .utf8)!
        ]
        SecItemDelete(bitchatQuery as CFDictionary)
        let bitchatStatus = SecItemAdd(bitchatQuery as CFDictionary, nil)
        XCTAssertEqual(bitchatStatus, errSecSuccess, "Should add bitchat item")
        
        // Run aggressive cleanup
        _ = KeychainManager.shared.aggressiveCleanupLegacyItems()
        
        // Verify other app item still exists
        var result: AnyObject?
        let checkStatus = SecItemCopyMatching(otherAppQuery as CFDictionary, &result)
        XCTAssertEqual(checkStatus, errSecSuccess, "Other app item should still exist")
        
        // Verify bitchat item was deleted
        var bitchatResult: AnyObject?
        let bitchatCheck = SecItemCopyMatching(bitchatQuery as CFDictionary, &bitchatResult)
        XCTAssertEqual(bitchatCheck, errSecItemNotFound, "Bitchat legacy item should be deleted")
        
        // Clean up
        SecItemDelete(otherAppQuery as CFDictionary)
    }
}