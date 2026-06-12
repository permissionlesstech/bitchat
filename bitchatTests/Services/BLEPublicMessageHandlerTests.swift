import BitFoundation
import Foundation
import Testing
@testable import bitchat

struct BLEPublicMessageHandlerTests {
    private final class Recorder {
        var localNickname = "Me"
        var peers: [PeerID: BLEPeerInfo] = [:]
        var signedName: String?
        var verifyPacketSignatureResult = false
        var linkState: (hasPeripheral: Bool, hasCentral: Bool) = (false, false)
        var selfBroadcastMessageID: String?

        var peersSnapshotReads = 0
        var verifyPacketSignatureQueries: [PeerID] = []
        var signedNameQueries: [PeerID] = []
        var trackedPackets: [BitchatPacket] = []
        var selfBroadcastTakes: [BitchatPacket] = []
        var deliveries: [(peerID: PeerID, nickname: String, content: String, timestamp: Date, messageID: String?)] = []
    }

    private let localPeerID = PeerID(str: "0102030405060708")
    private let remotePeerID = PeerID(str: "1122334455667788")

    private func makeHandler(
        recorder: Recorder,
        localPeerID: PeerID? = nil,
        now: Date = Date(timeIntervalSince1970: 1_000)
    ) -> BLEPublicMessageHandler {
        let resolvedLocalPeerID = localPeerID ?? self.localPeerID
        let environment = BLEPublicMessageHandlerEnvironment(
            localPeerID: { resolvedLocalPeerID },
            localNickname: { recorder.localNickname },
            now: { now },
            peersSnapshot: {
                recorder.peersSnapshotReads += 1
                return recorder.peers
            },
            verifyPacketSignature: { packet, _ in
                recorder.verifyPacketSignatureQueries.append(PeerID(hexData: packet.senderID))
                return recorder.verifyPacketSignatureResult
            },
            signedSenderDisplayName: { _, peerID in
                recorder.signedNameQueries.append(peerID)
                return recorder.signedName
            },
            trackPacketSeen: { packet in
                recorder.trackedPackets.append(packet)
            },
            linkState: { _ in recorder.linkState },
            takeSelfBroadcastMessageID: { packet in
                recorder.selfBroadcastTakes.append(packet)
                return recorder.selfBroadcastMessageID
            },
            deliverPublicMessage: { peerID, nickname, content, timestamp, messageID in
                recorder.deliveries.append((peerID, nickname, content, timestamp, messageID))
            }
        )
        return BLEPublicMessageHandler(environment: environment)
    }

    @Test
    func verifiedPeerBroadcastIsTrackedAndDelivered() {
        let now = Date(timeIntervalSince1970: 1_000)
        let recorder = Recorder()
        recorder.peers = [remotePeerID: makePeerInfo(remotePeerID, nickname: "Alice", isVerified: true)]
        // A valid packet signature is required even for a registry-verified peer:
        // senderID is spoofable, so registry membership alone is not authentication.
        recorder.signedName = "SignedAlice"
        let handler = makeHandler(recorder: recorder, now: now)
        let packet = makeMessagePacket(sender: remotePeerID, content: "hello mesh", timestamp: timestamp(now))

        handler.handle(packet, from: remotePeerID)

        #expect(recorder.peersSnapshotReads == 1)
        // Signature is verified, then the registry's collision-resolved name is preferred.
        #expect(recorder.signedNameQueries == [remotePeerID])
        #expect(recorder.trackedPackets.count == 1)
        #expect(recorder.selfBroadcastTakes.isEmpty)
        #expect(recorder.deliveries.count == 1)
        #expect(recorder.deliveries.first?.peerID == remotePeerID)
        #expect(recorder.deliveries.first?.nickname == "Alice")
        #expect(recorder.deliveries.first?.content == "hello mesh")
        #expect(recorder.deliveries.first?.timestamp == now)
        #expect(recorder.deliveries.first?.messageID == nil)
    }

    @Test
    func selfEchoIsDropped() {
        let now = Date(timeIntervalSince1970: 1_000)
        let recorder = Recorder()
        let handler = makeHandler(recorder: recorder, now: now)
        let packet = makeMessagePacket(sender: localPeerID, content: "echo", timestamp: timestamp(now), ttl: 3)

        handler.handle(packet, from: localPeerID)

        expectNoSideEffects(recorder)
    }

    @Test
    func staleBroadcastIsDropped() {
        let now = Date(timeIntervalSince1970: 1_000)
        let recorder = Recorder()
        recorder.peers = [remotePeerID: makePeerInfo(remotePeerID, nickname: "Alice", isVerified: true)]
        let handler = makeHandler(recorder: recorder, now: now)
        let staleTimestamp = UInt64((now.timeIntervalSince1970 - 901) * 1000)
        let packet = makeMessagePacket(sender: remotePeerID, content: "old", timestamp: staleTimestamp)

        handler.handle(packet, from: remotePeerID)

        expectNoSideEffects(recorder)
    }

    @Test
    func unknownPeerWithoutValidSignatureIsDroppedBeforeSyncTracking() {
        let now = Date(timeIntervalSince1970: 1_000)
        let recorder = Recorder()
        let handler = makeHandler(recorder: recorder, now: now)
        let packet = makeMessagePacket(sender: remotePeerID, content: "hi", timestamp: timestamp(now))

        handler.handle(packet, from: remotePeerID)

        #expect(recorder.signedNameQueries == [remotePeerID])
        // The sender must resolve before the packet is tracked for sync.
        #expect(recorder.trackedPackets.isEmpty)
        #expect(recorder.deliveries.isEmpty)
    }

    @Test
    func connectedButUnverifiedPeerIsDropped() {
        let now = Date(timeIntervalSince1970: 1_000)
        let recorder = Recorder()
        recorder.peers = [remotePeerID: makePeerInfo(remotePeerID, nickname: "Mallory", isVerified: false, isConnected: true)]
        let handler = makeHandler(recorder: recorder, now: now)
        let packet = makeMessagePacket(sender: remotePeerID, content: "hi", timestamp: timestamp(now))

        handler.handle(packet, from: remotePeerID)

        // Public messages never accept connected-but-unverified registry entries.
        #expect(recorder.signedNameQueries == [remotePeerID])
        #expect(recorder.trackedPackets.isEmpty)
        #expect(recorder.deliveries.isEmpty)
    }

    @Test
    func registryVerifiedPeerDeliveredBeforeIdentityCachePersists() {
        // A freshly verified announce updates the peer registry synchronously,
        // but identity-cache persistence is async. A message arriving in that
        // window has a valid signature and a registry signing key, yet the
        // persisted-identity lookup (signedName) would still return nil. It must
        // be verified against the registry key and delivered, not dropped.
        let now = Date(timeIntervalSince1970: 1_000)
        let recorder = Recorder()
        recorder.peers = [remotePeerID: makePeerInfo(
            remotePeerID,
            nickname: "Alice",
            isVerified: true,
            signingPublicKey: Data(repeating: 0xAB, count: 32)
        )]
        recorder.verifyPacketSignatureResult = true
        recorder.signedName = nil
        let handler = makeHandler(recorder: recorder, now: now)
        let packet = makeMessagePacket(sender: remotePeerID, content: "first msg", timestamp: timestamp(now))

        handler.handle(packet, from: remotePeerID)

        #expect(recorder.verifyPacketSignatureQueries == [remotePeerID])
        // Verified via the registry key, so no fallback to the persisted lookup.
        #expect(recorder.signedNameQueries.isEmpty)
        #expect(recorder.trackedPackets.count == 1)
        #expect(recorder.deliveries.count == 1)
        #expect(recorder.deliveries.first?.nickname == "Alice")
        #expect(recorder.deliveries.first?.content == "first msg")
    }

    @Test
    func registryPeerWithInvalidSignatureFallsBackAndDrops() {
        // Spoofed senderID: the peer is in the registry with a signing key, but
        // the packet signature does not verify against it. The handler must fall
        // back to the persisted lookup and, finding nothing, drop the message.
        let now = Date(timeIntervalSince1970: 1_000)
        let recorder = Recorder()
        recorder.peers = [remotePeerID: makePeerInfo(
            remotePeerID,
            nickname: "Alice",
            isVerified: true,
            signingPublicKey: Data(repeating: 0xAB, count: 32)
        )]
        recorder.verifyPacketSignatureResult = false
        recorder.signedName = nil
        let handler = makeHandler(recorder: recorder, now: now)
        let packet = makeMessagePacket(sender: remotePeerID, content: "spoofed", timestamp: timestamp(now))

        handler.handle(packet, from: remotePeerID)

        #expect(recorder.verifyPacketSignatureQueries == [remotePeerID])
        #expect(recorder.signedNameQueries == [remotePeerID])
        #expect(recorder.trackedPackets.isEmpty)
        #expect(recorder.deliveries.isEmpty)
    }

    @Test
    func signedSenderFallbackDeliversWithSignedName() {
        let now = Date(timeIntervalSince1970: 1_000)
        let recorder = Recorder()
        recorder.signedName = "SignedAlice"
        let handler = makeHandler(recorder: recorder, now: now)
        let packet = makeMessagePacket(sender: remotePeerID, content: "signed hello", timestamp: timestamp(now))

        handler.handle(packet, from: remotePeerID)

        #expect(recorder.signedNameQueries == [remotePeerID])
        #expect(recorder.trackedPackets.count == 1)
        #expect(recorder.deliveries.count == 1)
        #expect(recorder.deliveries.first?.nickname == "SignedAlice")
    }

    @Test
    func invalidUTF8PayloadIsTrackedForSyncButNotDelivered() {
        let now = Date(timeIntervalSince1970: 1_000)
        let recorder = Recorder()
        recorder.peers = [remotePeerID: makePeerInfo(remotePeerID, nickname: "Alice", isVerified: true)]
        recorder.signedName = "SignedAlice"
        let handler = makeHandler(recorder: recorder, now: now)
        let packet = makeMessagePacket(sender: remotePeerID, payload: Data([0xFF, 0xFE, 0xFD]), timestamp: timestamp(now))

        handler.handle(packet, from: remotePeerID)

        // Sync tracking happens before payload decoding, matching the original order.
        #expect(recorder.trackedPackets.count == 1)
        #expect(recorder.deliveries.isEmpty)
    }

    @Test
    func selfSyncReplayResolvesOriginalMessageID() {
        let now = Date(timeIntervalSince1970: 1_000)
        let recorder = Recorder()
        recorder.selfBroadcastMessageID = "original-id"
        let handler = makeHandler(recorder: recorder, now: now)
        // TTL 0 marks a sync replay of our own broadcast, not a self echo.
        let packet = makeMessagePacket(sender: localPeerID, content: "mine", timestamp: timestamp(now), ttl: 0)

        handler.handle(packet, from: localPeerID)

        #expect(recorder.selfBroadcastTakes.count == 1)
        #expect(recorder.deliveries.count == 1)
        #expect(recorder.deliveries.first?.peerID == localPeerID)
        #expect(recorder.deliveries.first?.nickname == recorder.localNickname)
        #expect(recorder.deliveries.first?.messageID == "original-id")
    }

    @Test
    func directedMessageIsDeliveredWithoutSyncTracking() {
        let now = Date(timeIntervalSince1970: 1_000)
        let recorder = Recorder()
        recorder.peers = [remotePeerID: makePeerInfo(remotePeerID, nickname: "Alice", isVerified: true)]
        recorder.signedName = "SignedAlice"
        let handler = makeHandler(recorder: recorder, now: now)
        let packet = makeMessagePacket(
            sender: remotePeerID,
            content: "direct",
            timestamp: timestamp(now),
            recipientID: Data(hexString: localPeerID.id)
        )

        handler.handle(packet, from: remotePeerID)

        #expect(recorder.trackedPackets.isEmpty)
        #expect(recorder.deliveries.count == 1)
        #expect(recorder.deliveries.first?.content == "direct")
    }

    private func expectNoSideEffects(_ recorder: Recorder) {
        #expect(recorder.signedNameQueries.isEmpty)
        #expect(recorder.trackedPackets.isEmpty)
        #expect(recorder.selfBroadcastTakes.isEmpty)
        #expect(recorder.deliveries.isEmpty)
    }

    private func makePeerInfo(
        _ peerID: PeerID,
        nickname: String,
        isVerified: Bool,
        isConnected: Bool = true,
        signingPublicKey: Data? = nil
    ) -> BLEPeerInfo {
        BLEPeerInfo(
            peerID: peerID,
            nickname: nickname,
            isConnected: isConnected,
            noisePublicKey: nil,
            signingPublicKey: signingPublicKey,
            isVerifiedNickname: isVerified,
            lastSeen: Date(timeIntervalSince1970: 999)
        )
    }

    private func makeMessagePacket(
        sender: PeerID,
        content: String? = nil,
        payload: Data? = nil,
        timestamp: UInt64,
        ttl: UInt8 = TransportConfig.messageTTLDefault,
        recipientID: Data? = nil
    ) -> BitchatPacket {
        BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: Data(hexString: sender.id) ?? Data(),
            recipientID: recipientID,
            timestamp: timestamp,
            payload: payload ?? Data((content ?? "").utf8),
            signature: nil,
            ttl: ttl
        )
    }

    private func timestamp(_ date: Date) -> UInt64 {
        UInt64(date.timeIntervalSince1970 * 1000)
    }
}
