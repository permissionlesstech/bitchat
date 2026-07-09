//
// PrekeyEndToEndTests.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
import CoreBluetooth
import BitFoundation
@testable import bitchat

/// Forward-secret courier flow through real BLEService instances: Bob gossips
/// a signed prekey bundle, Alice verifies and caches it, seals to a one-time
/// prekey instead of Bob's static key, Carol carries the opaque envelope, and
/// Bob opens it with the matching prekey private.
struct PrekeyEndToEndTests {

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

    private func makeService() -> BLEService {
        let keychain = MockKeychain()
        let service = BLEService(
            keychain: keychain,
            idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
            identityManager: MockIdentityManager(keychain),
            initializeBluetoothManagers: false
        )
        service.courierStore = CourierStore(persistsToDisk: false)
        service.prekeyBundleStore = PrekeyBundleStore(persistsToDisk: false)
        return service
    }

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

    /// Broadcast announce + prekey bundle from `peer` and return both packets.
    private func captureAnnounceAndBundle(from peer: BLEService, tap: PacketTap) async throws -> (announce: BitchatPacket, bundle: BitchatPacket) {
        peer.sendBroadcastAnnounce()
        let published = await TestHelpers.waitUntil(
            { tap.first(ofType: .announce) != nil && tap.first(ofType: .prekeyBundle) != nil },
            timeout: TestConstants.defaultTimeout
        )
        #expect(published)
        return (
            announce: try #require(tap.first(ofType: .announce)),
            bundle: try #require(tap.first(ofType: .prekeyBundle))
        )
    }

    // MARK: - Tests

    @Test func prekeySealedMailTravelsViaCourierAndOpens() async throws {
        let alice = makeService()
        let carol = makeService()
        let bob = makeService()
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

        // 1. While Bob is still around, Alice hears his verified announce
        //    (binding his signing key) and his gossiped prekey bundle.
        let (announce, bundlePacket) = try await captureAnnounceAndBundle(from: bob, tap: bobOut)
        alice._test_handlePacket(announce, fromPeerID: bob.myPeerID, preseedPeer: false)
        alice._test_handlePacket(bundlePacket, fromPeerID: bob.myPeerID, preseedPeer: false)

        let cached = await TestHelpers.waitUntil(
            { alice.prekeyBundleStore.hasUsableBundle(for: bob.noiseStaticPublicKeyData()) },
            timeout: TestConstants.defaultTimeout
        )
        #expect(cached)

        // 2. Bob goes dark; Alice seals for him and deposits with Carol.
        //    The envelope must be v2: sealed to a one-time prekey.
        #expect(alice.sendCourierMessage(
            "burn after reading",
            messageID: "prekey-msg-1",
            recipientNoiseKey: bob.noiseStaticPublicKeyData(),
            via: [carol.myPeerID]
        ))
        let deposited = await TestHelpers.waitUntil(
            { aliceOut.first(ofType: .courierEnvelope) != nil },
            timeout: TestConstants.defaultTimeout
        )
        #expect(deposited)
        let depositPacket = try #require(aliceOut.first(ofType: .courierEnvelope))
        let sealedEnvelope = try #require(CourierEnvelope.decode(depositPacket.payload))
        #expect(sealedEnvelope.prekeyID != nil)

        // 3. Carol carries it (opaque, prekey or not).
        carol._test_handlePacket(depositPacket, fromPeerID: alice.myPeerID, signingPublicKey: alice.noiseSigningPublicKeyData())
        let carried = await TestHelpers.waitUntil(
            { !carol.courierStore.isEmpty },
            timeout: TestConstants.defaultTimeout
        )
        #expect(carried)

        // 4. Bob resurfaces near Carol → handover, and the v2 discriminator
        //    survives the store round-trip.
        bob.sendBroadcastAnnounce()
        let reannounced = await TestHelpers.waitUntil(
            { bobOut.first(ofType: .announce) != nil },
            timeout: TestConstants.defaultTimeout
        )
        #expect(reannounced)
        let handoverTrigger = try #require(bobOut.first(ofType: .announce))
        carol._test_handlePacket(handoverTrigger, fromPeerID: bob.myPeerID, preseedPeer: false)

        let handedOver = await TestHelpers.waitUntil(
            { carolOut.first(ofType: .courierEnvelope) != nil },
            timeout: TestConstants.defaultTimeout
        )
        #expect(handedOver)
        let handoverPacket = try #require(carolOut.first(ofType: .courierEnvelope))
        let handedEnvelope = try #require(CourierEnvelope.decode(handoverPacket.payload))
        #expect(handedEnvelope.prekeyID == sealedEnvelope.prekeyID)

        // 5. Bob opens it with the matching one-time prekey private and sees
        //    Alice as the authenticated sender.
        bob._test_handlePacket(handoverPacket, fromPeerID: carol.myPeerID)
        let received = await TestHelpers.waitUntil(
            { !bobDelegate.snapshot().isEmpty },
            timeout: TestConstants.defaultTimeout
        )
        #expect(received)

        let delivered = try #require(bobDelegate.snapshot().first)
        #expect(delivered.type == .privateMessage)
        #expect(delivered.peerID == PeerID(hexData: alice.noiseStaticPublicKeyData()))
        let message = try #require(PrivateMessagePacket.decode(from: delivered.payload))
        #expect(message.messageID == "prekey-msg-1")
        #expect(message.content == "burn after reading")

        // 6. Redelivery tolerance: the same envelope arriving via another
        //    packet (spray-and-wait) still decrypts inside the prekey grace
        //    window (asserted at the crypto layer in NoisePrekeyTests), but
        //    the duplicate is absorbed before delivery — the receiver dedups
        //    on the inner message ID, so redundant courier copies never
        //    re-deliver (or re-ack) the same message.
        let redelivery = BitchatPacket(
            type: MessageType.courierEnvelope.rawValue,
            senderID: Data(hexString: carol.myPeerID.id) ?? Data(),
            recipientID: handoverPacket.recipientID,
            timestamp: handoverPacket.timestamp + 1,
            payload: handoverPacket.payload,
            signature: nil,
            ttl: 1
        )
        bob._test_handlePacket(redelivery, fromPeerID: carol.myPeerID)
        let redelivered = await TestHelpers.waitUntil(
            { bobDelegate.snapshot().count == 2 },
            timeout: TestConstants.shortTimeout
        )
        #expect(!redelivered)
        #expect(bobDelegate.snapshot().count == 1)
    }

    @Test func withoutBundleSealingFallsBackToStatic() async throws {
        let alice = makeService()
        let bob = makeService()

        let bobDelegate = NoiseCaptureDelegate()
        bob.delegate = bobDelegate
        let aliceOut = PacketTap()
        alice._test_onOutboundPacket = aliceOut.record

        // Bob is a connected "courier" who happens to be the recipient: the
        // envelope reaches him directly and the recipient tag matches.
        preseedConnectedPeer(bob, in: alice)

        // Alice never saw a bundle for Bob → v1 static-sealed envelope.
        #expect(alice.sendCourierMessage(
            "plain static seal",
            messageID: "static-msg-1",
            recipientNoiseKey: bob.noiseStaticPublicKeyData(),
            via: [bob.myPeerID]
        ))
        let deposited = await TestHelpers.waitUntil(
            { aliceOut.first(ofType: .courierEnvelope) != nil },
            timeout: TestConstants.defaultTimeout
        )
        #expect(deposited)
        let depositPacket = try #require(aliceOut.first(ofType: .courierEnvelope))
        let envelope = try #require(CourierEnvelope.decode(depositPacket.payload))
        #expect(envelope.prekeyID == nil)

        // Bob opens the v1 envelope exactly as before the prekey change.
        // (No preseed: Alice is absent from Bob's mesh, so the sender should
        // resolve to her full noise-key ID like the courier case.)
        bob._test_handlePacket(depositPacket, fromPeerID: alice.myPeerID, preseedPeer: false)
        let received = await TestHelpers.waitUntil(
            { !bobDelegate.snapshot().isEmpty },
            timeout: TestConstants.defaultTimeout
        )
        #expect(received)
        let delivered = try #require(bobDelegate.snapshot().first)
        #expect(delivered.peerID == PeerID(hexData: alice.noiseStaticPublicKeyData()))
        let message = try #require(PrivateMessagePacket.decode(from: delivered.payload))
        #expect(message.content == "plain static seal")
    }

    @Test func unverifiableBundleIsIgnored() async throws {
        let alice = makeService()
        let bob = makeService()

        let bobOut = PacketTap()
        bob._test_onOutboundPacket = bobOut.record

        // Alice receives Bob's bundle but never saw a verified announce, so
        // no signing key is bound to his noise key: the bundle must not be
        // cached or enter Alice's gossip store.
        let (_, bundlePacket) = try await captureAnnounceAndBundle(from: bob, tap: bobOut)
        alice._test_handlePacket(bundlePacket, fromPeerID: bob.myPeerID, preseedPeer: false)

        let cached = await TestHelpers.waitUntil(
            { alice.prekeyBundleStore.hasUsableBundle(for: bob.noiseStaticPublicKeyData()) },
            timeout: TestConstants.shortTimeout
        )
        #expect(!cached)
    }

    @Test func forgedBundleSignatureIsRejected() async throws {
        let alice = makeService()
        let bob = makeService()

        let bobOut = PacketTap()
        bob._test_onOutboundPacket = bobOut.record

        let (announce, bundlePacket) = try await captureAnnounceAndBundle(from: bob, tap: bobOut)
        alice._test_handlePacket(announce, fromPeerID: bob.myPeerID, preseedPeer: false)

        // Mallory tampers with the gossiped bundle in flight.
        let bundle = try #require(PrekeyBundle.decode(bundlePacket.payload))
        var forgedSignature = bundle.signature
        forgedSignature[0] ^= 0x01
        let forged = PrekeyBundle(
            noiseStaticPublicKey: bundle.noiseStaticPublicKey,
            prekeys: bundle.prekeys,
            generatedAt: bundle.generatedAt,
            signature: forgedSignature
        )
        let forgedPacket = BitchatPacket(
            type: MessageType.prekeyBundle.rawValue,
            senderID: bundlePacket.senderID,
            recipientID: nil,
            timestamp: bundlePacket.timestamp,
            payload: try #require(forged.encode()),
            signature: bundlePacket.signature,
            ttl: bundlePacket.ttl
        )
        alice._test_handlePacket(forgedPacket, fromPeerID: bob.myPeerID, preseedPeer: false)

        let cached = await TestHelpers.waitUntil(
            { alice.prekeyBundleStore.hasUsableBundle(for: bob.noiseStaticPublicKeyData()) },
            timeout: TestConstants.shortTimeout
        )
        #expect(!cached)
    }

    @Test func verifiedBundleEntersGossipStore() async throws {
        let alice = makeService()
        let bob = makeService()

        let bobOut = PacketTap()
        bob._test_onOutboundPacket = bobOut.record

        let (announce, bundlePacket) = try await captureAnnounceAndBundle(from: bob, tap: bobOut)
        alice._test_handlePacket(announce, fromPeerID: bob.myPeerID, preseedPeer: false)
        alice._test_handlePacket(bundlePacket, fromPeerID: bob.myPeerID, preseedPeer: false)

        let cached = await TestHelpers.waitUntil(
            { alice.prekeyBundleStore.hasUsableBundle(for: bob.noiseStaticPublicKeyData()) },
            timeout: TestConstants.defaultTimeout
        )
        #expect(cached)
        // The verified bundle now participates in Alice's sync rounds.
        #expect(alice._test_hasGossipPrekeyBundle(for: bob.myPeerID))
    }

    @Test func spoofedSenderPrekeyBundleIsRejected() async throws {
        let alice = makeService()
        let bob = makeService()

        let bobOut = PacketTap()
        bob._test_onOutboundPacket = bobOut.record

        let (announce, bundlePacket) = try await captureAnnounceAndBundle(from: bob, tap: bobOut)
        alice._test_handlePacket(announce, fromPeerID: bob.myPeerID, preseedPeer: false)

        // A relay re-broadcasts Bob's genuine bundle under a fabricated sender
        // ID (the DoS that would multiply cache/gossip entries and exhaust the
        // per-owner cap). Attribution is by the bundle's own key and the outer
        // signature is bound to Bob's sender ID, so the spoof is dropped — no
        // cache entry, and no gossip entry under either the fake or real ID.
        let fakeSender = Data((0..<8).map { _ in UInt8.random(in: 0...255) })
        let spoofed = BitchatPacket(
            type: MessageType.prekeyBundle.rawValue,
            senderID: fakeSender,
            recipientID: nil,
            timestamp: bundlePacket.timestamp + 5_000,
            payload: bundlePacket.payload,
            signature: bundlePacket.signature,
            ttl: bundlePacket.ttl
        )
        alice._test_handlePacket(spoofed, fromPeerID: PeerID(hexData: fakeSender), preseedPeer: false)

        let cached = await TestHelpers.waitUntil(
            { alice.prekeyBundleStore.hasUsableBundle(for: bob.noiseStaticPublicKeyData()) },
            timeout: TestConstants.shortTimeout
        )
        #expect(!cached)
        #expect(!alice._test_hasGossipPrekeyBundle(for: bob.myPeerID))
        #expect(!alice._test_hasGossipPrekeyBundle(for: PeerID(hexData: fakeSender)))
    }

    @Test func replayedPrekeyBundleWithFreshTimestampIsRejected() async throws {
        let alice = makeService()
        let bob = makeService()

        let bobOut = PacketTap()
        bob._test_onOutboundPacket = bobOut.record

        let (announce, bundlePacket) = try await captureAnnounceAndBundle(from: bob, tap: bobOut)
        alice._test_handlePacket(announce, fromPeerID: bob.myPeerID, preseedPeer: false)

        // Rewriting the outer timestamp (to defeat the freshness window)
        // invalidates the packet signature, which covers senderID + timestamp.
        let replay = BitchatPacket(
            type: MessageType.prekeyBundle.rawValue,
            senderID: bundlePacket.senderID,
            recipientID: nil,
            timestamp: bundlePacket.timestamp + 5_000,
            payload: bundlePacket.payload,
            signature: bundlePacket.signature,
            ttl: bundlePacket.ttl
        )
        alice._test_handlePacket(replay, fromPeerID: bob.myPeerID, preseedPeer: false)

        let cached = await TestHelpers.waitUntil(
            { alice.prekeyBundleStore.hasUsableBundle(for: bob.noiseStaticPublicKeyData()) },
            timeout: TestConstants.shortTimeout
        )
        #expect(!cached)
        #expect(!alice._test_hasGossipPrekeyBundle(for: bob.myPeerID))
    }
}
