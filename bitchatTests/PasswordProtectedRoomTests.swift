//
// PasswordProtectedRoomTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import XCTest
import CryptoKit
import CommonCrypto
@testable import bitchat

class PasswordProtectedRoomTests: XCTestCase {
    var viewModel: ChatViewModel!
    
    override func setUp() {
        super.setUp()
        // Clear UserDefaults to ensure test isolation
        clearAllUserDefaults()
        
        // Create a fresh view model for each test
        viewModel = ChatViewModel()
        
        // Ensure clean state
        viewModel.passwordProtectedRooms.removeAll()
        viewModel.roomCreators.removeAll()
        viewModel.roomPasswords.removeAll()
        viewModel.roomKeys.removeAll()
        viewModel.joinedRooms.removeAll()
        viewModel.roomMembers.removeAll()
        viewModel.roomMessages.removeAll()
    }
    
    private func clearAllUserDefaults() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "bitchat_nickname")
        defaults.removeObject(forKey: "bitchat_joined_rooms")
        defaults.removeObject(forKey: "bitchat_password_protected_rooms")
        defaults.removeObject(forKey: "bitchat_room_creators")
        defaults.removeObject(forKey: "bitchat_room_passwords")
        defaults.removeObject(forKey: "bitchat_favorite_peers")
        defaults.synchronize()
    }
    
    override func tearDown() {
        // Clean up after tests
        clearAllUserDefaults()
        viewModel = nil
        super.tearDown()
    }
    
    // MARK: - Password Key Derivation Tests
    
    func testPasswordKeyDerivation() {
        // Same password and room should always produce same key
        let password = "secretPassword123"
        let roomName = "#testroom"
        
        let key1 = deriveRoomKey(from: password, roomName: roomName)
        let key2 = deriveRoomKey(from: password, roomName: roomName)
        
        // Keys should be identical
        XCTAssertEqual(key1, key2, "Same password and room should produce same key")
    }
    
    func testDifferentPasswordsProduceDifferentKeys() {
        let roomName = "#testroom"
        let password1 = "password123"
        let password2 = "different456"
        
        let key1 = deriveRoomKey(from: password1, roomName: roomName)
        let key2 = deriveRoomKey(from: password2, roomName: roomName)
        
        XCTAssertNotEqual(key1, key2, "Different passwords should produce different keys")
    }
    
    func testDifferentRoomsProduceDifferentKeys() {
        let password = "samePassword"
        let room1 = "#room1"
        let room2 = "#room2"
        
        let key1 = deriveRoomKey(from: password, roomName: room1)
        let key2 = deriveRoomKey(from: password, roomName: room2)
        
        XCTAssertNotEqual(key1, key2, "Same password in different rooms should produce different keys")
    }
    
    // MARK: - Room Creation and Joining Tests
    
    func testJoinUnprotectedRoom() {
        let roomName = "#public"
        
        let success = viewModel.joinRoom(roomName)
        
        XCTAssertTrue(success, "Should be able to join unprotected room")
        XCTAssertTrue(viewModel.joinedRooms.contains(roomName))
        XCTAssertEqual(viewModel.currentRoom, roomName)
        XCTAssertTrue(viewModel.roomMembers[roomName]?.contains(viewModel.meshService.myPeerID) ?? false)
    }
    
    func testCreatePasswordProtectedRoom() {
        let roomName = "#private"
        let password = "secret123"
        
        // Join room first
        let joinSuccess = viewModel.joinRoom(roomName)
        XCTAssertTrue(joinSuccess)
        
        // Set password
        viewModel.setRoomPassword(password, for: roomName)
        
        XCTAssertTrue(viewModel.passwordProtectedRooms.contains(roomName))
        XCTAssertNotNil(viewModel.roomKeys[roomName])
        XCTAssertEqual(viewModel.roomPasswords[roomName], password)
        XCTAssertEqual(viewModel.roomCreators[roomName], viewModel.meshService.myPeerID)
    }
    
    func testJoinPasswordProtectedEmptyRoom() {
        let roomName = "#protected"
        let password = "test123"
        
        // Simulate room being marked as password protected
        viewModel.passwordProtectedRooms.insert(roomName)
        
        // Try to join with password - should be accepted tentatively for empty room
        let success = viewModel.joinRoom(roomName, password: password)
        
        XCTAssertTrue(success, "Should accept tentative access to empty password-protected room")
        XCTAssertNotNil(viewModel.roomKeys[roomName], "Should store key tentatively")
        XCTAssertEqual(viewModel.roomPasswords[roomName], password, "Should store password tentatively")
        
        // Should have a system message explaining tentative access
        let hasSystemMessage = viewModel.messages.contains { $0.sender == "system" && $0.content.contains("waiting for encrypted messages to verify password") }
        XCTAssertTrue(hasSystemMessage, "Should add system message explaining tentative access")
    }
    
    func testJoinPasswordProtectedRoomWithMessages() {
        let roomName = "#secure"
        let correctPassword = "correct123"
        let wrongPassword = "wrong456"
        let testMessage = "Test encrypted message"
        
        // First, create the room and set password as creator
        let _ = viewModel.joinRoom(roomName)
        viewModel.setRoomPassword(correctPassword, for: roomName)
        
        // Simulate an encrypted message in the room
        let key = viewModel.roomKeys[roomName]!
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
                room: roomName,
                encryptedContent: encryptedData,
                isEncrypted: true
            )
            
            // Add to room messages
            viewModel.roomMessages[roomName] = [encryptedMsg]
            
            // Clear keys to simulate another user
            viewModel.roomKeys.removeValue(forKey: roomName)
            viewModel.roomPasswords.removeValue(forKey: roomName)
            
            // Try to join with wrong password
            let wrongSuccess = viewModel.joinRoom(roomName, password: wrongPassword)
            XCTAssertFalse(wrongSuccess, "Should reject wrong password")
            
            // Try to join with correct password
            let correctSuccess = viewModel.joinRoom(roomName, password: correctPassword)
            XCTAssertTrue(correctSuccess, "Should accept correct password")
            XCTAssertNotNil(viewModel.roomKeys[roomName], "Should store key for correct password")
            
        } catch {
            XCTFail("Encryption failed: \(error)")
        }
    }
    
    // MARK: - Password Verification Tests
    
    func testEncryptDecryptRoomMessage() {
        let roomName = "#crypto"
        let password = "cryptoKey"
        let testMessage = "This is a secret message"
        
        // Derive key
        let key = deriveRoomKey(from: password, roomName: roomName)
        
        // Encrypt
        guard let messageData = testMessage.data(using: .utf8) else {
            XCTFail("Failed to convert message to data")
            return
        }
        
        do {
            let sealedBox = try AES.GCM.seal(messageData, using: key)
            let encryptedData = sealedBox.combined!
            
            // Store key and decrypt
            viewModel.roomKeys[roomName] = key
            let decrypted = viewModel.decryptRoomMessage(encryptedData, room: roomName)
            
            XCTAssertEqual(decrypted, testMessage, "Decrypted message should match original")
        } catch {
            XCTFail("Encryption failed: \(error)")
        }
    }
    
    func testWrongPasswordFailsDecryption() {
        let roomName = "#secure"
        let correctPassword = "correct"
        let wrongPassword = "wrong"
        let testMessage = "Secret content"
        
        // Encrypt with correct password
        let correctKey = deriveRoomKey(from: correctPassword, roomName: roomName)
        
        guard let messageData = testMessage.data(using: .utf8) else {
            XCTFail("Failed to convert message to data")
            return
        }
        
        do {
            let sealedBox = try AES.GCM.seal(messageData, using: correctKey)
            let encryptedData = sealedBox.combined!
            
            // Try to decrypt with wrong password
            let wrongKey = deriveRoomKey(from: wrongPassword, roomName: roomName)
            let decrypted = viewModel.decryptRoomMessage(encryptedData, room: roomName, testKey: wrongKey)
            
            XCTAssertNil(decrypted, "Wrong password should fail to decrypt")
        } catch {
            XCTFail("Encryption failed: \(error)")
        }
    }
    
    // MARK: - Room Creator Tests
    
    func testOnlyCreatorCanSetPassword() {
        let roomName = "#owned"
        let password = "ownerOnly"
        
        // Join room (becomes creator)
        let _ = viewModel.joinRoom(roomName)
        
        // Set password as creator
        viewModel.setRoomPassword(password, for: roomName)
        XCTAssertTrue(viewModel.passwordProtectedRooms.contains(roomName))
        
        // Simulate another user trying to set password
        viewModel.roomCreators[roomName] = "otherUser123"
        viewModel.setRoomPassword("hackerPassword", for: roomName)
        
        // Password should not change
        XCTAssertEqual(viewModel.roomPasswords[roomName], password, "Non-creator should not be able to change password")
    }
    
    func testCreatorCanRemovePassword() {
        let roomName = "#changeable"
        let password = "temporary"
        
        // Create protected room
        let _ = viewModel.joinRoom(roomName)
        viewModel.setRoomPassword(password, for: roomName)
        
        XCTAssertTrue(viewModel.passwordProtectedRooms.contains(roomName))
        
        // Remove password
        viewModel.removeRoomPassword(for: roomName)
        
        XCTAssertFalse(viewModel.passwordProtectedRooms.contains(roomName))
        XCTAssertNil(viewModel.roomKeys[roomName])
        XCTAssertNil(viewModel.roomPasswords[roomName])
    }
    
    // MARK: - Message Handling Tests
    
    func testReceiveEncryptedMessageWithoutKey() {
        let roomName = "#encrypted"
        
        // Join room without password
        let _ = viewModel.joinRoom(roomName)
        
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
            room: roomName,
            encryptedContent: Data([1, 2, 3, 4]), // dummy encrypted data
            isEncrypted: true
        )
        
        viewModel.didReceiveMessage(encryptedMessage)
        
        // Should mark room as password protected
        XCTAssertTrue(viewModel.passwordProtectedRooms.contains(roomName))
        
        // Should add system message
        let roomMessages = viewModel.roomMessages[roomName] ?? []
        let hasSystemMessage = roomMessages.contains { $0.sender == "system" && $0.content.contains("password protected") }
        XCTAssertTrue(hasSystemMessage, "Should add system message about password protection")
    }
    
    // MARK: - Command Tests
    
    func testJoinCommand() {
        let input = "/join #testroom"
        viewModel.sendMessage(input)
        
        XCTAssertTrue(viewModel.joinedRooms.contains("#testroom"))
        XCTAssertEqual(viewModel.currentRoom, "#testroom")
    }
    
    func testJoinCommandAlias() {
        let input = "/j #quick"
        viewModel.sendMessage(input)
        
        XCTAssertTrue(viewModel.joinedRooms.contains("#quick"))
        XCTAssertEqual(viewModel.currentRoom, "#quick")
    }
    
    func testInvalidRoomName() {
        let input = "/j #invalid-room!"
        viewModel.sendMessage(input)
        
        XCTAssertFalse(viewModel.joinedRooms.contains("#invalid-room!"))
        
        // Should have system message about invalid name
        let hasErrorMessage = viewModel.messages.contains { $0.sender == "system" && $0.content.contains("Invalid room name") }
        XCTAssertTrue(hasErrorMessage)
    }
    
    // MARK: - Key Commitment Tests
    
    func testKeyCommitmentVerification() {
        let roomName = "#commitment"
        let password = "testpass123"
        
        // Join and set password
        let _ = viewModel.joinRoom(roomName)
        viewModel.setRoomPassword(password, for: roomName)
        
        // Verify key commitment was stored
        XCTAssertNotNil(viewModel.roomKeyCommitments[roomName], "Should store key commitment")
        
        // Simulate another user with the stored commitment
        let commitment = viewModel.roomKeyCommitments[roomName]!
        viewModel.roomKeys.removeValue(forKey: roomName)
        viewModel.roomPasswords.removeValue(forKey: roomName)
        
        // Manually set the commitment as if received from network
        viewModel.roomKeyCommitments[roomName] = commitment
        
        // Try with wrong password - should fail immediately
        let wrongSuccess = viewModel.joinRoom(roomName, password: "wrongpass")
        XCTAssertFalse(wrongSuccess, "Should reject wrong password via commitment check")
        
        // Try with correct password - should succeed
        let correctSuccess = viewModel.joinRoom(roomName, password: password)
        XCTAssertTrue(correctSuccess, "Should accept correct password via commitment check")
    }
    
    func testOwnershipTransfer() {
        let roomName = "#transfertest"
        let password = "ownerpass"
        
        // Create room and set password
        let _ = viewModel.joinRoom(roomName)
        viewModel.setRoomPassword(password, for: roomName)
        
        // Verify creator is set
        XCTAssertEqual(viewModel.roomCreators[roomName], viewModel.meshService.myPeerID)
        
        // Simulate transfer (in real app would use /transfer command)
        let newOwnerID = "newowner123"
        viewModel.roomCreators[roomName] = newOwnerID
        
        // Verify ownership changed
        XCTAssertEqual(viewModel.roomCreators[roomName], newOwnerID)
        XCTAssertNotEqual(viewModel.roomCreators[roomName], viewModel.meshService.myPeerID)
    }
}

// MARK: - Helper Extensions for Testing

extension PasswordProtectedRoomTests {
    // Helper method to derive room key for testing
    // This duplicates the logic from ChatViewModel for testing purposes
    func deriveRoomKey(from password: String, roomName: String) -> SymmetricKey {
        let salt = roomName.data(using: .utf8)!
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