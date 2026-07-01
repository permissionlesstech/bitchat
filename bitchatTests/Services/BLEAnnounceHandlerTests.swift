import BitFoundation
import Foundation
import Testing
@testable import bitchat

struct BLEAnnounceHandlerTests {
    private final class Recorder {
        var existingNoisePublicKey: Data?
        var existingSigningPublicKey: Data?
        var persistedSigningPublicKey: Data?
        var persistedSigningKeyQueries: [PeerID] = []
        var signatureValid = true
        var linkState: (hasPeripheral: Bool, hasCentral: Bool) = (false, false)
        var upsertResult: BLEPeerAnnounceUpdate? = BLEPeerAnnounceUpdate(isNewPeer: false, wasDisconnected: false, previousNickname: nil)
        var dedupSeenIDs: Set<String> = []
        var shouldEmitReconnectLogResult = true

        var verifySignatureCalls: [(packet: BitchatPacket, signingPublicKey: Data)] = []
        var barrierCount = 0
        var upsertCalls: [(peerID: PeerID, announcement: AnnouncementPacket, isConnected: Bool, now: Date)] = []
        var reconnectLogQueries: [PeerID] = []
        var topologyUpdates: [(peerID: PeerID, neighbors: [Data])] = []
        var persistedIdentities: [AnnouncementPacket] = []
        var dedupContainsQueries: [String] = []
        var dedupMarkedIDs: [String] = []
        var uiEventDeliveries: [(peerID: PeerID, notifyPeerConnected: Bool, scheduleInitialSync: Bool)] = []
        var trackedPackets: [BitchatPacket] = []
        var announceBacks = 0
        var afterglowDelays: [TimeInterval] = []
    }

    private func makeHandler(
        recorder: Recorder,
        localPeerID: PeerID = PeerID(str: "0102030405060708"),
        now: Date = Date(timeIntervalSince1970: 1_000)
    ) -> BLEAnnounceHandler {
        let environment = BLEAnnounceHandlerEnvironment(
            localPeerID: { localPeerID },
            messageTTL: TransportConfig.messageTTLDefault,
            now: { now },
            existingPeerKeys: { _ in (recorder.existingNoisePublicKey, recorder.existingSigningPublicKey) },
            persistedSigningPublicKey: { peerID in
                recorder.persistedSigningKeyQueries.append(peerID)
                return recorder.persistedSigningPublicKey
            },
            verifySignature: { packet, signingPublicKey in
                recorder.verifySignatureCalls.append((packet, signingPublicKey))
                return recorder.signatureValid
            },
            linkState: { _ in recorder.linkState },
            withRegistryBarrier: { body in
                recorder.barrierCount += 1
                body()
            },
            upsertVerifiedAnnounce: { peerID, announcement, isConnected, now in
                recorder.upsertCalls.append((peerID, announcement, isConnected, now))
                return recorder.upsertResult
            },
            shouldEmitReconnectLog: { peerID, _ in
                recorder.reconnectLogQueries.append(peerID)
                return recorder.shouldEmitReconnectLogResult
            },
            updateTopology: { peerID, neighbors in
                recorder.topologyUpdates.append((peerID, neighbors))
            },
            persistIdentity: { announcement in
                recorder.persistedIdentities.append(announcement)
            },
            dedupContains: { id in
                recorder.dedupContainsQueries.append(id)
                return recorder.dedupSeenIDs.contains(id)
            },
            dedupMarkProcessed: { id in
                recorder.dedupMarkedIDs.append(id)
            },
            deliverAnnounceUIEvents: { peerID, notifyPeerConnected, scheduleInitialSync in
                recorder.uiEventDeliveries.append((peerID, notifyPeerConnected, scheduleInitialSync))
            },
            trackPacketSeen: { packet in
                recorder.trackedPackets.append(packet)
            },
            sendAnnounceBack: {
                recorder.announceBacks += 1
            },
            scheduleAfterglow: { delay in
                recorder.afterglowDelays.append(delay)
            }
        )
        return BLEAnnounceHandler(environment: environment)
    }

    @Test
    func verifiedNewPeerAnnounceUpsertsNotifiesSyncsAndAnnouncesBack() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let noiseKey = Data(repeating: 0x11, count: 32)
        let peerID = PeerID(publicKey: noiseKey)
        let packet = try makeAnnouncePacket(
            noisePublicKey: noiseKey,
            peerID: peerID,
            timestamp: timestamp(now),
            signature: Data(repeating: 0xEE, count: 64)
        )

        let recorder = Recorder()
        recorder.upsertResult = BLEPeerAnnounceUpdate(isNewPeer: true, wasDisconnected: false, previousNickname: nil)
        let handler = makeHandler(recorder: recorder, now: now)

        handler.handle(packet, from: peerID)

        #expect(recorder.verifySignatureCalls.count == 1)
        #expect(recorder.verifySignatureCalls.first?.signingPublicKey == Data(repeating: 0x99, count: 32))
        #expect(recorder.barrierCount == 1)
        #expect(recorder.upsertCalls.count == 1)
        #expect(recorder.upsertCalls.first?.peerID == peerID)
        #expect(recorder.upsertCalls.first?.announcement.nickname == "Alice")
        #expect(recorder.upsertCalls.first?.isConnected == true)
        #expect(recorder.upsertCalls.first?.now == now)
        #expect(recorder.persistedIdentities.count == 1)
        #expect(recorder.persistedIdentities.first?.noisePublicKey == noiseKey)
        #expect(recorder.uiEventDeliveries.count == 1)
        #expect(recorder.uiEventDeliveries.first?.peerID == peerID)
        #expect(recorder.uiEventDeliveries.first?.notifyPeerConnected == true)
        #expect(recorder.uiEventDeliveries.first?.scheduleInitialSync == true)
        #expect(recorder.trackedPackets.count == 1)
        #expect(recorder.dedupMarkedIDs == ["announce-back-\(peerID)"])
        #expect(recorder.announceBacks == 1)
        #expect(recorder.afterglowDelays.count == 1)
    }

    @Test
    func afterglowDelayStaysWithinConfiguredRange() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let noiseKey = Data(repeating: 0x12, count: 32)
        let peerID = PeerID(publicKey: noiseKey)
        let packet = try makeAnnouncePacket(
            noisePublicKey: noiseKey,
            peerID: peerID,
            timestamp: timestamp(now),
            signature: Data(repeating: 0xEE, count: 64)
        )

        let recorder = Recorder()
        recorder.upsertResult = BLEPeerAnnounceUpdate(isNewPeer: true, wasDisconnected: false, previousNickname: nil)
        let handler = makeHandler(recorder: recorder, now: now)

        for _ in 0..<8 {
            handler.handle(packet, from: peerID)
        }

        #expect(recorder.afterglowDelays.count == 8)
        for delay in recorder.afterglowDelays {
            #expect(delay >= 0.3 && delay <= 0.6)
        }
    }

    @Test
    func unverifiedAnnounceWithoutSignatureSkipsUpsertAndConnectNotify() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let noiseKey = Data(repeating: 0x22, count: 32)
        let peerID = PeerID(publicKey: noiseKey)
        let packet = try makeAnnouncePacket(
            noisePublicKey: noiseKey,
            peerID: peerID,
            timestamp: timestamp(now),
            signature: nil
        )

        let recorder = Recorder()
        let handler = makeHandler(recorder: recorder, now: now)

        handler.handle(packet, from: peerID)

        #expect(recorder.verifySignatureCalls.isEmpty)
        #expect(recorder.barrierCount == 1)
        #expect(recorder.upsertCalls.isEmpty)
        #expect(recorder.topologyUpdates.isEmpty)
        #expect(recorder.afterglowDelays.isEmpty)
        // Original behavior: list refresh, identity persistence, sync tracking
        // and announce-back still occur for unverified announces.
        #expect(recorder.uiEventDeliveries.count == 1)
        #expect(recorder.uiEventDeliveries.first?.notifyPeerConnected == false)
        #expect(recorder.uiEventDeliveries.first?.scheduleInitialSync == false)
        // Identity persistence MUST NOT occur for unverified announces:
        // persisting would let an attacker who replays a victim's noisePublicKey
        // overwrite the victim's stored signing key/nickname (identity poisoning).
        #expect(recorder.persistedIdentities.isEmpty)
        #expect(recorder.trackedPackets.count == 1)
        #expect(recorder.announceBacks == 1)
    }

    @Test
    func invalidSignatureSkipsUpsertAndConnectNotify() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let noiseKey = Data(repeating: 0x23, count: 32)
        let peerID = PeerID(publicKey: noiseKey)
        let packet = try makeAnnouncePacket(
            noisePublicKey: noiseKey,
            peerID: peerID,
            timestamp: timestamp(now),
            signature: Data(repeating: 0xEE, count: 64)
        )

        let recorder = Recorder()
        recorder.signatureValid = false
        let handler = makeHandler(recorder: recorder, now: now)

        handler.handle(packet, from: peerID)

        #expect(recorder.verifySignatureCalls.count == 1)
        #expect(recorder.upsertCalls.isEmpty)
        #expect(recorder.uiEventDeliveries.count == 1)
        #expect(recorder.uiEventDeliveries.first?.notifyPeerConnected == false)
    }

    @Test
    func malformedAnnounceIsNoOp() {
        let now = Date(timeIntervalSince1970: 1_000)
        let peerID = PeerID(str: "1122334455667788")
        let packet = BitchatPacket(
            type: MessageType.announce.rawValue,
            senderID: Data(hexString: peerID.id) ?? Data(),
            recipientID: nil,
            timestamp: timestamp(now),
            payload: Data([0x01, 0x20]),
            signature: nil,
            ttl: TransportConfig.messageTTLDefault
        )

        let recorder = Recorder()
        let handler = makeHandler(recorder: recorder, now: now)

        handler.handle(packet, from: peerID)

        expectNoSideEffects(recorder)
    }

    @Test
    func selfAnnounceIsNoOp() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let noiseKey = Data(repeating: 0x33, count: 32)
        let peerID = PeerID(publicKey: noiseKey)
        let packet = try makeAnnouncePacket(
            noisePublicKey: noiseKey,
            peerID: peerID,
            timestamp: timestamp(now),
            signature: Data(repeating: 0xEE, count: 64)
        )

        let recorder = Recorder()
        let handler = makeHandler(recorder: recorder, localPeerID: peerID, now: now)

        handler.handle(packet, from: peerID)

        expectNoSideEffects(recorder)
    }

    @Test
    func staleAnnounceIsNoOp() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let noiseKey = Data(repeating: 0x44, count: 32)
        let peerID = PeerID(publicKey: noiseKey)
        let staleTimestamp = UInt64((now.timeIntervalSince1970 - 901) * 1000)
        let packet = try makeAnnouncePacket(
            noisePublicKey: noiseKey,
            peerID: peerID,
            timestamp: staleTimestamp,
            signature: Data(repeating: 0xEE, count: 64)
        )

        let recorder = Recorder()
        let handler = makeHandler(recorder: recorder, now: now)

        handler.handle(packet, from: peerID)

        expectNoSideEffects(recorder)
    }

    @Test
    func reconnectedPeerNotifiesConnectionWithoutAfterglow() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let noiseKey = Data(repeating: 0x55, count: 32)
        let peerID = PeerID(publicKey: noiseKey)
        let packet = try makeAnnouncePacket(
            noisePublicKey: noiseKey,
            peerID: peerID,
            timestamp: timestamp(now),
            signature: Data(repeating: 0xEE, count: 64)
        )

        let recorder = Recorder()
        recorder.upsertResult = BLEPeerAnnounceUpdate(isNewPeer: false, wasDisconnected: true, previousNickname: "Alice")
        let handler = makeHandler(recorder: recorder, now: now)

        handler.handle(packet, from: peerID)

        #expect(recorder.uiEventDeliveries.count == 1)
        #expect(recorder.uiEventDeliveries.first?.peerID == peerID)
        #expect(recorder.uiEventDeliveries.first?.notifyPeerConnected == true)
        #expect(recorder.uiEventDeliveries.first?.scheduleInitialSync == true)
        #expect(recorder.reconnectLogQueries == [peerID])
        #expect(recorder.afterglowDelays.isEmpty)
    }

    @Test
    func relayedNewPeerSchedulesAfterglowWithoutConnectNotify() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let noiseKey = Data(repeating: 0x66, count: 32)
        let peerID = PeerID(publicKey: noiseKey)
        let packet = try makeAnnouncePacket(
            noisePublicKey: noiseKey,
            peerID: peerID,
            timestamp: timestamp(now),
            signature: Data(repeating: 0xEE, count: 64),
            ttl: TransportConfig.messageTTLDefault - 1
        )

        let recorder = Recorder()
        recorder.upsertResult = BLEPeerAnnounceUpdate(isNewPeer: true, wasDisconnected: false, previousNickname: nil)
        let handler = makeHandler(recorder: recorder, now: now)

        handler.handle(packet, from: peerID)

        #expect(recorder.upsertCalls.count == 1)
        #expect(recorder.upsertCalls.first?.isConnected == false)
        #expect(recorder.uiEventDeliveries.count == 1)
        #expect(recorder.uiEventDeliveries.first?.notifyPeerConnected == false)
        #expect(recorder.uiEventDeliveries.first?.scheduleInitialSync == false)
        #expect(recorder.afterglowDelays.count == 1)
    }

    @Test
    func announceBackIsSkippedWhenAlreadyMarked() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let noiseKey = Data(repeating: 0x77, count: 32)
        let peerID = PeerID(publicKey: noiseKey)
        let packet = try makeAnnouncePacket(
            noisePublicKey: noiseKey,
            peerID: peerID,
            timestamp: timestamp(now),
            signature: Data(repeating: 0xEE, count: 64)
        )

        let recorder = Recorder()
        recorder.dedupSeenIDs = ["announce-back-\(peerID)"]
        let handler = makeHandler(recorder: recorder, now: now)

        handler.handle(packet, from: peerID)

        #expect(recorder.dedupContainsQueries == ["announce-back-\(peerID)"])
        #expect(recorder.dedupMarkedIDs.isEmpty)
        #expect(recorder.announceBacks == 0)
    }

    @Test
    func verifiedAnnounceWithNeighborsUpdatesTopology() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let noiseKey = Data(repeating: 0x88, count: 32)
        let peerID = PeerID(publicKey: noiseKey)
        let neighbors = [Data(repeating: 0xAB, count: 8), Data(repeating: 0xCD, count: 8)]
        let packet = try makeAnnouncePacket(
            noisePublicKey: noiseKey,
            peerID: peerID,
            timestamp: timestamp(now),
            signature: Data(repeating: 0xEE, count: 64),
            directNeighbors: neighbors
        )

        let recorder = Recorder()
        let handler = makeHandler(recorder: recorder, now: now)

        handler.handle(packet, from: peerID)

        #expect(recorder.topologyUpdates.count == 1)
        #expect(recorder.topologyUpdates.first?.peerID == peerID)
        #expect(recorder.topologyUpdates.first?.neighbors == neighbors)
    }

    @Test
    func matchingPinnedSigningKeyIsAccepted() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let noiseKey = Data(repeating: 0x9A, count: 32)
        let peerID = PeerID(publicKey: noiseKey)
        let packet = try makeAnnouncePacket(
            noisePublicKey: noiseKey,
            peerID: peerID,
            timestamp: timestamp(now),
            signature: Data(repeating: 0xEE, count: 64)
        )

        let recorder = Recorder()
        recorder.existingNoisePublicKey = noiseKey
        // Matches the signing key encoded by makeAnnouncePacket.
        recorder.existingSigningPublicKey = Data(repeating: 0x99, count: 32)
        let handler = makeHandler(recorder: recorder, now: now)

        handler.handle(packet, from: peerID)

        #expect(recorder.upsertCalls.count == 1)
        #expect(recorder.persistedIdentities.count == 1)
    }

    @Test
    func signingKeyMismatchWithPinnedKeySkipsUpsertAndIdentityPersistence() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let noiseKey = Data(repeating: 0x9B, count: 32)
        let peerID = PeerID(publicKey: noiseKey)
        // Attacker announce: victim's noiseKey/peerID, attacker's signing key
        // (0x99 from makeAnnouncePacket) with a "valid" self-signature.
        let packet = try makeAnnouncePacket(
            noisePublicKey: noiseKey,
            peerID: peerID,
            timestamp: timestamp(now),
            signature: Data(repeating: 0xEE, count: 64)
        )

        let recorder = Recorder()
        recorder.existingNoisePublicKey = noiseKey
        recorder.existingSigningPublicKey = Data(repeating: 0x42, count: 32) // victim's pinned key
        recorder.signatureValid = true
        let handler = makeHandler(recorder: recorder, now: now)

        handler.handle(packet, from: peerID)

        #expect(recorder.upsertCalls.isEmpty)
        #expect(recorder.persistedIdentities.isEmpty)
        #expect(recorder.topologyUpdates.isEmpty)
        #expect(recorder.uiEventDeliveries.count == 1)
        #expect(recorder.uiEventDeliveries.first?.notifyPeerConnected == false)
    }

    @Test
    func persistedSigningKeyMismatchWithoutRegistryEntryIsRejected() throws {
        // Registry has no entry (app restart or offline-peer eviction), but
        // the persisted cryptographic identity still pins the victim's
        // signing key. An attacker replaying the victim's noiseKey/peerID
        // with their own signing key must not be treated as first contact.
        let now = Date(timeIntervalSince1970: 1_000)
        let noiseKey = Data(repeating: 0x9D, count: 32)
        let peerID = PeerID(publicKey: noiseKey)
        let packet = try makeAnnouncePacket(
            noisePublicKey: noiseKey,
            peerID: peerID,
            timestamp: timestamp(now),
            signature: Data(repeating: 0xEE, count: 64)
        )

        let recorder = Recorder()
        recorder.existingNoisePublicKey = nil
        recorder.existingSigningPublicKey = nil
        recorder.persistedSigningPublicKey = Data(repeating: 0x42, count: 32) // victim's persisted pin
        let handler = makeHandler(recorder: recorder, now: now)

        handler.handle(packet, from: peerID)

        #expect(recorder.persistedSigningKeyQueries == [peerID])
        #expect(recorder.upsertCalls.isEmpty)
        #expect(recorder.persistedIdentities.isEmpty)
        #expect(recorder.topologyUpdates.isEmpty)
        #expect(recorder.uiEventDeliveries.count == 1)
        #expect(recorder.uiEventDeliveries.first?.notifyPeerConnected == false)
    }

    @Test
    func persistedSigningKeyMatchWithoutRegistryEntryIsAccepted() throws {
        // Legitimate returning peer: registry entry evicted, persisted pin
        // matches the announced signing key — accepted like a normal announce.
        let now = Date(timeIntervalSince1970: 1_000)
        let noiseKey = Data(repeating: 0x9E, count: 32)
        let peerID = PeerID(publicKey: noiseKey)
        let packet = try makeAnnouncePacket(
            noisePublicKey: noiseKey,
            peerID: peerID,
            timestamp: timestamp(now),
            signature: Data(repeating: 0xEE, count: 64)
        )

        let recorder = Recorder()
        // Matches the signing key encoded by makeAnnouncePacket.
        recorder.persistedSigningPublicKey = Data(repeating: 0x99, count: 32)
        let handler = makeHandler(recorder: recorder, now: now)

        handler.handle(packet, from: peerID)

        #expect(recorder.upsertCalls.count == 1)
        #expect(recorder.persistedIdentities.count == 1)
    }

    @Test
    func registryPinnedSigningKeySkipsPersistedLookup() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let noiseKey = Data(repeating: 0x9F, count: 32)
        let peerID = PeerID(publicKey: noiseKey)
        let packet = try makeAnnouncePacket(
            noisePublicKey: noiseKey,
            peerID: peerID,
            timestamp: timestamp(now),
            signature: Data(repeating: 0xEE, count: 64)
        )

        let recorder = Recorder()
        recorder.existingNoisePublicKey = noiseKey
        recorder.existingSigningPublicKey = Data(repeating: 0x99, count: 32)
        let handler = makeHandler(recorder: recorder, now: now)

        handler.handle(packet, from: peerID)

        #expect(recorder.persistedSigningKeyQueries.isEmpty)
        #expect(recorder.upsertCalls.count == 1)
    }

    @Test
    func registryPinRejectionSkipsTopologyAndIdentityPersistence() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let noiseKey = Data(repeating: 0x9C, count: 32)
        let peerID = PeerID(publicKey: noiseKey)
        let packet = try makeAnnouncePacket(
            noisePublicKey: noiseKey,
            peerID: peerID,
            timestamp: timestamp(now),
            signature: Data(repeating: 0xEE, count: 64),
            directNeighbors: [Data(repeating: 0xAB, count: 8)]
        )

        // Pre-barrier trust check sees no pinned key (e.g. concurrent race),
        // but the registry itself refuses to replace its pinned signing key.
        let recorder = Recorder()
        recorder.upsertResult = nil
        let handler = makeHandler(recorder: recorder, now: now)

        handler.handle(packet, from: peerID)

        #expect(recorder.upsertCalls.count == 1)
        #expect(recorder.persistedIdentities.isEmpty)
        #expect(recorder.topologyUpdates.isEmpty)
        #expect(recorder.uiEventDeliveries.count == 1)
        #expect(recorder.uiEventDeliveries.first?.notifyPeerConnected == false)
        #expect(recorder.afterglowDelays.isEmpty)
    }

    @Test
    func keyMismatchWithExistingPeerKeepsAnnounceUnverified() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let noiseKey = Data(repeating: 0x99, count: 32)
        let peerID = PeerID(publicKey: noiseKey)
        let packet = try makeAnnouncePacket(
            noisePublicKey: noiseKey,
            peerID: peerID,
            timestamp: timestamp(now),
            signature: Data(repeating: 0xEE, count: 64)
        )

        let recorder = Recorder()
        recorder.existingNoisePublicKey = Data(repeating: 0xAA, count: 32)
        let handler = makeHandler(recorder: recorder, now: now)

        handler.handle(packet, from: peerID)

        #expect(recorder.upsertCalls.isEmpty)
        #expect(recorder.uiEventDeliveries.count == 1)
        #expect(recorder.uiEventDeliveries.first?.notifyPeerConnected == false)
    }

    @Test
    func attackerReplayingVictimNoiseKeyWithOwnSigningKeyIsRejectedEndToEnd() throws {
        // Real crypto: the attacker crafts a fully self-consistent announce
        // (victim's noiseKey/peerID, attacker's signing key and nickname,
        // valid packet signature made with the attacker's key). Without
        // signing-key pinning this used to overwrite the victim's registry
        // entry and persisted identity.
        let victim = NoiseEncryptionService(keychain: MockKeychain())
        let attacker = NoiseEncryptionService(keychain: MockKeychain())
        let victimNoiseKey = victim.getStaticPublicKeyData()
        let peerID = PeerID(publicKey: victimNoiseKey)
        let now = Date()

        final class RegistryBox {
            var registry = BLEPeerRegistry()
            var persistedIdentities: [AnnouncementPacket] = []
        }
        let box = RegistryBox()

        let environment = BLEAnnounceHandlerEnvironment(
            localPeerID: { PeerID(str: "0102030405060708") },
            messageTTL: TransportConfig.messageTTLDefault,
            now: { now },
            existingPeerKeys: { peerID in
                let info = box.registry.info(for: peerID)
                return (info?.noisePublicKey, info?.signingPublicKey)
            },
            persistedSigningPublicKey: { _ in nil },
            verifySignature: { packet, signingPublicKey in
                victim.verifyPacketSignature(packet, publicKey: signingPublicKey)
            },
            linkState: { _ in (hasPeripheral: true, hasCentral: false) },
            withRegistryBarrier: { body in body() },
            upsertVerifiedAnnounce: { peerID, announcement, isConnected, now in
                box.registry.upsertVerifiedAnnounce(
                    peerID: peerID,
                    nickname: announcement.nickname,
                    noisePublicKey: announcement.noisePublicKey,
                    signingPublicKey: announcement.signingPublicKey,
                    isConnected: isConnected,
                    now: now
                )
            },
            shouldEmitReconnectLog: { _, _ in false },
            updateTopology: { _, _ in },
            persistIdentity: { announcement in
                box.persistedIdentities.append(announcement)
            },
            dedupContains: { _ in true },
            dedupMarkProcessed: { _ in },
            deliverAnnounceUIEvents: { _, _, _ in },
            trackPacketSeen: { _ in },
            sendAnnounceBack: {},
            scheduleAfterglow: { _ in }
        )
        let handler = BLEAnnounceHandler(environment: environment)

        func makeSignedAnnounce(nickname: String, signer: NoiseEncryptionService) throws -> BitchatPacket {
            let announcement = AnnouncementPacket(
                nickname: nickname,
                noisePublicKey: victimNoiseKey,
                signingPublicKey: signer.getSigningPublicKeyData(),
                directNeighbors: nil
            )
            let payload = try #require(announcement.encode())
            let packet = BitchatPacket(
                type: MessageType.announce.rawValue,
                senderID: Data(hexString: peerID.id) ?? Data(),
                recipientID: nil,
                timestamp: UInt64(now.timeIntervalSince1970 * 1000),
                payload: payload,
                signature: nil,
                ttl: TransportConfig.messageTTLDefault
            )
            return try #require(signer.signPacket(packet))
        }

        // Legitimate announce from the victim is accepted and pinned.
        let victimAnnounce = try makeSignedAnnounce(nickname: "victim", signer: victim)
        handler.handle(victimAnnounce, from: peerID)

        #expect(box.registry.info(for: peerID)?.nickname == "victim")
        #expect(box.registry.info(for: peerID)?.signingPublicKey == victim.getSigningPublicKeyData())
        #expect(box.persistedIdentities.count == 1)

        // Attacker announce with a valid self-signature must be rejected.
        let attackerAnnounce = try makeSignedAnnounce(nickname: "attacker", signer: attacker)
        handler.handle(attackerAnnounce, from: peerID)

        #expect(box.registry.info(for: peerID)?.nickname == "victim")
        #expect(box.registry.info(for: peerID)?.signingPublicKey == victim.getSigningPublicKeyData())
        #expect(box.persistedIdentities.count == 1)

        // The victim's subsequent announces (same pinned key) still work.
        let victimRename = try makeSignedAnnounce(nickname: "victim-renamed", signer: victim)
        handler.handle(victimRename, from: peerID)

        #expect(box.registry.info(for: peerID)?.nickname == "victim-renamed")
        #expect(box.persistedIdentities.count == 2)
    }

    @Test
    func signingKeyPinSurvivesRegistryEvictionAndRestartEndToEnd() throws {
        // Real crypto + real persistence: the victim announces and gets
        // pinned, then the registry entry disappears (offline-peer eviction
        // via reconcileConnectivity, or app restart which starts with an
        // empty registry). The attacker replays the victim's
        // noiseKey/peerID with their own signing key and a valid
        // self-signature — the persisted identity must still block the
        // takeover, and must not be overwritten. The victim (same signing
        // key) must be re-accepted.
        let victim = NoiseEncryptionService(keychain: MockKeychain())
        let attacker = NoiseEncryptionService(keychain: MockKeychain())
        let victimNoiseKey = victim.getStaticPublicKeyData()
        let peerID = PeerID(publicKey: victimNoiseKey)
        let now = Date()

        let identityKeychain = MockKeychain()
        let identityManager = SecureIdentityStateManager(identityKeychain)

        final class RegistryBox {
            var registry = BLEPeerRegistry()
        }
        let box = RegistryBox()

        func makeEnvironment(identityManager: SecureIdentityStateManager) -> BLEAnnounceHandlerEnvironment {
            BLEAnnounceHandlerEnvironment(
                localPeerID: { PeerID(str: "0102030405060708") },
                messageTTL: TransportConfig.messageTTLDefault,
                now: { now },
                existingPeerKeys: { peerID in
                    let info = box.registry.info(for: peerID)
                    return (info?.noisePublicKey, info?.signingPublicKey)
                },
                // Mirrors the BLEService wiring: fall back to the persisted
                // cryptographic identity.
                persistedSigningPublicKey: { peerID in
                    identityManager.getCryptoIdentitiesByPeerIDPrefix(peerID)
                        .compactMap { $0.signingPublicKey }
                        .first
                },
                verifySignature: { packet, signingPublicKey in
                    victim.verifyPacketSignature(packet, publicKey: signingPublicKey)
                },
                linkState: { _ in (hasPeripheral: true, hasCentral: false) },
                withRegistryBarrier: { body in body() },
                upsertVerifiedAnnounce: { peerID, announcement, isConnected, now in
                    box.registry.upsertVerifiedAnnounce(
                        peerID: peerID,
                        nickname: announcement.nickname,
                        noisePublicKey: announcement.noisePublicKey,
                        signingPublicKey: announcement.signingPublicKey,
                        isConnected: isConnected,
                        now: now
                    )
                },
                shouldEmitReconnectLog: { _, _ in false },
                updateTopology: { _, _ in },
                persistIdentity: { announcement in
                    identityManager.upsertCryptographicIdentity(
                        fingerprint: announcement.noisePublicKey.sha256Fingerprint(),
                        noisePublicKey: announcement.noisePublicKey,
                        signingPublicKey: announcement.signingPublicKey,
                        claimedNickname: announcement.nickname
                    )
                },
                dedupContains: { _ in true },
                dedupMarkProcessed: { _ in },
                deliverAnnounceUIEvents: { _, _, _ in },
                trackPacketSeen: { _ in },
                sendAnnounceBack: {},
                scheduleAfterglow: { _ in }
            )
        }
        let handler = BLEAnnounceHandler(environment: makeEnvironment(identityManager: identityManager))

        func makeSignedAnnounce(nickname: String, signer: NoiseEncryptionService) throws -> BitchatPacket {
            let announcement = AnnouncementPacket(
                nickname: nickname,
                noisePublicKey: victimNoiseKey,
                signingPublicKey: signer.getSigningPublicKeyData(),
                directNeighbors: nil
            )
            let payload = try #require(announcement.encode())
            let packet = BitchatPacket(
                type: MessageType.announce.rawValue,
                senderID: Data(hexString: peerID.id) ?? Data(),
                recipientID: nil,
                timestamp: UInt64(now.timeIntervalSince1970 * 1000),
                payload: payload,
                signature: nil,
                ttl: TransportConfig.messageTTLDefault
            )
            return try #require(signer.signPacket(packet))
        }

        func persistedIdentity() -> CryptographicIdentity? {
            // queue.sync read; fences the manager's pending barrier writes.
            identityManager.getCryptoIdentitiesByPeerIDPrefix(peerID).first
        }

        // 1. Victim announces: pinned in the registry and persisted.
        handler.handle(try makeSignedAnnounce(nickname: "victim", signer: victim), from: peerID)
        #expect(box.registry.info(for: peerID)?.signingPublicKey == victim.getSigningPublicKeyData())
        #expect(persistedIdentity()?.signingPublicKey == victim.getSigningPublicKeyData())

        // 2. Registry entry disappears (eviction / restart).
        _ = box.registry.remove(peerID)
        #expect(box.registry.info(for: peerID) == nil)

        // 3. Attacker replay with own signing key: rejected via the persisted
        //    pin, and neither the registry nor the persisted identity change.
        handler.handle(try makeSignedAnnounce(nickname: "attacker", signer: attacker), from: peerID)
        #expect(box.registry.info(for: peerID) == nil)
        #expect(persistedIdentity()?.signingPublicKey == victim.getSigningPublicKeyData())
        #expect(identityManager.getSocialIdentity(for: victimNoiseKey.sha256Fingerprint())?.claimedNickname == "victim")

        // 4. Victim re-announces with the same signing key: accepted again.
        handler.handle(try makeSignedAnnounce(nickname: "victim", signer: victim), from: peerID)
        #expect(box.registry.info(for: peerID)?.nickname == "victim")
        #expect(box.registry.info(for: peerID)?.signingPublicKey == victim.getSigningPublicKeyData())

        // 5. Simulated app restart: a fresh identity manager reloads the pin
        //    from the (mock) keychain, and a fresh registry starts empty. The
        //    attacker replay is still rejected.
        identityManager.forceSave()
        let reloadedManager = SecureIdentityStateManager(identityKeychain)
        #expect(
            reloadedManager.getCryptoIdentitiesByPeerIDPrefix(peerID).first?.signingPublicKey
                == victim.getSigningPublicKeyData()
        )
        box.registry = BLEPeerRegistry()
        let restartedHandler = BLEAnnounceHandler(environment: makeEnvironment(identityManager: reloadedManager))
        restartedHandler.handle(try makeSignedAnnounce(nickname: "attacker", signer: attacker), from: peerID)
        #expect(box.registry.info(for: peerID) == nil)
        #expect(
            reloadedManager.getCryptoIdentitiesByPeerIDPrefix(peerID).first?.signingPublicKey
                == victim.getSigningPublicKeyData()
        )

        // ...while the victim is accepted after the restart.
        restartedHandler.handle(try makeSignedAnnounce(nickname: "victim", signer: victim), from: peerID)
        #expect(box.registry.info(for: peerID)?.signingPublicKey == victim.getSigningPublicKeyData())
    }

    private func expectNoSideEffects(_ recorder: Recorder) {
        #expect(recorder.barrierCount == 0)
        #expect(recorder.upsertCalls.isEmpty)
        #expect(recorder.topologyUpdates.isEmpty)
        #expect(recorder.persistedIdentities.isEmpty)
        #expect(recorder.dedupMarkedIDs.isEmpty)
        #expect(recorder.uiEventDeliveries.isEmpty)
        #expect(recorder.trackedPackets.isEmpty)
        #expect(recorder.announceBacks == 0)
        #expect(recorder.afterglowDelays.isEmpty)
    }

    private func makeAnnouncePacket(
        noisePublicKey: Data,
        peerID: PeerID,
        timestamp: UInt64,
        signature: Data?,
        ttl: UInt8 = TransportConfig.messageTTLDefault,
        directNeighbors: [Data]? = nil
    ) throws -> BitchatPacket {
        let announcement = AnnouncementPacket(
            nickname: "Alice",
            noisePublicKey: noisePublicKey,
            signingPublicKey: Data(repeating: 0x99, count: 32),
            directNeighbors: directNeighbors
        )
        let payload = try #require(announcement.encode())

        return BitchatPacket(
            type: MessageType.announce.rawValue,
            senderID: Data(hexString: peerID.id) ?? Data(),
            recipientID: nil,
            timestamp: timestamp,
            payload: payload,
            signature: signature,
            ttl: ttl
        )
    }

    private func timestamp(_ date: Date) -> UInt64 {
        UInt64(date.timeIntervalSince1970 * 1000)
    }
}
