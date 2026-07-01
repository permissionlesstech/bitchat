//
// NostrProtocolTests.swift
// bitchatTests
//
// Tests for NIP-17 gift-wrapped private messages
//

import Testing
import CryptoKit
import Foundation
import BitFoundation
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

    @Test func decryptRejectsInvalidSealSignature() throws {
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let giftWrap = try NostrProtocol.createPrivateMessageWithInvalidSealSignatureForTesting(
            content: "forged signature",
            recipientPubkey: recipient.publicKeyHex,
            senderIdentity: sender
        )

        expectInvalidEvent {
            _ = try NostrProtocol.decryptPrivateMessage(
                giftWrap: giftWrap,
                recipientIdentity: recipient
            )
        }
    }

    @Test func decryptRejectsSealRumorPubkeyMismatch() throws {
        let claimedSender = try NostrIdentity.generate()
        let sealSigner = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let giftWrap = try NostrProtocol.createPrivateMessageWithMismatchedSealRumorPubkeyForTesting(
            content: "spoofed sender",
            recipientPubkey: recipient.publicKeyHex,
            rumorIdentity: claimedSender,
            sealSignerIdentity: sealSigner
        )

        expectInvalidEvent {
            _ = try NostrProtocol.decryptPrivateMessage(
                giftWrap: giftWrap,
                recipientIdentity: recipient
            )
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
        let event = NostrEvent(
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
        let event = NostrEvent(
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

    @Test func geohashNotesSingleFilter_encodesExpectedTagShape() throws {
        let since = Date(timeIntervalSince1970: 1_234_567)
        let filter = NostrFilter.geohashNotes("u4pruyd", since: since, limit: 42)
        let data = try JSONEncoder().encode(filter)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["kinds"] as? [Int] == [1])
        #expect(object["#g"] as? [String] == ["u4pruyd"])
        #expect(object["since"] as? Int == 1_234_567)
        #expect(object["limit"] as? Int == 42)
    }

    // MARK: - Padding (v3 envelope)

    @Test func paddedLengthMatchesNIP44Buckets() {
        // Vectors from the NIP-44 reference test suite (calc_padded_len).
        let vectors: [(Int, Int)] = [
            (1, 32), (16, 32), (32, 32), (33, 64), (37, 64), (45, 64), (49, 64),
            (64, 64), (65, 96), (100, 128), (111, 128), (200, 224), (250, 256),
            (320, 320), (383, 384), (384, 384), (400, 448), (500, 512),
            (512, 512), (515, 640), (700, 768), (800, 896), (900, 1024),
            (1020, 1024), (65535, 65536)
        ]
        for (unpadded, expected) in vectors {
            #expect(
                NIP44Padding.paddedLength(for: unpadded) == expected,
                "paddedLength(for: \(unpadded)) should be \(expected)"
            )
        }
    }

    @Test func padUnpadRoundTrip() throws {
        for length in [1, 2, 31, 32, 33, 100, 320, 1020, 4096, 65535] {
            let plaintext = Data((0..<length).map { _ in UInt8.random(in: .min ... .max) })
            let padded = try NIP44Padding.pad(plaintext)
            #expect(padded.count == 2 + NIP44Padding.paddedLength(for: length))
            let unpadded = try NIP44Padding.unpad(padded)
            #expect(unpadded == plaintext)
        }
    }

    @Test func padHidesExactLengthWithinBucket() throws {
        // Two plaintexts of different length in the same bucket must produce
        // identically sized padded payloads (and thus ciphertexts).
        let short = try NIP44Padding.pad(Data(repeating: 0x41, count: 65))
        let long = try NIP44Padding.pad(Data(repeating: 0x42, count: 96))
        #expect(short.count == long.count)
    }

    @Test func padRejectsOutOfRangePlaintexts() {
        #expect(throws: (any Error).self) { try NIP44Padding.pad(Data()) }
        #expect(throws: (any Error).self) { try NIP44Padding.pad(Data(count: 65536)) }
    }

    @Test func unpadRejectsTamperedLengthPrefix() throws {
        var padded = try NIP44Padding.pad(Data(repeating: 0x41, count: 40))

        // Claimed length larger than the actual payload
        var tooLong = padded
        tooLong[tooLong.startIndex] = 0xFF
        tooLong[tooLong.startIndex + 1] = 0xFF
        #expect(throws: NostrError.invalidCiphertext) { try NIP44Padding.unpad(tooLong) }

        // Claimed length of zero
        var zero = padded
        zero[zero.startIndex] = 0x00
        zero[zero.startIndex + 1] = 0x00
        #expect(throws: NostrError.invalidCiphertext) { try NIP44Padding.unpad(zero) }

        // Claimed length whose bucket does not match the payload size
        // (payload is bucket 64; a claimed length of 20 expects bucket 32)
        var wrongBucket = padded
        wrongBucket[wrongBucket.startIndex] = 0x00
        wrongBucket[wrongBucket.startIndex + 1] = 0x14
        #expect(throws: NostrError.invalidCiphertext) { try NIP44Padding.unpad(wrongBucket) }

        // Truncated payloads
        #expect(throws: NostrError.invalidCiphertext) { try NIP44Padding.unpad(Data()) }
        #expect(throws: NostrError.invalidCiphertext) { try NIP44Padding.unpad(Data([0x00])) }
        padded.removeLast()
        #expect(throws: NostrError.invalidCiphertext) { try NIP44Padding.unpad(padded) }

        // Works on Data slices with non-zero startIndex
        let sliced = try (Data([0xAB]) + NIP44Padding.pad(Data(repeating: 0x41, count: 40))).dropFirst()
        #expect(try NIP44Padding.unpad(sliced) == Data(repeating: 0x41, count: 40))
    }

    @Test func paddedEnvelopeRoundTrip_v3() throws {
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let plaintext = "padded envelope test"

        let ciphertext = try NostrProtocol.encrypt(
            plaintext: plaintext,
            recipientPubkey: recipient.publicKeyHex,
            senderKey: sender.schnorrSigningKey(),
            padded: true
        )
        #expect(ciphertext.hasPrefix("v3:"))

        let decrypted = try NostrProtocol.decrypt(
            ciphertext: ciphertext,
            senderPubkey: sender.publicKeyHex,
            recipientKey: recipient.schnorrSigningKey()
        )
        #expect(decrypted == plaintext)
    }

    @Test func legacyUnpaddedEnvelopeStillDecrypts_v2() throws {
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let plaintext = "legacy v2 envelope"

        // What deployed clients send today.
        let ciphertext = try NostrProtocol.encrypt(
            plaintext: plaintext,
            recipientPubkey: recipient.publicKeyHex,
            senderKey: sender.schnorrSigningKey(),
            padded: false
        )
        #expect(ciphertext.hasPrefix("v2:"))

        let decrypted = try NostrProtocol.decrypt(
            ciphertext: ciphertext,
            senderPubkey: sender.publicKeyHex,
            recipientKey: recipient.schnorrSigningKey()
        )
        #expect(decrypted == plaintext)
    }

    @Test func outgoingMessagesStillUseV2UntilRolloutFlagFlips() throws {
        // Deployed clients reject anything that is not "v2:", so the padded
        // envelope must stay off by default until decrypt-side support is
        // widely shipped (see NostrProtocol.sendPaddedEnvelope).
        #expect(NostrProtocol.sendPaddedEnvelope == false)

        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let giftWrap = try NostrProtocol.createPrivateMessage(
            content: "default envelope",
            recipientPubkey: recipient.publicKeyHex,
            senderIdentity: sender
        )
        #expect(giftWrap.content.hasPrefix("v2:"))
    }

    @Test func decryptRejectsUnknownEnvelopeVersion() throws {
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let ciphertext = try NostrProtocol.encrypt(
            plaintext: "test",
            recipientPubkey: recipient.publicKeyHex,
            senderKey: sender.schnorrSigningKey(),
            padded: false
        )
        let mutated = "v9:" + ciphertext.dropFirst(3)
        #expect(throws: NostrError.invalidCiphertext) {
            _ = try NostrProtocol.decrypt(
                ciphertext: mutated,
                senderPubkey: sender.publicKeyHex,
                recipientKey: recipient.schnorrSigningKey()
            )
        }
    }

    // MARK: - Helpers
    private static func base64URLDecode(_ s: String) -> Data? {
        var str = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let rem = str.count % 4
        if rem > 0 { str.append(String(repeating: "=", count: 4 - rem)) }
        return Data(base64Encoded: str)
    }

    private func expectInvalidEvent(_ operation: () throws -> Void) {
        do {
            try operation()
            Issue.record("Expected NostrError.invalidEvent")
        } catch NostrError.invalidEvent {
            return
        } catch {
            Issue.record("Expected NostrError.invalidEvent, got \(error)")
        }
    }
}
