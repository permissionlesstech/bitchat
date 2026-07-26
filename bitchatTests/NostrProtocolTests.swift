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
        
        // Try to decrypt with wrong recipient. The outer envelope is bound to
        // the addressed recipient's `p` tag, so this now fails validation
        // before any decryption is attempted.
        expectInvalidEvent {
            _ = try NostrProtocol.decryptPrivateMessage(
                giftWrap: giftWrap,
                recipientIdentity: wrongRecipient
            )
        }
    }

    @Test func decryptAcceptsCurrentAndroidInnerRecipientTag() throws {
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()

        // Current Android's `createPrivateMessage` emits an unsigned kind-14
        // inner event with exactly [["p", recipient]], while released iOS
        // uses no inner tags. This isolated generator reproduces the Android
        // wire shape without making the production encoder depend on it.
        let giftWrap = try NostrProtocol.createPrivateMessageWithInnerTagsForTesting(
            content: "legacy message from Android",
            recipientPubkey: recipient.publicKeyHex,
            senderIdentity: sender,
            innerMessageTags: [["p", recipient.publicKeyHex]]
        )

        let result = try NostrProtocol.decryptPrivateMessage(
            giftWrap: giftWrap,
            recipientIdentity: recipient
        )
        #expect(result.content == "legacy message from Android")
        #expect(result.senderPubkey == sender.publicKeyHex)
    }

    @Test func decryptRejectsAlternateInnerTagShapes() throws {
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let otherRecipient = try NostrIdentity.generate()
        let invalidTagShapes = [
            [["p", otherRecipient.publicKeyHex]],
            [["p", recipient.publicKeyHex], ["p", recipient.publicKeyHex]],
            [["p", recipient.publicKeyHex, "unexpected"]],
            [["x", recipient.publicKeyHex]]
        ]

        for tags in invalidTagShapes {
            let giftWrap = try NostrProtocol.createPrivateMessageWithInnerTagsForTesting(
                content: "invalid inner tag shape",
                recipientPubkey: recipient.publicKeyHex,
                senderIdentity: sender,
                innerMessageTags: tags
            )
            expectInvalidEvent {
                _ = try NostrProtocol.decryptPrivateMessage(
                    giftWrap: giftWrap,
                    recipientIdentity: recipient
                )
            }
        }
    }

    @Test func decryptsFrozenLegacyEnvelopeProducedByAndroidB7f0b33d() throws {
        let eventData = try Data(contentsOf: fixtureURL(
            name: "AndroidLegacyPrivateEnvelopeB7f0b33d"
        ))
        let metadataData = try Data(contentsOf: fixtureURL(
            name: "AndroidLegacyPrivateEnvelopeB7f0b33dMetadata"
        ))
        let envelope = try JSONDecoder().decode(NostrEvent.self, from: eventData)
        let metadata = try JSONDecoder().decode(AndroidLegacyEnvelopeFixture.self, from: metadataData)
        let recipientKey = try #require(Data(hexString: metadata.recipientPrivateKey))
        let recipient = try NostrIdentity(privateKeyData: recipientKey)

        #expect(metadata.androidCommit == "b7f0b33d3a267c770d3d5a65ee2d8c7e755450db")
        #expect(metadata.generator == "NostrProtocol.createPrivateMessage")
        // The generator patch ships as .patch.txt so the Xcode synchronized
        // test group reliably copies it as a text resource; its pinned SHA-256
        // covers the unchanged patch content.
        #expect(metadata.generatorPatch == "AndroidLegacyPrivateEnvelopeB7f0b33dGenerator.patch.txt")
        #expect(metadata.fixtureSHA256 == eventData.sha256Fingerprint())
        #expect(metadata.gradleTest.contains("NostrProtocolTest.emitCrossPlatformFixtures"))
        let generatorPatch = try String(contentsOf: fixtureURL(
            name: "AndroidLegacyPrivateEnvelopeB7f0b33dGenerator.patch",
            extension: "txt"
        ))
        #expect(metadata.generatorPatchSHA256 == Data(generatorPatch.utf8).sha256Fingerprint())
        #expect(generatorPatch.contains("fun emitCrossPlatformFixtures()"))
        #expect(generatorPatch.contains(metadata.recipientPrivateKey))
        #expect(envelope.isValidSignature())
        #expect(envelope.kind == NostrProtocol.EventKind.giftWrap.rawValue)
        #expect(envelope.tags == [["p", recipient.publicKeyHex]])

        // The Android inner event carries exactly the recipient `p` tag, so a
        // successful decrypt also proves the Android inner-tag acceptance.
        let result = try NostrProtocol.decryptPrivateMessage(
            giftWrap: envelope,
            recipientIdentity: recipient
        )
        #expect(result.content == "legacy fixture from Android b7f0b33d")
        #expect(result.senderPubkey == metadata.senderPublicKey)
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
        let result = try NostrProtocol.decryptPrivateMessage(
            giftWrap: envelope,
            recipientIdentity: recipient
        )
        #expect(result.content == "legacy fixture from 733098bb")
        #expect(result.senderPubkey == "2e3d79df7047204f02b726c574e256f8de1dd80510f7dcb8b0d12df13acb87e6")
    }

    @Test func decryptRejectsOversizedCiphertextBeforeDecoding() throws {
        let recipient = try NostrIdentity.generate()
        let wrapper = try NostrIdentity.generate()
        let oversizedContent = "v2:"
            + String(
                repeating: "A",
                count: NostrProtocol.maximumPrivateEnvelopeCiphertextBytes
            )
        let event = NostrEvent(
            pubkey: wrapper.publicKeyHex,
            createdAt: Date(),
            kind: .giftWrap,
            tags: [["p", recipient.publicKeyHex]],
            content: oversizedContent
        )
        let signed = try event.sign(with: wrapper.schnorrSigningKey())

        expectInvalidCiphertext {
            _ = try NostrProtocol.decryptPrivateMessage(
                giftWrap: signed,
                recipientIdentity: recipient
            )
        }
    }

    @Test func decryptDoesNotMisinterpretStandardNIP44Payload() throws {
        let recipient = try NostrIdentity.generate()
        let wrapper = try NostrIdentity.generate()
        // A valid NIP-44 v2 payload from the official test vectors. Its wire
        // format starts with a version byte in standard Base64, not BitChat's
        // historical `v2:` prefix.
        let standardPayload = "AgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABee0G5VSK0/9YypIObAtDKfYEAjD35uVkHyB0F4DwrcNaCXlCWZKaArsGrY6M9wnuTMxWfp1RTN9Xga8no+kF5Vsb"
        let event = NostrEvent(
            pubkey: wrapper.publicKeyHex,
            createdAt: Date(),
            kind: .giftWrap,
            tags: [["p", recipient.publicKeyHex]],
            content: standardPayload
        )
        let signed = try event.sign(with: wrapper.schnorrSigningKey())

        expectInvalidCiphertext {
            _ = try NostrProtocol.decryptPrivateMessage(
                giftWrap: signed,
                recipientIdentity: recipient
            )
        }
    }

    @Test func decryptRejectsWrongOuterKind() throws {
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        var giftWrap = try NostrProtocol.createPrivateMessage(
            content: "wrong outer kind",
            recipientPubkey: recipient.publicKeyHex,
            senderIdentity: sender
        )
        giftWrap = NostrEvent(
            pubkey: giftWrap.pubkey,
            createdAt: Date(timeIntervalSince1970: TimeInterval(giftWrap.created_at)),
            kind: .textNote,
            tags: giftWrap.tags,
            content: giftWrap.content
        )

        expectInvalidEvent {
            _ = try NostrProtocol.decryptPrivateMessage(
                giftWrap: giftWrap,
                recipientIdentity: recipient
            )
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

    @Test
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


    @Test func inboundNostrEventRejectsTooManyTags() throws {
        var eventDict = Self.validInboundEventDict()
        eventDict["tags"] = Array(
            repeating: ["g", "u4pruyd"],
            count: TransportConfig.nostrMaxEventTags + 1
        )

        #expect(throws: NostrError.invalidEvent) {
            _ = try NostrEvent(from: eventDict)
        }
    }

    @Test func inboundNostrEventRejectsTooManyTagValues() throws {
        var eventDict = Self.validInboundEventDict()
        eventDict["tags"] = [Array(
            repeating: "value",
            count: TransportConfig.nostrMaxEventTagValues + 1
        )]

        #expect(throws: NostrError.invalidEvent) {
            _ = try NostrEvent(from: eventDict)
        }
    }

    @Test func inboundNostrEventRejectsOversizedTagValues() throws {
        var eventDict = Self.validInboundEventDict()
        eventDict["tags"] = [[
            "g",
            String(repeating: "a", count: TransportConfig.nostrMaxEventTagValueBytes + 1)
        ]]

        #expect(throws: NostrError.invalidEvent) {
            _ = try NostrEvent(from: eventDict)
        }
    }

    @Test func inboundNostrEventAcceptsTagsWithinLimits() throws {
        var eventDict = Self.validInboundEventDict()
        eventDict["tags"] = [["g", "u4pruyd"], ["t", "teleport"]]

        let event = try NostrEvent(from: eventDict)

        #expect(event.tags.count == 2)
    }

    // MARK: - Helpers
    private static func validInboundEventDict() -> [String: Any] {
        [
            "id": String(repeating: "0", count: 64),
            "pubkey": String(repeating: "1", count: 64),
            "created_at": 1_234_567,
            "kind": NostrProtocol.EventKind.ephemeralEvent.rawValue,
            "tags": [["g", "u4pruyd"]],
            "content": "hello",
            "sig": String(repeating: "2", count: 128)
        ]
    }

    private struct LegacyRecipientKeyFixture: Decodable {
        let recipientPrivateKey: String

        enum CodingKeys: String, CodingKey {
            case recipientPrivateKey = "recipient_private_key"
        }
    }

    private struct AndroidLegacyEnvelopeFixture: Decodable {
        let androidCommit: String
        let generator: String
        let generatorPatch: String
        let generatorPatchSHA256: String
        let gradleTest: String
        let fixtureSHA256: String
        let recipientPrivateKey: String
        let senderPublicKey: String

        enum CodingKeys: String, CodingKey {
            case androidCommit = "android_commit"
            case generator
            case generatorPatch = "generator_patch"
            case generatorPatchSHA256 = "generator_patch_sha256"
            case gradleTest = "gradle_test"
            case fixtureSHA256 = "fixture_sha256"
            case recipientPrivateKey = "recipient_private_key"
            case senderPublicKey = "sender_public_key"
        }
    }

    private func fixtureURL(name: String, extension fileExtension: String = "json") throws -> URL {
        // Bundle.module only exists under SwiftPM; the Xcode test targets
        // resolve resources through the test bundle (same pattern as
        // NoiseProtocolTests' NoiseTestVectors.json loader).
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: MockKeychain.self)
        #endif
        return try #require(bundle.url(forResource: name, withExtension: fileExtension))
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
