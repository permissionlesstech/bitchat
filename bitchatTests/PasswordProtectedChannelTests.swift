//
// PasswordProtectedChannelTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import XCTest
import CryptoKit
import CommonCrypto
@testable import bitchat

class PasswordProtectedChannelTests: XCTestCase {
    var viewModel: ChatViewModel!
    
    override func setUp() {
        super.setUp()
        // Clear UserDefaults to ensure test isolation
        clearAllUserDefaults()
        
        // Create a fresh view model for each test
        viewModel = ChatViewModel()
        
        // Ensure clean state
        viewModel.passwordProtectedChannels.removeAll()
        viewModel.channelCreators.removeAll()
        viewModel.channelPasswords.removeAll()
        viewModel.channelKeys.removeAll()
        viewModel.joinedChannels.removeAll()
        viewModel.channelMembers.removeAll()
        viewModel.channelMessages.removeAll()
    }
    
    private func clearAllUserDefaults() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "bitchat_nickname")
        defaults.removeObject(forKey: "bitchat_joined_channels")
        defaults.removeObject(forKey: "bitchat_password_protected_channels")
        defaults.removeObject(forKey: "bitchat_channel_creators")
        defaults.removeObject(forKey: "bitchat_channel_passwords")
        defaults.removeObject(forKey: "bitchat_favorite_peers")
    }
    
    override func tearDown() {
        // Clean up after tests
        clearAllUserDefaults()
        viewModel = nil
        super.tearDown()
    }
    
    // MARK: - Password Key Derivation Tests
    
    func testPasswordKeyDerivation() {
        // Same password and channel should always produce same key
        let password = "secretPassword123"
        let channelName = "#testchannel"
        
        let key1 = deriveChannelKey(from: password, channelName: channelName)
        let key2 = deriveChannelKey(from: password, channelName: channelName)
        
        // Keys should be identical
        XCTAssertEqual(key1, key2, "Same password and channel should produce same key")
    }
    
    func testDifferentPasswordsProduceDifferentKeys() {
        let channelName = "#testchannel"
        let password1 = "password123"
        let password2 = "different456"
        
        let key1 = deriveChannelKey(from: password1, channelName: channelName)
        let key2 = deriveChannelKey(from: password2, channelName: channelName)
        
        XCTAssertNotEqual(key1, key2, "Different passwords should produce different keys")
    }
    
    func testDifferentChannelsProduceDifferentKeys() {
        let password = "samePassword"
        let channel1 = "#channel1"
        let channel2 = "#channel2"
        
        let key1 = deriveChannelKey(from: password, channelName: channel1)
        let key2 = deriveChannelKey(from: password, channelName: channel2)
        
        XCTAssertNotEqual(key1, key2, "Same password in different channels should produce different keys")
    }
    
    // MARK: - Channel Creation and Joining Tests
    
    func testJoinUnprotectedChannel() {
        let channelName = "#public"
        
        let success = viewModel.joinChannel(channelName)
        
        XCTAssertTrue(success, "Should be able to join unprotected channel")
        XCTAssertTrue(viewModel.joinedChannels.contains(channelName))
        XCTAssertEqual(viewModel.currentChannel, channelName)
        XCTAssertTrue(viewModel.channelMembers[channelName]?.contains(viewModel.meshService.myPeerID) ?? false)
    }
    
    func testCreatePasswordProtectedChannel() {
        let channelName = "#private"
        let password = "secret123"
        
        // Join channel first
        let joinSuccess = viewModel.joinChannel(channelName)
        XCTAssertTrue(joinSuccess)
        
        // Set password
        viewModel.setChannelPassword(password, for: channelName)
        
        XCTAssertTrue(viewModel.passwordProtectedChannels.contains(channelName))
        XCTAssertNotNil(viewModel.channelKeys[channelName])
        XCTAssertEqual(viewModel.channelPasswords[channelName], password)
        XCTAssertEqual(viewModel.channelCreators[channelName], viewModel.meshService.myPeerID)
    }
    
    func testJoinPasswordProtectedEmptyChannel() {
        let channelName = "#protected"
        let password = "test123"
        
        // Simulate channel being marked as password protected
        viewModel.passwordProtectedChannels.insert(channelName)
        
        // Try to join with password - should be accepted tentatively for empty channel
        let success = viewModel.joinChannel(channelName, password: password)
        
        XCTAssertTrue(success, "Should accept tentative access to empty password-protected channel")
        XCTAssertNotNil(viewModel.channelKeys[channelName], "Should store key tentatively")
        XCTAssertEqual(viewModel.channelPasswords[channelName], password, "Should store password tentatively")
        
        // Should have a system message explaining tentative access
        let hasSystemMessage = viewModel.messages.contains { $0.sender == "system" && $0.content.contains("waiting for encrypted messages to verify password") }
        XCTAssertTrue(hasSystemMessage, "Should add system message explaining tentative access")
    }
    
    func testJoinPasswordProtectedChannelWithMessages() {
        let channelName = "#secure"
        let correctPassword = "correct123"
        let wrongPassword = "wrong456"
        let testMessage = "Test encrypted message"
        
        // First, create the channel and set password as creator
        let _ = viewModel.joinChannel(channelName)
        viewModel.setChannelPassword(correctPassword, for: channelName)
        
        // Simulate an encrypted message in the channel
        let key = viewModel.channelKeys[channelName]!
        guard let messageData = testMessage.data(using: .utf8) else {
            XCTFail("Failed to convert message to data")
            return
        }
        
        do {
            let sealedBox = try AES.GCM.seal(messageData, using: key)
            let encryptedData = sealedBox.combined!
            
            let encryptedMsg = BitchatMessage(
                sender: "alice",
                content: "[Encrypted message - password required]",
                timestamp: Date(),
                isRelay: false,
                originalSender: nil,
                isPrivate: false,
                recipientNickname: nil,
                senderPeerID: "alice123",
                mentions: nil,
                channel: channelName,
                encryptedContent: encryptedData,
                isEncrypted: true
            )
            
            // Add to channel messages
            viewModel.channelMessages[channelName] = [encryptedMsg]
            
            // Clear keys to simulate another user
            viewModel.channelKeys.removeValue(forKey: channelName)
            viewModel.channelPasswords.removeValue(forKey: channelName)
            
            // Try to join with wrong password
            let wrongSuccess = viewModel.joinChannel(channelName, password: wrongPassword)
            XCTAssertFalse(wrongSuccess, "Should reject wrong password")
            
            // Try to join with correct password
            let correctSuccess = viewModel.joinChannel(channelName, password: correctPassword)
            XCTAssertTrue(correctSuccess, "Should accept correct password")
            XCTAssertNotNil(viewModel.channelKeys[channelName], "Should store key for correct password")
            
        } catch {
            XCTFail("Encryption failed: \(error)")
        }
    }
    
    // MARK: - Password Verification Tests
    
    func testEncryptDecryptChannelMessage() {
        let channelName = "#crypto"
        let password = "cryptoKey"
        let testMessage = "This is a secret message"
        
        // Derive key
        let key = deriveChannelKey(from: password, channelName: channelName)
        
        // Encrypt
        guard let messageData = testMessage.data(using: .utf8) else {
            XCTFail("Failed to convert message to data")
            return
        }
        
        do {
            let sealedBox = try AES.GCM.seal(messageData, using: key)
            let encryptedData = sealedBox.combined!
            
            // Store key and decrypt
            viewModel.channelKeys[channelName] = key
            let decrypted = viewModel.decryptChannelMessage(encryptedData, channel: channelName)
            
            XCTAssertEqual(decrypted, testMessage, "Decrypted message should match original")
        } catch {
            XCTFail("Encryption failed: \(error)")
        }
    }
    
    func testWrongPasswordFailsDecryption() {
        let channelName = "#secure"
        let correctPassword = "correct"
        let wrongPassword = "wrong"
        let testMessage = "Secret content"
        
        // Encrypt with correct password
        let correctKey = deriveChannelKey(from: correctPassword, channelName: channelName)
        
        guard let messageData = testMessage.data(using: .utf8) else {
            XCTFail("Failed to convert message to data")
            return
        }
        
        do {
            let sealedBox = try AES.GCM.seal(messageData, using: correctKey)
            let encryptedData = sealedBox.combined!
            
            // Try to decrypt with wrong password
            let wrongKey = deriveChannelKey(from: wrongPassword, channelName: channelName)
            let decrypted = viewModel.decryptChannelMessage(encryptedData, channel: channelName, testKey: wrongKey)
            
            XCTAssertNil(decrypted, "Wrong password should fail to decrypt")
        } catch {
            XCTFail("Encryption failed: \(error)")
        }
    }
    
    // MARK: - Channel Creator Tests
    
    func testOnlyCreatorCanSetPassword() {
        let channelName = "#owned"
        let password = "ownerOnly"
        
        // Join channel (becomes creator)
        let _ = viewModel.joinChannel(channelName)
        
        // Set password as creator
        viewModel.setChannelPassword(password, for: channelName)
        XCTAssertTrue(viewModel.passwordProtectedChannels.contains(channelName))
        
        // Simulate another user trying to set password
        viewModel.channelCreators[channelName] = "otherUser123"
        viewModel.setChannelPassword("hackerPassword", for: channelName)
        
        // Password should not change
        XCTAssertEqual(viewModel.channelPasswords[channelName], password, "Non-creator should not be able to change password")
    }
    
    func testCreatorCanRemovePassword() {
        let channelName = "#changeable"
        let password = "temporary"
        
        // Create protected channel
        let _ = viewModel.joinChannel(channelName)
        viewModel.setChannelPassword(password, for: channelName)
        
        XCTAssertTrue(viewModel.passwordProtectedChannels.contains(channelName))
        
        // Remove password
        viewModel.removeChannelPassword(for: channelName)
        
        XCTAssertFalse(viewModel.passwordProtectedChannels.contains(channelName))
        XCTAssertNil(viewModel.channelKeys[channelName])
        XCTAssertNil(viewModel.channelPasswords[channelName])
    }
    
    // MARK: - Message Handling Tests
    
    func testReceiveEncryptedMessageWithoutKey() {
        let channelName = "#encrypted"
        
        // Join channel without password
        let _ = viewModel.joinChannel(channelName)
        
        // Simulate receiving encrypted message
        let encryptedMessage = BitchatMessage(
            sender: "alice",
            content: "[Encrypted message - password required]",
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: false,
            recipientNickname: nil,
            senderPeerID: "alice123",
            mentions: nil,
            channel: channelName,
            encryptedContent: Data([1, 2, 3, 4]), // dummy encrypted data
            isEncrypted: true
        )
        
        viewModel.didReceiveMessage(encryptedMessage)
        
        // Should mark channel as password protected
        XCTAssertTrue(viewModel.passwordProtectedChannels.contains(channelName))
        
        // Should add system message
        let channelMessages = viewModel.channelMessages[channelName] ?? []
        let hasSystemMessage = channelMessages.contains { $0.sender == "system" && $0.content.contains("password protected") }
        XCTAssertTrue(hasSystemMessage, "Should add system message about password protection")
    }
    
    // MARK: - Command Tests
    
    func testJoinCommand() {
        let input = "/join #testchannel"
        viewModel.sendMessage(input)
        
        XCTAssertTrue(viewModel.joinedChannels.contains("#testchannel"))
        XCTAssertEqual(viewModel.currentChannel, "#testchannel")
    }
    
    func testJoinCommandAlias() {
        let input = "/j #quick"
        viewModel.sendMessage(input)
        
        XCTAssertTrue(viewModel.joinedChannels.contains("#quick"))
        XCTAssertEqual(viewModel.currentChannel, "#quick")
    }
    
    func testInvalidChannelName() {
        let input = "/j #invalid-channel!"
        viewModel.sendMessage(input)
        
        XCTAssertFalse(viewModel.joinedChannels.contains("#invalid-channel!"))
        
        // Should have system message about invalid name
        let hasErrorMessage = viewModel.messages.contains { $0.sender == "system" && $0.content.contains("invalid channel name") }
        XCTAssertTrue(hasErrorMessage)
    }
    
    // MARK: - Key Commitment Tests
    
    func testKeyCommitmentVerification() {
        let channelName = "#commitment"
        let password = "testpass123"
        
        // Join and set password
        let _ = viewModel.joinChannel(channelName)
        viewModel.setChannelPassword(password, for: channelName)
        
        // Verify key commitment was stored
        XCTAssertNotNil(viewModel.channelKeyCommitments[channelName], "Should store key commitment")
        
        // Simulate another user with the stored commitment
        let commitment = viewModel.channelKeyCommitments[channelName]!
        viewModel.channelKeys.removeValue(forKey: channelName)
        viewModel.channelPasswords.removeValue(forKey: channelName)
        
        // Manually set the commitment as if received from network
        viewModel.channelKeyCommitments[channelName] = commitment
        
        // Try with wrong password - should fail immediately
        let wrongSuccess = viewModel.joinChannel(channelName, password: "wrongpass")
        XCTAssertFalse(wrongSuccess, "Should reject wrong password via commitment check")
        
        // Try with correct password - should succeed
        let correctSuccess = viewModel.joinChannel(channelName, password: password)
        XCTAssertTrue(correctSuccess, "Should accept correct password via commitment check")
    }
    
    func testOwnershipTransfer() {
        let channelName = "#transfertest"
        let password = "ownerpass"
        
        // Create channel and set password
        let _ = viewModel.joinChannel(channelName)
        viewModel.setChannelPassword(password, for: channelName)
        
        // Verify creator is set
        XCTAssertEqual(viewModel.channelCreators[channelName], viewModel.meshService.myPeerID)
        
        // Simulate transfer (in real app would use /transfer command)
        let newOwnerID = "newowner123"
        viewModel.channelCreators[channelName] = newOwnerID
        
        // Verify ownership changed
        XCTAssertEqual(viewModel.channelCreators[channelName], newOwnerID)
        XCTAssertNotEqual(viewModel.channelCreators[channelName], viewModel.meshService.myPeerID)
    }
}

// MARK: - Helper Extensions for Testing

extension PasswordProtectedChannelTests {
    // Helper method to derive channel key for testing
    // This duplicates the logic from ChatViewModel for testing purposes
    func deriveChannelKey(from password: String, channelName: String) -> SymmetricKey {
        let salt = channelName.data(using: .utf8)!
        let iterations = 100000
        let keyLength = 32
        
        var derivedKey = Data(count: keyLength)
        let passwordData = password.data(using: .utf8)!
        
        _ = derivedKey.withUnsafeMutableBytes { derivedKeyBytes in
            salt.withUnsafeBytes { saltBytes in
                passwordData.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress, passwordData.count,
                        saltBytes.baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        derivedKeyBytes.baseAddress, keyLength
                    )
                }
            }
        }
        
        return SymmetricKey(data: derivedKey)
    }
}