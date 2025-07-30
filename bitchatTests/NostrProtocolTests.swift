//
// NostrProtocolTests.swift
// bitchatTests
//
// Tests for NIP-17 gift-wrapped private messages
//

import XCTest
import CryptoKit
@testable import bitchat

final class NostrProtocolTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        // Enable secure logging for tests
        SecureLogger.enableLogging()
    }
    
    func testNIP17MessageRoundTrip() throws {
        // Create sender and recipient identities
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        
        print("Sender pubkey: \(sender.publicKeyHex)")
        print("Recipient pubkey: \(recipient.publicKeyHex)")
        
        // Create a test message
        let originalContent = "Hello from NIP-17 test!"
        
        // Create encrypted gift wrap
        let giftWrap = try NostrProtocol.createPrivateMessage(
            content: originalContent,
            recipientPubkey: recipient.publicKeyHex,
            senderIdentity: sender
        )
        
        print("Gift wrap created with ID: \(giftWrap.id)")
        print("Gift wrap pubkey: \(giftWrap.pubkey)")
        
        // Decrypt the gift wrap
        let (decryptedContent, senderPubkey) = try NostrProtocol.decryptPrivateMessage(
            giftWrap: giftWrap,
            recipientIdentity: recipient
        )
        
        // Verify
        XCTAssertEqual(decryptedContent, originalContent)
        XCTAssertEqual(senderPubkey, sender.publicKeyHex)
        
        print("✅ Successfully decrypted message: '\(decryptedContent)' from \(senderPubkey)")
    }
    
    func testGiftWrapUsesUniqueEphemeralKeys() throws {
        // Create identities
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        
        // Create two messages
        let message1 = try NostrProtocol.createPrivateMessage(
            content: "Message 1",
            recipientPubkey: recipient.publicKeyHex,
            senderIdentity: sender
        )
        
        let message2 = try NostrProtocol.createPrivateMessage(
            content: "Message 2",
            recipientPubkey: recipient.publicKeyHex,
            senderIdentity: sender
        )
        
        // Gift wrap pubkeys should be different (unique ephemeral keys)
        XCTAssertNotEqual(message1.pubkey, message2.pubkey)
        print("Message 1 gift wrap pubkey: \(message1.pubkey)")
        print("Message 2 gift wrap pubkey: \(message2.pubkey)")
        
        // Both should decrypt successfully
        let (content1, _) = try NostrProtocol.decryptPrivateMessage(
            giftWrap: message1,
            recipientIdentity: recipient
        )
        let (content2, _) = try NostrProtocol.decryptPrivateMessage(
            giftWrap: message2,
            recipientIdentity: recipient
        )
        
        XCTAssertEqual(content1, "Message 1")
        XCTAssertEqual(content2, "Message 2")
    }
    
    func testDecryptionFailsWithWrongRecipient() throws {
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let wrongRecipient = try NostrIdentity.generate()
        
        // Create message for recipient
        let giftWrap = try NostrProtocol.createPrivateMessage(
            content: "Secret message",
            recipientPubkey: recipient.publicKeyHex,
            senderIdentity: sender
        )
        
        // Try to decrypt with wrong recipient
        XCTAssertThrowsError(try NostrProtocol.decryptPrivateMessage(
            giftWrap: giftWrap,
            recipientIdentity: wrongRecipient
        )) { error in
            print("Expected error when decrypting with wrong key: \(error)")
        }
    }
}