import Foundation
import Testing
import BitFoundation
@testable import bitchat

@Suite("NoiseEncryptionService Tests")
struct NoiseEncryptionServiceTests {

    @Test("Encryption status accessors cover all cases")
    func encryptionStatusAccessorsCoverAllCases() {
        #expect(EncryptionStatus.none.icon == "lock.slash")
        #expect(EncryptionStatus.noHandshake.icon == nil)
        #expect(EncryptionStatus.noiseHandshaking.icon == "lock.rotation")
        #expect(EncryptionStatus.noiseSecured.icon == "lock.fill")
        #expect(EncryptionStatus.noiseVerified.icon == "checkmark.seal.fill")

        #expect(!EncryptionStatus.none.description.isEmpty)
        #expect(!EncryptionStatus.noHandshake.description.isEmpty)
        #expect(!EncryptionStatus.noiseHandshaking.description.isEmpty)
        #expect(!EncryptionStatus.noiseSecured.description.isEmpty)
        #expect(!EncryptionStatus.noiseVerified.description.isEmpty)

        #expect(!EncryptionStatus.none.accessibilityDescription.isEmpty)
        #expect(!EncryptionStatus.noHandshake.accessibilityDescription.isEmpty)
        #expect(!EncryptionStatus.noiseHandshaking.accessibilityDescription.isEmpty)
        #expect(!EncryptionStatus.noiseSecured.accessibilityDescription.isEmpty)
        #expect(!EncryptionStatus.noiseVerified.accessibilityDescription.isEmpty)
    }

    @Test("Announce and packet signatures round-trip and detect tampering")
    func announceAndPacketSignaturesRoundTrip() throws {
        let service = NoiseEncryptionService(keychain: MockKeychain())
        let signingPublicKey = service.getSigningPublicKeyData()
        let noisePublicKey = service.getStaticPublicKeyData()

        let signature = try #require(
            service.buildAnnounceSignature(
                peerID: Data([0xAA, 0xBB]),
                noiseKey: noisePublicKey,
                ed25519Key: signingPublicKey,
                nickname: "Alice",
                timestampMs: 12345
            ),
            "Expected announce signature"
        )

        #expect(
            service.verifyAnnounceSignature(
                signature: signature,
                peerID: Data([0xAA, 0xBB]),
                noiseKey: noisePublicKey,
                ed25519Key: signingPublicKey,
                nickname: "Alice",
                timestampMs: 12345,
                publicKey: signingPublicKey
            )
        )
        #expect(
            !service.verifyAnnounceSignature(
                signature: signature,
                peerID: Data([0xAA, 0xBB]),
                noiseKey: noisePublicKey,
                ed25519Key: signingPublicKey,
                nickname: "Mallory",
                timestampMs: 12345,
                publicKey: signingPublicKey
            )
        )
        #expect(!service.verifySignature(signature, for: Data("data".utf8), publicKey: Data([1, 2, 3])))

        let packet = BitchatPacket(
            type: MessageType.announce.rawValue,
            senderID: Data([0, 1, 2, 3, 4, 5, 6, 7]),
            recipientID: nil,
            timestamp: 42,
            payload: Data("payload".utf8),
            signature: nil,
            ttl: 7
        )
        let signedPacket = try #require(service.signPacket(packet), "Expected signed packet")

        #expect(service.verifyPacketSignature(signedPacket, publicKey: signingPublicKey))
        #expect(!service.verifyPacketSignature(packet, publicKey: signingPublicKey))

        var tampered = signedPacket
        tampered.signature = Data(repeating: 0xFF, count: 64)
        #expect(!service.verifyPacketSignature(tampered, publicKey: signingPublicKey))
    }

    @Test("Service-level handshake, encryption, and fingerprint lifecycle work")
    func handshakeEncryptionAndFingerprintLifecycle() async throws {
        let alice = NoiseEncryptionService(keychain: MockKeychain())
        let bob = NoiseEncryptionService(keychain: MockKeychain())
        let alicePeerID = PeerID(publicKey: alice.getStaticPublicKeyData())
        let bobPeerID = PeerID(publicKey: bob.getStaticPublicKeyData())
        let recorder = AuthenticationRecorder()

        #expect(alice.onPeerAuthenticated == nil)
        #expect(bob.onPeerAuthenticatedWithGeneration == nil)
        alice.addOnPeerAuthenticatedHandler(recorder.record(peerID:fingerprint:))
        bob.onPeerAuthenticated = recorder.record(peerID:fingerprint:)
        bob.onPeerAuthenticatedWithGeneration = recorder.record(
            peerID:fingerprint:sessionGeneration:
        )

        try establishSessions(alice: alice, bob: bob)

        let authenticated = await TestHelpers.waitUntil({ recorder.count >= 2 }, timeout: 5.0)
        #expect(authenticated)
        let generationAuthenticated = await TestHelpers.waitUntil(
            { recorder.generationCount >= 1 },
            timeout: 5.0
        )
        #expect(generationAuthenticated)
        #expect(alice.hasEstablishedSession(with: bobPeerID))
        #expect(bob.hasEstablishedSession(with: alicePeerID))
        #expect(alice.hasSession(with: bobPeerID))
        #expect(bob.hasSession(with: alicePeerID))
        #expect(alice.getPeerPublicKeyData(bobPeerID)?.count == 32)
        #expect(bob.getPeerPublicKeyData(alicePeerID)?.count == 32)
        #expect(alice.getPeerFingerprint(bobPeerID) != nil)
        #expect(bob.getPeerFingerprint(alicePeerID) != nil)
        #expect(recorder.generation(for: alicePeerID) == bob.sessionGeneration(for: alicePeerID))

        let plaintext = Data("secret payload".utf8)
        let ciphertext = try alice.encrypt(plaintext, for: bobPeerID)
        let decrypted = try bob.decrypt(ciphertext, from: alicePeerID)
        #expect(decrypted == plaintext)

        alice.clearSession(for: bobPeerID)
        #expect(!alice.hasSession(with: bobPeerID))
        #expect(alice.getPeerFingerprint(bobPeerID) == nil)

        bob.clearEphemeralStateForPanic()
        #expect(!bob.hasSession(with: alicePeerID))
        #expect(bob.getPeerFingerprint(alicePeerID) == nil)
    }

    @Test("Handshake rejects a claimed peer ID that does not match the authenticated static key")
    func handshakeRejectsClaimedPeerIDStaticKeyMismatch() async throws {
        let receiver = NoiseEncryptionService(keychain: MockKeychain())
        let claimedAlice = NoiseEncryptionService(keychain: MockKeychain())
        let mallory = NoiseEncryptionService(keychain: MockKeychain())
        let receiverPeerID = PeerID(publicKey: receiver.getStaticPublicKeyData())
        let claimedAlicePeerID = PeerID(publicKey: claimedAlice.getStaticPublicKeyData())
        let recorder = AuthenticationRecorder()
        receiver.addOnPeerAuthenticatedHandler(recorder.record(peerID:fingerprint:))

        let message1 = try mallory.initiateHandshake(with: receiverPeerID)
        let message2 = try #require(
            try receiver.processHandshakeMessage(from: claimedAlicePeerID, message: message1)
        )
        let message3 = try #require(
            try mallory.processHandshakeMessage(from: receiverPeerID, message: message2)
        )

        do {
            _ = try receiver.processHandshakeMessage(from: claimedAlicePeerID, message: message3)
            Issue.record("Expected the authenticated Mallory key to be rejected for Alice's peer ID")
        } catch let error as NoiseSessionError {
            #expect(error == .peerIdentityMismatch)
        } catch {
            Issue.record("Unexpected mismatch error: \(error)")
        }

        #expect(!receiver.hasSession(with: claimedAlicePeerID))
        let emittedAuthentication = await TestHelpers.waitUntil(
            { recorder.count > 0 },
            timeout: TestConstants.shortTimeout
        )
        #expect(!emittedAuthentication)
    }

    @Test("Failed forged replacement preserves the established peer session")
    func forgedReplacementPreservesEstablishedSession() async throws {
        let alice = NoiseEncryptionService(keychain: MockKeychain())
        let receiver = NoiseEncryptionService(keychain: MockKeychain())
        let mallory = NoiseEncryptionService(keychain: MockKeychain())
        let alicePeerID = PeerID(publicKey: alice.getStaticPublicKeyData())
        let receiverPeerID = PeerID(publicKey: receiver.getStaticPublicKeyData())
        let recorder = AuthenticationRecorder()
        receiver.addOnPeerAuthenticatedHandler(recorder.record(peerID:fingerprint:))

        try establishSessions(alice: alice, bob: receiver)
        let initialAuthentication = await TestHelpers.waitUntil(
            { recorder.count == 1 },
            timeout: TestConstants.longTimeout
        )
        #expect(initialAuthentication)

        let before = try alice.encrypt(Data("before".utf8), for: receiverPeerID)
        #expect(try receiver.decrypt(before, from: alicePeerID) == Data("before".utf8))

        let forgedMessage1 = try mallory.initiateHandshake(with: receiverPeerID)
        let forgedMessage2 = try #require(
            try receiver.processHandshakeMessage(from: alicePeerID, message: forgedMessage1)
        )
        // The replacement has not authenticated yet; the working Alice
        // transport session must remain available throughout the candidate.
        #expect(receiver.hasEstablishedSession(with: alicePeerID))
        let forgedMessage3 = try #require(
            try mallory.processHandshakeMessage(from: receiverPeerID, message: forgedMessage2)
        )

        do {
            _ = try receiver.processHandshakeMessage(from: alicePeerID, message: forgedMessage3)
            Issue.record("Expected forged replacement to fail peer binding")
        } catch let error as NoiseSessionError {
            #expect(error == .peerIdentityMismatch)
        } catch {
            Issue.record("Unexpected replacement error: \(error)")
        }

        #expect(receiver.hasEstablishedSession(with: alicePeerID))
        let after = try alice.encrypt(Data("after".utf8), for: receiverPeerID)
        #expect(try receiver.decrypt(after, from: alicePeerID) == Data("after".utf8))
        let emittedReplacementAuthentication = await TestHelpers.waitUntil(
            { recorder.count > 1 },
            timeout: TestConstants.shortTimeout
        )
        #expect(!emittedReplacementAuthentication)
    }

    @Test("Valid rehandshake atomically replaces the established session")
    func validRehandshakeReplacesEstablishedSession() throws {
        let alice = NoiseEncryptionService(keychain: MockKeychain())
        let receiver = NoiseEncryptionService(keychain: MockKeychain())
        let alicePeerID = PeerID(publicKey: alice.getStaticPublicKeyData())
        let receiverPeerID = PeerID(publicKey: receiver.getStaticPublicKeyData())

        try establishSessions(alice: alice, bob: receiver)
        alice.clearSession(for: receiverPeerID)

        let message1 = try alice.initiateHandshake(with: receiverPeerID)
        let message2 = try #require(
            try receiver.processHandshakeMessage(from: alicePeerID, message: message1)
        )
        #expect(receiver.hasEstablishedSession(with: alicePeerID))
        let message3 = try #require(
            try alice.processHandshakeMessage(from: receiverPeerID, message: message2)
        )
        _ = try receiver.processHandshakeMessage(from: alicePeerID, message: message3)

        #expect(alice.hasEstablishedSession(with: receiverPeerID))
        #expect(receiver.hasEstablishedSession(with: alicePeerID))
        let ciphertext = try alice.encrypt(Data("new session".utf8), for: receiverPeerID)
        #expect(try receiver.decrypt(ciphertext, from: alicePeerID) == Data("new session".utf8))
    }

    @Test("Automatic rekey exposes and completes its exact handshake bytes")
    func automaticRekeyHandshakeIsNotStranded() throws {
        let alice = NoiseEncryptionService(keychain: MockKeychain())
        let bob = NoiseEncryptionService(keychain: MockKeychain())
        let alicePeerID = PeerID(publicKey: alice.getStaticPublicKeyData())
        let bobPeerID = PeerID(publicKey: bob.getStaticPublicKeyData())
        try establishSessions(alice: alice, bob: bob)
        let originalGeneration = try #require(alice.sessionGeneration(for: bobPeerID))
        var leaseRan = false
        let leased = alice.withCurrentSessionGeneration(
            for: bobPeerID,
            expected: originalGeneration
        ) {
            leaseRan = true
            return true
        }
        #expect(leased == true)
        #expect(leaseRan)

        var emittedPeerID: PeerID?
        var emittedMessage: Data?
        alice.onRekeyHandshakeReady = { peerID, message in
            emittedPeerID = peerID
            emittedMessage = message
        }
        try alice._test_initiateAutomaticRekey(for: bobPeerID)

        #expect(emittedPeerID == bobPeerID)
        #expect(alice.sessionGeneration(for: bobPeerID) == nil)
        leaseRan = false
        let staleLease = alice.withCurrentSessionGeneration(
            for: bobPeerID,
            expected: originalGeneration
        ) {
            leaseRan = true
            return true
        }
        #expect(staleLease == nil)
        #expect(!leaseRan)
        let message1 = try #require(emittedMessage)
        #expect(!message1.isEmpty)
        #expect(alice.hasSession(with: bobPeerID))
        #expect(!alice.hasEstablishedSession(with: bobPeerID))

        let message2 = try #require(
            try bob.processHandshakeMessage(from: alicePeerID, message: message1)
        )
        let message3 = try #require(
            try alice.processHandshakeMessage(from: bobPeerID, message: message2)
        )
        _ = try bob.processHandshakeMessage(from: alicePeerID, message: message3)

        #expect(alice.hasEstablishedSession(with: bobPeerID))
        #expect(bob.hasEstablishedSession(with: alicePeerID))
        #expect(alice.sessionGeneration(for: bobPeerID) != originalGeneration)
    }

    @Test("Large private-file payloads use the bounded Noise extension")
    func largePrivateFileNoiseRoundTrip() throws {
        let alice = NoiseEncryptionService(keychain: MockKeychain())
        let bob = NoiseEncryptionService(keychain: MockKeychain())
        let alicePeerID = PeerID(publicKey: alice.getStaticPublicKeyData())
        let bobPeerID = PeerID(publicKey: bob.getStaticPublicKeyData())
        try establishSessions(alice: alice, bob: bob)

        let content = Data("%PDF-1.7\n".utf8) + Data(repeating: 0x51, count: 96 * 1024)
        let file = BitchatFilePacket(
            fileName: "large-private.pdf",
            fileSize: UInt64(content.count),
            mimeType: "application/pdf",
            content: content
        )
        let typedPayload = try #require(BLENoisePayloadFactory.privateFile(file))
        #expect(typedPayload.count > NoiseSecurityConstants.maxMessageSize)
        #expect(typedPayload.first == NoisePayloadType.privateFile.rawValue)
        #expect(
            typedPayload.count <= NoiseSecurityConstants.maxPrivateFilePlaintextSize,
            "typedBytes=\(typedPayload.count) limit=\(NoiseSecurityConstants.maxPrivateFilePlaintextSize)"
        )

        do {
            _ = try alice.encrypt(typedPayload, for: bobPeerID)
            Issue.record("Ordinary Noise payload path must retain its 64 KiB ceiling")
        } catch NoiseSecurityError.messageTooLarge {
            // Expected: only the purpose-specific private-file API may extend it.
        }

        let ciphertext: Data
        do {
            ciphertext = try alice.encryptPrivateFilePayload(typedPayload, for: bobPeerID)
        } catch {
            Issue.record("Private-file encryption failed: \(error)")
            return
        }
        let decrypted: Data
        do {
            decrypted = try bob.decrypt(ciphertext, from: alicePeerID)
        } catch {
            Issue.record("Private-file decryption failed: \(error); ciphertextBytes=\(ciphertext.count)")
            return
        }

        #expect(ciphertext.range(of: content) == nil)
        #expect(decrypted == typedPayload)
    }

    @Test("Encrypt without a session requests handshake and decrypt without session fails")
    func handshakeRequiredAndSessionNotEstablishedErrors() throws {
        let service = NoiseEncryptionService(keychain: MockKeychain())
        let peerID = PeerID(str: "1021324354657687")
        var requestedPeerID: PeerID?

        service.onHandshakeRequired = { requestedPeerID = $0 }

        do {
            _ = try service.encrypt(Data("hello".utf8), for: peerID)
            Issue.record("Expected handshakeRequired error")
        } catch NoiseEncryptionError.handshakeRequired {
            #expect(requestedPeerID == peerID)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        do {
            _ = try service.decrypt(Data("hello".utf8), from: peerID)
            Issue.record("Expected sessionNotEstablished error")
        } catch NoiseEncryptionError.sessionNotEstablished {
            // Expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Clearing persistent identity removes saved keys")
    func clearPersistentIdentityRemovesSavedKeys() {
        let keychain = MockKeychain()
        let service = NoiseEncryptionService(keychain: keychain)

        #expect(service.getStaticPublicKeyData().count == 32)
        #expect(service.getSigningPublicKeyData().count == 32)

        service.clearPersistentIdentity()

        if case .itemNotFound = keychain.getIdentityKeyWithResult(forKey: "noiseStaticKey") {
        } else {
            Issue.record("Expected noiseStaticKey to be removed")
        }

        if case .itemNotFound = keychain.getIdentityKeyWithResult(forKey: "ed25519SigningKey") {
        } else {
            Issue.record("Expected ed25519SigningKey to be removed")
        }
    }

    @Test("NoiseMessage JSON and binary encoding round-trip")
    func noiseMessageRoundTrips() throws {
        let message = NoiseMessage(
            type: .encryptedMessage,
            sessionID: UUID().uuidString,
            payload: Data([1, 2, 3, 4])
        )

        let encoded = try #require(message.encode(), "Expected JSON encoding")
        let decoded = try #require(NoiseMessage.decode(from: encoded), "Expected JSON decode")
        #expect(decoded.type == message.type)
        #expect(decoded.sessionID == message.sessionID)
        #expect(decoded.payload == message.payload)

        #expect(NoiseMessage.decodeWithError(from: Data("bad".utf8)) == nil)

        let binary = message.toBinaryData()
        let roundTripped = try #require(NoiseMessage.fromBinaryData(binary), "Expected binary decode")
        #expect(roundTripped.type == message.type)
        #expect(roundTripped.sessionID == message.sessionID)
        #expect(roundTripped.payload == message.payload)
        #expect(NoiseMessage.fromBinaryData(Data()) == nil)
    }

    private func establishSessions(
        alice: NoiseEncryptionService,
        bob: NoiseEncryptionService
    ) throws {
        let alicePeerID = PeerID(publicKey: alice.getStaticPublicKeyData())
        let bobPeerID = PeerID(publicKey: bob.getStaticPublicKeyData())
        let message1 = try alice.initiateHandshake(with: bobPeerID)
        let response = try bob.processHandshakeMessage(from: alicePeerID, message: message1)
        let message2 = try #require(response, "Expected handshake response")
        let final = try alice.processHandshakeMessage(from: bobPeerID, message: message2)
        let message3 = try #require(final, "Expected handshake final")
        let finalMessage = try bob.processHandshakeMessage(from: alicePeerID, message: message3)
        #expect(finalMessage == nil)
    }
}

private final class AuthenticationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(PeerID, String)] = []
    private var generationEntries: [(PeerID, UUID)] = []

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    var generationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return generationEntries.count
    }

    func record(peerID: PeerID, fingerprint: String) {
        lock.lock()
        entries.append((peerID, fingerprint))
        lock.unlock()
    }

    func record(peerID: PeerID, fingerprint _: String, sessionGeneration: UUID) {
        lock.lock()
        generationEntries.append((peerID, sessionGeneration))
        lock.unlock()
    }

    func generation(for peerID: PeerID) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        return generationEntries.last { $0.0 == peerID }?.1
    }
}
