import BitFoundation
import Foundation
import Testing
@testable import bitchat

struct BLEFileTransferHandlerTests {
    private final class Recorder {
        var localNickname = "Me"
        var peers: [PeerID: BLEPeerInfo] = [:]
        var signedName: String?
        var signatureVerifies = false
        var saveResult: URL? = URL(fileURLWithPath: "/tmp/files/incoming/sample.pdf")

        var signatureVerifyCount = 0
        var signedNameQueries: [PeerID] = []
        var trackedPackets: [BitchatPacket] = []
        var quotaReservations: [Int] = []
        var saveCalls: [(data: Data, preferredName: String?, subdirectory: String, fallbackExtension: String?, defaultPrefix: String)] = []
        var lastSeenUpdates: [PeerID] = []
        var deliveredMessages: [BitchatMessage] = []
    }

    private let localPeerID = PeerID(str: "0102030405060708")
    private let remotePeerID = PeerID(str: "1122334455667788")
    private let sampleSigningKey = Data(repeating: 0xAB, count: 32)

    private func makeHandler(recorder: Recorder) -> BLEFileTransferHandler {
        let environment = BLEFileTransferHandlerEnvironment(
            localPeerID: { [localPeerID] in localPeerID },
            localNickname: { recorder.localNickname },
            peersSnapshot: { recorder.peers },
            verifyPacketSignature: { _, _ in
                recorder.signatureVerifyCount += 1
                return recorder.signatureVerifies
            },
            signedSenderDisplayName: { _, peerID in
                recorder.signedNameQueries.append(peerID)
                return recorder.signedName
            },
            trackPacketSeen: { packet in
                recorder.trackedPackets.append(packet)
            },
            enforceStorageQuota: { reservingBytes in
                recorder.quotaReservations.append(reservingBytes)
            },
            saveIncomingFile: { data, preferredName, subdirectory, fallbackExtension, defaultPrefix in
                recorder.saveCalls.append((data, preferredName, subdirectory, fallbackExtension, defaultPrefix))
                return recorder.saveResult
            },
            updatePeerLastSeen: { peerID in
                recorder.lastSeenUpdates.append(peerID)
            },
            deliverMessage: { message in
                recorder.deliveredMessages.append(message)
            }
        )
        return BLEFileTransferHandler(environment: environment)
    }

    @Test
    func broadcastFileFromVerifiedPeerIsSavedAndDelivered() throws {
        let recorder = Recorder()
        recorder.peers = [remotePeerID: makePeerInfo(remotePeerID, nickname: "Alice", isVerified: true, signingPublicKey: sampleSigningKey)]
        recorder.signatureVerifies = true
        let handler = makeHandler(recorder: recorder)
        let content = Data("%PDF-1.7".utf8)
        let packet = try makeFileTransferPacket(sender: remotePeerID, mimeType: "application/pdf", content: content)

        #expect(handler.handle(packet, from: remotePeerID))

        #expect(recorder.signatureVerifyCount == 1)
        #expect(recorder.signedNameQueries.isEmpty)
        #expect(recorder.trackedPackets.count == 1)
        #expect(recorder.quotaReservations == [content.count])
        #expect(recorder.saveCalls.count == 1)
        #expect(recorder.saveCalls.first?.data == content)
        #expect(recorder.saveCalls.first?.preferredName == "sample")
        #expect(recorder.saveCalls.first?.subdirectory == "files/incoming")
        #expect(recorder.saveCalls.first?.fallbackExtension == "pdf")
        #expect(recorder.saveCalls.first?.defaultPrefix == "file")
        #expect(recorder.lastSeenUpdates.isEmpty)
        #expect(recorder.deliveredMessages.count == 1)
        let message = recorder.deliveredMessages.first
        #expect(message?.sender == "Alice")
        #expect(message?.content == "[file] sample.pdf")
        #expect(message?.isPrivate == false)
        #expect(message?.senderPeerID == remotePeerID)
        #expect(message?.timestamp == Date(timeIntervalSince1970: 900))
        #expect(message?.deliveryStatus == nil)
    }

    @Test
    func selfEchoIsDropped() throws {
        let recorder = Recorder()
        let handler = makeHandler(recorder: recorder)
        let packet = try makeFileTransferPacket(sender: localPeerID, mimeType: "application/pdf", content: Data("%PDF-1.7".utf8), ttl: 3)

        // The relay pipeline already suppresses self-originated packets, so the
        // handler reports "relayable" rather than treating the echo as forged.
        #expect(handler.handle(packet, from: localPeerID))

        expectNoSideEffects(recorder)
    }

    @Test
    func unknownPeerWithoutValidSignatureIsDropped() throws {
        let recorder = Recorder()
        let handler = makeHandler(recorder: recorder)
        let packet = try makeFileTransferPacket(sender: remotePeerID, mimeType: "application/pdf", content: Data("%PDF-1.7".utf8))

        #expect(!handler.handle(packet, from: remotePeerID))

        #expect(recorder.signedNameQueries == [remotePeerID])
        #expect(recorder.trackedPackets.isEmpty)
        #expect(recorder.deliveredMessages.isEmpty)
    }

    @Test
    func broadcastFromConnectedUnverifiedPeerWithoutSignatureIsDropped() throws {
        let recorder = Recorder()
        recorder.peers = [remotePeerID: makePeerInfo(remotePeerID, nickname: "Bob", isVerified: false, isConnected: true)]
        let handler = makeHandler(recorder: recorder)
        let packet = try makeFileTransferPacket(sender: remotePeerID, mimeType: "application/pdf", content: Data("%PDF-1.7".utf8))

        // Failed sender authentication must also stop the packet from being
        // relayed to downstream nodes.
        #expect(!handler.handle(packet, from: remotePeerID))

        // Broadcast files carry an attacker-controllable senderID, so — like
        // public messages — a connected-but-unverified peer must present a valid
        // packet signature. No signing key + no signed identity means dropped.
        #expect(recorder.signedNameQueries == [remotePeerID])
        #expect(recorder.trackedPackets.isEmpty)
        #expect(recorder.deliveredMessages.isEmpty)
    }

    @Test
    func broadcastFromConnectedUnverifiedPeerWithSignedIdentityIsAccepted() throws {
        let recorder = Recorder()
        // Connected but nickname not yet verified and no registry signing key —
        // the persisted-identity signature lookup still authenticates the
        // sender, so the transfer is accepted under that verified name.
        recorder.peers = [remotePeerID: makePeerInfo(remotePeerID, nickname: "Bob", isVerified: false, isConnected: true)]
        recorder.signedName = "Bob"
        let handler = makeHandler(recorder: recorder)
        let packet = try makeFileTransferPacket(sender: remotePeerID, mimeType: "application/pdf", content: Data("%PDF-1.7".utf8))

        #expect(handler.handle(packet, from: remotePeerID))

        #expect(recorder.signedNameQueries == [remotePeerID])
        #expect(recorder.deliveredMessages.count == 1)
        #expect(recorder.deliveredMessages.first?.sender == "Bob")
    }

    @Test
    func selfBroadcastReplayIsDeliveredWithoutSignatureCheck() throws {
        // Our own broadcast file replayed via gossip sync arrives with ttl==0
        // (so it is not treated as a self-echo) and cannot be verified against
        // the peer registry — it must still be accepted, matching
        // BLEPublicMessageHandler's self exemption.
        let recorder = Recorder()
        let handler = makeHandler(recorder: recorder)
        let packet = try makeFileTransferPacket(
            sender: localPeerID,
            mimeType: "application/pdf",
            content: Data("%PDF-1.7".utf8),
            ttl: 0
        )

        #expect(handler.handle(packet, from: localPeerID))

        #expect(recorder.signatureVerifyCount == 0)
        #expect(recorder.signedNameQueries.isEmpty)
        #expect(recorder.deliveredMessages.count == 1)
        #expect(recorder.deliveredMessages.first?.sender == "Me")
    }

    @Test
    func broadcastFromPeerNotInRegistryAcceptedViaSignedIdentity() throws {
        let recorder = Recorder()
        recorder.signedName = "Carol"
        let handler = makeHandler(recorder: recorder)
        let packet = try makeFileTransferPacket(sender: remotePeerID, mimeType: "application/pdf", content: Data("%PDF-1.7".utf8))

        #expect(handler.handle(packet, from: remotePeerID))

        // Peer absent from the registry: fall back to the persisted-identity
        // signature lookup (mirrors BLEPublicMessageHandler).
        #expect(recorder.signedNameQueries == [remotePeerID])
        #expect(recorder.deliveredMessages.count == 1)
        #expect(recorder.deliveredMessages.first?.sender == "Carol")
    }

    @Test
    func spoofedBroadcastVoiceNoteWithoutSignatureIsDropped() throws {
        // Regression for the PR #1406 finding: an in-range peer that observed a
        // public voice burst tries to overwrite the live bubble by broadcasting
        // a `voice_<burstID>.m4a` note under the talker's senderID. Without a
        // valid signature the note never reaches the coordinator's absorption.
        let recorder = Recorder()
        recorder.peers = [remotePeerID: makePeerInfo(remotePeerID, nickname: "Mallory", isVerified: false, isConnected: true)]
        let handler = makeHandler(recorder: recorder)
        let m4a = Data([0x00, 0x00, 0x00, 0x18]) + Data("ftypM4A ".utf8)
        let packet = try makeFileTransferPacket(
            sender: remotePeerID,
            mimeType: "audio/mp4",
            content: m4a,
            fileName: "voice_1122334455667788"
        )

        // The spoofed note must be dropped locally AND not relayed onward.
        #expect(!handler.handle(packet, from: remotePeerID))

        #expect(recorder.deliveredMessages.isEmpty)
    }

    @Test
    func privateFileFromConnectedUnverifiedPeerIsAccepted() throws {
        let recorder = Recorder()
        recorder.peers = [remotePeerID: makePeerInfo(remotePeerID, nickname: "Bob", isVerified: false, isConnected: true)]
        let handler = makeHandler(recorder: recorder)
        let packet = try makeFileTransferPacket(
            sender: remotePeerID,
            mimeType: "application/pdf",
            content: Data("%PDF-1.7".utf8),
            recipientID: Data(hexString: localPeerID.id)
        )

        #expect(handler.handle(packet, from: remotePeerID))

        // Directed transfers keep the lenient connected-peer path (no broadcast
        // exposure); no signature check is required.
        #expect(recorder.signatureVerifyCount == 0)
        #expect(recorder.signedNameQueries.isEmpty)
        #expect(recorder.deliveredMessages.count == 1)
        #expect(recorder.deliveredMessages.first?.isPrivate == true)
    }

    @Test
    func fileDirectedToAnotherPeerIsIgnored() throws {
        let recorder = Recorder()
        recorder.peers = [remotePeerID: makePeerInfo(remotePeerID, nickname: "Alice", isVerified: true)]
        let handler = makeHandler(recorder: recorder)
        let packet = try makeFileTransferPacket(
            sender: remotePeerID,
            mimeType: "application/pdf",
            content: Data("%PDF-1.7".utf8),
            recipientID: Data(hexString: "AABBCCDDEEFF0011")
        )

        // Not for us, but it must keep relaying toward the real recipient.
        #expect(handler.handle(packet, from: remotePeerID))

        #expect(recorder.trackedPackets.isEmpty)
        #expect(recorder.quotaReservations.isEmpty)
        #expect(recorder.saveCalls.isEmpty)
        #expect(recorder.deliveredMessages.isEmpty)
    }

    @Test
    func privateFileUpdatesLastSeenAndDeliversPrivateMessage() throws {
        let recorder = Recorder()
        recorder.peers = [remotePeerID: makePeerInfo(remotePeerID, nickname: "Alice", isVerified: true)]
        let handler = makeHandler(recorder: recorder)
        let packet = try makeFileTransferPacket(
            sender: remotePeerID,
            mimeType: "application/pdf",
            content: Data("%PDF-1.7".utf8),
            recipientID: Data(hexString: localPeerID.id)
        )

        #expect(handler.handle(packet, from: remotePeerID))

        // Directed transfers are not tracked for gossip sync.
        #expect(recorder.trackedPackets.isEmpty)
        #expect(recorder.lastSeenUpdates == [remotePeerID])
        #expect(recorder.deliveredMessages.count == 1)
        #expect(recorder.deliveredMessages.first?.isPrivate == true)
        // Must be explicit: BitchatMessage defaults private messages to
        // .sending, which the media views render as an in-flight send
        // (empty reveal mask, disabled reveal tap).
        #expect(recorder.deliveredMessages.first?.deliveryStatus == .delivered(to: "Me", at: Date(timeIntervalSince1970: 900)))
    }

    @Test
    func malformedPayloadIsTrackedForSyncButDropped() {
        let recorder = Recorder()
        recorder.peers = [remotePeerID: makePeerInfo(remotePeerID, nickname: "Alice", isVerified: true, signingPublicKey: sampleSigningKey)]
        recorder.signatureVerifies = true
        let handler = makeHandler(recorder: recorder)
        let packet = BitchatPacket(
            type: MessageType.fileTransfer.rawValue,
            senderID: Data(hexString: remotePeerID.id) ?? Data(),
            recipientID: nil,
            timestamp: 900_000,
            payload: Data([0x01, 0x02, 0x03]),
            signature: nil,
            ttl: TransportConfig.messageTTLDefault
        )

        // Local decode failures are not proof of forgery; the packet stays relayable.
        #expect(handler.handle(packet, from: remotePeerID))

        // Sync tracking happens before payload validation, matching the original order.
        #expect(recorder.trackedPackets.count == 1)
        #expect(recorder.quotaReservations.isEmpty)
        #expect(recorder.saveCalls.isEmpty)
        #expect(recorder.deliveredMessages.isEmpty)
    }

    @Test
    func unsupportedMimeIsDroppedBeforeQuotaAndSave() throws {
        let recorder = Recorder()
        recorder.peers = [remotePeerID: makePeerInfo(remotePeerID, nickname: "Alice", isVerified: true, signingPublicKey: sampleSigningKey)]
        recorder.signatureVerifies = true
        let handler = makeHandler(recorder: recorder)
        let packet = try makeFileTransferPacket(sender: remotePeerID, mimeType: nil, content: Data([0x4D, 0x5A, 0x00, 0x00]))

        #expect(handler.handle(packet, from: remotePeerID))

        #expect(recorder.trackedPackets.count == 1)
        #expect(recorder.quotaReservations.isEmpty)
        #expect(recorder.saveCalls.isEmpty)
        #expect(recorder.deliveredMessages.isEmpty)
    }

    @Test
    func saveFailureSkipsDelivery() throws {
        let recorder = Recorder()
        recorder.peers = [remotePeerID: makePeerInfo(remotePeerID, nickname: "Alice", isVerified: true, signingPublicKey: sampleSigningKey)]
        recorder.signatureVerifies = true
        recorder.saveResult = nil
        let handler = makeHandler(recorder: recorder)
        let packet = try makeFileTransferPacket(sender: remotePeerID, mimeType: "application/pdf", content: Data("%PDF-1.7".utf8))

        // A local save failure must not stop the mesh relay.
        #expect(handler.handle(packet, from: remotePeerID))

        #expect(recorder.quotaReservations.count == 1)
        #expect(recorder.saveCalls.count == 1)
        #expect(recorder.lastSeenUpdates.isEmpty)
        #expect(recorder.deliveredMessages.isEmpty)
    }

    @Test
    func quotaEvictionForFinalizedArrivalSkipsInFlightLiveCaptures() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("quota-live-capture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = BLEIncomingFileStore(baseDirectory: base)
        let incoming = try store.incomingDirectory(subdirectory: "voicenotes/incoming")

        // The in-flight partial is the LRU-oldest eviction candidate; without
        // the voice_live_ pattern guard it would be deleted first, unlinking
        // the inode under the coordinator's open FileHandle.
        let inFlight = incoming.appendingPathComponent("voice_live_00112233445566ff_1122334455667788_dm.aac")
        let evictable = incoming.appendingPathComponent("voice_old.m4a")
        try Data(count: 51 * 1024 * 1024).write(to: inFlight)
        try Data(count: 51 * 1024 * 1024).write(to: evictable)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: inFlight.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: evictable.path)

        // 102 MB used against the 100 MB quota forces one eviction. This is
        // the finalized-file arrival path (BLEFileTransferHandler via
        // BLEService), which knows nothing about in-flight captures — the
        // store itself must protect them.
        store.enforceQuota(reservingBytes: 0)

        #expect(FileManager.default.fileExists(atPath: inFlight.path))
        #expect(!FileManager.default.fileExists(atPath: evictable.path))
    }

    private func expectNoSideEffects(_ recorder: Recorder) {
        #expect(recorder.signedNameQueries.isEmpty)
        #expect(recorder.trackedPackets.isEmpty)
        #expect(recorder.quotaReservations.isEmpty)
        #expect(recorder.saveCalls.isEmpty)
        #expect(recorder.lastSeenUpdates.isEmpty)
        #expect(recorder.deliveredMessages.isEmpty)
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

    private func makeFileTransferPacket(
        sender: PeerID,
        mimeType: String?,
        content: Data,
        ttl: UInt8 = TransportConfig.messageTTLDefault,
        recipientID: Data? = nil,
        fileName: String = "sample"
    ) throws -> BitchatPacket {
        let filePacket = BitchatFilePacket(
            fileName: fileName,
            fileSize: UInt64(content.count),
            mimeType: mimeType,
            content: content
        )
        let payload = try #require(filePacket.encode())
        return BitchatPacket(
            type: MessageType.fileTransfer.rawValue,
            senderID: Data(hexString: sender.id) ?? Data(),
            recipientID: recipientID,
            timestamp: 900_000,
            payload: payload,
            signature: nil,
            ttl: ttl
        )
    }
}
