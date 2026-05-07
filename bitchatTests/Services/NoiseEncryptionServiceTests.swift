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
        let alicePeerID = PeerID(str: "0011223344556677")
        let bobPeerID = PeerID(str: "8899aabbccddeeff")
        let recorder = AuthenticationRecorder()

        #expect(alice.onPeerAuthenticated == nil)
        alice.addOnPeerAuthenticatedHandler(recorder.record(peerID:fingerprint:))
        bob.onPeerAuthenticated = recorder.record(peerID:fingerprint:)

        try establishSessions(alice: alice, bob: bob, alicePeerID: alicePeerID, bobPeerID: bobPeerID)

        let authenticated = await TestHelpers.waitUntil({ recorder.count >= 2 }, timeout: 0.5)
        #expect(authenticated)
        #expect(alice.hasEstablishedSession(with: alicePeerID))
        #expect(bob.hasEstablishedSession(with: bobPeerID))
        #expect(alice.hasSession(with: alicePeerID))
        #expect(bob.hasSession(with: bobPeerID))
        #expect(alice.getPeerPublicKeyData(alicePeerID)?.count == 32)
        #expect(bob.getPeerPublicKeyData(bobPeerID)?.count == 32)
        #expect(alice.getPeerFingerprint(alicePeerID) != nil)
        #expect(bob.getPeerFingerprint(bobPeerID) != nil)

        let plaintext = Data("secret payload".utf8)
        let ciphertext = try alice.encrypt(plaintext, for: alicePeerID)
        let decrypted = try bob.decrypt(ciphertext, from: bobPeerID)
        #expect(decrypted == plaintext)

        alice.clearSession(for: alicePeerID)
        #expect(!alice.hasSession(with: alicePeerID))
        #expect(alice.getPeerFingerprint(alicePeerID) == nil)

        bob.clearEphemeralStateForPanic()
        #expect(!bob.hasSession(with: bobPeerID))
        #expect(bob.getPeerFingerprint(bobPeerID) == nil)
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
        bob: NoiseEncryptionService,
        alicePeerID: PeerID,
        bobPeerID: PeerID
    ) throws {
        let message1 = try alice.initiateHandshake(with: alicePeerID)
        let response = try bob.processHandshakeMessage(from: bobPeerID, message: message1)
        let message2 = try #require(response, "Expected handshake response")
        let final = try alice.processHandshakeMessage(from: alicePeerID, message: message2)
        let message3 = try #require(final, "Expected handshake final")
        let finalMessage = try bob.processHandshakeMessage(from: bobPeerID, message: message3)
        #expect(finalMessage == nil)
    }
}

private final class AuthenticationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(PeerID, String)] = []

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    func record(peerID: PeerID, fingerprint: String) {
        lock.lock()
        entries.append((peerID, fingerprint))
        lock.unlock()
    }
}
