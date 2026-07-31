import BitFoundation
import Foundation
import Testing
@testable import bitchat

struct BLENoisePacketHandlerTests {
    private struct TestError: Error {}

    private final class Recorder {
        var handshakeResult: Result<Data?, Error> = .success(nil)
        var hasSession = false
        var decryptResult: Result<Data, Error> = .success(Data())

        var processedHandshakes: [(peerID: PeerID, message: Data)] = []
        var hasSessionQueries: [PeerID] = []
        var initiatedHandshakes: [PeerID] = []
        var broadcastPackets: [BitchatPacket] = []
        var lastSeenUpdates: [PeerID] = []
        var decryptCalls: [(payload: Data, peerID: PeerID)] = []
        var clearedSessions: [PeerID] = []
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
        let environment = BLENoisePacketHandlerEnvironment(
            localPeerID: { [localPeerID] in localPeerID },
            localPeerIDData: { [localPeerIDData] in localPeerIDData },
            messageTTL: TransportConfig.messageTTLDefault,
            now: { now },
            processHandshakeMessage: { peerID, message in
                recorder.processedHandshakes.append((peerID, message))
                return try recorder.handshakeResult.get()
            },
            hasNoiseSession: { peerID in
                recorder.hasSessionQueries.append(peerID)
                return recorder.hasSession
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
                return try recorder.decryptResult.get()
            },
            clearSession: { peerID in
                recorder.clearedSessions.append(peerID)
                recorder.events.append("clearSession")
            },
            deliverNoisePayload: { peerID, type, payload, timestamp in
                recorder.deliveries.append((peerID, type, payload, timestamp))
            }
        )
        return BLENoisePacketHandler(environment: environment)
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
        timestamp: UInt64 = 900_000
    ) -> BitchatPacket {
        BitchatPacket(
            type: MessageType.noiseEncrypted.rawValue,
            senderID: Data(hexString: remotePeerID.id) ?? Data(),
            recipientID: recipientID,
            timestamp: timestamp,
            payload: Data([0xC0, 0xFF, 0xEE]),
            signature: nil,
            ttl: TransportConfig.messageTTLDefault
        )
    }
}
