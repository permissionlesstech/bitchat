import BitFoundation
import Foundation
import Testing
@testable import bitchat

struct BLEAnnounceHandlerTests {
    private final class Recorder {
        var existingNoisePublicKey: Data?
        var signatureValid = true
        var linkState: (hasPeripheral: Bool, hasCentral: Bool) = (false, false)
        var linkBoundToOtherPeer = false
        var upsertResult = BLEPeerAnnounceUpdate(isNewPeer: false, wasDisconnected: false, previousNickname: nil)
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
            existingNoisePublicKey: { _ in recorder.existingNoisePublicKey },
            verifySignature: { packet, signingPublicKey in
                recorder.verifySignatureCalls.append((packet, signingPublicKey))
                return recorder.signatureValid
            },
            linkState: { _ in recorder.linkState },
            linkBoundToOtherPeer: { _, _ in recorder.linkBoundToOtherPeer },
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

        let result = handler.handle(packet, from: peerID)

        #expect(result?.peerID == peerID)
        #expect(result?.announcement.noisePublicKey == noiseKey)
        #expect(result?.isDirectAnnounce == true)
        #expect(result?.isVerified == true)
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

        let result = handler.handle(packet, from: peerID)

        #expect(result?.peerID == peerID)
        #expect(result?.announcement.noisePublicKey == noiseKey)
        #expect(result?.isVerified == false)
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

        let result = handler.handle(packet, from: peerID)

        #expect(result?.isVerified == false)
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

        let result = handler.handle(packet, from: peerID)

        #expect(result == nil)
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

        let result = handler.handle(packet, from: peerID)

        #expect(result == nil)
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

        let result = handler.handle(packet, from: peerID)

        #expect(result == nil)
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

        let result = handler.handle(packet, from: peerID)

        #expect(result?.isDirectAnnounce == false)
        #expect(result?.isVerified == true)
        #expect(recorder.upsertCalls.count == 1)
        #expect(recorder.upsertCalls.first?.isConnected == false)
        #expect(recorder.uiEventDeliveries.count == 1)
        #expect(recorder.uiEventDeliveries.first?.notifyPeerConnected == false)
        #expect(recorder.uiEventDeliveries.first?.scheduleInitialSync == false)
        #expect(recorder.afterglowDelays.count == 1)
    }

    /// TTL is unsigned, so a replayed announce with its TTL restored looks
    /// "direct" — but it arrives on a link another peer already owns. That
    /// link must not shortcut the (possibly absent) claimed peer into
    /// "connected".
    @Test
    func directAnnounceOnLinkBoundToAnotherPeerDoesNotMarkConnected() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let noiseKey = Data(repeating: 0x88, count: 32)
        let peerID = PeerID(publicKey: noiseKey)
        let packet = try makeAnnouncePacket(
            noisePublicKey: noiseKey,
            peerID: peerID,
            timestamp: timestamp(now),
            signature: Data(repeating: 0xEE, count: 64)
        )

        let recorder = Recorder()
        recorder.linkBoundToOtherPeer = true
        recorder.upsertResult = BLEPeerAnnounceUpdate(isNewPeer: true, wasDisconnected: false, previousNickname: nil)
        let handler = makeHandler(recorder: recorder, now: now)

        let result = handler.handle(packet, from: peerID)

        #expect(result?.isDirectAnnounce == true)
        #expect(result?.isVerified == true)
        #expect(recorder.upsertCalls.count == 1)
        #expect(recorder.upsertCalls.first?.isConnected == false)
    }

    /// A peer with its own live link stays connected even when a copy of its
    /// announce arrives on someone else's link.
    @Test
    func directAnnounceOnForeignLinkKeepsPeerWithOwnLinkConnected() throws {
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
        recorder.linkBoundToOtherPeer = true
        recorder.linkState = (hasPeripheral: false, hasCentral: true)
        let handler = makeHandler(recorder: recorder, now: now)

        handler.handle(packet, from: peerID)

        #expect(recorder.upsertCalls.count == 1)
        #expect(recorder.upsertCalls.first?.isConnected == true)
    }

    /// Documents the handler's contract around the rebind: the
    /// linkBoundToOtherPeer read reflects the binding BEFORE the rebind runs,
    /// so a replayed "direct" announce on someone else's link is denied the
    /// connected shortcut — presence only flips via the rebind itself
    /// (BLEService promotes the new owner after a successful, containment-
    /// checked rebind) or via a later announce arriving on the now-rebound
    /// link, as simulated here. Either way the residue is presence display
    /// only — DMs remain gated on canDeliverSecurely, so without a Noise
    /// session they take the retain + courier path (see MessageRouterTests
    /// .sendPrivate_connectedWithoutSecureSessionRetainsAndDepositsWithCourier).
    @Test
    func secondReplayedDirectAnnounceAfterRebindMarksAbsentPeerConnected() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let noiseKey = Data(repeating: 0xA1, count: 32)
        let victim = PeerID(publicKey: noiseKey)
        let packet = try makeAnnouncePacket(
            noisePublicKey: noiseKey,
            peerID: victim,
            timestamp: timestamp(now),
            signature: Data(repeating: 0xEE, count: 64)
        )

        let recorder = Recorder()
        let handler = makeHandler(recorder: recorder, now: now)

        // First replay: the link still belongs to the replayer and the victim
        // has no live link of its own — the connected shortcut is denied.
        recorder.linkBoundToOtherPeer = true
        recorder.linkState = (hasPeripheral: false, hasCentral: false)
        handler.handle(packet, from: victim)
        #expect(recorder.upsertCalls.count == 1)
        #expect(recorder.upsertCalls.first?.isConnected == false)

        // The rebind then binds the replayer's link to the victim's ID (the
        // rotation-heal path, containment-checked in BLEService). A second
        // replay now finds the link owned by the claimed peer …
        recorder.linkBoundToOtherPeer = false
        recorder.linkState = (hasPeripheral: false, hasCentral: true)
        handler.handle(packet, from: victim)

        // … and the absent victim reads as connected: the residual gap.
        #expect(recorder.upsertCalls.count == 2)
        #expect(recorder.upsertCalls.last?.isConnected == true)
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

        let result = handler.handle(packet, from: peerID)

        #expect(result?.isVerified == false)
        #expect(recorder.upsertCalls.isEmpty)
        #expect(recorder.uiEventDeliveries.count == 1)
        #expect(recorder.uiEventDeliveries.first?.notifyPeerConnected == false)
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
