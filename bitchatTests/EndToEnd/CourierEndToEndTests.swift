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
        let identityManager = MockIdentityManager(keychain)
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

    // MARK: - Tests

    @Test func courierCarriesMessageAcrossDisjointConnectivity() async throws {
        let alice = makeService()
        let carol = makeService()
        let bob = makeService()
        // Alice and Carol are mutual favorites; trust policy is exercised
        // separately in depositFromUntrustedPeerIsRejected.
        carol.courierDepositPolicy = { _ in true }

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
        carol._test_handlePacket(depositPacket, fromPeerID: alice.myPeerID)
        let carried = await TestHelpers.waitUntil(
            { !carol.courierStore.isEmpty },
            timeout: TestConstants.defaultTimeout
        )
        #expect(carried)

        // 3. Later, Bob announces near Carol → handover fires.
        bob.sendBroadcastAnnounce()
        let announced = await TestHelpers.waitUntil(
            { bobOut.first(ofType: .announce) != nil },
            timeout: TestConstants.defaultTimeout
        )
        #expect(announced)
        let announcePacket = try #require(bobOut.first(ofType: .announce))
        carol._test_handlePacket(announcePacket, fromPeerID: bob.myPeerID)

        let handedOver = await TestHelpers.waitUntil(
            { carolOut.first(ofType: .courierEnvelope) != nil },
            timeout: TestConstants.defaultTimeout
        )
        #expect(handedOver)
        #expect(carol.courierStore.isEmpty)
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
        // Sender resolves to Alice's stable mesh identity, not the courier's.
        #expect(delivered.peerID == alice.myPeerID)
        let message = try #require(PrivateMessagePacket.decode(from: delivered.payload))
        #expect(message.messageID == "courier-msg-1")
        #expect(message.content == "the camp moved north")
    }

    @Test func depositFromUntrustedPeerIsRejected() async throws {
        let carol = makeService()
        carol.courierDepositPolicy = { _ in false } // depositor is not a mutual favorite

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
        let packet = BitchatPacket(
            type: MessageType.courierEnvelope.rawValue,
            senderID: Data(hexString: alicePeerID.id) ?? Data(),
            recipientID: Data(hexString: carol.myPeerID.id),
            timestamp: UInt64(now.timeIntervalSince1970 * 1000),
            payload: try #require(envelope.encode()),
            signature: nil,
            ttl: 1
        )

        carol._test_handlePacket(packet, fromPeerID: alicePeerID)
        let stored = await TestHelpers.waitUntil(
            { !carol.courierStore.isEmpty },
            timeout: TestConstants.shortTimeout
        )
        #expect(!stored)
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

    var peerSnapshotPublisher: AnyPublisher<[TransportPeerSnapshot], Never> {
        Just(snapshots).eraseToAnyPublisher()
    }
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
    func isPeerReachable(_ peerID: PeerID) -> Bool { isPeerConnected(peerID) }
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
}
