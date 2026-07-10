//
// CourierEndToEndTests.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
import Combine
import CoreBluetooth
import BitFoundation
@testable import bitchat

/// Three-node courier flow exercised through real BLEService instances with
/// packets ferried in-process: Alice deposits a sealed envelope with Carol
/// while Bob is unreachable; Carol hands it over when Bob announces; Bob
/// opens it and sees Alice's message in the right DM thread.
struct CourierEndToEndTests {

    // MARK: - Helpers

    private final class PacketTap {
        private let lock = NSLock()
        private var packets: [BitchatPacket] = []

        func record(_ packet: BitchatPacket) {
            lock.lock(); packets.append(packet); lock.unlock()
        }

        func first(ofType type: MessageType) -> BitchatPacket? {
            lock.lock(); defer { lock.unlock() }
            return packets.first { $0.type == type.rawValue }
        }

        func count(ofType type: MessageType) -> Int {
            lock.lock(); defer { lock.unlock() }
            return packets.filter { $0.type == type.rawValue }.count
        }

        func all(ofType type: MessageType) -> [BitchatPacket] {
            lock.lock(); defer { lock.unlock() }
            return packets.filter { $0.type == type.rawValue }
        }
    }

    private final class NoiseCaptureDelegate: BitchatDelegate {
        private let lock = NSLock()
        private var payloads: [(peerID: PeerID, type: NoisePayloadType, payload: Data)] = []

        func didReceiveNoisePayload(from peerID: PeerID, type: NoisePayloadType, payload: Data, timestamp: Date) {
            lock.lock(); payloads.append((peerID, type, payload)); lock.unlock()
        }

        func snapshot() -> [(peerID: PeerID, type: NoisePayloadType, payload: Data)] {
            lock.lock(); defer { lock.unlock() }
            return payloads
        }

        // Unused BitchatDelegate requirements.
        func didReceiveMessage(_ message: BitchatMessage) {}
        func didConnectToPeer(_ peerID: PeerID) {}
        func didDisconnectFromPeer(_ peerID: PeerID) {}
        func didUpdatePeerList(_ peers: [PeerID]) {}
        func didUpdateBluetoothState(_ state: CBManagerState) {}
        func didReceivePublicMessage(from peerID: PeerID, nickname: String, content: String, timestamp: Date, messageID: String?) {}
    }

    private func makeService(identityManager: MockIdentityManager? = nil) -> BLEService {
        let keychain = MockKeychain()
        let identityManager = identityManager ?? MockIdentityManager(keychain)
        let idBridge = NostrIdentityBridge(keychain: MockKeychainHelper())
        let service = BLEService(
            keychain: keychain,
            idBridge: idBridge,
            identityManager: identityManager,
            initializeBluetoothManagers: false
        )
        service.courierStore = CourierStore(persistsToDisk: false)
        return service
    }

    /// Handling any packet from a peer preseeds it as a connected,
    /// verified entry in the receiving service's registry.
    private func preseedConnectedPeer(_ peer: BLEService, in service: BLEService) {
        let packet = BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: Data(hexString: peer.myPeerID.id) ?? Data(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: Data("ping".utf8),
            signature: nil,
            ttl: 1
        )
        service._test_handlePacket(packet, fromPeerID: peer.myPeerID)
    }

    /// Establishes the Noise session that proves the direct link's peer owns
    /// its announced static identity. CoreBluetooth is disabled in this suite,
    /// so the handshake is ferried in-process just like courier packets.
    private func establishNoiseSession(between initiator: BLEService, and responder: BLEService) throws {
        let message1 = try initiator._test_noiseInitiateHandshake(with: responder.myPeerID)
        let message2 = try #require(
            try responder._test_noiseProcessHandshakeMessage(from: initiator.myPeerID, message: message1)
        )
        let message3 = try #require(
            try initiator._test_noiseProcessHandshakeMessage(from: responder.myPeerID, message: message2)
        )
        _ = try responder._test_noiseProcessHandshakeMessage(from: initiator.myPeerID, message: message3)
    }

    // MARK: - Tests

    @Test func courierCarriesMessageAcrossDisjointConnectivity() async throws {
        let alice = makeService()
        let carol = makeService()
        let bob = makeService()
        // Alice and Carol are mutual favorites; trust policy is exercised
        // separately in depositFromUntrustedPeerIsRejected.
        carol.courierDepositPolicy = { _, _ in .favorite }

        let bobDelegate = NoiseCaptureDelegate()
        bob.delegate = bobDelegate

        let aliceOut = PacketTap()
        alice._test_onOutboundPacket = aliceOut.record
        let carolOut = PacketTap()
        carol._test_onOutboundPacket = carolOut.record
        let bobOut = PacketTap()
        bob._test_onOutboundPacket = bobOut.record

        // Alice can see Carol; Bob is nowhere on the mesh.
        preseedConnectedPeer(carol, in: alice)

        // 1. Alice seals to Bob's static key and deposits with Carol.
        #expect(alice.sendCourierMessage(
            "the camp moved north",
            messageID: "courier-msg-1",
            recipientNoiseKey: bob.noiseStaticPublicKeyData(),
            via: [carol.myPeerID]
        ))
        let deposited = await TestHelpers.waitUntil(
            { aliceOut.first(ofType: .courierEnvelope) != nil },
            timeout: TestConstants.defaultTimeout
        )
        #expect(deposited)
        let depositPacket = try #require(aliceOut.first(ofType: .courierEnvelope))

        // 2. Ferry the deposit to Carol; she carries it (opaque to her).
        carol._test_handlePacket(depositPacket, fromPeerID: alice.myPeerID, signingPublicKey: alice.noiseSigningPublicKeyData())
        let carried = await TestHelpers.waitUntil(
            { !carol.courierStore.isEmpty },
            timeout: TestConstants.defaultTimeout
        )
        #expect(carried)

        // 3. Later, Bob proves link ownership and announces near Carol →
        // handover fires.
        try establishNoiseSession(between: carol, and: bob)
        bob.sendBroadcastAnnounce()
        let announced = await TestHelpers.waitUntil(
            { bobOut.first(ofType: .announce) != nil },
            timeout: TestConstants.defaultTimeout
        )
        #expect(announced)
        let announcePacket = try #require(bobOut.first(ofType: .announce))
        carol._test_handlePacket(announcePacket, fromPeerID: bob.myPeerID, preseedPeer: false)

        let handedOver = await TestHelpers.waitUntil(
            { carolOut.first(ofType: .courierEnvelope) != nil },
            timeout: TestConstants.defaultTimeout
        )
        #expect(handedOver)
        // With CoreBluetooth disabled there is no physical link for the send
        // planner to accept, so Carol truthfully retains the durable copy even
        // though the packet tap lets us ferry the attempted handover below.
        #expect(!carol.courierStore.isEmpty)
        let handoverPacket = try #require(carolOut.first(ofType: .courierEnvelope))
        #expect(PeerID(hexData: handoverPacket.recipientID) == bob.myPeerID)

        // 4. Ferry the handover to Bob; he opens the envelope.
        bob._test_handlePacket(handoverPacket, fromPeerID: carol.myPeerID)
        let received = await TestHelpers.waitUntil(
            { !bobDelegate.snapshot().isEmpty },
            timeout: TestConstants.defaultTimeout
        )
        #expect(received)

        let delivered = try #require(bobDelegate.snapshot().first)
        #expect(delivered.type == .privateMessage)
        // Alice is absent from Bob's mesh, so the sender resolves to her
        // full noise-key ID — the stable favorite conversation — not the
        // short mesh ID (which Bob couldn't resolve to a nickname) and not
        // the courier's identity.
        #expect(delivered.peerID == PeerID(hexData: alice.noiseStaticPublicKeyData()))
        #expect(delivered.peerID != carol.myPeerID)
        let message = try #require(PrivateMessagePacket.decode(from: delivered.payload))
        #expect(message.messageID == "courier-msg-1")
        #expect(message.content == "the camp moved north")
    }

    @Test func courieredMailFromBlockedSenderIsDropped() async throws {
        let alice = makeService()
        let carol = makeService()
        let bobIdentity = MockIdentityManager(MockKeychain())
        let bob = makeService(identityManager: bobIdentity)
        carol.courierDepositPolicy = { _, _ in .favorite }

        let bobDelegate = NoiseCaptureDelegate()
        bob.delegate = bobDelegate
        let aliceOut = PacketTap()
        alice._test_onOutboundPacket = aliceOut.record
        let carolOut = PacketTap()
        carol._test_onOutboundPacket = carolOut.record
        let bobOut = PacketTap()
        bob._test_onOutboundPacket = bobOut.record

        preseedConnectedPeer(carol, in: alice)

        // Bob blocked Alice by her stable Noise identity while she was away.
        bobIdentity.setBlocked(alice.noiseStaticPublicKeyData().sha256Fingerprint(), isBlocked: true)

        #expect(alice.sendCourierMessage(
            "you should not see this",
            messageID: "courier-msg-blocked-sender",
            recipientNoiseKey: bob.noiseStaticPublicKeyData(),
            via: [carol.myPeerID]
        ))
        let deposited = await TestHelpers.waitUntil(
            { aliceOut.first(ofType: .courierEnvelope) != nil },
            timeout: TestConstants.defaultTimeout
        )
        #expect(deposited)
        let depositPacket = try #require(aliceOut.first(ofType: .courierEnvelope))

        carol._test_handlePacket(depositPacket, fromPeerID: alice.myPeerID, signingPublicKey: alice.noiseSigningPublicKeyData())
        let carried = await TestHelpers.waitUntil(
            { !carol.courierStore.isEmpty },
            timeout: TestConstants.defaultTimeout
        )
        #expect(carried)

        try establishNoiseSession(between: carol, and: bob)
        bob.sendBroadcastAnnounce()
        let announced = await TestHelpers.waitUntil(
            { bobOut.first(ofType: .announce) != nil },
            timeout: TestConstants.defaultTimeout
        )
        #expect(announced)
        let announcePacket = try #require(bobOut.first(ofType: .announce))
        carol._test_handlePacket(announcePacket, fromPeerID: bob.myPeerID, preseedPeer: false)

        let handedOver = await TestHelpers.waitUntil(
            { carolOut.first(ofType: .courierEnvelope) != nil },
            timeout: TestConstants.defaultTimeout
        )
        #expect(handedOver)
        let handoverPacket = try #require(carolOut.first(ofType: .courierEnvelope))

        // Bob opens the envelope — but the sealed sender is blocked, and it
        // must never reach the UI. The live block check can't cover this: the
        // sender is absent from Bob's registry, so no fingerprint resolves at
        // delivery time.
        bob._test_handlePacket(handoverPacket, fromPeerID: carol.myPeerID)
        let delivered = await TestHelpers.waitUntil(
            { !bobDelegate.snapshot().isEmpty },
            timeout: TestConstants.shortTimeout
        )
        #expect(!delivered)
    }

    @Test func unverifiedAnnounceDoesNotTriggerCourierHandover() async throws {
        let alice = makeService()
        let carol = makeService()
        let bob = makeService()
        carol.courierDepositPolicy = { _, _ in .favorite }

        let aliceOut = PacketTap()
        alice._test_onOutboundPacket = aliceOut.record
        let carolOut = PacketTap()
        carol._test_onOutboundPacket = carolOut.record
        let bobOut = PacketTap()
        bob._test_onOutboundPacket = bobOut.record

        preseedConnectedPeer(carol, in: alice)

        #expect(alice.sendCourierMessage(
            "hold until verified",
            messageID: "courier-msg-unverified-announce",
            recipientNoiseKey: bob.noiseStaticPublicKeyData(),
            via: [carol.myPeerID]
        ))
        let deposited = await TestHelpers.waitUntil(
            { aliceOut.first(ofType: .courierEnvelope) != nil },
            timeout: TestConstants.defaultTimeout
        )
        #expect(deposited)
        let depositPacket = try #require(aliceOut.first(ofType: .courierEnvelope))

        carol._test_handlePacket(depositPacket, fromPeerID: alice.myPeerID, signingPublicKey: alice.noiseSigningPublicKeyData())
        let carried = await TestHelpers.waitUntil(
            { !carol.courierStore.isEmpty },
            timeout: TestConstants.defaultTimeout
        )
        #expect(carried)

        let forgedAnnounce = try makeUnsignedAnnounce(from: bob)
        carol._test_handlePacket(forgedAnnounce, fromPeerID: bob.myPeerID, preseedPeer: false)

        let leakedOnUnverifiedAnnounce = await TestHelpers.waitUntil(
            { carolOut.count(ofType: .courierEnvelope) > 0 },
            timeout: TestConstants.shortTimeout
        )
        #expect(!leakedOnUnverifiedAnnounce)
        #expect(!carol.courierStore.isEmpty)

        bob.sendBroadcastAnnounce()
        let announced = await TestHelpers.waitUntil(
            { bobOut.first(ofType: .announce) != nil },
            timeout: TestConstants.defaultTimeout
        )
        #expect(announced)
        let verifiedAnnounce = try #require(bobOut.first(ofType: .announce))
        carol._test_handlePacket(verifiedAnnounce, fromPeerID: bob.myPeerID, preseedPeer: false)

        let handedOver = await TestHelpers.waitUntil(
            { carolOut.count(ofType: .courierEnvelope) == 1 },
            timeout: TestConstants.defaultTimeout
        )
        #expect(handedOver)
        #expect(!carol.courierStore.isEmpty)
    }

    @Test func relayedAnnounceTriggersNonDestructiveRemoteHandover() async throws {
        let alice = makeService()
        let carol = makeService()
        let bob = makeService()
        carol.courierDepositPolicy = { _, _ in .favorite }

        let aliceOut = PacketTap()
        alice._test_onOutboundPacket = aliceOut.record
        let carolOut = PacketTap()
        carol._test_onOutboundPacket = carolOut.record
        let bobOut = PacketTap()
        bob._test_onOutboundPacket = bobOut.record

        preseedConnectedPeer(carol, in: alice)

        #expect(alice.sendCourierMessage(
            "hold for a direct encounter",
            messageID: "courier-msg-relayed-announce",
            recipientNoiseKey: bob.noiseStaticPublicKeyData(),
            via: [carol.myPeerID]
        ))
        let deposited = await TestHelpers.waitUntil(
            { aliceOut.first(ofType: .courierEnvelope) != nil },
            timeout: TestConstants.defaultTimeout
        )
        #expect(deposited)
        let depositPacket = try #require(aliceOut.first(ofType: .courierEnvelope))

        carol._test_handlePacket(depositPacket, fromPeerID: alice.myPeerID, signingPublicKey: alice.noiseSigningPublicKeyData())
        let carried = await TestHelpers.waitUntil(
            { !carol.courierStore.isEmpty },
            timeout: TestConstants.defaultTimeout
        )
        #expect(carried)

        bob.sendBroadcastAnnounce()
        let announced = await TestHelpers.waitUntil(
            { bobOut.first(ofType: .announce) != nil },
            timeout: TestConstants.defaultTimeout
        )
        #expect(announced)
        let directAnnounce = try #require(bobOut.first(ofType: .announce))

        // A relayed copy has a decremented TTL but a still-valid signature
        // (TTL is excluded from announce signatures). The recipient is
        // multi-hop away, so a copy floods toward them speculatively while
        // the carried original stays put for a future direct encounter.
        var relayedAnnounce = directAnnounce
        relayedAnnounce.ttl = directAnnounce.ttl - 1
        carol._test_handlePacket(relayedAnnounce, fromPeerID: bob.myPeerID, preseedPeer: false)

        let remoteHandover = await TestHelpers.waitUntil(
            { carolOut.count(ofType: .courierEnvelope) == 1 },
            timeout: TestConstants.defaultTimeout
        )
        #expect(remoteHandover)
        #expect(!carol.courierStore.isEmpty)

        // A second relayed announce inside the cooldown must not re-flood
        // the same envelope. The original announce's dedup key is consumed
        // (sender/timestamp/payload — TTL excluded), so use a fresh announce;
        // wait out the 1s announce throttle first.
        try await Task.sleep(nanoseconds: 1_100_000_000)
        bob.sendBroadcastAnnounce()
        let reannounced = await TestHelpers.waitUntil(
            { bobOut.all(ofType: .announce).contains { $0.timestamp != directAnnounce.timestamp } },
            timeout: TestConstants.defaultTimeout
        )
        #expect(reannounced)
        let freshAnnounce = try #require(
            bobOut.all(ofType: .announce).first { $0.timestamp != directAnnounce.timestamp }
        )
        var relayedFreshAnnounce = freshAnnounce
        relayedFreshAnnounce.ttl = freshAnnounce.ttl - 1
        carol._test_handlePacket(relayedFreshAnnounce, fromPeerID: bob.myPeerID, preseedPeer: false)

        let refloodedInCooldown = await TestHelpers.waitUntil(
            { carolOut.count(ofType: .courierEnvelope) > 1 },
            timeout: TestConstants.shortTimeout
        )
        #expect(!refloodedInCooldown)
        #expect(!carol.courierStore.isEmpty)

        // A peer-level Noise session is still insufficient without a physical
        // ingress link that completed that handshake. This CoreBluetooth-free
        // harness deliberately has no such link proof, so restoring the
        // unsigned direct TTL cannot authorize destructive handover.
        try establishNoiseSession(between: carol, and: bob)
        try await Task.sleep(nanoseconds: 1_100_000_000)
        bob.sendBroadcastAnnounce()
        let announcedAgain = await TestHelpers.waitUntil(
            { bobOut.all(ofType: .announce).contains { $0.timestamp != directAnnounce.timestamp && $0.timestamp != freshAnnounce.timestamp } },
            timeout: TestConstants.defaultTimeout
        )
        #expect(announcedAgain)
        let directAgain = try #require(
            bobOut.all(ofType: .announce).first { $0.timestamp != directAnnounce.timestamp && $0.timestamp != freshAnnounce.timestamp }
        )
        carol._test_handlePacket(directAgain, fromPeerID: bob.myPeerID, preseedPeer: false)

        let handedOverWithoutLinkProof = await TestHelpers.waitUntil(
            { carolOut.count(ofType: .courierEnvelope) > 1 },
            timeout: TestConstants.shortTimeout
        )
        #expect(!handedOverWithoutLinkProof)
        #expect(!carol.courierStore.isEmpty)
    }

    @Test func sendCourierMessageRejectsInvalidRecipientKeyBeforeQueueing() async throws {
        let alice = makeService()
        let carol = makeService()
        preseedConnectedPeer(carol, in: alice)

        let aliceOut = PacketTap()
        alice._test_onOutboundPacket = aliceOut.record

        #expect(!alice.sendCourierMessage(
            "this cannot be sealed",
            messageID: "courier-msg-invalid-key",
            recipientNoiseKey: Data(repeating: 0x01, count: 8),
            via: [carol.myPeerID]
        ))

        let queuedPacket = await TestHelpers.waitUntil(
            { aliceOut.first(ofType: .courierEnvelope) != nil },
            timeout: TestConstants.shortTimeout
        )
        #expect(!queuedPacket)
    }

    @Test func depositFromUntrustedPeerIsRejected() async throws {
        let carol = makeService()
        carol.courierDepositPolicy = { _, _ in nil } // depositor is neither favorite nor verified

        let alice = NoiseEncryptionService(keychain: MockKeychain())
        let bobKey = NoiseEncryptionService(keychain: MockKeychain()).getStaticPublicKeyData()
        let typedPayload = try #require(BLENoisePayloadFactory.privateMessage(content: "x", messageID: "m1"))
        let sealed = try alice.sealCourierPayload(typedPayload, recipientStaticKey: bobKey)
        let now = Date()
        let envelope = CourierEnvelope(
            recipientTag: CourierEnvelope.recipientTag(
                noiseStaticKey: bobKey,
                epochDay: CourierEnvelope.epochDay(for: now)
            ),
            expiry: UInt64((now.timeIntervalSince1970 + 3600) * 1000),
            ciphertext: sealed
        )
        let alicePeerID = PeerID(publicKey: alice.getStaticPublicKeyData())
        let unsigned = BitchatPacket(
            type: MessageType.courierEnvelope.rawValue,
            senderID: Data(hexString: alicePeerID.id) ?? Data(),
            recipientID: Data(hexString: carol.myPeerID.id),
            timestamp: UInt64(now.timeIntervalSince1970 * 1000),
            payload: try #require(envelope.encode()),
            signature: nil,
            ttl: 1
        )
        let packet = try #require(alice.signPacket(unsigned))

        carol._test_handlePacket(packet, fromPeerID: alicePeerID, signingPublicKey: alice.getSigningPublicKeyData())
        let stored = await TestHelpers.waitUntil(
            { !carol.courierStore.isEmpty },
            timeout: TestConstants.shortTimeout
        )
        #expect(!stored)
    }

    @Test func unsignedDepositIsRejected() async throws {
        let carol = makeService()
        carol.courierDepositPolicy = { _, _ in .favorite }

        let alice = NoiseEncryptionService(keychain: MockKeychain())
        let bobKey = NoiseEncryptionService(keychain: MockKeychain()).getStaticPublicKeyData()
        let typedPayload = try #require(BLENoisePayloadFactory.privateMessage(content: "x", messageID: "m-unsigned"))
        let sealed = try alice.sealCourierPayload(typedPayload, recipientStaticKey: bobKey)
        let now = Date()
        let envelope = CourierEnvelope(
            recipientTag: CourierEnvelope.recipientTag(
                noiseStaticKey: bobKey,
                epochDay: CourierEnvelope.epochDay(for: now)
            ),
            expiry: UInt64((now.timeIntervalSince1970 + 3600) * 1000),
            ciphertext: sealed
        )
        let alicePeerID = PeerID(publicKey: alice.getStaticPublicKeyData())
        // Correct sender, willing policy — but no packet signature: the
        // courier cannot authenticate the depositor, so it must not carry.
        let packet = BitchatPacket(
            type: MessageType.courierEnvelope.rawValue,
            senderID: Data(hexString: alicePeerID.id) ?? Data(),
            recipientID: Data(hexString: carol.myPeerID.id),
            timestamp: UInt64(now.timeIntervalSince1970 * 1000),
            payload: try #require(envelope.encode()),
            signature: nil,
            ttl: 1
        )

        carol._test_handlePacket(packet, fromPeerID: alicePeerID, signingPublicKey: alice.getSigningPublicKeyData())
        let stored = await TestHelpers.waitUntil(
            { !carol.courierStore.isEmpty },
            timeout: TestConstants.shortTimeout
        )
        #expect(!stored)
    }

    @Test func courierDepositTrustUsesIngressPeerNotClaimedSender() async throws {
        let alice = makeService()
        let carol = makeService()
        let mallory = makeService()
        preseedConnectedPeer(alice, in: carol)
        preseedConnectedPeer(mallory, in: carol)

        let trustedAliceKey = Data(hexString: alice.myPeerID.id) ?? Data()
        carol.courierDepositPolicy = { depositorKey, _ in
            depositorKey == trustedAliceKey ? .favorite : nil
        }

        let aliceNoise = NoiseEncryptionService(keychain: MockKeychain())
        let bobKey = NoiseEncryptionService(keychain: MockKeychain()).getStaticPublicKeyData()
        let typedPayload = try #require(BLENoisePayloadFactory.privateMessage(content: "spoofed", messageID: "m-spoof"))
        let sealed = try aliceNoise.sealCourierPayload(typedPayload, recipientStaticKey: bobKey)
        let now = Date()
        let envelope = CourierEnvelope(
            recipientTag: CourierEnvelope.recipientTag(
                noiseStaticKey: bobKey,
                epochDay: CourierEnvelope.epochDay(for: now)
            ),
            expiry: UInt64((now.timeIntervalSince1970 + 3600) * 1000),
            ciphertext: sealed
        )
        let packet = BitchatPacket(
            type: MessageType.courierEnvelope.rawValue,
            senderID: Data(hexString: alice.myPeerID.id) ?? Data(),
            recipientID: Data(hexString: carol.myPeerID.id),
            timestamp: UInt64(now.timeIntervalSince1970 * 1000),
            payload: try #require(envelope.encode()),
            signature: nil,
            ttl: 1
        )

        carol._test_handlePacket(packet, fromPeerID: mallory.myPeerID, preseedPeer: false)
        let stored = await TestHelpers.waitUntil(
            { !carol.courierStore.isEmpty },
            timeout: TestConstants.shortTimeout
        )
        #expect(!stored)
    }

    /// Regression for the relaunch amplification storm: redundant copies of
    /// one message arrive as *distinct* envelopes (every seal uses a fresh
    /// ephemeral key), so only the inner message ID can dedup them. The first
    /// copy delivers; duplicates must stop right after the decrypt — no
    /// second delivery, no second ack/handshake trigger downstream.
    @Test func duplicateCourierCopiesDeliverInnerMessageOnce() async throws {
        let alice = makeService()
        let bob = makeService()
        let bobDelegate = NoiseCaptureDelegate()
        bob.delegate = bobDelegate

        let bobKey = bob.noiseStaticPublicKeyData()
        let first = try #require(alice.sealBridgeCourierEnvelope("once", messageID: "dup-1", recipientNoiseKey: bobKey))
        let second = try #require(alice.sealBridgeCourierEnvelope("once", messageID: "dup-1", recipientNoiseKey: bobKey))
        // Distinct seals: envelope-level dedup can never catch this pair.
        #expect(first.ciphertext != second.ciphertext)

        #expect(bob.openBridgedCourierEnvelope(first))
        #expect(bob.openBridgedCourierEnvelope(second))

        let delivered = await TestHelpers.waitUntil(
            { !bobDelegate.snapshot().isEmpty },
            timeout: TestConstants.defaultTimeout
        )
        #expect(delivered)
        // Give a duplicate delivery a chance to surface, then confirm the
        // second copy never reached the delegate.
        let duplicated = await TestHelpers.waitUntil(
            { bobDelegate.snapshot().count > 1 },
            timeout: TestConstants.shortTimeout
        )
        #expect(!duplicated)
        #expect(bobDelegate.snapshot().count == 1)
    }

    /// Acks for mail from absent senders (the usual couriered/bridged case)
    /// queue for a future session instead of initiating a handshake
    /// broadcast — otherwise every duplicate copy of every drop turns into a
    /// mesh-wide handshake flood at an identity that cannot answer.
    @Test func deliveryAckForAbsentPeerQueuesWithoutHandshake() async throws {
        let ble = makeService()
        let outbound = PacketTap()
        ble._test_onOutboundPacket = outbound.record

        // Nobody by this ID on the mesh (not connected, not reachable).
        ble.sendDeliveryAck(for: "msg-1", to: PeerID(str: "00000000000000ee"))

        let initiated = await TestHelpers.waitUntil(
            { outbound.count(ofType: .noiseHandshake) > 0 },
            timeout: TestConstants.shortTimeout
        )
        #expect(!initiated)

        // Control: a peer that is actually around still gets the handshake.
        let present = PeerID(str: "00000000000000ef")
        ble._test_seedConnectedPeer(present, nickname: "present")
        ble.sendDeliveryAck(for: "msg-2", to: present)
        let initiatedForPresent = await TestHelpers.waitUntil(
            { outbound.count(ofType: .noiseHandshake) > 0 },
            timeout: TestConstants.defaultTimeout
        )
        #expect(initiatedForPresent)
    }

    private func makeUnsignedAnnounce(from service: BLEService) throws -> BitchatPacket {
        let announcement = AnnouncementPacket(
            nickname: "Unsigned",
            noisePublicKey: service.noiseStaticPublicKeyData(),
            signingPublicKey: service.noiseSigningPublicKeyData(),
            directNeighbors: nil
        )
        let payload = try #require(announcement.encode())

        return BitchatPacket(
            type: MessageType.announce.rawValue,
            senderID: Data(hexString: service.myPeerID.id) ?? Data(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil,
            ttl: TransportConfig.messageTTLDefault
        )
    }
}

// MARK: - Router courier selection

/// Minimal transport stub for exercising MessageRouter's courier deposit
/// logic without BLE plumbing.
private final class CourierCaptureTransport: Transport {
    weak var delegate: BitchatDelegate?
    weak var eventDelegate: TransportEventDelegate?
    weak var peerEventsDelegate: TransportPeerEventsDelegate?

    var snapshots: [TransportPeerSnapshot] = []
    private(set) var courierSends: [(messageID: String, recipientKey: Data, couriers: [PeerID])] = []
    private(set) var directSends: [String] = []

    func currentPeerSnapshots() -> [TransportPeerSnapshot] { snapshots }

    var myPeerID = PeerID(str: "00000000000000aa")
    var myNickname = "stub"
    func setNickname(_ nickname: String) {}

    func startServices() {}
    func stopServices() {}
    func emergencyDisconnectAll() {}

    func isPeerConnected(_ peerID: PeerID) -> Bool {
        snapshots.contains { $0.peerID == peerID && $0.isConnected }
    }
    // Nostr-style reachability: claimed for peers with no live link (known
    // npub), where prompt delivery additionally needs a relay connection.
    var reachablePeers: Set<PeerID> = []
    var promptDelivery = true
    func isPeerReachable(_ peerID: PeerID) -> Bool {
        isPeerConnected(peerID) || reachablePeers.contains(peerID)
    }
    func canDeliverPromptly(to peerID: PeerID) -> Bool {
        isPeerReachable(peerID) && promptDelivery
    }
    func peerNickname(peerID: PeerID) -> String? { nil }
    func getPeerNicknames() -> [PeerID: String] { [:] }

    func getFingerprint(for peerID: PeerID) -> String? { nil }
    func getNoiseSessionState(for peerID: PeerID) -> LazyHandshakeState { .none }
    func triggerHandshake(with peerID: PeerID) {}

    func sendMessage(_ content: String, mentions: [String]) {}
    func sendPrivateMessage(_ content: String, to peerID: PeerID, recipientNickname: String, messageID: String) {
        directSends.append(messageID)
    }
    func sendReadReceipt(_ receipt: ReadReceipt, to peerID: PeerID) {}
    func sendFavoriteNotification(to peerID: PeerID, isFavorite: Bool) {}
    func sendBroadcastAnnounce() {}
    func sendDeliveryAck(for messageID: String, to peerID: PeerID) {}

    func sendCourierMessage(_ content: String, messageID: String, recipientNoiseKey: Data, via couriers: [PeerID]) -> Bool {
        courierSends.append((messageID, recipientNoiseKey, couriers))
        return true
    }
}

struct MessageRouterCourierTests {

    @Test @MainActor
    func unreachablePeerMessageGoesToTrustedCouriersOnly() {
        let bobKey = Data(repeating: 0xB0, count: 32)
        let bobID = PeerID(publicKey: bobKey)
        let carolKey = Data(repeating: 0xC0, count: 32)
        let carolID = PeerID(publicKey: carolKey)
        let daveKey = Data(repeating: 0xD0, count: 32)
        let daveID = PeerID(publicKey: daveKey)

        let transport = CourierCaptureTransport()
        transport.snapshots = [
            // Carol: connected mutual favorite → eligible courier.
            TransportPeerSnapshot(peerID: carolID, nickname: "carol", isConnected: true, noisePublicKey: carolKey, lastSeen: Date()),
            // Dave: connected but not trusted → never a courier.
            TransportPeerSnapshot(peerID: daveID, nickname: "dave", isConnected: true, noisePublicKey: daveKey, lastSeen: Date())
        ]

        let directory = CourierDirectory(
            noiseKey: { peerID in peerID == bobID ? bobKey : nil },
            isTrustedCourier: { $0 == carolKey }
        )
        let router = MessageRouter(transports: [transport], courierDirectory: directory)
        var carried: [String] = []
        router.onMessageCarried = { messageID, _ in carried.append(messageID) }

        router.sendPrivate("hi bob", to: bobID, recipientNickname: "bob", messageID: "m1")

        #expect(transport.directSends.isEmpty)
        #expect(transport.courierSends.count == 1)
        #expect(transport.courierSends.first?.messageID == "m1")
        #expect(transport.courierSends.first?.recipientKey == bobKey)
        #expect(transport.courierSends.first?.couriers == [carolID])
        #expect(carried == ["m1"])
    }

    /// Field-found: a DM sent while the recipient sits in the BLE
    /// reachability retention window (radio gone, still "reachable" for a
    /// minute) trusts the mesh and skips every deposit — and nothing
    /// retried. The periodic sweep must publish the bridge drop once the
    /// window lapses.
    @Test @MainActor
    func sweepDropsQueuedMessageOnceReachabilityLapses() {
        let bobKey = Data(repeating: 0xB0, count: 32)
        let bobID = PeerID(publicKey: bobKey)
        let transport = CourierCaptureTransport()
        transport.reachablePeers = [bobID] // retention window: stale but "reachable"
        transport.promptDelivery = true

        let directory = CourierDirectory(
            noiseKey: { peerID in peerID == bobID ? bobKey : nil },
            isTrustedCourier: { _ in false }
        )
        let router = MessageRouter(transports: [transport], courierDirectory: directory)
        var drops: [(content: String, messageID: String, key: Data)] = []
        router.bridgeCourierDeposit = { content, messageID, key, completion in
            drops.append((content, messageID, key))
            completion(true)
        }
        var carried: [String] = []
        router.onMessageCarried = { messageID, _ in carried.append(messageID) }

        router.sendPrivate("hi bob", to: bobID, recipientNickname: "bob", messageID: "m9")
        #expect(drops.isEmpty) // send trusted the (stale) mesh reachability

        // Still inside the window: the sweep must not spam relays.
        router.retryBridgeCourierDeposits()
        #expect(drops.isEmpty)

        // Window lapses; the sweep publishes the retained copy as a drop and
        // the sender's message shows "carried" (its ack has no radio route).
        transport.reachablePeers = []
        router.retryBridgeCourierDeposits()
        #expect(drops.count == 1)
        #expect(drops.first?.messageID == "m9")
        #expect(drops.first?.content == "hi bob")
        #expect(drops.first?.key == bobKey)
        #expect(carried == ["m9"])
    }

    @Test @MainActor
    func noCourierDepositWithoutKnownRecipientKey() {
        let transport = CourierCaptureTransport()
        transport.snapshots = [
            TransportPeerSnapshot(peerID: PeerID(str: "00000000000000cc"), nickname: "carol", isConnected: true, noisePublicKey: Data(repeating: 0xC0, count: 32), lastSeen: Date())
        ]
        let directory = CourierDirectory(noiseKey: { _ in nil }, isTrustedCourier: { _ in true })
        let router = MessageRouter(transports: [transport], courierDirectory: directory)
        var carried: [String] = []
        router.onMessageCarried = { messageID, _ in carried.append(messageID) }

        router.sendPrivate("hi", to: PeerID(str: "00000000000000bb"), recipientNickname: "bob", messageID: "m2")

        #expect(transport.courierSends.isEmpty)
        #expect(carried.isEmpty)
    }

    /// The production directory must resolve both ID forms: a 64-hex
    /// noise-key ID (offline favorite row) carries the key itself, and a
    /// short 16-hex ID resolves through the favorites store.
    @Test @MainActor
    func favoritesBackedDirectoryResolvesBothIDForms() {
        let directory = CourierDirectory.favoritesBacked()
        let bobKey = Data(repeating: 0xB7, count: 32)

        #expect(directory.noiseKey(PeerID(hexData: bobKey)) == bobKey)

        FavoritesPersistenceService.shared.addFavorite(peerNoisePublicKey: bobKey, peerNickname: "bob")
        defer { FavoritesPersistenceService.shared.removeFavorite(peerNoisePublicKey: bobKey) }
        #expect(directory.noiseKey(PeerID(publicKey: bobKey)) == bobKey)
    }

    @Test @MainActor
    func reachablePeerSkipsCourier() {
        let bobKey = Data(repeating: 0xB0, count: 32)
        let bobID = PeerID(publicKey: bobKey)
        let transport = CourierCaptureTransport()
        transport.snapshots = [
            TransportPeerSnapshot(peerID: bobID, nickname: "bob", isConnected: true, noisePublicKey: bobKey, lastSeen: Date())
        ]
        let directory = CourierDirectory(noiseKey: { _ in bobKey }, isTrustedCourier: { _ in true })
        let router = MessageRouter(transports: [transport], courierDirectory: directory)

        router.sendPrivate("hi", to: bobID, recipientNickname: "bob", messageID: "m3")

        #expect(transport.directSends == ["m3"])
        #expect(transport.courierSends.isEmpty)
    }

    /// A peer can be "reachable" through a transport that cannot deliver
    /// promptly (Nostr claims any favorite with a known npub, even with no
    /// relay connection). The queued send must not shadow the courier: a
    /// sealed copy goes to connected couriers in parallel, and receivers
    /// dedup by message ID if both arrive.
    @Test @MainActor
    func queuedReachableSendAlsoDepositsWithCourier() {
        let bobKey = Data(repeating: 0xB0, count: 32)
        let bobID = PeerID(publicKey: bobKey)
        let carolKey = Data(repeating: 0xC0, count: 32)
        let carolID = PeerID(publicKey: carolKey)

        let transport = CourierCaptureTransport()
        transport.snapshots = [
            TransportPeerSnapshot(peerID: carolID, nickname: "carol", isConnected: true, noisePublicKey: carolKey, lastSeen: Date())
        ]
        transport.reachablePeers = [bobID]
        transport.promptDelivery = false

        let directory = CourierDirectory(
            noiseKey: { peerID in peerID == bobID ? bobKey : nil },
            isTrustedCourier: { $0 == carolKey }
        )
        let router = MessageRouter(transports: [transport], courierDirectory: directory)
        var carried: [String] = []
        router.onMessageCarried = { messageID, _ in carried.append(messageID) }

        router.sendPrivate("hi bob", to: bobID, recipientNickname: "bob", messageID: "m4")

        #expect(transport.directSends == ["m4"])
        #expect(transport.courierSends.count == 1)
        #expect(transport.courierSends.first?.messageID == "m4")
        #expect(transport.courierSends.first?.couriers == [carolID])
        #expect(carried == ["m4"])
    }

    /// When the reachable transport can deliver promptly (relays up), the
    /// send is trusted and no courier quota is spent.
    @Test @MainActor
    func promptlyDeliverableReachablePeerSkipsCourier() {
        let bobKey = Data(repeating: 0xB0, count: 32)
        let bobID = PeerID(publicKey: bobKey)
        let carolKey = Data(repeating: 0xC0, count: 32)
        let carolID = PeerID(publicKey: carolKey)

        let transport = CourierCaptureTransport()
        transport.snapshots = [
            TransportPeerSnapshot(peerID: carolID, nickname: "carol", isConnected: true, noisePublicKey: carolKey, lastSeen: Date())
        ]
        transport.reachablePeers = [bobID]

        let directory = CourierDirectory(
            noiseKey: { peerID in peerID == bobID ? bobKey : nil },
            isTrustedCourier: { $0 == carolKey }
        )
        let router = MessageRouter(transports: [transport], courierDirectory: directory)
        var carried: [String] = []
        router.onMessageCarried = { messageID, _ in carried.append(messageID) }

        router.sendPrivate("hi bob", to: bobID, recipientNickname: "bob", messageID: "m5")

        #expect(transport.directSends == ["m5"])
        #expect(transport.courierSends.isEmpty)
        #expect(carried.isEmpty)
    }
}
