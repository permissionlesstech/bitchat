import CryptoKit
import Foundation
import Testing

@testable import bitchat

@Suite("Noise Coverage Tests")
struct NoiseCoverageTests {
    private let keychain = MockKeychain()
    private let aliceStaticKey = Curve25519.KeyAgreement.PrivateKey()
    private let bobStaticKey = Curve25519.KeyAgreement.PrivateKey()
    private let charlieStaticKey = Curve25519.KeyAgreement.PrivateKey()

    private let alicePeerID = PeerID(str: "0011223344556677")
    private let bobPeerID = PeerID(str: "8899aabbccddeeff")
    private let charliePeerID = PeerID(str: "fedcba9876543210")

    @Test("Protocol metadata and handshake patterns expose expected values")
    func protocolMetadataAndHandshakePatterns() {
        let ikName = NoiseProtocolName(pattern: NoisePattern.IK.patternName)
        #expect(ikName.pattern == "IK")
        #expect(ikName.dh == "25519")
        #expect(ikName.cipher == "ChaChaPoly")
        #expect(ikName.hash == "SHA256")
        #expect(ikName.fullName == "Noise_IK_25519_ChaChaPoly_SHA256")

        #expect(NoisePattern.XX.patternName == "XX")
        #expect(NoisePattern.IK.patternName == "IK")
        #expect(NoisePattern.NK.patternName == "NK")

        let ikPatterns = NoisePattern.IK.messagePatterns
        #expect(ikPatterns.count == 2)
        #expect(ikPatterns[0] == [.e, .es, .s, .ss])
        #expect(ikPatterns[1] == [.e, .ee, .se])

        let nkPatterns = NoisePattern.NK.messagePatterns
        #expect(nkPatterns.count == 2)
        #expect(nkPatterns[0] == [.e, .es])
        #expect(nkPatterns[1] == [.e, .ee])
    }

    @Test("Symmetric state supports long protocol names and mixKeyAndHash")
    func symmetricStateLongNameAndMixKeyAndHash() {
        let longName = String(repeating: "NoiseProtocol_", count: 3)
        let symmetricState = NoiseSymmetricState(protocolName: longName)
        let initialHash = symmetricState.getHandshakeHash()

        #expect(initialHash.count == 32)
        #expect(!symmetricState.hasCipherKey())

        symmetricState.mixKeyAndHash(Data("input-key-material".utf8))

        #expect(symmetricState.hasCipherKey())
        #expect(symmetricState.getHandshakeHash() != initialHash)
    }

    @Test("Cipher state rejects duplicate and stale extracted nonces")
    func cipherStateRejectsDuplicateAndStaleNonces() throws {
        let key = SymmetricKey(size: .bits256)
        let receiver = NoiseCipherState(key: key, useExtractedNonce: true)
        let initialPayload = try makeExtractedNoncePayload(
            key: key,
            nonce: 0,
            plaintext: Data("nonce-0".utf8)
        )

        let initialPlaintext = try receiver.decrypt(ciphertext: initialPayload)
        #expect(initialPlaintext == Data("nonce-0".utf8))

        #expect(throws: (any Error).self) {
            try receiver.decrypt(ciphertext: initialPayload)
        }

        for nonce in 1...1024 {
            let payload = try makeExtractedNoncePayload(
                key: key,
                nonce: UInt64(nonce),
                plaintext: Data("nonce-\(nonce)".utf8)
            )
            let plaintext = try receiver.decrypt(ciphertext: payload)
            #expect(plaintext == Data("nonce-\(nonce)".utf8))
        }

        #expect(throws: (any Error).self) {
            try receiver.decrypt(ciphertext: initialPayload)
        }
    }

    @Test("Cipher state handles large nonce jumps and associated-data mismatches")
    func cipherStateHandlesLargeJumpsAndAADMismatch() throws {
        let key = SymmetricKey(size: .bits256)
        let extractedReceiver = NoiseCipherState(key: key, useExtractedNonce: true)

        let jumped = try makeExtractedNoncePayload(
            key: key,
            nonce: 1500,
            plaintext: Data("future".utf8)
        )
        let slightlyOlder = try makeExtractedNoncePayload(
            key: key,
            nonce: 1499,
            plaintext: Data("older".utf8)
        )
        let tooOld = try makeExtractedNoncePayload(
            key: key,
            nonce: 100,
            plaintext: Data("ancient".utf8)
        )

        #expect(try extractedReceiver.decrypt(ciphertext: jumped) == Data("future".utf8))
        #expect(try extractedReceiver.decrypt(ciphertext: slightlyOlder) == Data("older".utf8))
        #expect(throws: (any Error).self) {
            try extractedReceiver.decrypt(ciphertext: tooOld)
        }

        let sender = NoiseCipherState(key: key)
        let receiver = NoiseCipherState(key: key)
        let plaintext = Data("associated-data".utf8)
        let aad = Data("good-aad".utf8)
        let ciphertext = try sender.encrypt(plaintext: plaintext, associatedData: aad)

        #expect(throws: (any Error).self) {
            try receiver.decrypt(ciphertext: ciphertext, associatedData: Data("bad-aad".utf8))
        }
        #expect(try receiver.decrypt(ciphertext: ciphertext, associatedData: aad) == plaintext)
        #expect(throws: (any Error).self) {
            try receiver.decrypt(ciphertext: Data(repeating: 0xAA, count: 15))
        }
    }

    @Test("Cipher state covers nonce guard rails and extracted payload bounds")
    func cipherStateCoversNonceGuardRailsAndExtractedPayloadBounds() throws {
        let uninitializedCipher = NoiseCipherState()
        #expect(throws: NoiseError.uninitializedCipher) {
            try uninitializedCipher.encrypt(plaintext: Data("missing-key".utf8))
        }
        #expect(throws: NoiseError.uninitializedCipher) {
            try uninitializedCipher.decrypt(ciphertext: Data(repeating: 0x00, count: 16))
        }
        #expect(try uninitializedCipher.extractNonceFromCiphertextPayloadForTesting(Data([0x00, 0x01, 0x02])) == nil)

        let key = SymmetricKey(size: .bits256)

        let highNonceCipher = NoiseCipherState(key: key)
        highNonceCipher.setNonceForTesting(1_000_000_001)
        #expect(throws: Never.self) {
            _ = try highNonceCipher.encrypt(plaintext: Data("high-nonce".utf8))
        }

        let exhaustedCipher = NoiseCipherState(key: key)
        exhaustedCipher.setNonceForTesting(UInt64(UInt32.max))
        #expect(throws: NoiseError.nonceExceeded) {
            try exhaustedCipher.encrypt(plaintext: Data("nonce-limit".utf8))
        }
    }

    @Test("Handshake validation rejects malformed keys and messages")
    func handshakeValidationRejectsMalformedInputs() throws {
        let responder = NoiseHandshakeState(
            role: .responder,
            pattern: .XX,
            keychain: keychain,
            localStaticKey: bobStaticKey
        )

        #expect(throws: (any Error).self) {
            try responder.readMessage(Data(repeating: 0x00, count: 31))
        }

        let invalidKeys = [
            Data(),
            Data(repeating: 0x00, count: 32),
            Data([0x01] + Array(repeating: 0x00, count: 31)),
            Data(repeating: 0xFF, count: 32),
        ]

        for invalidKey in invalidKeys {
            #expect(throws: (any Error).self) {
                _ = try NoiseHandshakeState.validatePublicKey(invalidKey)
            }
        }

        let valid = aliceStaticKey.publicKey.rawRepresentation
        let roundTripped = try NoiseHandshakeState.validatePublicKey(valid)
        #expect(roundTripped.rawRepresentation == valid)

        let initiator = NoiseHandshakeState(
            role: .initiator,
            pattern: .XX,
            keychain: keychain,
            localStaticKey: aliceStaticKey
        )
        let responderForTamper = NoiseHandshakeState(
            role: .responder,
            pattern: .XX,
            keychain: keychain,
            localStaticKey: bobStaticKey
        )

        let message1 = try initiator.writeMessage()
        _ = try responderForTamper.readMessage(message1)
        var message2 = try responderForTamper.writeMessage()
        message2[40] ^= 0x01

        #expect(throws: (any Error).self) {
            try initiator.readMessage(message2)
        }
    }

    @Test("Handshake readers reject invalid ephemeral and truncated static payloads")
    func handshakeReadersRejectInvalidEphemeralAndTruncatedStaticPayloads() throws {
        let invalidEphemeralResponder = NoiseHandshakeState(
            role: .responder,
            pattern: .XX,
            keychain: keychain,
            localStaticKey: bobStaticKey
        )

        #expect(throws: NoiseError.invalidMessage) {
            try invalidEphemeralResponder.readMessage(Data(repeating: 0x00, count: 32))
        }

        let truncatedStaticInitiator = NoiseHandshakeState(
            role: .initiator,
            pattern: .XX,
            keychain: keychain,
            localStaticKey: aliceStaticKey
        )
        _ = try truncatedStaticInitiator.writeMessage()
        let responderEphemeralOnly = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation

        #expect(throws: NoiseError.invalidMessage) {
            try truncatedStaticInitiator.readMessage(responderEphemeralOnly)
        }
    }

    @Test("IK handshake completes and supports transport messages")
    func ikHandshakeCompletesAndSupportsTransportMessages() throws {
        let initiator = NoiseHandshakeState(
            role: .initiator,
            pattern: .IK,
            keychain: keychain,
            localStaticKey: aliceStaticKey,
            remoteStaticKey: bobStaticKey.publicKey
        )
        let responder = NoiseHandshakeState(
            role: .responder,
            pattern: .IK,
            keychain: keychain,
            localStaticKey: bobStaticKey
        )

        let outboundPayload = Data("ik-outbound".utf8)
        let returnPayload = Data("ik-return".utf8)
        let message1 = try initiator.writeMessage(payload: outboundPayload)

        #expect(try responder.readMessage(message1) == outboundPayload)

        let message2 = try responder.writeMessage(payload: returnPayload)
        #expect(try initiator.readMessage(message2) == returnPayload)

        #expect(initiator.isHandshakeComplete())
        #expect(responder.isHandshakeComplete())

        let (initiatorSend, initiatorReceive, initiatorHash) = try initiator.getTransportCiphers(
            useExtractedNonce: true
        )
        let (responderSend, responderReceive, responderHash) = try responder.getTransportCiphers(
            useExtractedNonce: true
        )

        #expect(initiatorHash == responderHash)

        let clientCiphertext = try initiatorSend.encrypt(plaintext: Data("ik-transport".utf8))
        #expect(try responderReceive.decrypt(ciphertext: clientCiphertext) == Data("ik-transport".utf8))

        let serverCiphertext = try responderSend.encrypt(plaintext: Data("ik-response".utf8))
        #expect(try initiatorReceive.decrypt(ciphertext: serverCiphertext) == Data("ik-response".utf8))
    }

    @Test("NK handshake requires a responder static key and supports transport messages")
    func nkHandshakeRequiresStaticAndSupportsTransportMessages() throws {
        let missingStaticInitiator = NoiseHandshakeState(
            role: .initiator,
            pattern: .NK,
            keychain: keychain,
            localStaticKey: aliceStaticKey
        )

        #expect(throws: (any Error).self) {
            try missingStaticInitiator.writeMessage()
        }

        let initiator = NoiseHandshakeState(
            role: .initiator,
            pattern: .NK,
            keychain: keychain,
            localStaticKey: aliceStaticKey,
            remoteStaticKey: bobStaticKey.publicKey
        )
        let responder = NoiseHandshakeState(
            role: .responder,
            pattern: .NK,
            keychain: keychain,
            localStaticKey: bobStaticKey
        )

        let outboundPayload = Data("nk-outbound".utf8)
        let returnPayload = Data("nk-return".utf8)
        let message1 = try initiator.writeMessage(payload: outboundPayload)
        #expect(try responder.readMessage(message1) == outboundPayload)

        let message2 = try responder.writeMessage(payload: returnPayload)
        #expect(try initiator.readMessage(message2) == returnPayload)

        #expect(initiator.isHandshakeComplete())
        #expect(responder.isHandshakeComplete())

        let (initiatorSend, initiatorReceive, initiatorHash) = try initiator.getTransportCiphers(
            useExtractedNonce: true
        )
        let (responderSend, responderReceive, responderHash) = try responder.getTransportCiphers(
            useExtractedNonce: true
        )

        #expect(initiatorHash == responderHash)

        let clientCiphertext = try initiatorSend.encrypt(plaintext: Data("nk-transport".utf8))
        #expect(try responderReceive.decrypt(ciphertext: clientCiphertext) == Data("nk-transport".utf8))

        let serverCiphertext = try responderSend.encrypt(plaintext: Data("nk-response".utf8))
        #expect(try initiatorReceive.decrypt(ciphertext: serverCiphertext) == Data("nk-response".utf8))
    }

    @Test("Responder-side NK writes require peer ephemeral input")
    func responderWritesRequirePeerEphemeralInput() {
        let nkResponder = NoiseHandshakeState(
            role: .responder,
            pattern: .NK,
            keychain: keychain,
            localStaticKey: bobStaticKey
        )

        #expect(throws: NoiseError.missingKeys) {
            try nkResponder.writeMessage()
        }
    }

    @Test("Direct DH helpers reject missing keys across all patterns")
    func directDHHelpersRejectMissingKeysAcrossAllPatterns() throws {
        let eeState = NoiseHandshakeState(
            role: .initiator,
            pattern: .XX,
            keychain: keychain,
            localStaticKey: aliceStaticKey
        )
        #expect(throws: NoiseError.missingKeys) {
            try eeState.performDHOperationForTesting(.ee)
        }

        let esInitiator = NoiseHandshakeState(
            role: .initiator,
            pattern: .XX,
            keychain: keychain,
            localStaticKey: aliceStaticKey
        )
        #expect(throws: NoiseError.missingKeys) {
            try esInitiator.performDHOperationForTesting(.es)
        }

        let esResponder = NoiseHandshakeState(
            role: .responder,
            pattern: .XX,
            keychain: keychain,
            localStaticKey: nil
        )
        #expect(throws: NoiseError.missingKeys) {
            try esResponder.performDHOperationForTesting(.es)
        }

        let seInitiator = NoiseHandshakeState(
            role: .initiator,
            pattern: .XX,
            keychain: keychain,
            localStaticKey: nil
        )
        #expect(throws: NoiseError.missingKeys) {
            try seInitiator.performDHOperationForTesting(.se)
        }

        let seResponder = NoiseHandshakeState(
            role: .responder,
            pattern: .XX,
            keychain: keychain,
            localStaticKey: bobStaticKey
        )
        #expect(throws: NoiseError.missingKeys) {
            try seResponder.performDHOperationForTesting(.se)
        }

        let ssState = NoiseHandshakeState(
            role: .initiator,
            pattern: .XX,
            keychain: keychain,
            localStaticKey: nil
        )
        #expect(throws: NoiseError.missingKeys) {
            try ssState.performDHOperationForTesting(.ss)
        }

        #expect(throws: Never.self) {
            try eeState.performDHOperationForTesting(.e)
            try eeState.performDHOperationForTesting(.s)
        }
    }

    @Test("Prepared handshake writers cover remaining missing-key branches")
    func preparedHandshakeWritersCoverRemainingMissingKeyBranches() {
        let eeResponder = NoiseHandshakeState(
            role: .responder,
            pattern: .NK,
            keychain: keychain,
            localStaticKey: bobStaticKey
        )
        eeResponder.setCurrentPatternForTesting(1)
        #expect(throws: NoiseError.missingKeys) {
            try eeResponder.writeMessage()
        }

        let seInitiator = NoiseHandshakeState(
            role: .initiator,
            pattern: .XX,
            keychain: keychain,
            localStaticKey: aliceStaticKey
        )
        seInitiator.setCurrentPatternForTesting(2)
        #expect(throws: NoiseError.missingKeys) {
            try seInitiator.writeMessage()
        }

        let seResponder = NoiseHandshakeState(
            role: .responder,
            pattern: .IK,
            keychain: keychain,
            localStaticKey: bobStaticKey
        )
        seResponder.setCurrentPatternForTesting(1)
        seResponder.setRemoteEphemeralPublicKeyForTesting(Curve25519.KeyAgreement.PrivateKey().publicKey)
        #expect(throws: NoiseError.missingKeys) {
            try seResponder.writeMessage()
        }
    }

    @Test("Completed handshakes reject additional reads and writes")
    func completedHandshakesRejectAdditionalReadsAndWrites() throws {
        let initiator = NoiseHandshakeState(
            role: .initiator,
            pattern: .IK,
            keychain: keychain,
            localStaticKey: aliceStaticKey,
            remoteStaticKey: bobStaticKey.publicKey
        )
        let responder = NoiseHandshakeState(
            role: .responder,
            pattern: .IK,
            keychain: keychain,
            localStaticKey: bobStaticKey
        )

        let message1 = try initiator.writeMessage(payload: Data("first".utf8))
        _ = try responder.readMessage(message1)
        let message2 = try responder.writeMessage(payload: Data("second".utf8))
        _ = try initiator.readMessage(message2)

        #expect(throws: NoiseError.handshakeComplete) {
            try initiator.writeMessage()
        }
        #expect(throws: NoiseError.handshakeComplete) {
            try responder.readMessage(message1)
        }
    }

    @Test("XX final message requires a local static key")
    func xxFinalMessageRequiresLocalStaticKey() throws {
        let initiator = NoiseHandshakeState(
            role: .initiator,
            pattern: .XX,
            keychain: keychain,
            localStaticKey: nil
        )
        let responder = NoiseHandshakeState(
            role: .responder,
            pattern: .XX,
            keychain: keychain,
            localStaticKey: bobStaticKey
        )

        let message1 = try initiator.writeMessage()
        _ = try responder.readMessage(message1)
        let message2 = try responder.writeMessage()
        _ = try initiator.readMessage(message2)

        #expect(throws: (any Error).self) {
            try initiator.writeMessage()
        }
    }

    @Test("Responder start handshake is empty and transport ciphers require completion")
    func responderStartHandshakeAndIncompleteTransportCiphers() throws {
        let responderSession = NoiseSession(
            peerID: bobPeerID,
            role: .responder,
            keychain: keychain,
            localStaticKey: bobStaticKey
        )
        let incompleteHandshake = NoiseHandshakeState(
            role: .initiator,
            pattern: .XX,
            keychain: keychain,
            localStaticKey: aliceStaticKey
        )

        #expect(try responderSession.startHandshake().isEmpty)
        #expect(responderSession.getState() == .handshaking)

        #expect(throws: (any Error).self) {
            _ = try incompleteHandshake.getTransportCiphers(useExtractedNonce: true)
        }
    }

    @Test("Session manager callbacks establish and failed handshakes clean up state")
    func sessionManagerCallbacksAndFailureCleanup() async throws {
        let establishedRecorder = SessionCallbackRecorder()
        let aliceManager = NoiseSessionManager(localStaticKey: aliceStaticKey, keychain: keychain)
        let bobManager = NoiseSessionManager(localStaticKey: bobStaticKey, keychain: keychain)

        aliceManager.onSessionEstablished = establishedRecorder.recordEstablished(peerID:remoteKey:)
        bobManager.onSessionEstablished = establishedRecorder.recordEstablished(peerID:remoteKey:)

        try establishManagerSessions(aliceManager: aliceManager, bobManager: bobManager)

        let didEstablish = await TestHelpers.waitUntil(
            { establishedRecorder.establishedCount == 2 },
            timeout: 0.5
        )
        #expect(didEstablish)
        #expect(establishedRecorder.establishedPeerIDs.contains(alicePeerID))
        #expect(establishedRecorder.establishedPeerIDs.contains(bobPeerID))

        let failureRecorder = SessionCallbackRecorder()
        let failingManager = NoiseSessionManager(localStaticKey: charlieStaticKey, keychain: keychain)
        failingManager.onSessionFailed = failureRecorder.recordFailure(peerID:error:)

        #expect(throws: (any Error).self) {
            try failingManager.handleIncomingHandshake(
                from: charliePeerID,
                message: Data(repeating: 0x00, count: 31)
            )
        }

        let didFail = await TestHelpers.waitUntil(
            { failureRecorder.failureCount == 1 },
            timeout: 0.5
        )
        #expect(didFail)
        #expect(failingManager.getSession(for: charliePeerID) == nil)
    }

    @Test("Session manager cleans up initiator sessions after start-handshake failures")
    func sessionManagerCleansUpInitiatorSessionsAfterStartHandshakeFailures() {
        let manager = NoiseSessionManager(
            localStaticKey: aliceStaticKey,
            keychain: keychain,
            sessionFactory: { peerID, role in
                FailingNoiseSession(
                    peerID: peerID,
                    role: role,
                    keychain: self.keychain,
                    localStaticKey: self.aliceStaticKey
                )
            }
        )

        #expect(throws: FailingNoiseSession.Error.synthetic) {
            try manager.initiateHandshake(with: alicePeerID)
        }
        #expect(manager.getSession(for: alicePeerID) == nil)
    }

    @Test("Session manager rekeys established sessions and replaces partial handshakes")
    func sessionManagerRekeysAndReplacesSessions() throws {
        let manager = NoiseSessionManager(localStaticKey: aliceStaticKey, keychain: keychain)

        #expect(throws: NoiseSessionError.sessionNotFound) {
            try manager.encrypt(Data("missing".utf8), for: alicePeerID)
        }
        #expect(throws: NoiseSessionError.sessionNotFound) {
            try manager.decrypt(Data("missing".utf8), from: alicePeerID)
        }

        let initialHandshake = try manager.initiateHandshake(with: alicePeerID)
        #expect(!initialHandshake.isEmpty)
        let firstSession = try #require(manager.getSession(for: alicePeerID))

        let restartedHandshake = try manager.initiateHandshake(with: alicePeerID)
        let restartedSession = try #require(manager.getSession(for: alicePeerID))

        #expect(!restartedHandshake.isEmpty)
        #expect(restartedSession !== firstSession)

        let restartedInitiator = NoiseSession(
            peerID: alicePeerID,
            role: .initiator,
            keychain: keychain,
            localStaticKey: bobStaticKey
        )
        let replacementMessage = try restartedInitiator.startHandshake()
        let replacementResponse = try manager.handleIncomingHandshake(
            from: alicePeerID,
            message: replacementMessage
        )
        let replacementSession = try #require(manager.getSession(for: alicePeerID))

        #expect(replacementResponse != nil)
        #expect(replacementSession !== restartedSession)

        let aliceManager = NoiseSessionManager(localStaticKey: aliceStaticKey, keychain: keychain)
        let bobManager = NoiseSessionManager(localStaticKey: bobStaticKey, keychain: keychain)
        try establishManagerSessions(aliceManager: aliceManager, bobManager: bobManager)

        let establishedSession = try #require(
            aliceManager.getSession(for: alicePeerID) as? SecureNoiseSession
        )
        establishedSession.setMessageCountForTesting(
            UInt64(Double(NoiseSecurityConstants.maxMessagesPerSession) * 0.9)
        )

        let sessionsNeedingRekey = aliceManager.getSessionsNeedingRekey()
        #expect(sessionsNeedingRekey.contains { $0.peerID == alicePeerID && $0.needsRekey })

        #expect(throws: NoiseSessionError.alreadyEstablished) {
            try aliceManager.initiateHandshake(with: alicePeerID)
        }

        try aliceManager.initiateRekey(for: alicePeerID)
        let rekeyedSession = try #require(aliceManager.getSession(for: alicePeerID))

        #expect(rekeyedSession !== establishedSession)
        #expect(rekeyedSession.getState() == .handshaking)
    }

    @Test("Secure noise sessions enforce limits and renegotiation thresholds")
    func secureNoiseSessionsEnforceLimitsAndThresholds() throws {
        let initiator = SecureNoiseSession(
            peerID: alicePeerID,
            role: .initiator,
            keychain: keychain,
            localStaticKey: aliceStaticKey
        )
        let responder = SecureNoiseSession(
            peerID: bobPeerID,
            role: .responder,
            keychain: keychain,
            localStaticKey: bobStaticKey
        )

        try establishSessions(initiator: initiator, responder: responder)

        responder.setMessageCountForTesting(0)
        responder.setLastActivityTimeForTesting(Date())
        #expect(!responder.needsRenegotiation())

        responder.setMessageCountForTesting(
            UInt64(Double(NoiseSecurityConstants.maxMessagesPerSession) * 0.9)
        )
        #expect(responder.needsRenegotiation())

        responder.setMessageCountForTesting(0)
        responder.setLastActivityTimeForTesting(
            Date().addingTimeInterval(-(NoiseSecurityConstants.sessionTimeout + 1))
        )
        #expect(responder.needsRenegotiation())

        initiator.setMessageCountForTesting(NoiseSecurityConstants.maxMessagesPerSession)
        #expect(throws: (any Error).self) {
            try initiator.encrypt(Data("exhausted".utf8))
        }

        initiator.setMessageCountForTesting(0)
        #expect(throws: (any Error).self) {
            try initiator.encrypt(Data(repeating: 0xAB, count: NoiseSecurityConstants.maxMessageSize + 1))
        }

        responder.setLastActivityTimeForTesting(Date())
        #expect(throws: (any Error).self) {
            try responder.decrypt(
                Data(repeating: 0xCD, count: NoiseSecurityConstants.maxMessageSize + 1)
            )
        }

        let transportCiphertext = try initiator.encrypt(Data("secure-session".utf8))
        #expect(try responder.decrypt(transportCiphertext) == Data("secure-session".utf8))
    }

    @Test("Secure noise sessions expire based on session start time")
    func secureNoiseSessionsExpireBasedOnSessionStartTime() throws {
        let initiator = SecureNoiseSession(
            peerID: alicePeerID,
            role: .initiator,
            keychain: keychain,
            localStaticKey: aliceStaticKey
        )
        let responder = SecureNoiseSession(
            peerID: bobPeerID,
            role: .responder,
            keychain: keychain,
            localStaticKey: bobStaticKey
        )

        try establishSessions(initiator: initiator, responder: responder)

        initiator.setSessionStartTimeForTesting(
            Date().addingTimeInterval(-(NoiseSecurityConstants.sessionTimeout + 1))
        )
        #expect(throws: (any Error).self) {
            try initiator.encrypt(Data("expired".utf8))
        }

        responder.setSessionStartTimeForTesting(
            Date().addingTimeInterval(-(NoiseSecurityConstants.sessionTimeout + 1))
        )
        #expect(throws: (any Error).self) {
            try responder.decrypt(Data())
        }
    }

    @Test("Rate limiter handles global message caps and per-peer resets")
    func rateLimiterGlobalMessageCapAndReset() async throws {
        let globalLimiter = NoiseRateLimiter()
        for index in 0..<NoiseSecurityConstants.maxGlobalMessagesPerSecond {
            #expect(globalLimiter.allowMessage(from: PeerID(str: "peer-\(index)")))
        }
        #expect(!globalLimiter.allowMessage(from: charliePeerID))

        let peerLimiter = NoiseRateLimiter()
        for _ in 0..<NoiseSecurityConstants.maxMessagesPerSecond {
            #expect(peerLimiter.allowMessage(from: alicePeerID))
        }
        #expect(!peerLimiter.allowMessage(from: alicePeerID))

        peerLimiter.reset(for: alicePeerID)
        try await sleep(0.05)
        #expect(peerLimiter.allowMessage(from: alicePeerID))
    }

    @Test("Cipher state decrypts high extracted nonces and rejects truncated extracted payloads")
    func cipherStateDecryptsHighExtractedNoncesAndRejectsTruncatedPayloads() throws {
        let key = SymmetricKey(size: .bits256)
        let receiver = NoiseCipherState(key: key, useExtractedNonce: true)
        let highNoncePayload = try makeExtractedNoncePayload(
            key: key,
            nonce: 1_000_000_001,
            plaintext: Data("high-nonce".utf8)
        )

        #expect(try receiver.decrypt(ciphertext: highNoncePayload) == Data("high-nonce".utf8))
        #expect(throws: NoiseError.invalidCiphertext) {
            try receiver.decrypt(ciphertext: extractedNoncePrefix(7))
        }
    }

    private func establishSessions(initiator: NoiseSession, responder: NoiseSession) throws {
        let message1 = try initiator.startHandshake()
        let response2 = try responder.processHandshakeMessage(message1)
        let message2 = try #require(response2)
        let response3 = try initiator.processHandshakeMessage(message2)
        let message3 = try #require(response3)
        let final = try responder.processHandshakeMessage(message3)
        #expect(final == nil)
    }

    private func establishManagerSessions(
        aliceManager: NoiseSessionManager,
        bobManager: NoiseSessionManager
    ) throws {
        let message1 = try aliceManager.initiateHandshake(with: alicePeerID)
        let response2 = try bobManager.handleIncomingHandshake(from: bobPeerID, message: message1)
        let message2 = try #require(response2)
        let response3 = try aliceManager.handleIncomingHandshake(from: alicePeerID, message: message2)
        let message3 = try #require(response3)
        let final = try bobManager.handleIncomingHandshake(from: bobPeerID, message: message3)
        #expect(final == nil)
    }

    private func makeExtractedNoncePayload(
        key: SymmetricKey,
        nonce: UInt64,
        plaintext: Data,
        associatedData: Data = Data()
    ) throws -> Data {
        var fullNonce = Data(count: 12)
        withUnsafeBytes(of: nonce.littleEndian) { bytes in
            fullNonce.replaceSubrange(4..<12, with: bytes)
        }

        let sealedBox = try ChaChaPoly.seal(
            plaintext,
            using: key,
            nonce: ChaChaPoly.Nonce(data: fullNonce),
            authenticating: associatedData
        )

        return extractedNoncePrefix(nonce) + sealedBox.ciphertext + sealedBox.tag
    }

    private func extractedNoncePrefix(_ nonce: UInt64) -> Data {
        withUnsafeBytes(of: nonce.bigEndian) { bytes in
            Data(bytes.suffix(4))
        }
    }
}

private final class SessionCallbackRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var establishedEntries: [(PeerID, Data)] = []
    private var failureEntries: [(PeerID, String)] = []

    var establishedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return establishedEntries.count
    }

    var failureCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return failureEntries.count
    }

    var establishedPeerIDs: [PeerID] {
        lock.lock()
        defer { lock.unlock() }
        return establishedEntries.map(\.0)
    }

    func recordEstablished(peerID: PeerID, remoteKey: Curve25519.KeyAgreement.PublicKey) {
        lock.lock()
        establishedEntries.append((peerID, remoteKey.rawRepresentation))
        lock.unlock()
    }

    func recordFailure(peerID: PeerID, error: Error) {
        lock.lock()
        failureEntries.append((peerID, String(describing: error)))
        lock.unlock()
    }
}

private final class FailingNoiseSession: NoiseSession {
    enum Error: Swift.Error {
        case synthetic
    }

    override func startHandshake() throws -> Data {
        throw Error.synthetic
    }
}
