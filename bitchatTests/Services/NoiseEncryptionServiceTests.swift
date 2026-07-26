import Foundation
import Testing
import BitFoundation
@testable import bitchat

@Suite("NoiseEncryptionService Tests", .serialized)
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

        let authenticated = await TestHelpers.waitUntil({ recorder.count >= 2 }, timeout: TestConstants.settleTimeout)
        #expect(authenticated)
        let generationAuthenticated = await TestHelpers.waitUntil(
            { recorder.generationCount >= 1 },
            timeout: TestConstants.settleTimeout
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
            timeout: TestConstants.negativeWaitWindow
        )
        #expect(!emittedAuthentication)
    }

    @Test("Failed forged reconnect restores the established peer session")
    func forgedReconnectRestoresEstablishedSession() async throws {
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
        // Outbound/session-generation APIs fail closed while the old
        // transport is retained solely for receive and bounded rollback.
        #expect(!receiver.hasEstablishedSession(with: alicePeerID))
        let forgedMessage3 = try #require(
            try mallory.processHandshakeMessage(from: receiverPeerID, message: forgedMessage2)
        )

        do {
            _ = try receiver.processHandshakeMessage(from: alicePeerID, message: forgedMessage3)
            Issue.record("Expected forged reconnect to fail peer binding")
        } catch let error as NoiseSessionError {
            #expect(error == .peerIdentityMismatch)
        } catch {
            Issue.record("Unexpected reconnect error: \(error)")
        }

        #expect(receiver.hasEstablishedSession(with: alicePeerID))
        let after = try alice.encrypt(Data("after".utf8), for: receiverPeerID)
        #expect(try receiver.decrypt(after, from: alicePeerID) == Data("after".utf8))
        let emittedReplacementAuthentication = await TestHelpers.waitUntil(
            { recorder.count > 1 },
            timeout: TestConstants.negativeWaitWindow
        )
        #expect(!emittedReplacementAuthentication)
    }

    @Test("Valid ordinary rehandshake atomically replaces the established session")
    func validOrdinaryRehandshakeReplacesEstablishedSession() throws {
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
        #expect(!receiver.hasEstablishedSession(with: alicePeerID))
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
        var emittedInitiation: NoiseHandshakeInitiation?
        alice.onRekeyHandshakeReady = { peerID, initiation in
            emittedPeerID = peerID
            emittedInitiation = initiation
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
        let initiation = try #require(emittedInitiation)
        let message1 = try #require(
            alice.claimHandshakeInitiation(initiation, for: bobPeerID)
        )
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

    @Test("Concurrent BLE starts preserve one ordinary attempt")
    func duplicateHandshakeIfNeededPreservesFirstAttempt() throws {
        let alice = NoiseEncryptionService(keychain: MockKeychain())
        let bob = NoiseEncryptionService(keychain: MockKeychain())
        let alicePeerID = PeerID(publicKey: alice.getStaticPublicKeyData())
        let bobPeerID = PeerID(publicKey: bob.getStaticPublicKeyData())
        let starts = HandshakeInitiationRecorder()

        DispatchQueue.concurrentPerform(iterations: 20) { _ in
            do {
                starts.record(
                    try alice.initiateHandshakeIfNeeded(with: bobPeerID)
                )
            } catch {
                starts.record(error: error)
            }
        }

        #expect(starts.errorCount == 0)
        let attempt = try #require(starts.initiations.first)
        #expect(starts.initiations.count == 1)
        let message1 = try #require(
            alice.claimHandshakeInitiation(attempt, for: bobPeerID)
        )
        let message2 = try #require(
            try bob.processHandshakeMessage(from: alicePeerID, message: message1)
        )
        let message3 = try #require(
            try alice.processHandshakeMessage(from: bobPeerID, message: message2)
        )
        _ = try bob.processHandshakeMessage(from: alicePeerID, message: message3)

        let ciphertext = try alice.encrypt(
            Data("one atomic start".utf8),
            for: bobPeerID
        )
        #expect(
            try bob.decrypt(ciphertext, from: alicePeerID)
                == Data("one atomic start".utf8)
        )
    }

    @Test("Restarted peer establishes against a retained ordinary session")
    func restartedPeerCompletesRetainedRemoteRehandshake() throws {
        let aliceKeychain = MockKeychain()
        let alice = NoiseEncryptionService(keychain: aliceKeychain)
        let bob = NoiseEncryptionService(keychain: MockKeychain())
        let alicePeerID = PeerID(publicKey: alice.getStaticPublicKeyData())
        let bobPeerID = PeerID(publicKey: bob.getStaticPublicKeyData())
        try establishSessions(alice: alice, bob: bob)

        let restartedAlice = NoiseEncryptionService(keychain: aliceKeychain)
        let attempt = try #require(
            try restartedAlice.initiateHandshakeIfNeeded(with: bobPeerID)
        )
        #expect(
            try restartedAlice.initiateHandshakeIfNeeded(with: bobPeerID)
                == nil
        )
        let message1 = try #require(
            restartedAlice.claimHandshakeInitiation(
                attempt,
                for: bobPeerID
            )
        )
        let message2 = try #require(
            try bob.processHandshakeMessage(from: alicePeerID, message: message1)
        )
        let message3 = try #require(
            try restartedAlice.processHandshakeMessage(
                from: bobPeerID,
                message: message2
            )
        )
        _ = try bob.processHandshakeMessage(from: alicePeerID, message: message3)

        let forward = try restartedAlice.encrypt(
            Data("after restart".utf8),
            for: bobPeerID
        )
        #expect(
            try bob.decrypt(forward, from: alicePeerID)
                == Data("after restart".utf8)
        )
    }

    @Test("Crossed ordinary initiations choose one deterministic initiator")
    func crossedOrdinaryInitiationsResolveDeterministically() throws {
        let endpoints = orderedServices()
        let lowerAttempt = try #require(
            try endpoints.lower.initiateHandshakeIfNeeded(
                with: endpoints.higherPeerID
            )
        )
        let higherAttempt = try #require(
            try endpoints.higher.initiateHandshakeIfNeeded(
                with: endpoints.lowerPeerID
            )
        )
        let lowerMessage1 = try #require(
            endpoints.lower.claimHandshakeInitiation(
                lowerAttempt,
                for: endpoints.higherPeerID
            )
        )
        let higherMessage1 = try #require(
            endpoints.higher.claimHandshakeInitiation(
                higherAttempt,
                for: endpoints.lowerPeerID
            )
        )

        #expect(
            try endpoints.lower.processHandshakeMessage(
                from: endpoints.higherPeerID,
                message: higherMessage1
            ) == nil
        )
        let message2 = try #require(
            try endpoints.higher.processHandshakeMessage(
                from: endpoints.lowerPeerID,
                message: lowerMessage1
            )
        )
        let message3 = try #require(
            try endpoints.lower.processHandshakeMessage(
                from: endpoints.higherPeerID,
                message: message2
            )
        )
        _ = try endpoints.higher.processHandshakeMessage(
            from: endpoints.lowerPeerID,
            message: message3
        )

        let ciphertext = try endpoints.lower.encrypt(
            Data("crossed".utf8),
            for: endpoints.higherPeerID
        )
        #expect(
            try endpoints.higher.decrypt(
                ciphertext,
                from: endpoints.lowerPeerID
            ) == Data("crossed".utf8)
        )
    }

    @Test("Delayed losing message one cannot replace the fresh winner")
    func delayedCrossedInitiationIsSuppressed() throws {
        let endpoints = orderedServices()
        let lowerAttempt = try #require(
            try endpoints.lower.initiateHandshakeIfNeeded(
                with: endpoints.higherPeerID
            )
        )
        let higherAttempt = try #require(
            try endpoints.higher.initiateHandshakeIfNeeded(
                with: endpoints.lowerPeerID
            )
        )
        let lowerMessage1 = try #require(
            endpoints.lower.claimHandshakeInitiation(
                lowerAttempt,
                for: endpoints.higherPeerID
            )
        )
        let delayedHigherMessage1 = try #require(
            endpoints.higher.claimHandshakeInitiation(
                higherAttempt,
                for: endpoints.lowerPeerID
            )
        )

        let message2 = try #require(
            try endpoints.higher.processHandshakeMessage(
                from: endpoints.lowerPeerID,
                message: lowerMessage1
            )
        )
        let message3 = try #require(
            try endpoints.lower.processHandshakeMessage(
                from: endpoints.higherPeerID,
                message: message2
            )
        )
        #expect(
            try endpoints.lower.processHandshakeMessage(
                from: endpoints.higherPeerID,
                message: delayedHigherMessage1
            ) == nil
        )
        _ = try endpoints.higher.processHandshakeMessage(
            from: endpoints.lowerPeerID,
            message: message3
        )

        let ciphertext = try endpoints.higher.encrypt(
            Data("winner intact".utf8),
            for: endpoints.lowerPeerID
        )
        #expect(
            try endpoints.lower.decrypt(
                ciphertext,
                from: endpoints.higherPeerID
            ) == Data("winner intact".utf8)
        )
    }

    @Test("Automatic rekey token dies if an inbound initiation wins first")
    func automaticRekeyClaimsOnlyAtTransportHandoff() throws {
        let endpoints = orderedServices()
        try establishSessions(
            alice: endpoints.lower,
            bob: endpoints.higher
        )

        var preparedRekey: NoiseHandshakeInitiation?
        endpoints.higher.onRekeyHandshakeReady = { _, initiation in
            preparedRekey = initiation
        }
        try endpoints.higher._test_initiateAutomaticRekey(
            for: endpoints.lowerPeerID
        )
        let staleRekey = try #require(preparedRekey)

        let winningAttempt = try endpoints.lower.initiateReconnectHandshake(
            with: endpoints.higherPeerID
        )
        let winningMessage1 = try #require(
            endpoints.lower.claimHandshakeInitiation(
                winningAttempt,
                for: endpoints.higherPeerID
            )
        )
        let message2 = try #require(
            try endpoints.higher.processHandshakeMessage(
                from: endpoints.lowerPeerID,
                message: winningMessage1
            )
        )
        #expect(
            endpoints.higher.claimHandshakeInitiation(
                staleRekey,
                for: endpoints.lowerPeerID
            ) == nil
        )
        let message3 = try #require(
            try endpoints.lower.processHandshakeMessage(
                from: endpoints.higherPeerID,
                message: message2
            )
        )
        _ = try endpoints.higher.processHandshakeMessage(
            from: endpoints.lowerPeerID,
            message: message3
        )
        #expect(
            endpoints.higher.hasEstablishedSession(
                with: endpoints.lowerPeerID
            )
        )
    }

    @Test("Ordinary timeout produces exactly one bounded retry")
    func ordinaryInitiationTimeoutIsBounded() async throws {
        let service = NoiseEncryptionService(
            keychain: MockKeychain(),
            ordinaryHandshakeTimeout: 0.03
        )
        let peerID = PeerID(str: "1021324354657687")
        let recorder = HandshakeStartRecorder()
        service.onHandshakeRecoveryRequired = { [weak service] request in
            guard let service else { return }
            do {
                let payload = try claimPreparedRecoveryPayload(
                    service,
                    request: request
                )
                recorder.recordTimeout()
                recorder.record(message: payload)
            } catch {
                recorder.record(error: error)
            }
        }

        let first = try #require(
            try service.initiateHandshakeIfNeeded(
                with: peerID,
                retryOnTimeout: true
            )
        )
        #expect(
            service.claimHandshakeInitiation(first, for: peerID) != nil
        )
        let retried = await TestHelpers.waitUntil(
            { recorder.messages.count == 1 },
            timeout: TestConstants.longTimeout
        )
        #expect(retried)
        let retryExpired = await TestHelpers.waitUntil(
            { !service.hasSession(with: peerID) },
            timeout: TestConstants.longTimeout
        )
        #expect(retryExpired)
        #expect(recorder.timeoutCount == 1)
        #expect(recorder.errorCount == 0)
    }

    @Test("Claim gives an attempt a full on-wire timeout window")
    func handshakeClaimRearmsDeadline() async throws {
        let timeoutInterval: TimeInterval = 1
        let service = NoiseEncryptionService(
            keychain: MockKeychain(),
            ordinaryHandshakeTimeout: timeoutInterval
        )
        let peerID = PeerID(str: "1021324354657687")
        let recorder = HandshakeStartRecorder()
        service.onHandshakeRecoveryRequired = { [weak service] request in
            let firedAt = DispatchTime.now().uptimeNanoseconds
            service?.cancelHandshakeRecovery(request)
            recorder.recordTimeout(at: firedAt)
        }

        let attempt = try #require(
            try service.initiateHandshakeIfNeeded(
                with: peerID,
                retryOnTimeout: true
            )
        )
        try? await Task.sleep(nanoseconds: 500_000_000)
        let claimed = service.claimHandshakeInitiation(attempt, for: peerID)
        let claimedAt = DispatchTime.now().uptimeNanoseconds
        #expect(claimed == attempt.payload)
        let expired = await TestHelpers.waitUntil(
            { recorder.timeoutCount == 1 },
            timeout: 5
        )
        #expect(expired)
        let firedAt = try #require(recorder.firstTimeoutUptimeNanoseconds)
        try #require(firedAt >= claimedAt)
        let elapsed = TimeInterval(firedAt - claimedAt) / 1_000_000_000
        // A non-rearmed deadline would fire roughly 0.5 seconds after the
        // claim. Measure on the timeout queue instead of relying on a task to
        // resume inside a narrow pre-deadline window under parallel CI load.
        #expect(elapsed >= timeoutInterval * 0.75)
        #expect(!service.hasSession(with: peerID))
        #expect(recorder.timeoutCount == 1)
    }

    @Test("Duplicate spoofed message one cannot extend rollback or repause during cooldown")
    func pacedMessageOneCannotHoldOutboundPaused() async throws {
        let alice = NoiseEncryptionService(keychain: MockKeychain())
        let bob = NoiseEncryptionService(
            keychain: MockKeychain(),
            // Generous for the same reason as the quarantine-restore test
            // (#1483): this timeout also arms during the `establishSessions`
            // setup handshake below, where bob is the responder. At 0.06 a
            // preempted runner could fire it mid-setup, tear down the half-open
            // responder, and make message 3 be answered as a fresh initiation.
            ordinaryResponderHandshakeTimeout: 1.0,
            ordinaryReconnectRollbackCooldown: 0.3
        )
        let mallory = NoiseEncryptionService(keychain: MockKeychain())
        let alicePeerID = PeerID(publicKey: alice.getStaticPublicKeyData())
        let bobPeerID = PeerID(publicKey: bob.getStaticPublicKeyData())
        let recovery = HandshakeStartRecorder()
        bob.onHandshakeRecoveryRequired = { [weak bob] request in
            bob?.cancelHandshakeRecovery(request)
            recovery.recordTimeout()
        }
        try establishSessions(alice: alice, bob: bob)

        let spoofedMessage1 = try mallory.initiateHandshake(with: bobPeerID)
        _ = try #require(
            try bob.processHandshakeMessage(
                from: alicePeerID,
                message: spoofedMessage1
            )
        )
        // Exercise replacement before yielding: the test runner may resume a
        // short sleep after the fixed responder deadline under parallel load.
        _ = try #require(
            try bob.processHandshakeMessage(
                from: alicePeerID,
                message: spoofedMessage1
            )
        )

        let restored = await TestHelpers.waitUntil(
            { bob.hasEstablishedSession(with: alicePeerID) },
            timeout: TestConstants.longTimeout
        )
        #expect(restored)
        let callbackArrived = await TestHelpers.waitUntil(
            { recovery.timeoutCount == 1 },
            timeout: TestConstants.longTimeout
        )
        #expect(callbackArrived)

        // Still inside cooldown: the same unauthenticated initiation is
        // coalesced without removing the restored outbound generation.
        #expect(
            try bob.processHandshakeMessage(
                from: alicePeerID,
                message: spoofedMessage1
            ) == nil
        )
        #expect(bob.hasEstablishedSession(with: alicePeerID))
        let ciphertext = try alice.encrypt(
            Data("not repaused".utf8),
            for: bobPeerID
        )
        #expect(
            try bob.decrypt(ciphertext, from: alicePeerID)
                == Data("not repaused".utf8)
        )
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(recovery.timeoutCount == 1)
    }

    @Test("Lost reconnect message three restores then retries once")
    func lostReconnectCompletionGetsOneLocalRetry() async throws {
        let alice = NoiseEncryptionService(
            keychain: MockKeychain(),
            ordinaryHandshakeTimeout: 0.04
        )
        let bob = NoiseEncryptionService(
            keychain: MockKeychain(),
            ordinaryHandshakeTimeout: 0.04,
            // Also arms during the `establishSessions` setup handshake below,
            // where bob is the responder. Observed failing on a loaded CI
            // runner with exactly the signature #1483 documented: the setup's
            // `#expect(finalMessage == nil)` saw a 96-byte message 2, because
            // the half-open responder had already been torn down and message 3
            // was answered as a fresh initiation.
            ordinaryResponderHandshakeTimeout: 1.0
        )
        let alicePeerID = PeerID(publicKey: alice.getStaticPublicKeyData())
        let bobPeerID = PeerID(publicKey: bob.getStaticPublicKeyData())
        try establishSessions(alice: alice, bob: bob)
        alice.clearSession(for: bobPeerID)

        let recovery = HandshakeStartRecorder()
        bob.onHandshakeRecoveryRequired = { [weak bob] request in
            guard let bob else { return }
            do {
                recovery.recordTimeout()
                recovery.record(
                    message: try claimPreparedRecoveryPayload(
                        bob,
                        request: request
                    )
                )
            } catch {
                recovery.record(error: error)
            }
        }

        let message1 = try alice.initiateHandshake(with: bobPeerID)
        let message2 = try #require(
            try bob.processHandshakeMessage(from: alicePeerID, message: message1)
        )
        _ = try #require(
            try alice.processHandshakeMessage(from: bobPeerID, message: message2)
        )
        // Drop message 3. Bob restores its old receive-only transport and
        // initiates one bounded convergence retry; drop that message 1 too.
        let retryPrepared = await TestHelpers.waitUntil(
            { recovery.messages.count == 1 },
            timeout: TestConstants.longTimeout
        )
        #expect(retryPrepared)
        let retryExpired = await TestHelpers.waitUntil(
            { !bob.hasSession(with: alicePeerID) },
            timeout: TestConstants.longTimeout
        )
        #expect(retryExpired)
        #expect(recovery.timeoutCount == 1)
        #expect(recovery.errorCount == 0)
    }

    @Test("Deterministic responder recovers once from an always-yield peer")
    func yieldedResponderRecoversFromLegacyDoubleYield() async throws {
        let timeoutInterval: TimeInterval = 1
        let endpoints = orderedServices(
            ordinaryHandshakeTimeout: timeoutInterval,
            ordinaryResponderHandshakeTimeout: timeoutInterval
        )
        let modern = endpoints.higher
        let legacy = endpoints.lower
        let recovery = HandshakeStartRecorder()
        modern.onHandshakeRecoveryRequired = { request in
            // Preparing here would arm the retry before the test task can
            // forward message 1. Record the token so preparation and the
            // simulated on-wire exchange remain synchronous.
            recovery.recordTimeout()
            recovery.record(request: request)
        }

        let modernAttempt = try #require(
            try modern.initiateHandshakeIfNeeded(
                with: endpoints.lowerPeerID,
                retryOnTimeout: true
            )
        )
        let legacyAttempt = try #require(
            try legacy.initiateHandshakeIfNeeded(
                with: endpoints.higherPeerID
            )
        )
        let modernMessage1 = try #require(
            modern.claimHandshakeInitiation(
                modernAttempt,
                for: endpoints.lowerPeerID
            )
        )
        let legacyMessage1 = try #require(
            legacy.claimHandshakeInitiation(
                legacyAttempt,
                for: endpoints.higherPeerID
            )
        )

        let modernMessage2 = try #require(
            try modern.processHandshakeMessage(
                from: endpoints.lowerPeerID,
                message: legacyMessage1
            )
        )
        // Released peers yielded regardless of ID. Clearing their local
        // initiator reproduces that role choice without changing wire bytes.
        legacy.clearSession(for: endpoints.higherPeerID)
        let legacyMessage2 = try #require(
            try legacy.processHandshakeMessage(
                from: endpoints.higherPeerID,
                message: modernMessage1
            )
        )

        do {
            _ = try modern.processHandshakeMessage(
                from: endpoints.lowerPeerID,
                message: legacyMessage2
            )
            Issue.record("Expected the crossed responder message to fail")
        } catch is NoiseManagedHandshakeFailure {
            // The manager owns the single retry.
        } catch {
            Issue.record("Unexpected managed failure: \(error)")
        }
        do {
            _ = try legacy.processHandshakeMessage(
                from: endpoints.higherPeerID,
                message: modernMessage2
            )
            Issue.record("Expected the legacy responder message to fail")
        } catch {
            // Expected; this side did not own retry intent.
        }

        let recoveryRequested = await TestHelpers.waitUntil(
            { recovery.requests.count == 1 },
            timeout: 5
        )
        #expect(recoveryRequested)
        let recoveryRequest = try #require(recovery.requests.first)
        let retryMessage1 = try #require(
            try claimPreparedRecoveryPayload(
                modern,
                request: recoveryRequest
            )
        )
        let retryMessage2 = try #require(
            try legacy.processHandshakeMessage(
                from: endpoints.higherPeerID,
                message: retryMessage1
            )
        )
        let retryMessage3 = try #require(
            try modern.processHandshakeMessage(
                from: endpoints.lowerPeerID,
                message: retryMessage2
            )
        )
        _ = try legacy.processHandshakeMessage(
            from: endpoints.higherPeerID,
            message: retryMessage3
        )
        try? await Task.sleep(
            nanoseconds: UInt64(timeoutInterval * 1_200_000_000)
        )
        #expect(recovery.timeoutCount == 1)
        let ciphertext = try modern.encrypt(
            Data("legacy converged".utf8),
            for: endpoints.lowerPeerID
        )
        #expect(
            try legacy.decrypt(
                ciphertext,
                from: endpoints.higherPeerID
            ) == Data("legacy converged".utf8)
        )
    }

    @Test("Immediate legacy restart during completion grace converges once")
    func immediateLegacyRestartDuringCompletionGrace() async throws {
        let firstKeychain = MockKeychain()
        let secondKeychain = MockKeychain()
        let first = NoiseEncryptionService(
            keychain: firstKeychain,
            recentInitiatorCompletionGracePeriod: 0.03
        )
        let second = NoiseEncryptionService(
            keychain: secondKeychain,
            recentInitiatorCompletionGracePeriod: 0.03
        )
        let firstPeerID = PeerID(publicKey: first.getStaticPublicKeyData())
        let secondPeerID = PeerID(publicKey: second.getStaticPublicKeyData())

        let lower: NoiseEncryptionService
        let higher: NoiseEncryptionService
        let higherKeychain: MockKeychain
        let lowerPeerID: PeerID
        let higherPeerID: PeerID
        if firstPeerID < secondPeerID {
            lower = first
            lowerPeerID = firstPeerID
            higher = second
            higherKeychain = secondKeychain
            higherPeerID = secondPeerID
        } else {
            lower = second
            lowerPeerID = secondPeerID
            higher = first
            higherKeychain = firstKeychain
            higherPeerID = firstPeerID
        }
        try establishSessions(alice: lower, bob: higher)

        let restartedHigher = NoiseEncryptionService(keychain: higherKeychain)
        let recovery = HandshakeStartRecorder()
        lower.onHandshakeRecoveryRequired = { [weak lower] request in
            guard let lower else { return }
            do {
                recovery.recordTimeout()
                recovery.record(
                    message: try claimPreparedRecoveryPayload(
                        lower,
                        request: request
                    )
                )
            } catch {
                recovery.record(error: error)
            }
        }

        let restartAttempt = try #require(
            try restartedHigher.initiateHandshakeIfNeeded(with: lowerPeerID)
        )
        let restartMessage1 = try #require(
            restartedHigher.claimHandshakeInitiation(
                restartAttempt,
                for: lowerPeerID
            )
        )
        #expect(
            try lower.processHandshakeMessage(
                from: higherPeerID,
                message: restartMessage1
            ) == nil
        )
        #expect(
            try lower.processHandshakeMessage(
                from: higherPeerID,
                message: restartMessage1
            ) == nil
        )
        #expect(lower.hasEstablishedSession(with: higherPeerID))

        let requested = await TestHelpers.waitUntil(
            { recovery.messages.count == 1 },
            timeout: TestConstants.longTimeout
        )
        #expect(requested)
        let retryMessage1 = try #require(recovery.messages.first)
        let retryMessage2 = try #require(
            try restartedHigher.processHandshakeMessage(
                from: lowerPeerID,
                message: retryMessage1
            )
        )
        let retryMessage3 = try #require(
            try lower.processHandshakeMessage(
                from: higherPeerID,
                message: retryMessage2
            )
        )
        _ = try restartedHigher.processHandshakeMessage(
            from: lowerPeerID,
            message: retryMessage3
        )
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(recovery.timeoutCount == 1)
        #expect(recovery.errorCount == 0)
        let ciphertext = try restartedHigher.encrypt(
            Data("restart converged".utf8),
            for: lowerPeerID
        )
        #expect(
            try lower.decrypt(ciphertext, from: higherPeerID)
                == Data("restart converged".utf8)
        )
    }

    @Test("Atomic reconnect retires old sending keys before message one")
    func atomicReconnectQueuesUntilOrdinaryHandshakeCompletes() throws {
        let alice = NoiseEncryptionService(keychain: MockKeychain())
        let bob = NoiseEncryptionService(keychain: MockKeychain())
        let alicePeerID = PeerID(publicKey: alice.getStaticPublicKeyData())
        let bobPeerID = PeerID(publicKey: bob.getStaticPublicKeyData())

        try establishSessions(alice: alice, bob: bob)
        let oldCiphertext = try alice.encrypt(Data("old transport".utf8), for: bobPeerID)
        #expect(try bob.decrypt(oldCiphertext, from: alicePeerID) == Data("old transport".utf8))

        let initiation = try alice.initiateReconnectHandshake(with: bobPeerID)
        #expect(alice.hasSession(with: bobPeerID))
        #expect(!alice.hasEstablishedSession(with: bobPeerID))
        do {
            _ = try alice.encrypt(Data("must queue".utf8), for: bobPeerID)
            Issue.record("Expected encryption to wait for the reconnect")
        } catch NoiseEncryptionError.handshakeRequired {
            // Expected: BLE queues behind the ordinary handshaking session.
        } catch {
            Issue.record("Unexpected in-window encryption error: \(error)")
        }

        let message1 = try #require(
            alice.claimHandshakeInitiation(initiation, for: bobPeerID)
        )
        bob.clearSession(for: alicePeerID)
        let message2 = try #require(
            try bob.processHandshakeMessage(from: alicePeerID, message: message1)
        )
        let message3 = try #require(
            try alice.processHandshakeMessage(from: bobPeerID, message: message2)
        )
        _ = try bob.processHandshakeMessage(from: alicePeerID, message: message3)

        let fresh = try alice.encrypt(Data("fresh transport".utf8), for: bobPeerID)
        #expect(try bob.decrypt(fresh, from: alicePeerID) == Data("fresh transport".utf8))
    }

    @Test("Inbound reconnect quarantines old sending keys until identity proof")
    func inboundReconnectQuarantinesOldTransport() throws {
        let restarted = NoiseEncryptionService(keychain: MockKeychain())
        let retained = NoiseEncryptionService(keychain: MockKeychain())
        let restartedPeerID = PeerID(publicKey: restarted.getStaticPublicKeyData())
        let retainedPeerID = PeerID(publicKey: retained.getStaticPublicKeyData())

        try establishSessions(alice: restarted, bob: retained)
        let inFlightOldCiphertext = try restarted.encrypt(
            Data("old receive-only transport".utf8),
            for: retainedPeerID
        )
        restarted.clearSession(for: retainedPeerID)

        let message1 = try restarted.initiateHandshake(with: retainedPeerID)
        let message2 = try #require(
            try retained.processHandshakeMessage(
                from: restartedPeerID,
                message: message1
            )
        )
        #expect(!retained.hasEstablishedSession(with: restartedPeerID))
        #expect(
            try retained.decrypt(
                inFlightOldCiphertext,
                from: restartedPeerID
            ) == Data("old receive-only transport".utf8)
        )
        do {
            _ = try retained.encrypt(
                Data("must queue at responder".utf8),
                for: restartedPeerID
            )
            Issue.record("Expected quarantined responder encryption to wait")
        } catch NoiseEncryptionError.handshakeRequired {
            // Expected.
        } catch {
            Issue.record("Unexpected quarantine encryption error: \(error)")
        }

        let message3 = try #require(
            try restarted.processHandshakeMessage(
                from: retainedPeerID,
                message: message2
            )
        )
        _ = try retained.processHandshakeMessage(
            from: restartedPeerID,
            message: message3
        )

        let fresh = try retained.encrypt(
            Data("identity proved".utf8),
            for: restartedPeerID
        )
        #expect(
            try restarted.decrypt(fresh, from: retainedPeerID)
                == Data("identity proved".utf8)
        )
    }

    @Test("Malformed handshake bytes cannot tear down an established session")
    func establishedSessionIgnoresNonInitialHandshakeGarbage() throws {
        let alice = NoiseEncryptionService(keychain: MockKeychain())
        let bob = NoiseEncryptionService(keychain: MockKeychain())
        let alicePeerID = PeerID(publicKey: alice.getStaticPublicKeyData())
        let bobPeerID = PeerID(publicKey: bob.getStaticPublicKeyData())
        try establishSessions(alice: alice, bob: bob)

        #expect(
            try bob.processHandshakeMessage(
                from: alicePeerID,
                message: Data(repeating: 0xA5, count: 31)
            ) == nil
        )
        #expect(bob.hasEstablishedSession(with: alicePeerID))
        let ciphertext = try alice.encrypt(
            Data("session survived".utf8),
            for: bobPeerID
        )
        #expect(
            try bob.decrypt(ciphertext, from: alicePeerID)
                == Data("session survived".utf8)
        )
    }

    @Test("Forged reconnect restores the quarantined transport")
    func forgedReconnectRestoresQuarantinedTransport() throws {
        let alice = NoiseEncryptionService(keychain: MockKeychain())
        let bob = NoiseEncryptionService(keychain: MockKeychain())
        let mallory = NoiseEncryptionService(keychain: MockKeychain())
        let alicePeerID = PeerID(publicKey: alice.getStaticPublicKeyData())
        let bobPeerID = PeerID(publicKey: bob.getStaticPublicKeyData())

        try establishSessions(alice: alice, bob: bob)

        let forgedMessage1 = try mallory.initiateHandshake(with: bobPeerID)
        let forgedMessage2 = try #require(
            try bob.processHandshakeMessage(
                from: alicePeerID,
                message: forgedMessage1
            )
        )
        #expect(!bob.hasEstablishedSession(with: alicePeerID))
        let forgedMessage3 = try #require(
            try mallory.processHandshakeMessage(
                from: bobPeerID,
                message: forgedMessage2
            )
        )

        do {
            _ = try bob.processHandshakeMessage(
                from: alicePeerID,
                message: forgedMessage3
            )
            Issue.record("Expected forged static identity to be rejected")
        } catch NoiseSessionError.peerIdentityMismatch {
            // Expected; the manager restores the quarantined transport.
        } catch {
            Issue.record("Unexpected forged reconnect error: \(error)")
        }

        #expect(bob.hasEstablishedSession(with: alicePeerID))
        let oldTransport = try alice.encrypt(
            Data("rollback survived".utf8),
            for: bobPeerID
        )
        #expect(
            try bob.decrypt(oldTransport, from: alicePeerID)
                == Data("rollback survived".utf8)
        )
    }

    @Test("Lost reconnect completion restores the quarantined transport")
    func timedOutReconnectRestoresQuarantinedTransport() async throws {
        let alice = NoiseEncryptionService(keychain: MockKeychain())
        // The injected responder timeout also arms during the ordinary setup
        // handshake below (bob is its responder), where the only work between
        // message 1 and message 3 is two consecutive synchronous statements.
        // It must be generous enough that a preempted runner cannot let the
        // timeout fire mid-setup and tear down the half-open responder — at
        // 20ms a loaded 2-core CI runner did exactly that, so message 3 was
        // answered as a fresh initiation (96-byte message 2) and nothing was
        // ever quarantined.
        let bob = NoiseEncryptionService(
            keychain: MockKeychain(),
            ordinaryResponderHandshakeTimeout: 1.0
        )
        let mallory = NoiseEncryptionService(keychain: MockKeychain())
        let alicePeerID = PeerID(publicKey: alice.getStaticPublicKeyData())
        let bobPeerID = PeerID(publicKey: bob.getStaticPublicKeyData())

        try establishSessions(alice: alice, bob: bob)
        let forgedMessage1 = try mallory.initiateHandshake(with: bobPeerID)
        _ = try #require(
            try bob.processHandshakeMessage(
                from: alicePeerID,
                message: forgedMessage1
            )
        )
        #expect(!bob.hasEstablishedSession(with: alicePeerID))

        // Poll instead of sleeping a fixed interval: the responder timeout
        // fires on bob's manager queue at the quarantine deadline, and a
        // starved runner can delay that work item well past the deadline.
        let restored = await TestHelpers.waitUntil(
            { bob.hasEstablishedSession(with: alicePeerID) },
            timeout: TestConstants.longTimeout
        )
        try #require(
            restored,
            "Responder timeout should restore the quarantined transport"
        )
        let oldTransport = try alice.encrypt(
            Data("timeout rollback".utf8),
            for: bobPeerID
        )
        #expect(
            try bob.decrypt(oldTransport, from: alicePeerID)
                == Data("timeout rollback".utf8)
        )
    }

    @Test("Failed reconnect authorization preserves the established transport")
    func failedReconnectAuthorizationPreservesSession() throws {
        let alice = NoiseEncryptionService(keychain: MockKeychain())
        let bob = NoiseEncryptionService(keychain: MockKeychain())
        let alicePeerID = PeerID(publicKey: alice.getStaticPublicKeyData())
        let bobPeerID = PeerID(publicKey: bob.getStaticPublicKeyData())

        try establishSessions(alice: alice, bob: bob)
        // The initiator exchange consumed two authorizations for this peer.
        for _ in 2..<NoiseSecurityConstants.maxHandshakesPerMinute {
            do {
                _ = try alice.initiateHandshake(with: bobPeerID)
                Issue.record("Expected the established-session guard")
            } catch NoiseSessionError.alreadyEstablished {
                // Expected.
            }
        }

        do {
            _ = try alice.initiateReconnectHandshake(with: bobPeerID)
            Issue.record("Expected reconnect authorization to be rate limited")
        } catch NoiseSecurityError.rateLimitExceeded {
            // Expected before the working session moves.
        } catch {
            Issue.record("Unexpected reconnect authorization error: \(error)")
        }

        #expect(alice.hasEstablishedSession(with: bobPeerID))
        let ciphertext = try alice.encrypt(
            Data("still established".utf8),
            for: bobPeerID
        )
        #expect(
            try bob.decrypt(ciphertext, from: alicePeerID)
                == Data("still established".utf8)
        )
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

    @Test("Responder completion state spans ordinary XX message three")
    func responderCompletionStateTracksOrdinaryHandshake() throws {
        let alice = NoiseEncryptionService(keychain: MockKeychain())
        let bob = NoiseEncryptionService(keychain: MockKeychain())
        let alicePeerID = PeerID(
            publicKey: alice.getStaticPublicKeyData()
        )
        let bobPeerID = PeerID(publicKey: bob.getStaticPublicKeyData())

        let message1 = try alice.initiateHandshake(with: bobPeerID)
        #expect(
            !bob.isAwaitingResponderHandshakeCompletion(with: alicePeerID)
        )

        let message2 = try #require(
            try bob.processHandshakeMessage(
                from: alicePeerID,
                message: message1
            )
        )
        #expect(
            bob.isAwaitingResponderHandshakeCompletion(with: alicePeerID)
        )

        let message3 = try #require(
            try alice.processHandshakeMessage(
                from: bobPeerID,
                message: message2
            )
        )
        #expect(
            bob.isAwaitingResponderHandshakeCompletion(with: alicePeerID)
        )

        _ = try bob.processHandshakeMessage(
            from: alicePeerID,
            message: message3
        )
        #expect(
            !bob.isAwaitingResponderHandshakeCompletion(with: alicePeerID)
        )
    }

    @Test("Transport readiness rejection spends no message budget")
    func transportReadinessRejectionSpendsNoMessageBudget() throws {
        let alice = NoiseEncryptionService(keychain: MockKeychain())
        let bob = NoiseEncryptionService(keychain: MockKeychain())
        let alicePeerID = PeerID(
            publicKey: alice.getStaticPublicKeyData()
        )
        let bobPeerID = PeerID(publicKey: bob.getStaticPublicKeyData())
        try establishSessions(alice: alice, bob: bob)
        let plaintext = Data([
            NoisePayloadType.privateMessage.rawValue,
            0xAB, 0xCD
        ])
        let ciphertext = try alice.encrypt(plaintext, for: bobPeerID)

        for _ in 0...NoiseSecurityConstants.maxMessagesPerSecond {
            do {
                _ = try bob.decryptWithSessionGeneration(
                    ciphertext,
                    from: alicePeerID,
                    establishedGenerationIsReady: { _ in false }
                )
                Issue.record(
                    "Expected transport generation readiness rejection"
                )
            } catch NoiseEncryptionError.transportGenerationNotReady {
                // Expected: authorization and nonce mutation are both later.
            } catch {
                Issue.record("Unexpected readiness error: \(error)")
            }
        }

        let decrypted = try bob.decryptWithSessionGeneration(
            ciphertext,
            from: alicePeerID,
            establishedGenerationIsReady: { _ in true }
        )
        #expect(decrypted.plaintext == plaintext)
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

private func orderedServices(
    ordinaryHandshakeTimeout: TimeInterval =
        NoiseSecurityConstants.ordinaryHandshakeTimeout,
    ordinaryResponderHandshakeTimeout: TimeInterval =
        NoiseSecurityConstants.ordinaryResponderHandshakeTimeout
) -> (
    lower: NoiseEncryptionService,
    lowerPeerID: PeerID,
    higher: NoiseEncryptionService,
    higherPeerID: PeerID
) {
    let first = NoiseEncryptionService(
        keychain: MockKeychain(),
        ordinaryHandshakeTimeout: ordinaryHandshakeTimeout,
        ordinaryResponderHandshakeTimeout:
            ordinaryResponderHandshakeTimeout
    )
    let second = NoiseEncryptionService(
        keychain: MockKeychain(),
        ordinaryHandshakeTimeout: ordinaryHandshakeTimeout,
        ordinaryResponderHandshakeTimeout:
            ordinaryResponderHandshakeTimeout
    )
    let firstPeerID = PeerID(publicKey: first.getStaticPublicKeyData())
    let secondPeerID = PeerID(publicKey: second.getStaticPublicKeyData())
    if firstPeerID < secondPeerID {
        return (first, firstPeerID, second, secondPeerID)
    }
    return (second, secondPeerID, first, firstPeerID)
}

private func claimPreparedRecoveryPayload(
    _ service: NoiseEncryptionService,
    request: NoiseHandshakeRecoveryRequest
) throws -> Data? {
    guard let preparation =
        try service.prepareHandshakeRecovery(request) else {
        return nil
    }
    switch preparation {
    case .ordinary(let initiation):
        return service.claimHandshakeInitiation(
            initiation,
            for: request.peerID
        )
    case .transferred:
        return nil
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

private final class HandshakeInitiationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedInitiations: [NoiseHandshakeInitiation] = []
    private var storedErrorCount = 0

    var initiations: [NoiseHandshakeInitiation] {
        lock.lock()
        defer { lock.unlock() }
        return storedInitiations
    }

    var errorCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedErrorCount
    }

    func record(_ initiation: NoiseHandshakeInitiation?) {
        guard let initiation else { return }
        lock.lock()
        storedInitiations.append(initiation)
        lock.unlock()
    }

    func record(error _: Error) {
        lock.lock()
        storedErrorCount += 1
        lock.unlock()
    }
}

private final class HandshakeStartRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedMessages: [Data] = []
    private var storedRequests: [NoiseHandshakeRecoveryRequest] = []
    private var storedErrorCount = 0
    private var storedTimeoutCount = 0
    private var storedTimeoutUptimes: [UInt64] = []

    var messages: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return storedMessages
    }

    var requests: [NoiseHandshakeRecoveryRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequests
    }

    var errorCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedErrorCount
    }

    var timeoutCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedTimeoutCount
    }

    var firstTimeoutUptimeNanoseconds: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return storedTimeoutUptimes.first
    }

    func record(message: Data?) {
        guard let message else { return }
        lock.lock()
        storedMessages.append(message)
        lock.unlock()
    }

    func record(request: NoiseHandshakeRecoveryRequest) {
        lock.lock()
        storedRequests.append(request)
        lock.unlock()
    }

    func record(error _: Error) {
        lock.lock()
        storedErrorCount += 1
        lock.unlock()
    }

    func recordTimeout(
        at uptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        lock.lock()
        storedTimeoutCount += 1
        storedTimeoutUptimes.append(uptimeNanoseconds)
        lock.unlock()
    }
}
