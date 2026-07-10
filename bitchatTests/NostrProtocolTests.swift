//
// NostrProtocolTests.swift
// bitchatTests
//
// Tests for BitChat's proprietary private-envelope transport over Nostr.
//

import Testing
import Foundation
import BitFoundation
@testable import bitchat

struct NostrProtocolTests {
    
    @Test func privateEnvelopeRoundTrip() throws {
        // Create sender and recipient identities
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        
        print("Sender pubkey: \(sender.publicKeyHex)")
        print("Recipient pubkey: \(recipient.publicKeyHex)")
        
        // Create a test message
        let originalContent = "Hello from BitChat private-envelope test!"
        
        let envelope = try NostrProtocol.createPrivateEnvelope(
            content: originalContent,
            recipientPubkey: recipient.publicKeyHex,
            senderIdentity: sender
        )
        
        print("Private envelope created with ID: \(envelope.id)")
        print("Private envelope pubkey: \(envelope.pubkey)")
        
        let (decryptedContent, senderPubkey, timestamp) = try NostrProtocol.decryptPrivateEnvelope(
            envelope: envelope,
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
    
    @Test func privateEnvelopesUseUniqueEphemeralKeys() throws {
        // Create identities
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        
        // Create two messages
        let message1 = try NostrProtocol.createPrivateEnvelope(
            content: "Message 1",
            recipientPubkey: recipient.publicKeyHex,
            senderIdentity: sender
        )
        
        let message2 = try NostrProtocol.createPrivateEnvelope(
            content: "Message 2",
            recipientPubkey: recipient.publicKeyHex,
            senderIdentity: sender
        )
        
        // Public envelope keys must be one-time use.
        #expect(message1.pubkey != message2.pubkey)
        
        print("Message 1 envelope pubkey: \(message1.pubkey)")
        print("Message 2 envelope pubkey: \(message2.pubkey)")
        
        // Both should decrypt successfully
        let (content1, _, _) = try NostrProtocol.decryptPrivateEnvelope(
            envelope: message1,
            recipientIdentity: recipient
        )
        let (content2, _, _) = try NostrProtocol.decryptPrivateEnvelope(
            envelope: message2,
            recipientIdentity: recipient
        )
        
        #expect(content1 == "Message 1")
        #expect(content2 == "Message 2")
    }

    @Test func privateEnvelopeUsesBitChatWireFormatAtEveryLayer() throws {
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let envelope = try NostrProtocol.createPrivateEnvelope(
            content: "bitchat-specific",
            recipientPubkey: recipient.publicKeyHex,
            senderIdentity: sender
        )

        #expect(envelope.kind == NostrProtocol.EventKind.privateEnvelope.rawValue)
        #expect(envelope.kind != NostrProtocol.EventKind.legacyNIP59GiftWrap.rawValue)
        #expect(envelope.content.hasPrefix(NostrProtocol.privateEnvelopeContentPrefix))
        #expect(!envelope.content.hasPrefix("v2:"))
        #expect(envelope.tags == [["p", recipient.publicKeyHex]])
        #expect(envelope.created_at <= Int(Date().timeIntervalSince1970))

        let layers = try NostrProtocol.decodePrivateEnvelopeLayersForTesting(
            envelope: envelope,
            recipientIdentity: recipient
        )
        #expect(layers.seal.kind == NostrProtocol.EventKind.privateSeal.rawValue)
        #expect(layers.seal.content.hasPrefix(NostrProtocol.privateEnvelopeContentPrefix))
        #expect(layers.seal.tags.isEmpty)
        #expect(layers.message.kind == NostrProtocol.EventKind.privateMessage.rawValue)
        #expect(layers.message.tags.isEmpty)
        #expect(layers.message.sig == nil)
    }

    @Test func decryptAcceptsReceiveOnlyLegacyBitChatEnvelope() throws {
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let envelope = try NostrProtocol.createLegacyPrivateEnvelopeForTesting(
            content: "legacy in-flight message",
            recipientPubkey: recipient.publicKeyHex,
            senderIdentity: sender
        )

        #expect(envelope.kind == NostrProtocol.EventKind.legacyNIP59GiftWrap.rawValue)
        #expect(envelope.content.hasPrefix("v2:"))

        let result = try NostrProtocol.decryptPrivateEnvelope(
            envelope: envelope,
            recipientIdentity: recipient
        )
        #expect(result.content == "legacy in-flight message")
        #expect(result.senderPubkey == sender.publicKeyHex)

        let layers = try NostrProtocol.decodePrivateEnvelopeLayersForTesting(
            envelope: envelope,
            recipientIdentity: recipient
        )
        #expect(layers.seal.kind == NostrProtocol.EventKind.legacyNIP59Seal.rawValue)
        #expect(layers.message.kind == NostrProtocol.EventKind.legacyNIP17DirectMessage.rawValue)
    }

    @Test func decryptsFrozenLegacyEnvelopeProducedByRelease733098bb() throws {
        let eventData = try Data(contentsOf: fixtureURL(
            name: "LegacyPrivateEnvelope733098bb"
        ))
        let keyData = try Data(contentsOf: fixtureURL(
            name: "LegacyPrivateEnvelope733098bbRecipientKey"
        ))
        let envelope = try JSONDecoder().decode(NostrEvent.self, from: eventData)
        let keyFixture = try JSONDecoder().decode(LegacyRecipientKeyFixture.self, from: keyData)
        let recipientKey = try #require(Data(hexString: keyFixture.recipientPrivateKey))
        let recipient = try NostrIdentity(privateKeyData: recipientKey)

        #expect(envelope.isValidSignature())
        let result = try NostrProtocol.decryptPrivateEnvelope(
            envelope: envelope,
            recipientIdentity: recipient
        )
        #expect(result.content == "legacy fixture from 733098bb")
        #expect(result.senderPubkey == "2e3d79df7047204f02b726c574e256f8de1dd80510f7dcb8b0d12df13acb87e6")
    }

    @Test func publicationBatchDualPublishesOnlyBeforeExplicitDeadline() throws {
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let beforeDeadline = NostrProtocol.legacyPrivateEnvelopePublicationDeadline
            .addingTimeInterval(-1)

        let migrationBatch = try NostrProtocol.createPrivateEnvelopePublicationBatch(
            content: "mixed-version",
            recipientPubkey: recipient.publicKeyHex,
            senderIdentity: sender,
            now: beforeDeadline
        )
        #expect(migrationBatch.map(\.kind) == [
            NostrProtocol.EventKind.privateEnvelope.rawValue,
            NostrProtocol.EventKind.legacyNIP59GiftWrap.rawValue
        ])
        for envelope in migrationBatch {
            let result = try NostrProtocol.decryptPrivateEnvelope(
                envelope: envelope,
                recipientIdentity: recipient
            )
            #expect(result.content == "mixed-version")
        }

        let postMigrationBatch = try NostrProtocol.createPrivateEnvelopePublicationBatch(
            content: "new-only",
            recipientPubkey: recipient.publicKeyHex,
            senderIdentity: sender,
            now: NostrProtocol.legacyPrivateEnvelopePublicationDeadline
        )
        #expect(postMigrationBatch.map(\.kind) == [
            NostrProtocol.EventKind.privateEnvelope.rawValue
        ])
    }

    @Test func mailboxLookbackCoversFullRetentionWindowAndTimestampFuzz() {
        let sentAt = Date(timeIntervalSince1970: 1_800_000_000)
        let earliestPublicTimestamp = sentAt.addingTimeInterval(
            -TransportConfig.nostrPrivateEnvelopeTimestampFuzzSeconds
        )
        let reconnectAtRetentionBoundary = sentAt.addingTimeInterval(24 * 60 * 60)
        let filterSince = reconnectAtRetentionBoundary.addingTimeInterval(
            -TransportConfig.nostrDMSubscribeLookbackSeconds
        )

        #expect(TransportConfig.nostrDMSubscribeLookbackSeconds == (24 * 60 * 60) + (15 * 60))
        #expect(filterSince <= earliestPublicTimestamp)
    }

    @Test func largePrivateEnvelopeFitsLayerSpecificExpansionLimits() throws {
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        // Large enough that the nested Base64 seal exceeds the inner 32 KiB
        // cap, while the inner message JSON itself remains below that cap.
        let content = String(repeating: "A", count: 30 * 1024)

        let envelope = try NostrProtocol.createPrivateEnvelope(
            content: content,
            recipientPubkey: recipient.publicKeyHex,
            senderIdentity: sender
        )
        let decrypted = try NostrProtocol.decryptPrivateEnvelope(
            envelope: envelope,
            recipientIdentity: recipient
        )

        #expect(decrypted.content == content)
        #expect(envelope.content.utf8.count <= NostrProtocol.maximumPrivateEnvelopeCiphertextBytes)
    }

    @Test func privateEnvelopeRejectsOversizedCiphertextBeforeDecoding() throws {
        let recipient = try NostrIdentity.generate()
        let wrapper = try NostrIdentity.generate()
        let oversizedContent = NostrProtocol.privateEnvelopeContentPrefix
            + String(
                repeating: "A",
                count: NostrProtocol.maximumPrivateEnvelopeCiphertextBytes
            )
        let event = NostrEvent(
            pubkey: wrapper.publicKeyHex,
            createdAt: Date(),
            kind: .privateEnvelope,
            tags: [["p", recipient.publicKeyHex]],
            content: oversizedContent
        )
        let signed = try event.sign(with: wrapper.schnorrSigningKey())

        expectInvalidCiphertext {
            _ = try NostrProtocol.decryptPrivateEnvelope(
                envelope: signed,
                recipientIdentity: recipient
            )
        }
    }

    @Test func privateEnvelopeRejectsOversizedPlaintextBeforeEncryption() throws {
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let oversizedPlaintext = String(
            repeating: "x",
            count: NostrProtocol.maximumPrivateEnvelopePlaintextBytes + 1
        )

        expectInvalidCiphertext {
            _ = try NostrProtocol.createPrivateEnvelope(
                content: oversizedPlaintext,
                recipientPubkey: recipient.publicKeyHex,
                senderIdentity: sender
            )
        }
    }

    @Test func privateEnvelopeRejectsOversizedNestedJSONBeforeParsing() {
        let oversizedJSON = String(
            repeating: "{",
            count: NostrProtocol.maximumPrivateEnvelopePlaintextBytes + 1
        )
        expectInvalidCiphertext {
            _ = try NostrProtocol.decodePrivateEnvelopeEventJSONForTesting(oversizedJSON)
        }
    }

    @Test func decryptDoesNotMisinterpretStandardNIP44PayloadAsLegacyBitChat() throws {
        let recipient = try NostrIdentity.generate()
        let wrapper = try NostrIdentity.generate()
        // A valid NIP-44 v2 payload from the official test vectors. Its wire
        // format starts with a version byte in standard Base64, not BitChat's
        // historical `v2:` prefix.
        let standardPayload = "AgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABee0G5VSK0/9YypIObAtDKfYEAjD35uVkHyB0F4DwrcNaCXlCWZKaArsGrY6M9wnuTMxWfp1RTN9Xga8no+kF5Vsb"
        let event = NostrEvent(
            pubkey: wrapper.publicKeyHex,
            createdAt: Date(),
            kind: .legacyNIP59GiftWrap,
            tags: [["p", recipient.publicKeyHex]],
            content: standardPayload
        )
        let signed = try event.sign(with: wrapper.schnorrSigningKey())

        expectInvalidCiphertext {
            _ = try NostrProtocol.decryptPrivateEnvelope(
                envelope: signed,
                recipientIdentity: recipient
            )
        }
    }
    
    @Test func decryptionFailsWithWrongRecipient() throws {
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let wrongRecipient = try NostrIdentity.generate()
        
        // Create message for recipient
        let envelope = try NostrProtocol.createPrivateEnvelope(
            content: "Secret message",
            recipientPubkey: recipient.publicKeyHex,
            senderIdentity: sender
        )
        
        expectInvalidEvent {
            _ = try NostrProtocol.decryptPrivateEnvelope(
                envelope: envelope,
                recipientIdentity: wrongRecipient
            )
        }
    }

    @Test func decryptRejectsInvalidSealSignature() throws {
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let envelope = try NostrProtocol.createPrivateEnvelopeWithInvalidSealSignatureForTesting(
            content: "forged signature",
            recipientPubkey: recipient.publicKeyHex,
            senderIdentity: sender
        )

        expectInvalidEvent {
            _ = try NostrProtocol.decryptPrivateEnvelope(
                envelope: envelope,
                recipientIdentity: recipient
            )
        }
    }

    @Test func decryptRejectsSealMessagePubkeyMismatch() throws {
        let claimedSender = try NostrIdentity.generate()
        let sealSigner = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let envelope = try NostrProtocol.createPrivateEnvelopeWithMismatchedSealMessagePubkeyForTesting(
            content: "spoofed sender",
            recipientPubkey: recipient.publicKeyHex,
            messageIdentity: claimedSender,
            sealSignerIdentity: sealSigner
        )

        expectInvalidEvent {
            _ = try NostrProtocol.decryptPrivateEnvelope(
                envelope: envelope,
                recipientIdentity: recipient
            )
        }
    }

    @Test
    func deliveredAckRoundTripsInsidePrivateEnvelope() throws {
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

        let envelope = try NostrProtocol.createPrivateEnvelope(
            content: embedded,
            recipientPubkey: recipient.publicKeyHex,
            senderIdentity: sender
        )

        #expect(envelope.content.hasPrefix(NostrProtocol.privateEnvelopeContentPrefix))

        // Decrypt as recipient
        let (content, senderPubkey, _) = try NostrProtocol.decryptPrivateEnvelope(
            envelope: envelope,
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

    @Test func readReceiptRoundTripsInsidePrivateEnvelope() throws {
        // Identities
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        
        let messageID = "TEST-MSG-READ-1"
        let senderPeerID = PeerID(str: "fedcba9876543210") // 8-byte hex peer ID
        let embedded = try #require(
            NostrEmbeddedBitChat.encodeAckForNostrNoRecipient(type: .readReceipt, messageID: messageID, senderPeerID: senderPeerID),
            "Failed to embed read ack"
        )

        let envelope = try NostrProtocol.createPrivateEnvelope(
            content: embedded,
            recipientPubkey: recipient.publicKeyHex,
            senderIdentity: sender
        )

        #expect(envelope.content.hasPrefix(NostrProtocol.privateEnvelopeContentPrefix))

        let (content, senderPubkey, _) = try NostrProtocol.decryptPrivateEnvelope(
            envelope: envelope,
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

    @Test func privateEnvelopeFilterIncludesPrimaryAndCompatibilityKinds() throws {
        let since = Date(timeIntervalSince1970: 1_234_567)
        let filter = NostrFilter.privateEnvelopesFor(pubkey: "recipient", since: since)
        let data = try JSONEncoder().encode(filter)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["kinds"] as? [Int] == [
            NostrProtocol.EventKind.privateEnvelope.rawValue,
            NostrProtocol.EventKind.legacyNIP59GiftWrap.rawValue
        ])
        #expect(object["#p"] as? [String] == ["recipient"])
        #expect(object["since"] as? Int == 1_234_567)
        #expect(object["limit"] as? Int ==
            TransportConfig.nostrRelayDefaultFetchLimit
                * NostrProtocol.acceptedPrivateEnvelopeKinds.count
        )
    }

    // MARK: - Helpers
    private struct LegacyRecipientKeyFixture: Decodable {
        let recipientPrivateKey: String

        enum CodingKeys: String, CodingKey {
            case recipientPrivateKey = "recipient_private_key"
        }
    }

    private func fixtureURL(name: String) throws -> URL {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: MockKeychain.self)
        #endif
        return try #require(bundle.url(forResource: name, withExtension: "json"))
    }

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

    private func expectInvalidCiphertext(_ operation: () throws -> Void) {
        do {
            try operation()
            Issue.record("Expected NostrError.invalidCiphertext")
        } catch NostrError.invalidCiphertext {
            return
        } catch {
            Issue.record("Expected NostrError.invalidCiphertext, got \(error)")
        }
    }
}
