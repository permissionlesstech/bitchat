import BitFoundation
import Combine
import CoreBluetooth
import Foundation
import Testing
@testable import bitchat

/// Wire-level coverage for finalized DM media. The sender encrypts one typed
/// private-file payload, relays see only the outer Noise packet/fragments, and
/// the receiver reassembles, decrypts, validates, persists, and delivers it.
@Suite("Private media end to end", .serialized)
struct PrivateMediaEndToEndTests {
    @Test
    func privateMediaCancellationTombstonesAreCountBounded() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-media-tombstone-bound-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = makeService(baseDirectory: root)

        for index in 0..<600 {
            service.cancelTransfer("cancelled-before-admission-\(index)")
        }

        #expect(service._test_privateMediaAdmissionEntryCount() <= 512)
        await service._test_drainPrivateMediaSendPipeline()
    }

    @Test
    func privateMediaAdmissionCapacityRejectsNewcomerWithoutEvictingActiveTransfer() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-media-admission-capacity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = makeService(baseDirectory: root)
        let now = Date()
        let activeIDs = (0..<512).map { "capacity-active-\($0)" }
        for transferId in activeIDs {
            #expect(service._test_beginPrivateMediaAdmission(transferId, now: now))
        }
        defer {
            for transferId in activeIDs {
                service._test_finishPrivateMediaAdmission(transferId)
            }
        }

        let overflowID = "capacity-overflow-\(UUID().uuidString)"
        let rejections = TransferCancellationRecorder()
        let cancellable = TransferProgressManager.shared.publisher.sink { rejections.record($0) }
        let content = Data("%PDF-1.7\ncapacity".utf8)
        service.sendFilePrivate(
            BitchatFilePacket(
                fileName: "capacity.pdf",
                fileSize: UInt64(content.count),
                mimeType: "application/pdf",
                content: content
            ),
            to: PeerID(str: "1122334455667788"),
            transferId: overflowID,
            allowLegacyFallback: true
        )

        #expect(await TestHelpers.waitUntil(
            { rejections.contains(overflowID) },
            timeout: TestConstants.longTimeout
        ))
        #expect(rejections.reason(for: overflowID) != nil)
        #expect(service._test_isPrivateMediaAdmissionActive(activeIDs[0], now: now))
        #expect(service._test_privateMediaAdmissionEntryCount() == 512)
        _ = cancellable
    }

    @Test
    func expiredActivePrivateMediaAdmissionEmitsVisibleFailure() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-media-admission-expiry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = makeService(baseDirectory: root)
        let transferId = "expired-active-\(UUID().uuidString)"
        let admittedAt = Date(timeIntervalSince1970: 1_000)
        let rejections = TransferCancellationRecorder()
        let cancellable = TransferProgressManager.shared.publisher.sink { rejections.record($0) }

        #expect(service._test_beginPrivateMediaAdmission(transferId, now: admittedAt))
        #expect(!service._test_isPrivateMediaAdmissionActive(
            transferId,
            now: admittedAt.addingTimeInterval(60 * 60 + 1)
        ))
        #expect(await TestHelpers.waitUntil(
            { rejections.contains(transferId) },
            timeout: TestConstants.longTimeout
        ))
        #expect(rejections.reason(for: transferId) != nil)
        #expect(service._test_privateMediaAdmissionEntryCount() == 0)
        _ = cancellable
    }

    @Test
    func approvedLegacySendCancelledBeforeDeferredAdmissionDoesNotTransmit() async throws {
        try await assertApprovedLegacySendCancelledBeforeAdmission(label: "cancel")
    }

    @Test
    func approvedLegacySendDeletedBeforeDeferredAdmissionDoesNotTransmit() async throws {
        // ChatMediaTransferCoordinator.deleteMediaMessage now invokes this same
        // synchronous transport cancellation before removing its mapping; its
        // coordinator-level call is covered separately in the context tests.
        try await assertApprovedLegacySendCancelledBeforeAdmission(label: "delete")
    }

    @Test
    func legacyFallbackRequiresPerSendConsentAndConsumesItOnce() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-media-capability-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let aliceRoot = root.appendingPathComponent("alice", isDirectory: true)
        let bobRoot = root.appendingPathComponent("bob", isDirectory: true)
        let alice = makeService(baseDirectory: aliceRoot)
        let bob = makeService(baseDirectory: bobRoot)
        alice._test_seedConnectedPeer(
            bob.myPeerID,
            nickname: "Old Bob",
            noisePublicKey: bob.noiseStaticPublicKeyData()
        )

        let tap = PacketTap()
        let delegate = MessageCaptureDelegate()
        alice._test_onOutboundPacket = tap.record
        bob.delegate = delegate
        let content = Data("%PDF-1.7\nprivate".utf8)
        let file = BitchatFilePacket(
            fileName: "private.pdf",
            fileSize: UInt64(content.count),
            mimeType: "application/pdf",
            content: content
        )
        let cancellations = TransferCancellationRecorder()
        let cancellable = TransferProgressManager.shared.publisher.sink { cancellations.record($0) }

        let deniedID = "legacy-without-consent-\(UUID().uuidString)"
        alice.sendFilePrivate(
            file,
            to: bob.myPeerID,
            transferId: deniedID
        )
        let denied = await TestHelpers.waitUntil(
            { cancellations.contains(deniedID) },
            timeout: TestConstants.longTimeout
        )
        #expect(denied)
        #expect(tap.snapshot().allSatisfy { $0.type != MessageType.fileTransfer.rawValue })

        let allowedID = "legacy-with-consent-\(UUID().uuidString)"
        alice.sendFilePrivate(
            file,
            to: bob.myPeerID,
            transferId: allowedID,
            allowLegacyFallback: true
        )

        let sent = await TestHelpers.waitUntil(
            { tap.snapshot().contains { $0.type == MessageType.fileTransfer.rawValue } },
            timeout: TestConstants.longTimeout
        )
        #expect(sent)

        let outbound = tap.snapshot()
        let rawTransfers = outbound.filter { $0.type == MessageType.fileTransfer.rawValue }
        let raw = try #require(rawTransfers.first)
        #expect(rawTransfers.count == 1, "Migration fallback must never dual-send")
        #expect(outbound.allSatisfy { $0.type != MessageType.noiseEncrypted.rawValue })
        #expect(raw.recipientID == Data(hexString: bob.myPeerID.toShort().id))
        #expect(raw.signature?.count == 64)
        #expect(BitchatFilePacket.decode(raw.payload)?.content == content)

        // Exercise the normal raw receive path with Alice's actual signing
        // key. The migration fallback is accepted because it is directed and
        // signed; the handler still rejects unsigned/forged raw transfers.
        bob._test_handlePacket(
            raw,
            fromPeerID: alice.myPeerID,
            signingPublicKey: alice.noiseSigningPublicKeyData()
        )
        let delivered = await TestHelpers.waitUntil(
            { delegate.snapshot().count == 1 },
            timeout: TestConstants.longTimeout
        )
        #expect(delivered)
        #expect(delegate.snapshot().first?.isPrivate == true)
        #expect(recursivelyStoredFiles(under: bobRoot).count == 1)

        // Consent is invocation-scoped, not a sticky peer preference.
        let retryID = "legacy-retry-without-consent-\(UUID().uuidString)"
        alice.sendFilePrivate(file, to: bob.myPeerID, transferId: retryID)
        let retryDenied = await TestHelpers.waitUntil(
            { cancellations.contains(retryID) },
            timeout: TestConstants.longTimeout
        )
        #expect(retryDenied)
        #expect(tap.snapshot().filter { $0.type == MessageType.fileTransfer.rawValue }.count == 1)
        _ = cancellable
    }

    @Test
    func authenticatedPrivateMediaCapabilityPinsAgainstRawDowngrade() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-media-pin-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = MockIdentityManager(MockKeychain())
        let alice = makeService(
            baseDirectory: root.appendingPathComponent("alice", isDirectory: true),
            identityManager: identity
        )
        let bob = makeService(baseDirectory: root.appendingPathComponent("bob", isDirectory: true))
        let bobKey = bob.noiseStaticPublicKeyData()

        alice._test_seedConnectedPeer(
            bob.myPeerID,
            nickname: "Bob",
            capabilities: .privateMedia,
            noisePublicKey: bobKey
        )
        #expect(alice.privateMediaSendPolicy(to: bob.myPeerID) == .awaitingCapabilityProof)
        let bobFingerprint = bobKey.sha256Fingerprint()
        #expect(!identity.hasObservedPrivateMediaCapability(fingerprint: bobFingerprint))

        try await establishSession(alice: alice, bob: bob)
        let capabilityPinned = await TestHelpers.waitUntil(
            { identity.hasObservedPrivateMediaCapability(fingerprint: bobFingerprint) },
            timeout: TestConstants.longTimeout
        )
        #expect(capabilityPinned)

        #expect(alice.privateMediaSendPolicy(to: bob.myPeerID) == .encrypted)

        // A public no-bit announce cannot override state authenticated by the
        // current session. A later authenticated no-bit state is a real
        // downgrade and must block despite a caller offering legacy consent.
        alice._test_seedConnectedPeer(
            bob.myPeerID,
            nickname: "Bob",
            capabilities: [],
            noisePublicKey: bobKey
        )
        #expect(alice.privateMediaSendPolicy(to: bob.myPeerID) == .encrypted)
        let authenticatedNoBit = try authenticatedPeerStatePacket(
            from: bob,
            to: alice,
            capabilities: []
        )
        alice._test_handlePacket(authenticatedNoBit, fromPeerID: bob.myPeerID)
        let downgradeObserved = await TestHelpers.waitUntil(
            { alice.privateMediaSendPolicy(to: bob.myPeerID) == .blockedDowngrade },
            timeout: TestConstants.longTimeout
        )
        #expect(downgradeObserved)
        #expect(alice.privateMediaSendPolicy(to: bob.myPeerID) == .blockedDowngrade)

        let tap = PacketTap()
        alice._test_onOutboundPacket = tap.record
        let transferID = "pinned-downgrade-\(UUID().uuidString)"
        let cancellations = TransferCancellationRecorder()
        let cancellable = TransferProgressManager.shared.publisher.sink { cancellations.record($0) }
        let content = Data("%PDF-1.7\nblocked".utf8)
        alice.sendFilePrivate(
            BitchatFilePacket(
                fileName: "blocked.pdf",
                fileSize: UInt64(content.count),
                mimeType: "application/pdf",
                content: content
            ),
            to: bob.myPeerID,
            transferId: transferID,
            allowLegacyFallback: true
        )

        let blocked = await TestHelpers.waitUntil(
            { cancellations.contains(transferID) },
            timeout: TestConstants.longTimeout
        )
        #expect(blocked)
        #expect(tap.snapshot().allSatisfy { $0.type != MessageType.fileTransfer.rawValue })
        _ = cancellable
    }

    @Test
    func unpinnedExplicitCapabilitiesWithoutPrivateMediaRequireConsent() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-media-explicit-capabilities-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let alice = makeService(baseDirectory: root.appendingPathComponent("alice", isDirectory: true))
        let bob = makeService(baseDirectory: root.appendingPathComponent("bob", isDirectory: true))

        alice._test_seedConnectedPeer(
            bob.myPeerID,
            nickname: "Modern Bob",
            capabilities: [],
            noisePublicKey: bob.noiseStaticPublicKeyData()
        )

        #expect(alice.privateMediaSendPolicy(to: bob.myPeerID) == .legacyRequiresConsent)
    }

    @Test
    func capabilityAnnounceCannotPoisonPinWithoutMatchingNoiseAuthentication() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-media-poisoning-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = MockIdentityManager(MockKeychain())
        let alice = makeService(
            baseDirectory: root.appendingPathComponent("alice", isDirectory: true),
            identityManager: identity
        )
        let bob = makeService(baseDirectory: root.appendingPathComponent("bob", isDirectory: true))
        let bobFingerprint = bob.noiseStaticPublicKeyData().sha256Fingerprint()
        let capableAnnounce = try signedAnnounce(
            from: bob,
            capabilities: .privateMedia
        )
        alice._test_handlePacket(
            capableAnnounce,
            fromPeerID: bob.myPeerID,
            preseedPeer: false
        )
        let advertised = await TestHelpers.waitUntil(
            { alice.privateMediaSendPolicy(to: bob.myPeerID) == .awaitingCapabilityProof },
            timeout: TestConstants.longTimeout
        )
        #expect(advertised)
        // The production signed-announce path ran, but with no authenticated
        // session it must remain a no-op. Querying policy is side-effect free.
        #expect(!identity.hasObservedPrivateMediaCapability(fingerprint: bobFingerprint))

        let noBitAnnounce = try signedAnnounce(
            from: bob,
            capabilities: []
        )
        alice._test_handlePacket(
            noBitAnnounce,
            fromPeerID: bob.myPeerID,
            preseedPeer: false
        )
        let remainedLegacyEligible = await TestHelpers.waitUntil(
            { alice.privateMediaSendPolicy(to: bob.myPeerID) == .legacyRequiresConsent },
            timeout: TestConstants.longTimeout
        )
        #expect(remainedLegacyEligible)
    }

    @Test
    func copiedNoiseKeyPreannounceCannotPinWhenRealOwnerAuthenticates() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-media-copied-static-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = MockIdentityManager(MockKeychain())
        let alice = makeService(
            baseDirectory: root.appendingPathComponent("alice", isDirectory: true),
            identityManager: identity
        )
        let bob = makeService(baseDirectory: root.appendingPathComponent("bob", isDirectory: true))
        let attacker = makeService(baseDirectory: root.appendingPathComponent("attacker", isDirectory: true))
        let bobKey = bob.noiseStaticPublicKeyData()
        let bobFingerprint = bobKey.sha256Fingerprint()

        // Mallory copies Bob's public Noise key, advertises bit 8, supplies
        // Mallory's Ed25519 key, and self-signs. This is internally consistent
        // but does not prove possession of Bob's Noise private key.
        let forged = try copiedStaticAnnounce(
            claimedOwner: bob,
            signedBy: attacker,
            capabilities: .privateMedia
        )
        alice._test_handlePacket(forged, fromPeerID: bob.myPeerID, preseedPeer: false)
        let hintAccepted = await TestHelpers.waitUntil(
            { alice.privateMediaSendPolicy(to: bob.myPeerID) == .awaitingCapabilityProof },
            timeout: TestConstants.longTimeout
        )
        #expect(hintAccepted)
        #expect(!identity.hasObservedPrivateMediaCapability(fingerprint: bobFingerprint))

        let proofs = try await establishSessionCapturingPeerState(alice: alice, bob: bob)
        #expect(!identity.hasObservedPrivateMediaCapability(fingerprint: bobFingerprint))
        #expect(alice.privateMediaSendPolicy(to: bob.myPeerID) == .awaitingCapabilityProof)

        // Only Bob's encrypted state authorizes bit 8 and replaces the forged
        // announcement signing key with Bob's Noise-authenticated Ed key.
        alice._test_handlePacket(proofs.bob, fromPeerID: bob.myPeerID)
        let pinned = await TestHelpers.waitUntil(
            { identity.hasObservedPrivateMediaCapability(fingerprint: bobFingerprint) },
            timeout: TestConstants.longTimeout
        )
        #expect(pinned)
        #expect(identity.authenticatedSigningPublicKey(forFingerprint: bobFingerprint)
            == bob.noiseSigningPublicKeyData())
        #expect(alice.privateMediaSendPolicy(to: bob.myPeerID) == .encrypted)

        bob._test_handlePacket(proofs.alice, fromPeerID: alice.myPeerID)
        alice._test_onOutboundPacket = nil
        bob._test_onOutboundPacket = nil
    }

    @Test
    func droppedInitiatorProofConvergesViaSingleAuthenticatedEcho() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-media-proof-echo-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let alice = makeService(baseDirectory: root.appendingPathComponent("alice", isDirectory: true))
        let bob = makeService(baseDirectory: root.appendingPathComponent("bob", isDirectory: true))
        alice._test_seedConnectedPeer(
            bob.myPeerID,
            nickname: "Bob",
            capabilities: .privateMedia,
            noisePublicKey: bob.noiseStaticPublicKeyData()
        )
        bob._test_seedConnectedPeer(
            alice.myPeerID,
            nickname: "Alice",
            capabilities: .privateMedia,
            noisePublicKey: alice.noiseStaticPublicKeyData()
        )

        let initial = try await establishSessionCapturingPeerState(alice: alice, bob: bob)
        // Model Alice's first proof racing ahead of Bob's message-3 handling
        // and being dropped. Bob's proof reaches Alice; Alice must emit one
        // idempotent echo that lets Bob converge without a new handshake.
        _ = initial.alice
        let echoTap = PacketTap()
        alice._test_onOutboundPacket = echoTap.record
        alice._test_handlePacket(initial.bob, fromPeerID: bob.myPeerID)
        let echoed = await TestHelpers.waitUntil(
            { echoTap.snapshot().contains { $0.type == MessageType.noiseEncrypted.rawValue } },
            timeout: TestConstants.longTimeout
        )
        #expect(echoed)
        let echo = try #require(
            echoTap.snapshot().first { $0.type == MessageType.noiseEncrypted.rawValue }
        )
        bob._test_handlePacket(echo, fromPeerID: alice.myPeerID)
        let converged = await TestHelpers.waitUntil(
            {
                alice.privateMediaSendPolicy(to: bob.myPeerID) == .encrypted
                    && bob.privateMediaSendPolicy(to: alice.myPeerID) == .encrypted
            },
            timeout: TestConstants.longTimeout
        )
        #expect(converged)
        alice._test_onOutboundPacket = nil
        bob._test_onOutboundPacket = nil
    }

    @Test
    func noProofTimeoutResolvesToConsentWithoutSendingRawMedia() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-media-proof-timeout-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let alice = makeService(baseDirectory: root.appendingPathComponent("alice", isDirectory: true))
        let bob = makeService(baseDirectory: root.appendingPathComponent("bob", isDirectory: true))
        alice._test_seedConnectedPeer(
            bob.myPeerID,
            nickname: "Prerelease Bob",
            capabilities: .privateMedia,
            noisePublicKey: bob.noiseStaticPublicKeyData()
        )

        _ = try await establishSessionCapturingPeerState(alice: alice, bob: bob)
        #expect(alice.privateMediaSendPolicy(to: bob.myPeerID) == .awaitingCapabilityProof)
        let recorder = PrivateMediaPolicyRecorder()
        alice.resolvePrivateMediaSendPolicy(to: bob.myPeerID) { recorder.record($0) }
        let registered = await TestHelpers.waitUntil(
            { alice._test_hasPendingPrivateMediaPolicyResolution(for: bob.myPeerID) },
            timeout: TestConstants.longTimeout
        )
        #expect(registered)
        alice._test_forcePrivateMediaProofTimeout(for: bob.myPeerID)
        let resolved = await TestHelpers.waitUntil(
            { recorder.snapshot() == .legacyRequiresConsent },
            timeout: TestConstants.longTimeout
        )
        #expect(resolved)
        #expect(alice.privateMediaSendPolicy(to: bob.myPeerID) == .legacyRequiresConsent)
        #expect(recorder.snapshot() != .encrypted)
        alice._test_onOutboundPacket = nil
        bob._test_onOutboundPacket = nil
    }

    @Test
    func queuedPrivatePayloadWaitsForProofNotHandshakeCompletion() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-media-proof-drain-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let alice = makeService(baseDirectory: root.appendingPathComponent("alice", isDirectory: true))
        let bob = makeService(baseDirectory: root.appendingPathComponent("bob", isDirectory: true))
        alice._test_seedConnectedPeer(
            bob.myPeerID,
            nickname: "Bob",
            capabilities: .privateMedia,
            noisePublicKey: bob.noiseStaticPublicKeyData()
        )
        let proofs = try await establishSessionCapturingPeerState(alice: alice, bob: bob)

        let content = Data("proof-gated-private-file".utf8)
        let file = BitchatFilePacket(
            fileName: "proof.txt",
            fileSize: UInt64(content.count),
            mimeType: "text/plain",
            content: content
        )
        let payload = try #require(BLENoisePayloadFactory.privateFile(file))
        let transferID = "proof-gated-\(UUID().uuidString)"
        alice._test_enqueuePendingNoisePayload(payload, transferId: transferID, for: bob.myPeerID)
        alice._test_sendPendingNoisePayloadsAfterHandshake(for: bob.myPeerID)

        #expect(alice._test_privateMediaTransferState(transferId: transferID).pendingNoise)
        alice._test_handlePacket(proofs.bob, fromPeerID: bob.myPeerID)
        let drained = await TestHelpers.waitUntil(
            { !alice._test_privateMediaTransferState(transferId: transferID).pendingNoise },
            timeout: TestConstants.longTimeout
        )
        #expect(drained)
        bob._test_handlePacket(proofs.alice, fromPeerID: alice.myPeerID)
        alice._test_onOutboundPacket = nil
        bob._test_onOutboundPacket = nil
    }

    @Test
    func authenticatedFingerprintMismatchCannotPoisonCapabilityPin() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-media-key-mismatch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = MockIdentityManager(MockKeychain())
        let alice = makeService(
            baseDirectory: root.appendingPathComponent("alice", isDirectory: true),
            identityManager: identity
        )
        let bob = makeService(baseDirectory: root.appendingPathComponent("bob", isDirectory: true))
        let impostor = makeService(baseDirectory: root.appendingPathComponent("impostor", isDirectory: true))
        let impostorKey = impostor.noiseStaticPublicKeyData()
        let reconciliations = PeerIDRecorder()
        alice._test_onPrivateMediaSessionReconciled = reconciliations.record

        alice._test_seedConnectedPeer(
            bob.myPeerID,
            nickname: "Bob",
            capabilities: .privateMedia,
            noisePublicKey: impostorKey
        )
        try await establishSession(alice: alice, bob: bob)

        let sessionReconciled = await TestHelpers.waitUntil(
            { reconciliations.contains(bob.myPeerID) },
            timeout: TestConstants.longTimeout
        )
        #expect(sessionReconciled)
        #expect(!identity.hasObservedPrivateMediaCapability(
            fingerprint: impostorKey.sha256Fingerprint()
        ))
        alice._test_seedConnectedPeer(
            bob.myPeerID,
            nickname: "Bob",
            capabilities: [],
            noisePublicKey: impostorKey
        )
        #expect(alice.privateMediaSendPolicy(to: bob.myPeerID) == .legacyRequiresConsent)
    }

    @Test
    func capabilityAnnounceAfterNoiseSessionStillRequiresEncryptedProof() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-media-race-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = MockIdentityManager(MockKeychain())
        let alice = makeService(
            baseDirectory: root.appendingPathComponent("alice", isDirectory: true),
            identityManager: identity
        )
        let bob = makeService(baseDirectory: root.appendingPathComponent("bob", isDirectory: true))

        let proofs = try await establishSessionCapturingPeerState(alice: alice, bob: bob)
        let bobKey = bob.noiseStaticPublicKeyData()
        let capableAnnounce = try signedAnnounce(
            from: bob,
            capabilities: .privateMedia
        )
        alice._test_handlePacket(
            capableAnnounce,
            fromPeerID: bob.myPeerID,
            preseedPeer: false
        )

        let announceDidNotPin = await TestHelpers.waitUntil(
            { alice.privateMediaSendPolicy(to: bob.myPeerID) == .awaitingCapabilityProof },
            timeout: TestConstants.longTimeout
        )
        #expect(announceDidNotPin)
        #expect(!identity.hasObservedPrivateMediaCapability(
            fingerprint: bobKey.sha256Fingerprint()
        ))

        alice._test_handlePacket(proofs.bob, fromPeerID: bob.myPeerID)

        let pinned = await TestHelpers.waitUntil(
            {
                identity.hasObservedPrivateMediaCapability(
                    fingerprint: bobKey.sha256Fingerprint()
                )
            },
            timeout: TestConstants.longTimeout
        )
        #expect(pinned)
        bob._test_handlePacket(proofs.alice, fromPeerID: alice.myPeerID)
        alice._test_onOutboundPacket = nil
        bob._test_onOutboundPacket = nil
    }

    @Test
    func encryptedAndConsentedLegacySendsRejectAboveAndroidFragmentCap() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-media-fragment-cap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let alice = makeService(baseDirectory: root.appendingPathComponent("alice", isDirectory: true))
        let bob = makeService(baseDirectory: root.appendingPathComponent("bob", isDirectory: true))
        let oldCarol = makeService(baseDirectory: root.appendingPathComponent("carol", isDirectory: true))

        alice._test_seedConnectedPeer(
            bob.myPeerID,
            nickname: "Bob",
            capabilities: .privateMedia,
            noisePublicKey: bob.noiseStaticPublicKeyData()
        )
        alice._test_seedConnectedPeer(
            oldCarol.myPeerID,
            nickname: "Old Carol",
            noisePublicKey: oldCarol.noiseStaticPublicKeyData()
        )
        try await establishSession(alice: alice, bob: bob)

        var state: UInt64 = 0x1234_5678_9ABC_DEF0
        let body = Data((0..<(130 * 1024)).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: state >> 32)
        })
        let content = Data("%PDF-1.7\n".utf8) + body
        let file = BitchatFilePacket(
            fileName: "too-many-fragments.pdf",
            fileSize: UInt64(content.count),
            mimeType: "application/pdf",
            content: content
        )

        let tap = PacketTap()
        alice._test_onOutboundPacket = tap.record
        let rejections = TransferCancellationRecorder()
        let cancellable = TransferProgressManager.shared.publisher.sink { rejections.record($0) }
        let encryptedID = "encrypted-over-256-\(UUID().uuidString)"
        let legacyID = "legacy-over-256-\(UUID().uuidString)"

        alice.sendFilePrivate(file, to: bob.myPeerID, transferId: encryptedID)
        alice.sendFilePrivate(
            file,
            to: oldCarol.myPeerID,
            transferId: legacyID,
            allowLegacyFallback: true
        )

        let bothRejected = await TestHelpers.waitUntil(
            { rejections.contains(encryptedID) && rejections.contains(legacyID) },
            timeout: TestConstants.longTimeout
        )
        #expect(bothRejected)
        #expect(rejections.reason(for: encryptedID)?.contains("256") == true)
        #expect(rejections.reason(for: legacyID)?.contains("256") == true)
        #expect(tap.snapshot().isEmpty, "No outer packet or fragment may be exposed before size rejection")
        _ = cancellable
    }

    @Test
    func queuedPrivateEncryptionFailureRejectsBoundTransfer() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-media-queued-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let alice = makeService(baseDirectory: root.appendingPathComponent("alice", isDirectory: true))
        let bob = makeService(baseDirectory: root.appendingPathComponent("bob", isDirectory: true))
        try await establishSession(alice: alice, bob: bob)

        let transferID = "queued-encryption-failure-\(UUID().uuidString)"
        let rejections = TransferCancellationRecorder()
        let cancellable = TransferProgressManager.shared.publisher.sink { rejections.record($0) }
        var oversizedTypedPayload = Data([NoisePayloadType.privateFile.rawValue])
        oversizedTypedPayload.append(Data(
            repeating: 0x42,
            count: NoiseSecurityConstants.maxPrivateFilePlaintextSize
        ))

        alice._test_enqueuePendingNoisePayload(
            oversizedTypedPayload,
            transferId: transferID,
            for: bob.myPeerID
        )
        alice._test_sendPendingNoisePayloadsAfterHandshake(for: bob.myPeerID)

        let rejected = await TestHelpers.waitUntil(
            { rejections.contains(transferID) },
            timeout: TestConstants.longTimeout
        )
        #expect(rejected)
        #expect(rejections.reason(for: transferID)?.isEmpty == false)
        _ = cancellable
    }

    @Test
    func canonical0x20EncryptedFileIsAcceptedAcrossV1OuterPacket() async throws {
        let content = Data("%PDF-1.7\nandroid-private".utf8)
        try await assertInboundEncryptedPrivateMedia(
            typeByte: 0x20,
            content: content,
            outerVersion: 1,
            directoryLabel: "android-0x20"
        )
    }

    @Test
    func prerelease0x09LargeEncryptedFileIsAcceptedDuringMigration() async throws {
        let content = Data("%PDF-1.7\nprerelease-private".utf8)
            + Data(repeating: 0x39, count: 70 * 1024)
        #expect(content.count > NoiseSecurityConstants.maxMessageSize)
        try await assertInboundEncryptedPrivateMedia(
            typeByte: NoisePayloadType.prereleasePrivateFileRawValue,
            content: content,
            outerVersion: 2,
            directoryLabel: "prerelease-0x09"
        )
    }

    @Test
    func privateJPEGIsOpaqueBeforeFragmentationAndDelivers() async throws {
        let marker = Data("JPEG_PRIVATE_MARKER_7f5e5eacb86f4b9a".utf8)
        let content = Data([0xFF, 0xD8, 0xFF, 0xE0])
            + marker
            + Data(repeating: 0x4A, count: 6 * 1024)
        try await assertPrivateMediaRoundTrip(
            fileName: "private.jpg",
            mimeType: "image/jpeg",
            content: content,
            marker: marker,
            expectedMessagePrefix: "[image]"
        )
    }

    @Test
    func finalizedPrivateM4AIsOpaqueBeforeFragmentationAndDelivers() async throws {
        let marker = Data("M4A_PRIVATE_MARKER_e0cd431b61fb4a6c".utf8)
        let content = Data([0x00, 0x00, 0x00, 0x18])
            + Data("ftypM4A ".utf8)
            + marker
            + Data(repeating: 0x4D, count: 6 * 1024)
        try await assertPrivateMediaRoundTrip(
            fileName: "voice_0011223344556677.m4a",
            mimeType: "audio/mp4",
            content: content,
            marker: marker,
            expectedMessagePrefix: "[voice]"
        )
    }

    @Test
    func capablePeerUsesCanonicalAndroid0x20EncryptedSend() async throws {
        let marker = Data("PDF_PRIVATE_MARKER_b333f84b8fc7478d".utf8)
        let content = Data("%PDF-1.7\n".utf8)
            + marker
            + Data(repeating: 0x50, count: 6 * 1024)
        let file = BitchatFilePacket(
            fileName: "private.pdf",
            fileSize: UInt64(content.count),
            mimeType: "application/pdf",
            content: content
        )
        #expect(BLENoisePayloadFactory.privateFile(file)?.first == 0x20)
        try await assertPrivateMediaRoundTrip(
            fileName: "private.pdf",
            mimeType: "application/pdf",
            content: content,
            marker: marker,
            expectedMessagePrefix: "[file]"
        )
    }

    @Test
    func privateMediaAboveOrdinaryNoiseLimitUsesV2OuterPacketAndDelivers() async throws {
        let marker = Data("LARGE_PRIVATE_MARKER_1ec63f261a7041ee".utf8)
        let content = Data("%PDF-1.7\n".utf8)
            + marker
            + Data(repeating: 0x4C, count: 70 * 1024)
        try await assertPrivateMediaRoundTrip(
            fileName: "large-private.pdf",
            mimeType: "application/pdf",
            content: content,
            marker: marker,
            expectedMessagePrefix: "[file]",
            expectedOuterVersion: 2
        )
    }

    /// Models an already-established remote sender independently of the local
    /// send policy. Exact Android b7f0b33d plaintext bytes are frozen in
    /// `BLENoisePayloadFactoryTests`; this helper exercises the encrypted
    /// inbound transport around that shared wire encoding.
    private func assertInboundEncryptedPrivateMedia(
        typeByte: UInt8,
        content: Data,
        outerVersion: UInt8,
        directoryLabel: String
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-media-\(directoryLabel)-\(UUID().uuidString)", isDirectory: true)
        let aliceRoot = root.appendingPathComponent("alice", isDirectory: true)
        let bobRoot = root.appendingPathComponent("bob", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let alice = makeService(baseDirectory: aliceRoot)
        let bob = makeService(baseDirectory: bobRoot)
        let delegate = MessageCaptureDelegate()
        bob.delegate = delegate
        try await establishSession(alice: alice, bob: bob)

        let file = BitchatFilePacket(
            fileName: "\(directoryLabel).pdf",
            fileSize: UInt64(content.count),
            mimeType: "application/pdf",
            content: content
        )
        let encodedFile = try #require(file.encode())
        var typedPayload = Data([typeByte])
        typedPayload.append(encodedFile)

        let encrypted = try alice._test_makeEncryptedNoisePacket(typedPayload, to: bob.myPeerID)
        let remoteShapedPacket = BitchatPacket(
            type: encrypted.type,
            senderID: encrypted.senderID,
            recipientID: encrypted.recipientID,
            timestamp: encrypted.timestamp,
            payload: encrypted.payload,
            signature: nil,
            ttl: encrypted.ttl,
            version: outerVersion
        )
        bob._test_handlePacket(remoteShapedPacket, fromPeerID: alice.myPeerID)

        let delivered = await TestHelpers.waitUntil(
            { delegate.snapshot().count == 1 },
            timeout: TestConstants.longTimeout
        )
        #expect(delivered)
        #expect(delegate.snapshot().first?.isPrivate == true)
        let stored = recursivelyStoredFiles(under: bobRoot)
        #expect(stored.count == 1)
        if let storedURL = stored.first {
            #expect(try Data(contentsOf: storedURL) == content)
        }
    }

    private func assertApprovedLegacySendCancelledBeforeAdmission(label: String) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-media-admission-\(label)-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let alice = makeService(baseDirectory: root.appendingPathComponent("alice", isDirectory: true))
        let bob = makeService(baseDirectory: root.appendingPathComponent("bob", isDirectory: true))
        alice._test_seedConnectedPeer(
            bob.myPeerID,
            nickname: "Legacy Bob",
            noisePublicKey: bob.noiseStaticPublicKeyData()
        )

        let transferId = "approved-\(label)-\(UUID().uuidString)"
        let gate = PrivateMediaDeferredSendGate()
        let tap = PacketTap()
        alice._test_onOutboundPacket = tap.record
        alice._test_beforePrivateMediaDeferredSend = { id in
            guard id == transferId else { return }
            gate.pause()
        }
        defer {
            gate.release()
            alice._test_beforePrivateMediaDeferredSend = nil
        }

        let content = Data("%PDF-1.7\ncancelled-before-admission".utf8)
        alice.sendFilePrivate(
            BitchatFilePacket(
                fileName: "cancelled.pdf",
                fileSize: UInt64(content.count),
                mimeType: "application/pdf",
                content: content
            ),
            to: bob.myPeerID,
            transferId: transferId,
            allowLegacyFallback: true
        )

        let paused = await TestHelpers.waitUntil(
            { gate.hasPaused },
            timeout: TestConstants.longTimeout
        )
        #expect(paused)

        // This is the transport action used by both cancel and delete. It must
        // invalidate synchronously while messageQueue is still held above.
        alice.cancelTransfer(transferId)
        gate.release()
        await alice._test_drainPrivateMediaSendPipeline()

        let state = alice._test_privateMediaTransferState(transferId: transferId)
        #expect(!state.admissionActive)
        #expect(!state.pendingNoise)
        #expect(state.activeScheduler == 0)
        #expect(state.pendingScheduler == 0)
        #expect(await TestHelpers.waitUntil(
            { alice._test_privateMediaAdmissionEntryCount() == 0 },
            timeout: TestConstants.longTimeout
        ))
        #expect(tap.snapshot().allSatisfy {
            $0.type != MessageType.fileTransfer.rawValue
                && $0.type != MessageType.noiseEncrypted.rawValue
        })
    }

    private func assertPrivateMediaRoundTrip(
        fileName: String,
        mimeType: String,
        content: Data,
        marker: Data,
        expectedMessagePrefix: String,
        expectedOuterVersion: UInt8 = 2
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-media-e2e-\(UUID().uuidString)", isDirectory: true)
        let aliceRoot = root.appendingPathComponent("alice", isDirectory: true)
        let bobRoot = root.appendingPathComponent("bob", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let alice = makeService(baseDirectory: aliceRoot)
        let bob = makeService(baseDirectory: bobRoot)
        let tap = PacketTap()
        let delegate = MessageCaptureDelegate()
        bob.delegate = delegate

        alice._test_seedConnectedPeer(
            bob.myPeerID,
            nickname: "Bob",
            capabilities: .privateMedia,
            noisePublicKey: bob.noiseStaticPublicKeyData()
        )
        bob._test_seedConnectedPeer(
            alice.myPeerID,
            nickname: "Alice",
            capabilities: .privateMedia,
            noisePublicKey: alice.noiseStaticPublicKeyData()
        )
        try await establishSession(alice: alice, bob: bob)
        alice._test_onOutboundPacket = tap.record

        let file = BitchatFilePacket(
            fileName: fileName,
            fileSize: UInt64(content.count),
            mimeType: mimeType,
            content: content
        )
        alice.sendFilePrivate(file, to: bob.myPeerID, transferId: "wire-\(UUID().uuidString)")

        let fragmented = await TestHelpers.waitUntil(
            { tap.hasCompleteFragmentTrain },
            timeout: 10
        )
        #expect(fragmented)

        let outbound = tap.snapshot()
        let encryptedPackets = outbound.filter { $0.type == MessageType.noiseEncrypted.rawValue }
        let fragments = outbound
            .filter { $0.type == MessageType.fragment.rawValue }
            .sorted { fragmentIndex($0) < fragmentIndex($1) }

        #expect(encryptedPackets.count == 1)
        #expect(encryptedPackets.first?.version == expectedOuterVersion)
        #expect(!fragments.isEmpty)
        #expect(outbound.allSatisfy { $0.type != MessageType.fileTransfer.rawValue })
        for packet in encryptedPackets + fragments {
            #expect(packet.payload.range(of: marker) == nil)
            #expect(packet.payload.range(of: content) == nil)
        }

        // Real BLE delivers the train at the scheduler's paced interval. Feed
        // bounded batches here instead of enqueuing hundreds of synthetic
        // callbacks at once, which can exhaust libdispatch worker threads as
        // they wait on the fragment-assembly barrier.
        for batchStart in stride(from: 0, to: fragments.count, by: 16) {
            let batchEnd = min(batchStart + 16, fragments.count)
            for fragment in fragments[batchStart..<batchEnd] {
                bob._test_handlePacket(fragment, fromPeerID: alice.myPeerID)
            }
            await bob._test_drainFragmentPipeline()
        }

        let delivered = await TestHelpers.waitUntil(
            { delegate.snapshot().count == 1 },
            timeout: TestConstants.longTimeout
        )
        #expect(delivered)

        let message = try #require(delegate.snapshot().first)
        #expect(message.isPrivate)
        #expect(message.senderPeerID == alice.myPeerID)
        #expect(message.content.hasPrefix(expectedMessagePrefix))

        let stored = recursivelyStoredFiles(under: bobRoot)
        #expect(stored.count == 1)
        let storedURL = try #require(stored.first)
        #expect(try Data(contentsOf: storedURL) == content)
    }

    private func makeService(
        baseDirectory: URL,
        identityManager: SecureIdentityStateManagerProtocol? = nil
    ) -> BLEService {
        let keychain = MockKeychain()
        return BLEService(
            keychain: keychain,
            idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
            identityManager: identityManager ?? MockIdentityManager(keychain),
            initializeBluetoothManagers: false,
            incomingFileStore: BLEIncomingFileStore(baseDirectory: baseDirectory)
        )
    }

    private func establishSession(alice: BLEService, bob: BLEService) async throws {
        let proofs = try await establishSessionCapturingPeerState(alice: alice, bob: bob)
        bob._test_handlePacket(proofs.alice, fromPeerID: alice.myPeerID)
        alice._test_handlePacket(proofs.bob, fromPeerID: bob.myPeerID)
        // Fence the message/identity mutations without assuming either test
        // seeded a registry entry (inbound-only tests intentionally do not).
        await alice._test_drainNoiseMessagePipeline()
        await bob._test_drainNoiseMessagePipeline()
        alice._test_onOutboundPacket = nil
        bob._test_onOutboundPacket = nil
    }

    private func establishSessionCapturingPeerState(
        alice: BLEService,
        bob: BLEService
    ) async throws -> (alice: BitchatPacket, bob: BitchatPacket) {
        let aliceTap = PacketTap()
        let bobTap = PacketTap()
        alice._test_onOutboundPacket = aliceTap.record
        bob._test_onOutboundPacket = bobTap.record

        let first = try alice._test_noiseInitiateHandshake(with: bob.myPeerID)
        let second = try #require(
            try bob._test_noiseProcessHandshakeMessage(from: alice.myPeerID, message: first)
        )
        let third = try #require(
            try alice._test_noiseProcessHandshakeMessage(from: bob.myPeerID, message: second)
        )
        _ = try bob._test_noiseProcessHandshakeMessage(from: alice.myPeerID, message: third)
        #expect(alice.canDeliverSecurely(to: bob.myPeerID))
        #expect(bob.canDeliverSecurely(to: alice.myPeerID))

        let emitted = await TestHelpers.waitUntil(
            {
                aliceTap.snapshot().contains { $0.type == MessageType.noiseEncrypted.rawValue }
                    && bobTap.snapshot().contains { $0.type == MessageType.noiseEncrypted.rawValue }
            },
            timeout: TestConstants.longTimeout
        )
        #expect(emitted)
        let aliceProof = try #require(
            aliceTap.snapshot().first { $0.type == MessageType.noiseEncrypted.rawValue }
        )
        let bobProof = try #require(
            bobTap.snapshot().first { $0.type == MessageType.noiseEncrypted.rawValue }
        )
        return (aliceProof, bobProof)
    }

    private func authenticatedPeerStatePacket(
        from sender: BLEService,
        to recipient: BLEService,
        capabilities: PeerCapabilities
    ) throws -> BitchatPacket {
        let state = AuthenticatedPeerStatePacket(
            capabilities: capabilities,
            signingPublicKey: sender.noiseSigningPublicKeyData()
        )
        let typed = try #require(BLENoisePayloadFactory.authenticatedPeerState(state))
        return try sender._test_makeEncryptedNoisePacket(typed, to: recipient.myPeerID)
    }

    private func signedAnnounce(
        from service: BLEService,
        capabilities: PeerCapabilities?
    ) throws -> BitchatPacket {
        let announcement = AnnouncementPacket(
            nickname: "Bob",
            noisePublicKey: service.noiseStaticPublicKeyData(),
            signingPublicKey: service.noiseSigningPublicKeyData(),
            directNeighbors: nil,
            capabilities: capabilities
        )
        let payload = try #require(announcement.encode())
        let unsigned = BitchatPacket(
            type: MessageType.announce.rawValue,
            senderID: Data(hexString: service.myPeerID.id) ?? Data(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1_000),
            payload: payload,
            signature: nil,
            ttl: TransportConfig.messageTTLDefault
        )
        return service.signPacketForBroadcast(unsigned)
    }

    private func copiedStaticAnnounce(
        claimedOwner: BLEService,
        signedBy signer: BLEService,
        capabilities: PeerCapabilities
    ) throws -> BitchatPacket {
        let announcement = AnnouncementPacket(
            nickname: "Mallory-as-Bob",
            noisePublicKey: claimedOwner.noiseStaticPublicKeyData(),
            signingPublicKey: signer.noiseSigningPublicKeyData(),
            directNeighbors: nil,
            capabilities: capabilities
        )
        let payload = try #require(announcement.encode())
        let unsigned = BitchatPacket(
            type: MessageType.announce.rawValue,
            senderID: Data(hexString: claimedOwner.myPeerID.id) ?? Data(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1_000),
            payload: payload,
            signature: nil,
            // Relayed shape avoids the proactive direct-hint handshake in
            // this deterministic test; it does not change signature validity.
            ttl: TransportConfig.messageTTLDefault - 1
        )
        return signer.signPacketForBroadcast(unsigned)
    }

    private func recursivelyStoredFiles(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }

        return enumerator.compactMap { item in
            guard let url = item as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return nil
            }
            return url
        }
    }
}

private func fragmentIndex(_ packet: BitchatPacket) -> Int {
    guard packet.payload.count >= 10 else { return .max }
    return (Int(packet.payload[8]) << 8) | Int(packet.payload[9])
}

private final class PacketTap: @unchecked Sendable {
    private let lock = NSLock()
    private var packets: [BitchatPacket] = []

    func record(_ packet: BitchatPacket) {
        lock.lock()
        packets.append(packet)
        lock.unlock()
    }

    func snapshot() -> [BitchatPacket] {
        lock.lock()
        defer { lock.unlock() }
        return packets
    }

    var hasCompleteFragmentTrain: Bool {
        let fragments = snapshot().filter { $0.type == MessageType.fragment.rawValue }
        guard let first = fragments.first, first.payload.count >= 12 else { return false }
        let total = (Int(first.payload[10]) << 8) | Int(first.payload[11])
        return total > 0 && fragments.count >= total
    }
}

private final class PrivateMediaDeferredSendGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var paused = false
    private var released = false

    var hasPaused: Bool {
        condition.lock()
        defer { condition.unlock() }
        return paused
    }

    func pause() {
        condition.lock()
        paused = true
        condition.broadcast()
        while !released {
            condition.wait()
        }
        condition.unlock()
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class PeerIDRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var peerIDs: [PeerID] = []

    func record(_ peerID: PeerID) {
        lock.lock()
        peerIDs.append(peerID)
        lock.unlock()
    }

    func contains(_ peerID: PeerID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return peerIDs.contains(peerID)
    }
}

private final class PrivateMediaPolicyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var policy: PrivateMediaSendPolicy?

    func record(_ policy: PrivateMediaSendPolicy) {
        lock.lock()
        self.policy = policy
        lock.unlock()
    }

    func snapshot() -> PrivateMediaSendPolicy? {
        lock.lock()
        defer { lock.unlock() }
        return policy
    }
}

private final class MessageCaptureDelegate: BitchatDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [BitchatMessage] = []

    func didReceiveMessage(_ message: BitchatMessage) {
        lock.lock()
        messages.append(message)
        lock.unlock()
    }

    func snapshot() -> [BitchatMessage] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }

    func didConnectToPeer(_ peerID: PeerID) {}
    func didDisconnectFromPeer(_ peerID: PeerID) {}
    func didUpdatePeerList(_ peers: [PeerID]) {}
    func didUpdateBluetoothState(_ state: CBManagerState) {}
}

private final class TransferCancellationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var transferIDs: Set<String> = []
    private var rejectionReasons: [String: String] = [:]

    func record(_ event: TransferProgressManager.Event) {
        let id: String
        switch event {
        case .cancelled(let cancelledID, _, _):
            id = cancelledID
        case .rejected(let rejectedID, _):
            id = rejectedID
        case .started, .updated, .completed:
            return
        }
        lock.lock()
        transferIDs.insert(id)
        if case .rejected(_, let reason) = event {
            rejectionReasons[id] = reason
        }
        lock.unlock()
    }

    func contains(_ transferID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return transferIDs.contains(transferID)
    }


    func reason(for transferID: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return rejectionReasons[transferID]
    }
}
