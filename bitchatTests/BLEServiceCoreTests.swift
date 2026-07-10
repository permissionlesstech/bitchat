//
// BLEServiceCoreTests.swift
// bitchatTests
//
// Focused BLEService tests for packet handling behavior.
//

import Testing
import Foundation
import CoreBluetooth
import BitFoundation
@testable import bitchat

struct BLEServiceCoreTests {

    @Test
    func duplicatePacket_isDeduped() async throws {
        let ble = makeService()
        let delegate = PublicCaptureDelegate()
        ble.delegate = delegate

        // Public messages must carry a valid signature from the claimed sender;
        // sign the packet and preseed the sender's signing key so the receiver
        // can verify it (production `sendMessage` signs public broadcasts too).
        let signer = NoiseEncryptionService(keychain: MockKeychain())
        let sender = PeerID(str: "1122334455667788")
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        let unsigned = makePublicPacket(content: "Hello", sender: sender, timestamp: timestamp)
        let packet = try #require(signer.signPacket(unsigned), "Failed to sign public message")
        let signingKey = signer.getSigningPublicKeyData()

        ble._test_handlePacket(packet, fromPeerID: sender, signingPublicKey: signingKey)
        let receivedFirst = await TestHelpers.waitUntil(
            { delegate.publicMessagesSnapshot().count == 1 },
            timeout: TestConstants.longTimeout
        )
        #expect(receivedFirst)

        ble._test_handlePacket(packet, fromPeerID: sender, signingPublicKey: signingKey)
        let receivedDuplicate = await TestHelpers.waitUntil(
            { delegate.publicMessagesSnapshot().count > 1 },
            timeout: TestConstants.shortTimeout
        )
        #expect(!receivedDuplicate)

        let messages = delegate.publicMessagesSnapshot()
        #expect(messages.count == 1)
        #expect(messages.first?.content == "Hello")
    }

    @Test
    func staleBroadcast_isIgnored() async {
        let ble = makeService()
        let delegate = PublicCaptureDelegate()
        ble.delegate = delegate

        let sender = PeerID(str: "A1B2C3D4E5F60708")
        let oldTimestamp = UInt64(Date().addingTimeInterval(-901).timeIntervalSince1970 * 1000)
        let packet = makePublicPacket(content: "Old", sender: sender, timestamp: oldTimestamp)

        ble._test_handlePacket(packet, fromPeerID: sender)

        let didReceive = await TestHelpers.waitUntil({ !delegate.publicMessagesSnapshot().isEmpty }, timeout: 0.3)
        #expect(!didReceive)
        #expect(delegate.publicMessagesSnapshot().isEmpty)
    }

    @Test
    func announceSenderMismatch_isRejected() async throws {
        let ble = makeService()

        let signer = NoiseEncryptionService(keychain: MockKeychain())
        let announcement = AnnouncementPacket(
            nickname: "Spoof",
            noisePublicKey: signer.getStaticPublicKeyData(),
            signingPublicKey: signer.getSigningPublicKeyData(),
            directNeighbors: nil
        )
        let payload = try #require(announcement.encode(), "Failed to encode announcement")

        let derivedPeerID = PeerID(publicKey: announcement.noisePublicKey)
        let wrongFirst = derivedPeerID.bare.first == "0" ? "1" : "0"
        let wrongBare = String(wrongFirst) + String(derivedPeerID.bare.dropFirst())
        let wrongPeerID = PeerID(str: wrongBare)
        let packet = BitchatPacket(
            type: MessageType.announce.rawValue,
            senderID: Data(hexString: wrongPeerID.id) ?? Data(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil,
            ttl: 7
        )
        let signed = try #require(signer.signPacket(packet), "Failed to sign announce packet")

        ble._test_handlePacket(signed, fromPeerID: wrongPeerID, preseedPeer: false)

        _ = await TestHelpers.waitUntil({ !ble.currentPeerSnapshots().isEmpty }, timeout: 0.3)
        #expect(ble.currentPeerSnapshots().isEmpty)
    }

    @Test
    func ingressAllowsRelayedSenderOnBoundLink() async throws {
        let ble = makeService()
        let boundPeer = PeerID(str: "1122334455667788")
        let relayedSender = PeerID(str: "8899aabbccddeeff")
        let packet = makePublicPacket(
            content: "Relayed",
            sender: relayedSender,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000)
        )

        #expect(ble._test_acceptsIngress(packet: packet, boundPeerID: boundPeer))
    }

    @Test
    func ingressAllowsDirectAnnounceThatConflictsWithBoundLink() async throws {
        // Peer-ID rotation heal: the announce must reach signature
        // verification, which decides whether the link rebinds.
        let ble = makeService()
        let boundPeer = PeerID(str: "1122334455667788")
        let claimedPeer = PeerID(str: "8899aabbccddeeff")
        let packet = BitchatPacket(
            type: MessageType.announce.rawValue,
            senderID: Data(hexString: claimedPeer.id) ?? Data(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: Data(),
            signature: nil,
            ttl: 7
        )

        #expect(ble._test_acceptsIngress(packet: packet, boundPeerID: boundPeer))
    }

    @Test
    func ingressRejectsRequestSyncThatConflictsWithBoundLink() async throws {
        let ble = makeService()
        let boundPeer = PeerID(str: "1122334455667788")
        let claimedPeer = PeerID(str: "8899aabbccddeeff")
        let packet = BitchatPacket(
            type: MessageType.requestSync.rawValue,
            senderID: Data(hexString: claimedPeer.id) ?? Data(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: Data(),
            signature: nil,
            ttl: 0
        )

        #expect(!ble._test_acceptsIngress(packet: packet, boundPeerID: boundPeer))
    }

    @Test
    func verifiedDirectAnnounceRebindsRotatedLinkAndRetiresOldPeer() async throws {
        let ble = makeService()
        let oldPeerID = PeerID(str: "1122334455667788")
        let centralUUID = "central-rotation"

        // A connected peer whose link binding predates its relaunch.
        ble._test_seedConnectedPeer(oldPeerID, nickname: "alice")
        ble._test_bindCentral(centralUUID, to: oldPeerID)

        // The relaunched device re-announces its rotated identity over the
        // still-open link.
        let signer = NoiseEncryptionService(keychain: MockKeychain())
        let announcement = AnnouncementPacket(
            nickname: "alice",
            noisePublicKey: signer.getStaticPublicKeyData(),
            signingPublicKey: signer.getSigningPublicKeyData(),
            directNeighbors: nil
        )
        let payload = try #require(announcement.encode(), "Failed to encode announcement")
        let newPeerID = PeerID(publicKey: announcement.noisePublicKey)
        let unsigned = BitchatPacket(
            type: MessageType.announce.rawValue,
            senderID: Data(hexString: newPeerID.id) ?? Data(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil,
            ttl: 7
        )
        let packet = try #require(signer.signPacket(unsigned), "Failed to sign announce packet")

        #expect(ble._test_recordIngressIfNew(packet: packet, linkID: centralUUID))
        ble._test_handlePacket(packet, fromPeerID: newPeerID, preseedPeer: false)

        let rebound = await TestHelpers.waitUntil(
            { ble._test_centralBinding(centralUUID) == newPeerID },
            timeout: TestConstants.longTimeout
        )
        #expect(rebound)

        let retired = await TestHelpers.waitUntil(
            {
                let peerIDs = ble.currentPeerSnapshots().map(\.peerID)
                return peerIDs.contains(newPeerID) && !peerIDs.contains(oldPeerID)
            },
            timeout: TestConstants.longTimeout
        )
        #expect(retired)
    }

    @Test
    func replayedDirectAnnounceCannotStealBoundIdentity() async throws {
        let ble = makeService()
        let attackerPeerID = PeerID(str: "1122334455667788")
        let victimLink = "central-victim"
        let attackerLink = "central-attacker"

        // The victim's identity, genuinely bound on its own link.
        let victimSigner = NoiseEncryptionService(keychain: MockKeychain())
        let announcement = AnnouncementPacket(
            nickname: "victim",
            noisePublicKey: victimSigner.getStaticPublicKeyData(),
            signingPublicKey: victimSigner.getSigningPublicKeyData(),
            directNeighbors: nil
        )
        let payload = try #require(announcement.encode(), "Failed to encode announcement")
        let victimPeerID = PeerID(publicKey: announcement.noisePublicKey)
        let courierStore = CourierStore(persistsToDisk: false)
        ble.courierStore = courierStore
        let carriedEnvelope = CourierEnvelope(
            recipientTag: CourierEnvelope.recipientTag(
                noiseStaticKey: announcement.noisePublicKey,
                epochDay: CourierEnvelope.epochDay(for: Date())
            ),
            expiry: UInt64(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000),
            ciphertext: Data(repeating: 0xA5, count: 128)
        )
        #expect(courierStore.deposit(
            carriedEnvelope,
            from: Data(repeating: 0xC0, count: 32),
            tier: .favorite
        ))
        let sprayRecipientKey = Data(repeating: 0xB4, count: 32)
        let sprayEnvelope = CourierEnvelope(
            recipientTag: CourierEnvelope.recipientTag(
                noiseStaticKey: sprayRecipientKey,
                epochDay: CourierEnvelope.epochDay(for: Date())
            ),
            expiry: UInt64(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000),
            ciphertext: Data(repeating: 0xB5, count: 128),
            copies: 4
        )
        #expect(courierStore.deposit(
            sprayEnvelope,
            from: Data(repeating: 0xC0, count: 32),
            tier: .favorite
        ))
        ble._test_seedConnectedPeer(victimPeerID, nickname: "victim")
        ble._test_bindCentral(victimLink, to: victimPeerID)
        ble._test_seedConnectedPeer(attackerPeerID, nickname: "attacker")
        ble._test_bindCentral(attackerLink, to: attackerPeerID)

        // Preserve the hard case: a valid victim session still exists on the
        // victim's own physical link when the announce is replayed elsewhere.
        let message1 = try ble._test_noiseInitiateHandshake(with: victimPeerID)
        let message2 = try #require(
            try victimSigner.processHandshakeMessage(from: ble.myPeerID, message: message1)
        )
        let message3 = try #require(
            try ble._test_noiseProcessHandshakeMessage(from: victimPeerID, message: message2)
        )
        _ = try victimSigner.processHandshakeMessage(from: ble.myPeerID, message: message3)
        #expect(ble.canDeliverSecurely(to: victimPeerID))
        ble._test_markNoiseAuthenticatedCentral(victimLink, to: victimPeerID)

        // The victim's fresh signed announce replayed on the attacker's bound
        // link with its direct TTL restored (TTL is excluded from signing, so
        // the signature still verifies).
        let unsigned = BitchatPacket(
            type: MessageType.announce.rawValue,
            senderID: Data(hexString: victimPeerID.id) ?? Data(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil,
            ttl: 7
        )
        let packet = try #require(victimSigner.signPacket(unsigned), "Failed to sign announce packet")

        #expect(ble._test_recordIngressIfNew(packet: packet, linkID: attackerLink))
        ble._test_handlePacket(packet, fromPeerID: victimPeerID, preseedPeer: false)

        // The rebind must be refused: the identity already owns a live link.
        let stolen = await TestHelpers.waitUntil(
            { ble._test_centralBinding(attackerLink) == victimPeerID },
            timeout: 0.3
        )
        #expect(!stolen)
        #expect(ble._test_centralBinding(attackerLink) == attackerPeerID)
        #expect(ble._test_centralBinding(victimLink) == victimPeerID)
        // A valid signature authenticates the announce contents, not the
        // unsigned direct TTL. Without a Noise-authenticated session on the
        // ingress link, the replay must not retire mail or consume spray state.
        #expect(!courierStore.isEmpty)
        await Task.yield()
        await Task.yield()
        let stillEligibleForSpray = courierStore.takeSprayCopies(for: announcement.noisePublicKey)
        #expect(stillEligibleForSpray.map(\.copies) == [2])
        #expect(courierStore.takeEnvelopes(for: announcement.noisePublicKey) == [carriedEnvelope])
        #expect(ble.canDeliverSecurely(to: victimPeerID))
        // And the replay must not retire the link's real bound peer.
        #expect(ble.currentPeerSnapshots().map(\.peerID).contains(attackerPeerID))
    }

    @Test
    func replayedDirectAnnounceForAbsentPeerNeverYieldsSecureDelivery() async throws {
        // Residual heal-path gap: the victim has NO live link, so the
        // identity-owns-a-link containment cannot refuse the rebind. The
        // replay steals the link binding, and because a successful rebind
        // promotes its new owner to connected (a legitimate rotation heal
        // requires that), the absent victim may read as connected. That
        // forged presence is display-only and accepted — the invariant that
        // holds is that the stolen link can never produce an established
        // Noise session, so MessageRouter's canDeliverSecurely gate routes
        // DMs through retain + courier instead of trusting it outright.
        let ble = makeService()
        let attackerPeerID = PeerID(str: "1122334455667788")
        let attackerLink = "central-attacker-absent-victim"
        ble._test_seedConnectedPeer(attackerPeerID, nickname: "attacker")
        ble._test_bindCentral(attackerLink, to: attackerPeerID)

        // The absent victim's fresh signed announce, replayed on the
        // attacker's bound link with its direct TTL restored.
        let victimSigner = NoiseEncryptionService(keychain: MockKeychain())
        let announcement = AnnouncementPacket(
            nickname: "victim",
            noisePublicKey: victimSigner.getStaticPublicKeyData(),
            signingPublicKey: victimSigner.getSigningPublicKeyData(),
            directNeighbors: nil
        )
        let payload = try #require(announcement.encode(), "Failed to encode announcement")
        let victimPeerID = PeerID(publicKey: announcement.noisePublicKey)
        let unsigned = BitchatPacket(
            type: MessageType.announce.rawValue,
            senderID: Data(hexString: victimPeerID.id) ?? Data(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil,
            ttl: 7
        )
        let packet = try #require(victimSigner.signPacket(unsigned), "Failed to sign announce packet")

        #expect(ble._test_recordIngressIfNew(packet: packet, linkID: attackerLink))
        ble._test_handlePacket(packet, fromPeerID: victimPeerID, preseedPeer: false)

        // The rebind steals the link (no live link owns the victim's
        // identity, so containment cannot refuse) …
        let rebound = await TestHelpers.waitUntil(
            { ble._test_centralBinding(attackerLink) == victimPeerID },
            timeout: TestConstants.longTimeout
        )
        #expect(rebound)
        // … and the promote marks the absent victim connected: the accepted,
        // display-only forged-presence residue (documented at
        // BLEAnnounceHandler's linkBoundToOtherPeer check) …
        let forgedPresence = await TestHelpers.waitUntil(
            { ble.isPeerConnected(victimPeerID) },
            timeout: TestConstants.longTimeout
        )
        #expect(forgedPresence)
        // … but secure delivery stays impossible — the DM gate holds, and
        // MessageRouter retains + couriers instead of trusting the link.
        #expect(!ble.canDeliverSecurely(to: victimPeerID))
    }

    @Test
    func replayedDirectAnnounceWithStaleVictimSessionCannotBridgeThroughForeignLink() async throws {
        let ble = makeService()
        // Keep announce handling out of the carried-mail path: the regression
        // is specifically BridgeCourierService's direct delivery preflight.
        ble.courierStore = CourierStore(persistsToDisk: false)
        let attackerPeerID = PeerID(str: "1122334455667788")
        let attackerLink = "central-attacker-stale-victim-session"
        ble._test_seedConnectedPeer(attackerPeerID, nickname: "attacker")
        ble._test_bindCentral(attackerLink, to: attackerPeerID)

        let victim = NoiseEncryptionService(keychain: MockKeychain())
        let announcement = AnnouncementPacket(
            nickname: "victim",
            noisePublicKey: victim.getStaticPublicKeyData(),
            signingPublicKey: victim.getSigningPublicKeyData(),
            directNeighbors: nil
        )
        let victimPeerID = PeerID(publicKey: announcement.noisePublicKey)

        // Establish a real peer-level victim session without associating it
        // with the attacker's physical link. This is the stale-session case
        // that a plain `canDeliverSecurely` check cannot distinguish.
        let message1 = try ble._test_noiseInitiateHandshake(with: victimPeerID)
        let message2 = try #require(
            try victim.processHandshakeMessage(from: ble.myPeerID, message: message1)
        )
        let message3 = try #require(
            try ble._test_noiseProcessHandshakeMessage(from: victimPeerID, message: message2)
        )
        _ = try victim.processHandshakeMessage(from: ble.myPeerID, message: message3)
        #expect(ble.canDeliverSecurely(to: victimPeerID))

        let payload = try #require(announcement.encode(), "Failed to encode announcement")
        let unsigned = BitchatPacket(
            type: MessageType.announce.rawValue,
            senderID: Data(hexString: victimPeerID.id) ?? Data(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil,
            ttl: 7
        )
        let replay = try #require(victim.signPacket(unsigned), "Failed to sign replayed announce")
        #expect(ble._test_recordIngressIfNew(packet: replay, linkID: attackerLink))
        ble._test_handlePacket(replay, fromPeerID: victimPeerID, preseedPeer: false)

        let rebound = await TestHelpers.waitUntil(
            { ble._test_centralBinding(attackerLink) == victimPeerID },
            timeout: TestConstants.longTimeout
        )
        #expect(rebound)
        #expect(ble.canDeliverSecurely(to: victimPeerID))

        let outbound = OutboundPacketTap()
        ble._test_onOutboundPacket = { outbound.record($0) }
        let envelope = CourierEnvelope(
            recipientTag: CourierEnvelope.recipientTag(
                noiseStaticKey: announcement.noisePublicKey,
                epochDay: CourierEnvelope.epochDay(for: Date())
            ),
            expiry: UInt64(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000),
            ciphertext: Data(repeating: 0xA5, count: 128)
        )

        #expect(!ble.deliverBridgedEnvelope(envelope, to: victimPeerID))
        // Reject before even entering the outbound pipeline: otherwise a
        // real attacker CBCentral could accept the opaque courier packet and
        // cause the relay drop's persisted seen ID to be consumed forever.
        #expect(outbound.count(ofType: .courierEnvelope) == 0)
    }

    /// A legitimate rotation announce necessarily arrives on a link still
    /// bound to the OLD ID, so its registry upsert stores the new peer
    /// disconnected. The successful rebind must promote it: a healed
    /// rotation with a live link has to read as connected again for routing
    /// and outbox flushes.
    @Test
    func rotationHealPromotesRotatedPeerToConnected() async throws {
        let ble = makeService()
        let oldPeerID = PeerID(str: "1122334455667788")
        let centralUUID = "central-rotation-promote"

        ble._test_seedConnectedPeer(oldPeerID, nickname: "alice")
        ble._test_bindCentral(centralUUID, to: oldPeerID)

        let signer = NoiseEncryptionService(keychain: MockKeychain())
        let announcement = AnnouncementPacket(
            nickname: "alice",
            noisePublicKey: signer.getStaticPublicKeyData(),
            signingPublicKey: signer.getSigningPublicKeyData(),
            directNeighbors: nil
        )
        let payload = try #require(announcement.encode(), "Failed to encode announcement")
        let newPeerID = PeerID(publicKey: announcement.noisePublicKey)
        let unsigned = BitchatPacket(
            type: MessageType.announce.rawValue,
            senderID: Data(hexString: newPeerID.id) ?? Data(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil,
            ttl: 7
        )
        let packet = try #require(signer.signPacket(unsigned), "Failed to sign announce packet")

        #expect(ble._test_recordIngressIfNew(packet: packet, linkID: centralUUID))
        ble._test_handlePacket(packet, fromPeerID: newPeerID, preseedPeer: false)

        let rebound = await TestHelpers.waitUntil(
            { ble._test_centralBinding(centralUUID) == newPeerID },
            timeout: TestConstants.longTimeout
        )
        #expect(rebound)

        let connected = await TestHelpers.waitUntil(
            { ble.isPeerConnected(newPeerID) },
            timeout: TestConstants.longTimeout
        )
        #expect(connected)
    }

    /// Noise sessions are keyed by the short wire ID, but routers may key
    /// sends by the full 64-hex Noise key (favorites resolution does). The
    /// secure-delivery gate must normalize like isPeerConnected, or an
    /// established session is misread as insecure and every DM needlessly
    /// retains + couriers until an ack.
    @Test
    func canDeliverSecurelyNormalizesFullNoiseKeyPeerIDs() async throws {
        let ble = makeService()
        let remote = NoiseEncryptionService(keychain: MockKeychain())
        let remoteKey = remote.getStaticPublicKeyData()
        let shortID = PeerID(publicKey: remoteKey)
        let fullKeyID = PeerID(hexData: remoteKey)
        #expect(fullKeyID.toShort() == shortID)
        #expect(!ble.canDeliverSecurely(to: shortID))

        // Full XX handshake; the local side keys the session by the short
        // wire ID, exactly as packets present it in production.
        let m1 = try ble._test_noiseInitiateHandshake(with: shortID)
        let m2 = try #require(try remote.processHandshakeMessage(from: ble.myPeerID, message: m1))
        let m3 = try #require(try ble._test_noiseProcessHandshakeMessage(from: shortID, message: m2))
        _ = try remote.processHandshakeMessage(from: ble.myPeerID, message: m3)

        #expect(ble.canDeliverSecurely(to: shortID))
        #expect(ble.canDeliverSecurely(to: fullKeyID))
    }

    @Test
    func ingressRejectsSelfLoopbackBeforeSpoofChecks() async throws {
        let ble = makeService()
        let packet = makePublicPacket(
            content: "Loopback",
            sender: ble.myPeerID,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000)
        )

        #expect(!ble._test_acceptsIngress(packet: packet, boundPeerID: PeerID(str: "1122334455667788")))
    }

    @Test
    func ingressAllowsSelfAuthoredRSRWithTTLZeroFromBoundPeer() async throws {
        let ble = makeService()
        var packet = makePublicPacket(
            content: "Recovered by sync",
            sender: ble.myPeerID,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000)
        )
        packet.isRSR = true
        packet.ttl = 0

        #expect(ble._test_acceptsIngress(packet: packet, boundPeerID: PeerID(str: "1122334455667788")))
    }

    @Test
    func ingressRecordSuppressesSecondLinkDuplicate() async throws {
        let ble = makeService()
        let packet = makePublicPacket(
            content: "Duplicate link copy",
            sender: PeerID(str: "1122334455667788"),
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000)
        )

        #expect(ble._test_recordIngressIfNew(packet: packet, linkID: "central-a"))
        #expect(!ble._test_recordIngressIfNew(packet: packet, linkID: "central-b"))
    }

    @Test
    func panicReset_rotatesPeerIDDerivedFromNewNoiseFingerprint() async throws {
        let ble = makeService()
        let originalPeerID = ble.myPeerID
        let originalFingerprint = ble.noiseIdentityFingerprint()
        #expect(originalPeerID == PeerID(str: originalFingerprint.prefix(16)))

        ble.resetIdentityForPanic(currentNickname: "anon")

        // The Noise identity is regenerated and the peer ID swaps with it
        // (atomically, behind a messageQueue barrier).
        let newFingerprint = ble.noiseIdentityFingerprint()
        #expect(newFingerprint != originalFingerprint)
        #expect(ble.myPeerID != originalPeerID)
        #expect(ble.myPeerID == PeerID(str: newFingerprint.prefix(16)))
    }

    @Test
    func modifiedServices_rediscoverWhenBitChatServiceIsInvalidated() async throws {
        let otherService = CBUUID(string: "0000180F-0000-1000-8000-00805F9B34FB")

        #expect(BLEService._test_shouldRediscoverBitChatService(
            invalidatedServiceUUIDs: [BLEService.serviceUUID],
            cachedServiceUUIDs: [otherService]
        ))
    }

    @Test
    func modifiedServices_rediscoverWhenCachedServicesNoLongerIncludeBitChat() async throws {
        let otherService = CBUUID(string: "0000180F-0000-1000-8000-00805F9B34FB")

        #expect(BLEService._test_shouldRediscoverBitChatService(
            invalidatedServiceUUIDs: [otherService],
            cachedServiceUUIDs: [otherService]
        ))
    }

    @Test
    func modifiedServices_ignoreUnrelatedInvalidationWhenBitChatIsStillCached() async throws {
        let otherService = CBUUID(string: "0000180F-0000-1000-8000-00805F9B34FB")

        #expect(!BLEService._test_shouldRediscoverBitChatService(
            invalidatedServiceUUIDs: [otherService],
            cachedServiceUUIDs: [BLEService.serviceUUID, otherService]
        ))
    }

    /// Pings are unsigned, so their claimed sender is attacker-controlled.
    /// The pong budget must be keyed on the ingress link (the directly
    /// connected peer that delivered the packet): rotating forged sender IDs
    /// over one link exhausts one budget instead of resetting it, so a single
    /// malicious link cannot turn /ping into an amplification primitive.
    @Test
    func meshPingResponseBudget_isPerIngressLinkNotClaimedSender() async throws {
        let ble = makeService()
        let outbound = OutboundPacketTap()
        ble._test_onOutboundPacket = outbound.record

        let link = PeerID(str: "1122334455667788")
        let budget = TransportConfig.meshPingInboundMaxPerLink
        let myRecipientData = try #require(Data(hexString: ble.myPeerID.id))

        for i in 0..<(budget * 2) {
            // A fresh forged sender for every ping, all arriving on one link.
            let forgedSender = PeerID(str: String(format: "%016x", 0xA0_0000 + i))
            var nonce = Data(repeating: 0, count: MeshPingPayload.nonceLength)
            nonce[0] = UInt8(i)
            let payload = try #require(MeshPingPayload(nonce: nonce, originTTL: 7))
            let packet = BitchatPacket(
                type: MessageType.ping.rawValue,
                senderID: Data(hexString: forgedSender.id) ?? Data(),
                recipientID: myRecipientData,
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: payload.encode(),
                signature: nil,
                ttl: 7
            )
            ble._test_handlePacket(packet, fromPeerID: link, preseedPeer: false)
        }

        let reachedBudget = await TestHelpers.waitUntil(
            { outbound.count(ofType: .pong) >= budget },
            timeout: TestConstants.longTimeout
        )
        #expect(reachedBudget)
        // Give any over-budget pong a chance to surface, then confirm the
        // rotated sender IDs never bought a sixth response.
        let exceededBudget = await TestHelpers.waitUntil(
            { outbound.count(ofType: .pong) > budget },
            timeout: TestConstants.shortTimeout
        )
        #expect(!exceededBudget)
        #expect(outbound.count(ofType: .pong) == budget)
    }
}

/// Thread-safe capture of packets leaving the service under test.
private final class OutboundPacketTap {
    private let lock = NSLock()
    private var packets: [BitchatPacket] = []

    func record(_ packet: BitchatPacket) {
        lock.lock(); packets.append(packet); lock.unlock()
    }

    func count(ofType type: MessageType) -> Int {
        lock.lock(); defer { lock.unlock() }
        return packets.filter { $0.type == type.rawValue }.count
    }
}

private func makeService() -> BLEService {
    let keychain = MockKeychain()
    let identityManager = MockIdentityManager(keychain)
    let idBridge = NostrIdentityBridge(keychain: MockKeychainHelper())
    return BLEService(
        keychain: keychain,
        idBridge: idBridge,
        identityManager: identityManager,
        initializeBluetoothManagers: false
    )
}

private func makePublicPacket(content: String, sender: PeerID, timestamp: UInt64) -> BitchatPacket {
    BitchatPacket(
        type: MessageType.message.rawValue,
        senderID: Data(hexString: sender.id) ?? Data(),
        recipientID: nil,
        timestamp: timestamp,
        payload: Data(content.utf8),
        signature: nil,
        ttl: 3
    )
}

private final class PublicCaptureDelegate: BitchatDelegate {
    private let lock = NSLock()
    private(set) var publicMessages: [BitchatMessage] = []

    func didReceivePublicMessage(from peerID: PeerID, nickname: String, content: String, timestamp: Date, messageID: String?) {
        let message = BitchatMessage(
            id: messageID,
            sender: nickname,
            content: content,
            timestamp: timestamp,
            isRelay: false,
            originalSender: nil,
            isPrivate: false,
            recipientNickname: nil,
            senderPeerID: peerID,
            mentions: nil
        )
        lock.lock()
        publicMessages.append(message)
        lock.unlock()
    }

    func didReceiveMessage(_ message: BitchatMessage) {}
    func didConnectToPeer(_ peerID: PeerID) {}
    func didDisconnectFromPeer(_ peerID: PeerID) {}
    func didUpdatePeerList(_ peers: [PeerID]) {}
    func didUpdateBluetoothState(_ state: CBManagerState) {}

    func publicMessagesSnapshot() -> [BitchatMessage] {
        lock.lock()
        defer { lock.unlock() }
        return publicMessages
    }
}
