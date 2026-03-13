//
// NostrProtocolTests.swift
// bitchatTests
//
// Tests for NIP-17 gift-wrapped private messages
//

import Testing
import CryptoKit
import Foundation
@testable import bitchat

struct NostrProtocolTests {
    
    @Test func nip17MessageRoundTrip() throws {
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
        let (decryptedContent, senderPubkey, timestamp) = try NostrProtocol.decryptPrivateMessage(
            giftWrap: giftWrap,
            recipientIdentity: recipient
        )
        
        // Verify
        #expect(decryptedContent == originalContent)
        #expect(senderPubkey == sender.publicKeyHex)
        
        // Verify timestamp is reasonable (within last minute)
        let messageDate = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let timeDiff = abs(messageDate.timeIntervalSinceNow)
        #expect(timeDiff < 60, "Message timestamp should be recent")
        
        print("✅ Successfully decrypted message: '\(decryptedContent)' from \(senderPubkey) at \(messageDate)")
    }
    
    @Test func giftWrapUsesUniqueEphemeralKeys() throws {
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
        #expect(message1.pubkey != message2.pubkey)
        
        print("Message 1 gift wrap pubkey: \(message1.pubkey)")
        print("Message 2 gift wrap pubkey: \(message2.pubkey)")
        
        // Both should decrypt successfully
        let (content1, _, _) = try NostrProtocol.decryptPrivateMessage(
            giftWrap: message1,
            recipientIdentity: recipient
        )
        let (content2, _, _) = try NostrProtocol.decryptPrivateMessage(
            giftWrap: message2,
            recipientIdentity: recipient
        )
        
        #expect(content1 == "Message 1")
        #expect(content2 == "Message 2")
    }
    
    @Test func decryptionFailsWithWrongRecipient() throws {
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
        if #available(macOS 14.4, iOS 17.4, *) {
            #expect(throws: CryptoKitError.authenticationFailure) {
                try NostrProtocol.decryptPrivateMessage(
                    giftWrap: giftWrap,
                    recipientIdentity: wrongRecipient
                )
            }
        } else {
            #expect(throws: (any Error).self) {
                try NostrProtocol.decryptPrivateMessage(
                    giftWrap: giftWrap,
                    recipientIdentity: wrongRecipient
                )
            }
        }
    }

    func testAckRoundTripNIP44V2_Delivered() throws {
        // Identities
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()

        // Build a DELIVERED ack embedded payload (geohash-style, no recipient peer ID)
        let messageID = "TEST-MSG-DELIVERED-1"
        let senderPeerID = PeerID(str: "0123456789abcdef") // 8-byte hex peer ID

        let embedded = try #require(
            NostrEmbeddedBitChat.encodeAckForNostrNoRecipient(type: .delivered, messageID: messageID, senderPeerID: senderPeerID),
            "Failed to embed delivered ack"
        )

        // Create NIP-17 gift wrap to recipient (uses NIP-44 v2 internally)
        let giftWrap = try NostrProtocol.createPrivateMessage(
            content: embedded,
            recipientPubkey: recipient.publicKeyHex,
            senderIdentity: sender
        )

        // Ensure v2 format was used for ciphertext
        #expect(giftWrap.content.hasPrefix("v2:"))

        // Decrypt as recipient
        let (content, senderPubkey, _) = try NostrProtocol.decryptPrivateMessage(
            giftWrap: giftWrap,
            recipientIdentity: recipient
        )

        // Verify sender is correct
        #expect(senderPubkey == sender.publicKeyHex)

        // Parse BitChat payload
        #expect(content.hasPrefix("bitchat1:"))
        let base64url = String(content.dropFirst("bitchat1:".count))
        let packetData = try #require(Self.base64URLDecode(base64url))
        let packet = try #require(BitchatPacket.from(packetData), "Failed to decode bitchat packet")
        
        #expect(packet.type == MessageType.noiseEncrypted.rawValue)
        let payload = try #require(NoisePayload.decode(packet.payload), "Failed to decode NoisePayload")
        
        switch payload.type {
        case .delivered:
            let mid = String(data: payload.data, encoding: .utf8)
            #expect(mid == messageID)
        default:
            Issue.record("Unexpected payload type: \(payload.type)")
        }
    }

    @Test func ackRoundTripNIP44V2_ReadReceipt() throws {
        // Identities
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        
        let messageID = "TEST-MSG-READ-1"
        let senderPeerID = PeerID(str: "fedcba9876543210") // 8-byte hex peer ID
        let embedded = try #require(
            NostrEmbeddedBitChat.encodeAckForNostrNoRecipient(type: .readReceipt, messageID: messageID, senderPeerID: senderPeerID),
            "Failed to embed read ack"
        )

        let giftWrap = try NostrProtocol.createPrivateMessage(
            content: embedded,
            recipientPubkey: recipient.publicKeyHex,
            senderIdentity: sender
        )

        #expect(giftWrap.content.hasPrefix("v2:"))

        let (content, senderPubkey, _) = try NostrProtocol.decryptPrivateMessage(
            giftWrap: giftWrap,
            recipientIdentity: recipient
        )
        #expect(senderPubkey == sender.publicKeyHex)

        #expect(content.hasPrefix("bitchat1:"))
        let base64url = String(content.dropFirst("bitchat1:".count))
        let packetData = try #require(Self.base64URLDecode(base64url))
        let packet = try #require(BitchatPacket.from(packetData), "Failed to decode bitchat packet")
        
        #expect(packet.type == MessageType.noiseEncrypted.rawValue)
        let payload = try #require(NoisePayload.decode(packet.payload), "Failed to decode NoisePayload")
        
        switch payload.type {
        case .readReceipt:
            let mid = String(data: payload.data, encoding: .utf8)
            #expect(mid == messageID)
        default:
            Issue.record("Unexpected payload type: \(payload.type)")
        }
    }

    @Test func nostrEventSignatureVerification_roundTrip() throws {
        let identity = try NostrIdentity.generate()
        var event = NostrEvent(
            pubkey: identity.publicKeyHex,
            createdAt: Date(),
            kind: .ephemeralEvent,
            tags: [],
            content: "Signed event"
        )
        let signed = try event.sign(with: identity.schnorrSigningKey())
        #expect(signed.isValidSignature())
    }

    @Test func nostrEventSignatureVerification_detectsTamper() throws {
        let identity = try NostrIdentity.generate()
        var event = NostrEvent(
            pubkey: identity.publicKeyHex,
            createdAt: Date(),
            kind: .ephemeralEvent,
            tags: [],
            content: "Original"
        )
        var signed = try event.sign(with: identity.schnorrSigningKey())
        signed.id = "deadbeef"
        #expect(!signed.isValidSignature())
    }

    // MARK: - Helpers
    private static func base64URLDecode(_ s: String) -> Data? {
        var str = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let rem = str.count % 4
        if rem > 0 { str.append(String(repeating: "=", count: 4 - rem)) }
        return Data(base64Encoded: str)
    }
}
