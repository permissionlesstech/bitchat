import BitFoundation
import CryptoKit
import Foundation
import Testing
@testable import bitchat

struct BLENoisePacketHandlerTests {
    private struct TestError: Error {}

    private final class Recorder {
        var handshakeResult: Result<Data?, Error> = .success(nil)
        var handshakeAuthenticated = false
        var hasSession = false
        let sessionGeneration = UUID()
        var awaitingResponderHandshake = false
        var decryptResult: Result<Data, Error> = .success(Data())
        var currentDate = Date(timeIntervalSince1970: 1_000)
        var transportGenerationReady = false
        var forcedServiceDecryptError: Error?

        var processedHandshakes: [(peerID: PeerID, message: Data)] = []
        var hasSessionQueries: [PeerID] = []
        var initiatedHandshakes: [PeerID] = []
        var broadcastPackets: [BitchatPacket] = []
        var lastSeenUpdates: [PeerID] = []
        var decryptCalls: [(payload: Data, peerID: PeerID)] = []
        var clearedSessions: [PeerID] = []
        var authenticatedPeerStates: [(peerID: PeerID, payload: Data, generation: UUID)] = []
        var deliveries: [(peerID: PeerID, type: NoisePayloadType, payload: Data, timestamp: Date)] = []
        /// Ordered side-effect log to assert recovery sequencing.
        var events: [String] = []
    }

    private let localPeerID = PeerID(str: "0102030405060708")
    private let remotePeerID = PeerID(str: "1122334455667788")
    private let localPeerIDData = Data(hexString: "0102030405060708") ?? Data()

    private func makeHandler(
        recorder: Recorder,
        now: Date = Date(timeIntervalSince1970: 1_000)
    ) -> BLENoisePacketHandler {
        recorder.currentDate = now
        let environment = BLENoisePacketHandlerEnvironment(
            localPeerID: { [localPeerID] in localPeerID },
            localPeerIDData: { [localPeerIDData] in localPeerIDData },
            messageTTL: TransportConfig.messageTTLDefault,
            now: { recorder.currentDate },
            processHandshakeMessage: { peerID, message in
                recorder.processedHandshakes.append((peerID, message))
                return NoiseHandshakeProcessingResult(
                    response: try recorder.handshakeResult.get(),
                    didEstablishAuthenticatedSession:
                        recorder.handshakeAuthenticated
                )
            },
            hasNoiseSession: { peerID in
                recorder.hasSessionQueries.append(peerID)
                return recorder.hasSession
            },
            isAwaitingResponderHandshakeCompletion: { _ in
                recorder.awaitingResponderHandshake
            },
            initiateHandshake: { peerID in
                recorder.initiatedHandshakes.append(peerID)
                recorder.events.append("initiateHandshake")
            },
            broadcastPacket: { packet in
                recorder.broadcastPackets.append(packet)
            },
            updatePeerLastSeen: { peerID in
                recorder.lastSeenUpdates.append(peerID)
            },
            decrypt: { payload, peerID in
                recorder.decryptCalls.append((payload, peerID))
                return BLENoiseDecryptionResult(
                    plaintext: try recorder.decryptResult.get(),
                    sessionGeneration: recorder.sessionGeneration
                )
            },
            clearSession: { peerID in
                recorder.clearedSessions.append(peerID)
                recorder.events.append("clearSession")
            },
            handleAuthenticatedPeerState: { peerID, payload, generation in
                recorder.authenticatedPeerStates.append((peerID, payload, generation))
            },
            deliverNoisePayload: { peerID, type, payload, timestamp in
                recorder.deliveries.append((peerID, type, payload, timestamp))
            }
        )
        return BLENoisePacketHandler(environment: environment)
    }

    private func makeServiceBackedHandler(
        service: NoiseEncryptionService,
        localPeerID: PeerID,
        recorder: Recorder,
        transportGenerationIsReady:
            @escaping (UUID) -> Bool
    ) -> BLENoisePacketHandler {
        BLENoisePacketHandler(
            environment: BLENoisePacketHandlerEnvironment(
                localPeerID: { localPeerID },
                localPeerIDData: {
                    Data(hexString: localPeerID.id) ?? Data()
                },
                messageTTL: TransportConfig.messageTTLDefault,
                now: { recorder.currentDate },
                processHandshakeMessage: { peerID, message in
                    try service.processHandshakeMessageWithResult(
                        from: peerID,
                        message: message
                    )
                },
                hasNoiseSession: { peerID in
                    service.hasSession(with: peerID)
                },
                isAwaitingResponderHandshakeCompletion: { peerID in
                    service.isAwaitingResponderHandshakeCompletion(
                        with: peerID
                    )
                },
                initiateHandshake: { peerID in
                    recorder.initiatedHandshakes.append(peerID)
                },
                broadcastPacket: { packet in
                    recorder.broadcastPackets.append(packet)
                },
                updatePeerLastSeen: { peerID in
                    recorder.lastSeenUpdates.append(peerID)
                },
                decrypt: { payload, peerID in
                    recorder.decryptCalls.append((payload, peerID))
                    if let error = recorder.forcedServiceDecryptError {
                        throw error
                    }
                    let result =
                        try service.decryptWithSessionGeneration(
                            payload,
                            from: peerID,
                            establishedGenerationIsReady:
                                transportGenerationIsReady
                        )
                    return BLENoiseDecryptionResult(
                        plaintext: result.plaintext,
                        sessionGeneration: result.sessionGeneration
                    )
                },
                clearSession: { peerID in
                    recorder.clearedSessions.append(peerID)
                    service.clearSession(for: peerID)
                },
                handleAuthenticatedPeerState: {
                    peerID, payload, generation in
                    recorder.authenticatedPeerStates.append(
                        (peerID, payload, generation)
                    )
                },
                deliverNoisePayload: {
                    peerID, type, payload, timestamp in
                    recorder.deliveries.append(
                        (peerID, type, payload, timestamp)
                    )
                }
            )
        )
    }

    private func establishedServices() throws -> (
        sender: NoiseEncryptionService,
        receiver: NoiseEncryptionService,
        senderPeerID: PeerID,
        receiverPeerID: PeerID
    ) {
        let sender = NoiseEncryptionService(keychain: MockKeychain())
        let receiver = NoiseEncryptionService(keychain: MockKeychain())
        let senderPeerID = PeerID(
            publicKey: sender.getStaticPublicKeyData()
        )
        let receiverPeerID = PeerID(
            publicKey: receiver.getStaticPublicKeyData()
        )
        let message1 = try sender.initiateHandshake(with: receiverPeerID)
        let message2 = try #require(
            try receiver.processHandshakeMessage(
                from: senderPeerID,
                message: message1
            )
        )
        let message3 = try #require(
            try sender.processHandshakeMessage(
                from: receiverPeerID,
                message: message2
            )
        )
        _ = try receiver.processHandshakeMessage(
            from: senderPeerID,
            message: message3
        )
        return (
            sender,
            receiver,
            senderPeerID,
            receiverPeerID
        )
    }

    // MARK: Handshake

    @Test
    func handshakeForUsBroadcastsResponsePacket() {
        let now = Date(timeIntervalSince1970: 1_000)
        let recorder = Recorder()
        recorder.handshakeResult = .success(Data([0xAA, 0xBB]))
        let handler = makeHandler(recorder: recorder, now: now)
        let packet = makeHandshakePacket(recipientID: Data(hexString: localPeerID.id))

        handler.handleHandshake(packet, from: remotePeerID)

        #expect(recorder.processedHandshakes.count == 1)
        #expect(recorder.processedHandshakes.first?.peerID == remotePeerID)
        #expect(recorder.processedHandshakes.first?.message == packet.payload)
        #expect(recorder.broadcastPackets.count == 1)
        let response = recorder.broadcastPackets.first
        #expect(response?.type == MessageType.noiseHandshake.rawValue)
        #expect(response?.senderID == localPeerIDData)
        #expect(response?.recipientID == Data(hexString: remotePeerID.id))
        #expect(response?.payload == Data([0xAA, 0xBB]))
        #expect(response?.signature == nil)
        #expect(response?.ttl == TransportConfig.messageTTLDefault)
        #expect(response?.timestamp == UInt64(now.timeIntervalSince1970 * 1000))
        #expect(recorder.initiatedHandshakes.isEmpty)
    }

    @Test
    func handshakeWithoutResponseDoesNotBroadcast() {
        let recorder = Recorder()
        recorder.handshakeResult = .success(nil)
        let handler = makeHandler(recorder: recorder)
        let packet = makeHandshakePacket(recipientID: Data(hexString: localPeerID.id))

        handler.handleHandshake(packet, from: remotePeerID)

        #expect(recorder.processedHandshakes.count == 1)
        #expect(recorder.broadcastPackets.isEmpty)
        #expect(recorder.initiatedHandshakes.isEmpty)
    }

    @Test
    func handshakeResultPreservesExactCandidateAuthentication() {
        let recorder = Recorder()
        recorder.handshakeAuthenticated = true
        let handler = makeHandler(recorder: recorder)
        let packet = makeHandshakePacket(
            recipientID: Data(hexString: localPeerID.id)
        )

        let result = handler.handleHandshakeWithResult(
            packet,
            from: remotePeerID
        )

        #expect(result.processed)
        #expect(result.didEstablishAuthenticatedSession)
    }

    @Test
    func handshakeForAnotherPeerIsIgnored() {
        let recorder = Recorder()
        let handler = makeHandler(recorder: recorder)
        let packet = makeHandshakePacket(recipientID: Data(hexString: remotePeerID.id))

        handler.handleHandshake(packet, from: remotePeerID)

        #expect(recorder.processedHandshakes.isEmpty)
        #expect(recorder.broadcastPackets.isEmpty)
        #expect(recorder.initiatedHandshakes.isEmpty)
    }

    @Test
    func handshakeFailureInitiatesNewHandshakeWhenNoSession() {
        let recorder = Recorder()
        recorder.handshakeResult = .failure(TestError())
        recorder.hasSession = false
        let handler = makeHandler(recorder: recorder)
        let packet = makeHandshakePacket(recipientID: Data(hexString: localPeerID.id))

        handler.handleHandshake(packet, from: remotePeerID)

        #expect(recorder.hasSessionQueries == [remotePeerID])
        #expect(recorder.initiatedHandshakes == [remotePeerID])
        #expect(recorder.broadcastPackets.isEmpty)
    }

    @Test
    func handshakeFailureSkipsInitiateWhenSessionExists() {
        let recorder = Recorder()
        recorder.handshakeResult = .failure(TestError())
        recorder.hasSession = true
        let handler = makeHandler(recorder: recorder)
        let packet = makeHandshakePacket(recipientID: Data(hexString: localPeerID.id))

        handler.handleHandshake(packet, from: remotePeerID)

        #expect(recorder.hasSessionQueries == [remotePeerID])
        #expect(recorder.initiatedHandshakes.isEmpty)
    }

    @Test
    func peerIdentityMismatchDoesNotRecreateHandshakeState() {
        let recorder = Recorder()
        recorder.handshakeResult = .failure(NoiseSessionError.peerIdentityMismatch)
        recorder.hasSession = false
        let handler = makeHandler(recorder: recorder)
        let packet = makeHandshakePacket(recipientID: Data(hexString: localPeerID.id))

        #expect(!handler.handleHandshake(packet, from: remotePeerID))

        #expect(recorder.hasSessionQueries.isEmpty)
        #expect(recorder.initiatedHandshakes.isEmpty)
        #expect(recorder.broadcastPackets.isEmpty)
    }

    @Test
    func managedHandshakeFailureDoesNotStartASecondRecovery() {
        let recorder = Recorder()
        recorder.handshakeResult = .failure(
            NoiseManagedHandshakeFailure(underlying: TestError())
        )
        recorder.hasSession = false
        let handler = makeHandler(recorder: recorder)
        let packet = makeHandshakePacket(
            recipientID: Data(hexString: localPeerID.id)
        )

        #expect(!handler.handleHandshake(packet, from: remotePeerID))
        #expect(recorder.hasSessionQueries.isEmpty)
        #expect(recorder.initiatedHandshakes.isEmpty)
        #expect(recorder.broadcastPackets.isEmpty)
    }

    // MARK: Encrypted

    @Test
    func encryptedWithoutRecipientIsDropped() {
        let recorder = Recorder()
        let handler = makeHandler(recorder: recorder)
        let packet = makeEncryptedPacket(recipientID: nil)

        handler.handleEncrypted(packet, from: remotePeerID)

        #expect(recorder.lastSeenUpdates.isEmpty)
        #expect(recorder.decryptCalls.isEmpty)
        #expect(recorder.deliveries.isEmpty)
    }

    @Test
    func encryptedForAnotherPeerIsDropped() {
        let recorder = Recorder()
        let handler = makeHandler(recorder: recorder)
        let packet = makeEncryptedPacket(recipientID: Data(hexString: remotePeerID.id))

        handler.handleEncrypted(packet, from: remotePeerID)

        #expect(recorder.lastSeenUpdates.isEmpty)
        #expect(recorder.decryptCalls.isEmpty)
        #expect(recorder.deliveries.isEmpty)
    }

    @Test
    func decryptedPayloadIsDeliveredWithTypeAndTimestamp() {
        let now = Date(timeIntervalSince1970: 1_000)
        let recorder = Recorder()
        recorder.decryptResult = .success(Data([NoisePayloadType.privateMessage.rawValue, 0x01, 0x02, 0x03]))
        let handler = makeHandler(recorder: recorder, now: now)
        let sentAt = Date(timeIntervalSince1970: 900)
        let packet = makeEncryptedPacket(
            recipientID: Data(hexString: localPeerID.id),
            timestamp: UInt64(sentAt.timeIntervalSince1970 * 1000)
        )

        handler.handleEncrypted(packet, from: remotePeerID)

        #expect(recorder.lastSeenUpdates == [remotePeerID])
        #expect(recorder.decryptCalls.count == 1)
        #expect(recorder.decryptCalls.first?.payload == packet.payload)
        #expect(recorder.deliveries.count == 1)
        #expect(recorder.deliveries.first?.peerID == remotePeerID)
        #expect(recorder.deliveries.first?.type == .privateMessage)
        #expect(recorder.deliveries.first?.payload == Data([0x01, 0x02, 0x03]))
        #expect(recorder.deliveries.first?.timestamp == sentAt)
        #expect(recorder.clearedSessions.isEmpty)
        #expect(recorder.initiatedHandshakes.isEmpty)
    }

    @Test
    func authenticatedPeerStateIsConsumedByTransportNotDeliveredToUI() {
        let recorder = Recorder()
        recorder.decryptResult = .success(Data([
            NoisePayloadType.authenticatedPeerState.rawValue,
            0x01, 0x02, 0x03
        ]))
        let handler = makeHandler(recorder: recorder)
        let packet = makeEncryptedPacket(recipientID: Data(hexString: localPeerID.id))

        handler.handleEncrypted(packet, from: remotePeerID)

        #expect(recorder.authenticatedPeerStates.count == 1)
        #expect(recorder.authenticatedPeerStates.first?.peerID == remotePeerID)
        #expect(recorder.authenticatedPeerStates.first?.payload == Data([0x01, 0x02, 0x03]))
        #expect(recorder.authenticatedPeerStates.first?.generation == recorder.sessionGeneration)
        #expect(recorder.deliveries.isEmpty)
    }

    @Test
    func emptyDecryptedPayloadIsIgnored() {
        let recorder = Recorder()
        recorder.decryptResult = .success(Data())
        let handler = makeHandler(recorder: recorder)
        let packet = makeEncryptedPacket(recipientID: Data(hexString: localPeerID.id))

        handler.handleEncrypted(packet, from: remotePeerID)

        #expect(recorder.decryptCalls.count == 1)
        #expect(recorder.deliveries.isEmpty)
        #expect(recorder.clearedSessions.isEmpty)
    }

    @Test
    func unknownNoisePayloadTypeIsIgnored() {
        let recorder = Recorder()
        recorder.decryptResult = .success(Data([0xEE, 0x01]))
        let handler = makeHandler(recorder: recorder)
        let packet = makeEncryptedPacket(recipientID: Data(hexString: localPeerID.id))

        handler.handleEncrypted(packet, from: remotePeerID)

        #expect(recorder.decryptCalls.count == 1)
        #expect(recorder.deliveries.isEmpty)
    }

    @Test
    func missingSessionInitiatesHandshakeWithoutClearing() {
        let recorder = Recorder()
        recorder.decryptResult = .failure(NoiseEncryptionError.sessionNotEstablished)
        recorder.hasSession = false
        let handler = makeHandler(recorder: recorder)
        let packet = makeEncryptedPacket(recipientID: Data(hexString: localPeerID.id))

        handler.handleEncrypted(packet, from: remotePeerID)

        #expect(recorder.hasSessionQueries == [remotePeerID])
        #expect(recorder.initiatedHandshakes == [remotePeerID])
        #expect(recorder.clearedSessions.isEmpty)
        #expect(recorder.deliveries.isEmpty)
    }

    @Test
    func missingSessionSkipsInitiateWhenSessionAppeared() {
        let recorder = Recorder()
        recorder.decryptResult = .failure(NoiseEncryptionError.sessionNotEstablished)
        recorder.hasSession = true
        let handler = makeHandler(recorder: recorder)
        let packet = makeEncryptedPacket(recipientID: Data(hexString: localPeerID.id))

        handler.handleEncrypted(packet, from: remotePeerID)

        #expect(recorder.initiatedHandshakes.isEmpty)
        #expect(recorder.clearedSessions.isEmpty)
    }

    @Test
    func decryptFailureClearsSessionThenReinitiatesHandshake() {
        let recorder = Recorder()
        recorder.decryptResult = .failure(TestError())
        // Even with a live session, recovery clears it and re-initiates unconditionally.
        recorder.hasSession = true
        let handler = makeHandler(recorder: recorder)
        let packet = makeEncryptedPacket(recipientID: Data(hexString: localPeerID.id))

        handler.handleEncrypted(packet, from: remotePeerID)

        #expect(recorder.clearedSessions == [remotePeerID])
        #expect(recorder.initiatedHandshakes == [remotePeerID])
        // Session-recovery order must stay clear → re-initiate.
        #expect(recorder.events == ["clearSession", "initiateHandshake"])
        #expect(recorder.deliveries.isEmpty)
    }

    @Test
    func earlyCiphertextIsRetriedAfterResponderHandshakeCompletes() {
        let recorder = Recorder()
        recorder.hasSession = true
        recorder.awaitingResponderHandshake = true
        recorder.decryptResult = .failure(
            CryptoKitError.authenticationFailure
        )
        let handler = makeHandler(recorder: recorder)
        let encrypted = makeEncryptedPacket(
            recipientID: Data(hexString: localPeerID.id)
        )

        handler.handleEncrypted(encrypted, from: remotePeerID)

        #expect(recorder.decryptCalls.count == 1)
        #expect(recorder.clearedSessions.isEmpty)
        #expect(recorder.initiatedHandshakes.isEmpty)

        recorder.awaitingResponderHandshake = false
        recorder.decryptResult = .success(
            Data([NoisePayloadType.privateMessage.rawValue, 0xCA, 0xFE])
        )
        handler.handleSessionAuthenticated(remotePeerID)
        handler.handleSessionAuthenticated(remotePeerID)

        #expect(recorder.decryptCalls.count == 2)
        #expect(recorder.deliveries.count == 1)
        #expect(recorder.deliveries.first?.type == .privateMessage)
        #expect(recorder.deliveries.first?.payload == Data([0xCA, 0xFE]))
        #expect(recorder.clearedSessions.isEmpty)
        #expect(recorder.initiatedHandshakes.isEmpty)
    }

    @Test
    func panicResetDiscardsDeferredCiphertextBeforeFutureAuthentication() {
        let recorder = Recorder()
        recorder.hasSession = true
        recorder.awaitingResponderHandshake = true
        recorder.decryptResult = .failure(
            CryptoKitError.authenticationFailure
        )
        let handler = makeHandler(recorder: recorder)
        let prePanicCiphertext = makeEncryptedPacket(
            recipientID: Data(hexString: localPeerID.id),
            payload: Data(
                count: NoiseSecurityConstants.maxMessageSize
                    + NoiseSecurityConstants.transportCiphertextOverhead
            )
        )

        handler.handleEncrypted(prePanicCiphertext, from: remotePeerID)
        #expect(recorder.decryptCalls.count == 1)

        handler.resetForPanic()

        // Three maximum-sized packets fit only when reset also zeroed the
        // global byte accounting. They model ciphertext received under the
        // replacement identity before that responder handshake completes.
        for index in 0..<3 {
            handler.handleEncrypted(
                makeEncryptedPacket(
                    recipientID: Data(hexString: localPeerID.id),
                    timestamp: UInt64(901_000 + index),
                    payload: Data(
                        count: NoiseSecurityConstants.maxMessageSize
                            + NoiseSecurityConstants.transportCiphertextOverhead
                    )
                ),
                from: remotePeerID
            )
        }
        #expect(recorder.decryptCalls.count == 4)

        recorder.awaitingResponderHandshake = false
        recorder.decryptResult = .success(
            Data([NoisePayloadType.privateMessage.rawValue, 0xCA, 0xFE])
        )
        handler.handleSessionAuthenticated(remotePeerID)

        // Only the three post-reset packets replay; the pre-panic packet does
        // not survive into the replacement session.
        #expect(recorder.decryptCalls.count == 7)
        #expect(recorder.deliveries.count == 3)
        #expect(recorder.clearedSessions.isEmpty)
        #expect(recorder.initiatedHandshakes.isEmpty)
    }

    @Test
    func ciphertextQueuedAheadOfEstablishmentCallbackDoesNotConsumeNonce()
        throws {
        let alice = NoiseEncryptionService(keychain: MockKeychain())
        let bob = NoiseEncryptionService(keychain: MockKeychain())
        let alicePeerID = PeerID(
            publicKey: alice.getStaticPublicKeyData()
        )
        let bobPeerID = PeerID(publicKey: bob.getStaticPublicKeyData())

        let message1 = try alice.initiateHandshake(with: bobPeerID)
        let message2 = try #require(
            try bob.processHandshakeMessage(
                from: alicePeerID,
                message: message1
            )
        )
        let message3 = try #require(
            try alice.processHandshakeMessage(
                from: bobPeerID,
                message: message2
            )
        )
        let typedPayload = Data([
            NoisePayloadType.privateMessage.rawValue,
            0xCA, 0xFE
        ])
        let ciphertext = try alice.encrypt(
            typedPayload,
            for: bobPeerID
        )

        // Manager promotion has completed, but the serialized BLE callback is
        // deliberately still behind this ciphertext.
        _ = try bob.processHandshakeMessage(
            from: alicePeerID,
            message: message3
        )
        let recorder = Recorder()
        recorder.transportGenerationReady = false
        let handler = makeServiceBackedHandler(
            service: bob,
            localPeerID: bobPeerID,
            recorder: recorder,
            transportGenerationIsReady: { _ in
                recorder.transportGenerationReady
            }
        )
        let packet = makeEncryptedPacket(
            recipientID: Data(hexString: bobPeerID.id),
            payload: ciphertext
        )

        handler.handleEncrypted(packet, from: alicePeerID)
        #expect(recorder.deliveries.isEmpty)
        #expect(recorder.clearedSessions.isEmpty)

        // The exact ciphertext must still authenticate, proving the readiness
        // rejection happened before the receive nonce was consumed.
        recorder.transportGenerationReady = true
        handler.handleSessionAuthenticated(alicePeerID)

        #expect(recorder.decryptCalls.count == 2)
        #expect(recorder.deliveries.count == 1)
        #expect(recorder.deliveries.first?.type == .privateMessage)
        #expect(recorder.deliveries.first?.payload == Data([0xCA, 0xFE]))
        #expect(recorder.clearedSessions.isEmpty)
        #expect(recorder.initiatedHandshakes.isEmpty)
    }

    @Test
    func ciphertextQueuedAheadOfRestoreCallbackDoesNotConsumeNonce()
        throws {
        let alice = NoiseEncryptionService(keychain: MockKeychain())
        let bob = NoiseEncryptionService(keychain: MockKeychain())
        let mallory = NoiseEncryptionService(keychain: MockKeychain())
        let alicePeerID = PeerID(
            publicKey: alice.getStaticPublicKeyData()
        )
        let bobPeerID = PeerID(publicKey: bob.getStaticPublicKeyData())

        let initial1 = try alice.initiateHandshake(with: bobPeerID)
        let initial2 = try #require(
            try bob.processHandshakeMessage(
                from: alicePeerID,
                message: initial1
            )
        )
        let initial3 = try #require(
            try alice.processHandshakeMessage(
                from: bobPeerID,
                message: initial2
            )
        )
        _ = try bob.processHandshakeMessage(
            from: alicePeerID,
            message: initial3
        )
        let typedPayload = Data([
            NoisePayloadType.privateMessage.rawValue,
            0xBE, 0xEF
        ])
        let delayedCiphertext = try alice.encrypt(
            typedPayload,
            for: bobPeerID
        )

        let forged1 = try mallory.initiateHandshake(with: bobPeerID)
        let forged2 = try #require(
            try bob.processHandshakeMessage(
                from: alicePeerID,
                message: forged1
            )
        )
        let forged3 = try #require(
            try mallory.processHandshakeMessage(
                from: bobPeerID,
                message: forged2
            )
        )
        #expect(throws: NoiseSessionError.peerIdentityMismatch) {
            try bob.processHandshakeMessage(
                from: alicePeerID,
                message: forged3
            )
        }
        #expect(bob.hasEstablishedSession(with: alicePeerID))

        let recorder = Recorder()
        recorder.transportGenerationReady = false
        let handler = makeServiceBackedHandler(
            service: bob,
            localPeerID: bobPeerID,
            recorder: recorder,
            transportGenerationIsReady: { _ in
                recorder.transportGenerationReady
            }
        )
        let packet = makeEncryptedPacket(
            recipientID: Data(hexString: bobPeerID.id),
            payload: delayedCiphertext
        )

        // Manager rollback is visible, while the BLE restore callback is
        // deliberately still queued behind this ciphertext.
        handler.handleEncrypted(packet, from: alicePeerID)
        #expect(recorder.deliveries.isEmpty)
        #expect(recorder.clearedSessions.isEmpty)

        recorder.transportGenerationReady = true
        handler.handleSessionAuthenticated(alicePeerID)

        #expect(recorder.decryptCalls.count == 2)
        #expect(recorder.deliveries.count == 1)
        #expect(recorder.deliveries.first?.type == .privateMessage)
        #expect(recorder.deliveries.first?.payload == Data([0xBE, 0xEF]))
        #expect(recorder.clearedSessions.isEmpty)
        #expect(recorder.initiatedHandshakes.isEmpty)
    }

    @Test
    func oversizedCiphertextCannotEvictEstablishedTransport() throws {
        let pair = try establishedServices()
        let recorder = Recorder()
        recorder.transportGenerationReady = true
        let handler = makeServiceBackedHandler(
            service: pair.receiver,
            localPeerID: pair.receiverPeerID,
            recorder: recorder,
            transportGenerationIsReady: { _ in
                recorder.transportGenerationReady
            }
        )

        handler.handleEncrypted(
            makeEncryptedPacket(
                recipientID: Data(hexString: pair.receiverPeerID.id),
                payload: Data(
                    count:
                        NoiseSecurityConstants
                            .maxPrivateFileCiphertextSize + 1
                )
            ),
            from: pair.senderPeerID
        )
        #expect(
            pair.receiver.hasEstablishedSession(with: pair.senderPeerID)
        )
        #expect(recorder.clearedSessions.isEmpty)

        let valid = try pair.sender.encrypt(
            Data([NoisePayloadType.privateMessage.rawValue, 0x01]),
            for: pair.receiverPeerID
        )
        handler.handleEncrypted(
            makeEncryptedPacket(
                recipientID: Data(hexString: pair.receiverPeerID.id),
                payload: valid
            ),
            from: pair.senderPeerID
        )

        #expect(recorder.deliveries.count == 1)
        #expect(recorder.deliveries.first?.payload == Data([0x01]))
        #expect(recorder.clearedSessions.isEmpty)
        #expect(recorder.initiatedHandshakes.isEmpty)
    }

    @Test
    func forgedAuthenticationFailureCannotEvictEstablishedTransport()
        throws {
        let pair = try establishedServices()
        let recorder = Recorder()
        recorder.transportGenerationReady = true
        let handler = makeServiceBackedHandler(
            service: pair.receiver,
            localPeerID: pair.receiverPeerID,
            recorder: recorder,
            transportGenerationIsReady: { _ in
                recorder.transportGenerationReady
            }
        )
        let valid = try pair.sender.encrypt(
            Data([NoisePayloadType.privateMessage.rawValue, 0x02]),
            for: pair.receiverPeerID
        )
        var forged = valid
        forged[forged.index(before: forged.endIndex)] ^= 0xFF

        handler.handleEncrypted(
            makeEncryptedPacket(
                recipientID: Data(hexString: pair.receiverPeerID.id),
                payload: forged
            ),
            from: pair.senderPeerID
        )
        #expect(
            pair.receiver.hasEstablishedSession(with: pair.senderPeerID)
        )
        #expect(recorder.clearedSessions.isEmpty)

        // Authentication failure leaves nonce state untouched, so the exact
        // original ciphertext remains valid.
        handler.handleEncrypted(
            makeEncryptedPacket(
                recipientID: Data(hexString: pair.receiverPeerID.id),
                payload: valid
            ),
            from: pair.senderPeerID
        )

        #expect(recorder.deliveries.count == 1)
        #expect(recorder.deliveries.first?.payload == Data([0x02]))
        #expect(recorder.clearedSessions.isEmpty)
        #expect(recorder.initiatedHandshakes.isEmpty)
    }

    @Test
    func replayCannotEvictEstablishedTransportOrBlockNextNonce() throws {
        let pair = try establishedServices()
        let recorder = Recorder()
        recorder.transportGenerationReady = true
        let handler = makeServiceBackedHandler(
            service: pair.receiver,
            localPeerID: pair.receiverPeerID,
            recorder: recorder,
            transportGenerationIsReady: { _ in
                recorder.transportGenerationReady
            }
        )
        let first = try pair.sender.encrypt(
            Data([NoisePayloadType.privateMessage.rawValue, 0x03]),
            for: pair.receiverPeerID
        )
        let firstPacket = makeEncryptedPacket(
            recipientID: Data(hexString: pair.receiverPeerID.id),
            payload: first
        )

        handler.handleEncrypted(firstPacket, from: pair.senderPeerID)
        handler.handleEncrypted(firstPacket, from: pair.senderPeerID)
        #expect(
            pair.receiver.hasEstablishedSession(with: pair.senderPeerID)
        )
        #expect(recorder.clearedSessions.isEmpty)

        let next = try pair.sender.encrypt(
            Data([NoisePayloadType.privateMessage.rawValue, 0x04]),
            for: pair.receiverPeerID
        )
        handler.handleEncrypted(
            makeEncryptedPacket(
                recipientID: Data(hexString: pair.receiverPeerID.id),
                payload: next
            ),
            from: pair.senderPeerID
        )

        #expect(recorder.deliveries.count == 2)
        #expect(recorder.deliveries.map { $0.payload } == [
            Data([0x03]), Data([0x04])
        ])
        #expect(recorder.clearedSessions.isEmpty)
        #expect(recorder.initiatedHandshakes.isEmpty)
    }

    @Test
    func rateLimitFailureCannotEvictEstablishedTransportOrConsumeNonce()
        throws {
        let pair = try establishedServices()
        let recorder = Recorder()
        recorder.transportGenerationReady = true
        recorder.forcedServiceDecryptError =
            NoiseSecurityError.rateLimitExceeded
        let handler = makeServiceBackedHandler(
            service: pair.receiver,
            localPeerID: pair.receiverPeerID,
            recorder: recorder,
            transportGenerationIsReady: { _ in
                recorder.transportGenerationReady
            }
        )
        let valid = try pair.sender.encrypt(
            Data([NoisePayloadType.privateMessage.rawValue, 0x05]),
            for: pair.receiverPeerID
        )

        handler.handleEncrypted(
            makeEncryptedPacket(
                recipientID: Data(hexString: pair.receiverPeerID.id),
                payload: Data(repeating: 0xA5, count: 20)
            ),
            from: pair.senderPeerID
        )
        #expect(
            pair.receiver.hasEstablishedSession(with: pair.senderPeerID)
        )
        #expect(recorder.clearedSessions.isEmpty)

        recorder.forcedServiceDecryptError = nil
        handler.handleEncrypted(
            makeEncryptedPacket(
                recipientID: Data(hexString: pair.receiverPeerID.id),
                payload: valid
            ),
            from: pair.senderPeerID
        )

        #expect(recorder.deliveries.count == 1)
        #expect(recorder.deliveries.first?.payload == Data([0x05]))
        #expect(recorder.clearedSessions.isEmpty)
        #expect(recorder.initiatedHandshakes.isEmpty)
    }

    @Test
    func maximumPrivateFileCiphertextIsEligibleForDeferredRetry() {
        let recorder = Recorder()
        recorder.hasSession = true
        recorder.awaitingResponderHandshake = true
        recorder.decryptResult = .failure(
            CryptoKitError.authenticationFailure
        )
        let handler = makeHandler(recorder: recorder)
        let encrypted = makeEncryptedPacket(
            recipientID: Data(hexString: localPeerID.id),
            payload: Data(
                count: NoiseSecurityConstants.maxPrivateFileCiphertextSize
            )
        )

        handler.handleEncrypted(encrypted, from: remotePeerID)
        recorder.awaitingResponderHandshake = false
        recorder.decryptResult = .success(
            Data([NoisePayloadType.privateFile.rawValue, 0x01])
        )
        handler.handleSessionAuthenticated(remotePeerID)

        #expect(recorder.decryptCalls.count == 2)
        #expect(recorder.deliveries.count == 1)
        #expect(recorder.deliveries.first?.type == .privateFile)
        #expect(recorder.clearedSessions.isEmpty)
        #expect(recorder.initiatedHandshakes.isEmpty)
    }

    @Test
    func oversizedEarlyCiphertextIsNotDeferred() {
        let recorder = Recorder()
        recorder.hasSession = true
        recorder.awaitingResponderHandshake = true
        recorder.decryptResult = .failure(
            CryptoKitError.authenticationFailure
        )
        let handler = makeHandler(recorder: recorder)
        let encrypted = makeEncryptedPacket(
            recipientID: Data(hexString: localPeerID.id),
            payload: Data(
                count:
                    NoiseSecurityConstants.maxPrivateFileCiphertextSize + 1
            )
        )

        handler.handleEncrypted(encrypted, from: remotePeerID)
        recorder.awaitingResponderHandshake = false
        recorder.decryptResult = .success(
            Data([NoisePayloadType.delivered.rawValue, 0x01])
        )
        handler.handleSessionAuthenticated(remotePeerID)

        #expect(recorder.decryptCalls.count == 1)
        #expect(recorder.deliveries.isEmpty)
        #expect(recorder.clearedSessions.isEmpty)
        #expect(recorder.initiatedHandshakes.isEmpty)
    }

    @Test
    func missingSessionCiphertextIsRetriedAfterResponderHandshakeCompletes() {
        let recorder = Recorder()
        recorder.hasSession = true
        recorder.awaitingResponderHandshake = true
        recorder.decryptResult = .failure(
            NoiseEncryptionError.sessionNotEstablished
        )
        let handler = makeHandler(recorder: recorder)
        let encrypted = makeEncryptedPacket(
            recipientID: Data(hexString: localPeerID.id)
        )

        handler.handleEncrypted(encrypted, from: remotePeerID)
        #expect(recorder.decryptCalls.count == 1)
        #expect(recorder.initiatedHandshakes.isEmpty)

        recorder.awaitingResponderHandshake = false
        recorder.decryptResult = .success(
            Data([NoisePayloadType.delivered.rawValue, 0x01])
        )
        handler.handleSessionAuthenticated(remotePeerID)

        #expect(recorder.decryptCalls.count == 2)
        #expect(recorder.deliveries.count == 1)
        #expect(recorder.clearedSessions.isEmpty)
        #expect(recorder.initiatedHandshakes.isEmpty)
    }

    @Test
    func lowNonceCiphertextIsRetriedAfterResponderHandshakeCompletes() {
        let recorder = Recorder()
        recorder.hasSession = true
        recorder.awaitingResponderHandshake = true
        recorder.decryptResult = .failure(NoiseError.replayDetected)
        let handler = makeHandler(recorder: recorder)
        let encrypted = makeEncryptedPacket(
            recipientID: Data(hexString: localPeerID.id)
        )

        handler.handleEncrypted(encrypted, from: remotePeerID)
        recorder.awaitingResponderHandshake = false
        recorder.decryptResult = .success(
            Data([NoisePayloadType.readReceipt.rawValue, 0x02])
        )
        handler.handleSessionAuthenticated(remotePeerID)

        #expect(recorder.decryptCalls.count == 2)
        #expect(recorder.deliveries.count == 1)
        #expect(recorder.deliveries.first?.type == .readReceipt)
        #expect(recorder.clearedSessions.isEmpty)
        #expect(recorder.initiatedHandshakes.isEmpty)
    }

    @Test
    func invalidDeferredCiphertextDoesNotClearAuthenticatedSession() {
        let recorder = Recorder()
        recorder.hasSession = true
        recorder.awaitingResponderHandshake = true
        recorder.decryptResult = .failure(
            CryptoKitError.authenticationFailure
        )
        let handler = makeHandler(recorder: recorder)
        let encrypted = makeEncryptedPacket(
            recipientID: Data(hexString: localPeerID.id)
        )

        handler.handleEncrypted(encrypted, from: remotePeerID)
        recorder.awaitingResponderHandshake = false
        handler.handleSessionAuthenticated(remotePeerID)

        #expect(recorder.decryptCalls.count == 2)
        #expect(recorder.deliveries.isEmpty)
        #expect(recorder.clearedSessions.isEmpty)
        #expect(recorder.initiatedHandshakes.isEmpty)
    }

    @Test
    func nonCipherFailureDuringResponderHandshakeIsDroppedNotDeferred() {
        let recorder = Recorder()
        recorder.hasSession = true
        recorder.awaitingResponderHandshake = true
        recorder.decryptResult = .failure(TestError())
        let handler = makeHandler(recorder: recorder)
        handler.handleEncrypted(
            makeEncryptedPacket(
                recipientID: Data(hexString: localPeerID.id)
            ),
            from: remotePeerID
        )

        recorder.awaitingResponderHandshake = false
        recorder.decryptResult = .success(
            Data([NoisePayloadType.delivered.rawValue, 0x01])
        )
        handler.handleSessionAuthenticated(remotePeerID)

        #expect(recorder.decryptCalls.count == 1)
        #expect(recorder.deliveries.isEmpty)
        #expect(recorder.clearedSessions.isEmpty)
        #expect(recorder.initiatedHandshakes.isEmpty)
    }

    @Test
    func earlyCiphertextBufferIsBoundedPerPeer() {
        let recorder = Recorder()
        recorder.hasSession = true
        recorder.awaitingResponderHandshake = true
        recorder.decryptResult = .failure(
            CryptoKitError.authenticationFailure
        )
        let handler = makeHandler(recorder: recorder)

        for index in 0..<5 {
            handler.handleEncrypted(
                makeEncryptedPacket(
                    recipientID: Data(hexString: localPeerID.id),
                    timestamp: UInt64(900_000 + index)
                ),
                from: remotePeerID
            )
        }
        #expect(recorder.decryptCalls.count == 5)

        recorder.awaitingResponderHandshake = false
        recorder.decryptResult = .success(
            Data([NoisePayloadType.delivered.rawValue, 0x01])
        )
        handler.handleSessionAuthenticated(remotePeerID)

        #expect(recorder.decryptCalls.count == 9)
        #expect(recorder.deliveries.count == 4)
        #expect(recorder.clearedSessions.isEmpty)
        #expect(recorder.initiatedHandshakes.isEmpty)
    }

    @Test
    func earlyCiphertextBufferIsBoundedGlobally() {
        let recorder = Recorder()
        recorder.hasSession = true
        recorder.awaitingResponderHandshake = true
        recorder.decryptResult = .failure(
            CryptoKitError.authenticationFailure
        )
        let handler = makeHandler(recorder: recorder)
        let peers = (1...33).map {
            PeerID(str: String(format: "%016llx", UInt64($0)))
        }
        let packet = makeEncryptedPacket(
            recipientID: Data(hexString: localPeerID.id)
        )

        for peerID in peers {
            handler.handleEncrypted(packet, from: peerID)
        }
        #expect(recorder.decryptCalls.count == 33)

        recorder.awaitingResponderHandshake = false
        recorder.decryptResult = .success(
            Data([NoisePayloadType.delivered.rawValue, 0x01])
        )
        for peerID in peers {
            handler.handleSessionAuthenticated(peerID)
        }

        #expect(recorder.decryptCalls.count == 65)
        #expect(recorder.deliveries.count == 32)
        #expect(recorder.clearedSessions.isEmpty)
        #expect(recorder.initiatedHandshakes.isEmpty)
    }

    @Test
    func earlyCiphertextBufferKeepsPrivateFileRoomAndByteBound() {
        let recorder = Recorder()
        recorder.hasSession = true
        recorder.awaitingResponderHandshake = true
        recorder.decryptResult = .failure(
            CryptoKitError.authenticationFailure
        )
        let handler = makeHandler(recorder: recorder)
        let peers = [
            PeerID(str: "0000000000000001"),
            PeerID(str: "0000000000000002"),
            PeerID(str: "0000000000000003")
        ]

        handler.handleEncrypted(
            makeEncryptedPacket(
                recipientID: Data(hexString: localPeerID.id),
                payload: Data(
                    count:
                        NoiseSecurityConstants.maxPrivateFileCiphertextSize
                )
            ),
            from: peers[0]
        )
        handler.handleEncrypted(
            makeEncryptedPacket(
                recipientID: Data(hexString: localPeerID.id),
                payload: Data(count: 256 * 1024)
            ),
            from: peers[1]
        )
        handler.handleEncrypted(
            makeEncryptedPacket(
                recipientID: Data(hexString: localPeerID.id),
                payload: Data([0x01])
            ),
            from: peers[2]
        )

        recorder.awaitingResponderHandshake = false
        recorder.decryptResult = .success(
            Data([NoisePayloadType.delivered.rawValue, 0x01])
        )
        for peerID in peers {
            handler.handleSessionAuthenticated(peerID)
        }

        #expect(recorder.decryptCalls.count == 5)
        #expect(recorder.deliveries.count == 2)
        #expect(recorder.clearedSessions.isEmpty)
        #expect(recorder.initiatedHandshakes.isEmpty)
    }

    @Test
    func expiredEarlyCiphertextIsNotRetried() {
        let recorder = Recorder()
        recorder.hasSession = true
        recorder.awaitingResponderHandshake = true
        recorder.decryptResult = .failure(
            CryptoKitError.authenticationFailure
        )
        let handler = makeHandler(recorder: recorder)
        handler.handleEncrypted(
            makeEncryptedPacket(
                recipientID: Data(hexString: localPeerID.id)
            ),
            from: remotePeerID
        )

        recorder.currentDate =
            recorder.currentDate.addingTimeInterval(
                NoiseSecurityConstants.ordinaryResponderHandshakeTimeout
                    + 0.001
            )
        recorder.awaitingResponderHandshake = false
        recorder.decryptResult = .success(
            Data([NoisePayloadType.delivered.rawValue, 0x01])
        )
        handler.handleSessionAuthenticated(remotePeerID)

        #expect(recorder.decryptCalls.count == 1)
        #expect(recorder.deliveries.isEmpty)
        #expect(recorder.clearedSessions.isEmpty)
        #expect(recorder.initiatedHandshakes.isEmpty)
    }

    @Test
    func earlyCiphertextSurvivesResponderHandshakeWindow() {
        let recorder = Recorder()
        recorder.hasSession = true
        recorder.awaitingResponderHandshake = true
        recorder.decryptResult = .failure(
            CryptoKitError.authenticationFailure
        )
        let handler = makeHandler(recorder: recorder)
        handler.handleEncrypted(
            makeEncryptedPacket(
                recipientID: Data(hexString: localPeerID.id)
            ),
            from: remotePeerID
        )

        recorder.currentDate =
            recorder.currentDate.addingTimeInterval(
                NoiseSecurityConstants.ordinaryResponderHandshakeTimeout
                    - 0.001
            )
        recorder.awaitingResponderHandshake = false
        recorder.decryptResult = .success(
            Data([NoisePayloadType.delivered.rawValue, 0x01])
        )
        handler.handleSessionAuthenticated(remotePeerID)

        #expect(recorder.decryptCalls.count == 2)
        #expect(recorder.deliveries.count == 1)
        #expect(recorder.clearedSessions.isEmpty)
        #expect(recorder.initiatedHandshakes.isEmpty)
    }

    private func makeHandshakePacket(recipientID: Data?) -> BitchatPacket {
        BitchatPacket(
            type: MessageType.noiseHandshake.rawValue,
            senderID: Data(hexString: remotePeerID.id) ?? Data(),
            recipientID: recipientID,
            timestamp: 900_000,
            payload: Data([0x01, 0x02, 0x03]),
            signature: nil,
            ttl: TransportConfig.messageTTLDefault
        )
    }

    private func makeEncryptedPacket(
        recipientID: Data?,
        timestamp: UInt64 = 900_000,
        payload: Data = Data([0xC0, 0xFF, 0xEE])
    ) -> BitchatPacket {
        BitchatPacket(
            type: MessageType.noiseEncrypted.rawValue,
            senderID: Data(hexString: remotePeerID.id) ?? Data(),
            recipientID: recipientID,
            timestamp: timestamp,
            payload: payload,
            signature: nil,
            ttl: TransportConfig.messageTTLDefault
        )
    }
}
