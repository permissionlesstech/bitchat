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
        // SecureLogger is always enabled
    }
    
    func testNIP17MessageRoundTrip() throws {
        // Create sender and recipient identities
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        
        #if DEBUG
        print("Sender pubkey: \(sender.publicKeyHex)")
        print("Recipient pubkey: \(recipient.publicKeyHex)")
        #endif
        
        // Create a test message
        let originalContent = "Hello from NIP-17 test!"
        
        // Create encrypted gift wrap
        let giftWrap = try NostrProtocol.createPrivateMessage(
            content: originalContent,
            recipientPubkey: recipient.publicKeyHex,
            senderIdentity: sender
        )
        
        #if DEBUG
        print("Gift wrap created with ID: \(giftWrap.id)")
        print("Gift wrap pubkey: \(giftWrap.pubkey)")
        #endif
        
        // Decrypt the gift wrap
        let (decryptedContent, senderPubkey, timestamp) = try NostrProtocol.decryptPrivateMessage(
            giftWrap: giftWrap,
            recipientIdentity: recipient
        )
        
        // Verify
        XCTAssertEqual(decryptedContent, originalContent)
        XCTAssertEqual(senderPubkey, sender.publicKeyHex)
        
        // Verify timestamp is reasonable (within last minute)
        let messageDate = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let timeDiff = abs(messageDate.timeIntervalSinceNow)
        XCTAssertLessThan(timeDiff, 60, "Message timestamp should be recent")
        
        #if DEBUG
        print("✅ Successfully decrypted message: '\(decryptedContent)' from \(senderPubkey) at \(messageDate)")
        #endif
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
        #if DEBUG
        print("Message 1 gift wrap pubkey: \(message1.pubkey)")
        print("Message 2 gift wrap pubkey: \(message2.pubkey)")
        #endif
        
        // Both should decrypt successfully
        let (content1, _, _) = try NostrProtocol.decryptPrivateMessage(
            giftWrap: message1,
            recipientIdentity: recipient
        )
        let (content2, _, _) = try NostrProtocol.decryptPrivateMessage(
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
            #if DEBUG
            print("Expected error when decrypting with wrong key: \(error)")
            #endif
        }
    }

    func testAckRoundTripNIP44V2_Delivered() throws {
        // Identities
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()

        // Build a DELIVERED ack embedded payload (geohash-style, no recipient peer ID)
        let messageID = "TEST-MSG-DELIVERED-1"
        let senderPeerID = "0123456789abcdef" // 8-byte hex peer ID
        guard let embedded = NostrEmbeddedBitChat.encodeAckForNostrNoRecipient(type: .delivered, messageID: messageID, senderPeerID: senderPeerID) else {
            XCTFail("Failed to embed delivered ack")
            return
        }

        // Create NIP-17 gift wrap to recipient (uses NIP-44 v2 internally)
        let giftWrap = try NostrProtocol.createPrivateMessage(
            content: embedded,
            recipientPubkey: recipient.publicKeyHex,
            senderIdentity: sender
        )

        // Ensure v2 format was used for ciphertext
        XCTAssertTrue(giftWrap.content.hasPrefix("v2:"))

        // Decrypt as recipient
        let (content, senderPubkey, _) = try NostrProtocol.decryptPrivateMessage(
            giftWrap: giftWrap,
            recipientIdentity: recipient
        )

        // Verify sender is correct
        XCTAssertEqual(senderPubkey, sender.publicKeyHex)

        // Parse BitChat payload
        XCTAssertTrue(content.hasPrefix("bitchat1:"))
        let base64url = String(content.dropFirst("bitchat1:".count))
        guard let packetData = Self.base64URLDecode(base64url),
              let packet = BitchatPacket.from(packetData) else {
            return XCTFail("Failed to decode bitchat packet")
        }
        XCTAssertEqual(packet.type, MessageType.noiseEncrypted.rawValue)
        guard let payload = NoisePayload.decode(packet.payload) else {
            return XCTFail("Failed to decode NoisePayload")
        }
        switch payload.type {
        case .delivered:
            let mid = String(data: payload.data, encoding: .utf8)
            XCTAssertEqual(mid, messageID)
        default:
            XCTFail("Unexpected payload type: \(payload.type)")
        }
    }

    func testAckRoundTripNIP44V2_ReadReceipt() throws {
        // Identities
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()

        let messageID = "TEST-MSG-READ-1"
        let senderPeerID = "fedcba9876543210" // 8-byte hex peer ID
        guard let embedded = NostrEmbeddedBitChat.encodeAckForNostrNoRecipient(type: .readReceipt, messageID: messageID, senderPeerID: senderPeerID) else {
            XCTFail("Failed to embed read ack")
            return
        }

        let giftWrap = try NostrProtocol.createPrivateMessage(
            content: embedded,
            recipientPubkey: recipient.publicKeyHex,
            senderIdentity: sender
        )

        XCTAssertTrue(giftWrap.content.hasPrefix("v2:"))

        let (content, senderPubkey, _) = try NostrProtocol.decryptPrivateMessage(
            giftWrap: giftWrap,
            recipientIdentity: recipient
        )
        XCTAssertEqual(senderPubkey, sender.publicKeyHex)

        XCTAssertTrue(content.hasPrefix("bitchat1:"))
        let base64url = String(content.dropFirst("bitchat1:".count))
        guard let packetData = Self.base64URLDecode(base64url),
              let packet = BitchatPacket.from(packetData) else {
            return XCTFail("Failed to decode bitchat packet")
        }
        XCTAssertEqual(packet.type, MessageType.noiseEncrypted.rawValue)
        guard let payload = NoisePayload.decode(packet.payload) else {
            return XCTFail("Failed to decode NoisePayload")
        }
        switch payload.type {
        case .readReceipt:
            let mid = String(data: payload.data, encoding: .utf8)
            XCTAssertEqual(mid, messageID)
        default:
            XCTFail("Unexpected payload type: \(payload.type)")
        }
    }

    // MARK: - Helpers
    private static func base64URLDecode(_ s: String) -> Data? {
        var str = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let rem = str.count % 4
        if rem > 0 { str.append(String(repeating: "=", count: 4 - rem)) }
        return Data(base64Encoded: str)
    }
}
