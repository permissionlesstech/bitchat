import BitFoundation
import Foundation
import Testing
@testable import bitchat

struct BLEFileTransferHandlerTests {
    private final class Recorder {
        var localNickname = "Me"
        var peers: [PeerID: BLEPeerInfo] = [:]
        var signedName: String?
        var saveResult: URL? = URL(fileURLWithPath: "/tmp/files/incoming/sample.pdf")

        var signedNameQueries: [PeerID] = []
        var trackedPackets: [BitchatPacket] = []
        var quotaReservations: [Int] = []
        var saveCalls: [(data: Data, preferredName: String?, subdirectory: String, fallbackExtension: String?, defaultPrefix: String)] = []
        var lastSeenUpdates: [PeerID] = []
        var deliveredMessages: [BitchatMessage] = []
    }

    private let localPeerID = PeerID(str: "0102030405060708")
    private let remotePeerID = PeerID(str: "1122334455667788")

    private func makeHandler(recorder: Recorder) -> BLEFileTransferHandler {
        let environment = BLEFileTransferHandlerEnvironment(
            localPeerID: { [localPeerID] in localPeerID },
            localNickname: { recorder.localNickname },
            peersSnapshot: { recorder.peers },
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
        recorder.peers = [remotePeerID: makePeerInfo(remotePeerID, nickname: "Alice", isVerified: true)]
        let handler = makeHandler(recorder: recorder)
        let content = Data("%PDF-1.7".utf8)
        let packet = try makeFileTransferPacket(sender: remotePeerID, mimeType: "application/pdf", content: content)

        handler.handle(packet, from: remotePeerID)

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

        handler.handle(packet, from: localPeerID)

        expectNoSideEffects(recorder)
    }

    @Test
    func unknownPeerWithoutValidSignatureIsDropped() throws {
        let recorder = Recorder()
        let handler = makeHandler(recorder: recorder)
        let packet = try makeFileTransferPacket(sender: remotePeerID, mimeType: "application/pdf", content: Data("%PDF-1.7".utf8))

        handler.handle(packet, from: remotePeerID)

        #expect(recorder.signedNameQueries == [remotePeerID])
        #expect(recorder.trackedPackets.isEmpty)
        #expect(recorder.deliveredMessages.isEmpty)
    }

    @Test
    func connectedUnverifiedPeerIsAccepted() throws {
        let recorder = Recorder()
        recorder.peers = [remotePeerID: makePeerInfo(remotePeerID, nickname: "Bob", isVerified: false, isConnected: true)]
        let handler = makeHandler(recorder: recorder)
        let packet = try makeFileTransferPacket(sender: remotePeerID, mimeType: "application/pdf", content: Data("%PDF-1.7".utf8))

        handler.handle(packet, from: remotePeerID)

        // Unlike public messages, file transfers accept connected-but-unverified peers.
        #expect(recorder.signedNameQueries.isEmpty)
        #expect(recorder.deliveredMessages.count == 1)
        #expect(recorder.deliveredMessages.first?.sender == "Bob")
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

        handler.handle(packet, from: remotePeerID)

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

        handler.handle(packet, from: remotePeerID)

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
        recorder.peers = [remotePeerID: makePeerInfo(remotePeerID, nickname: "Alice", isVerified: true)]
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

        handler.handle(packet, from: remotePeerID)

        // Sync tracking happens before payload validation, matching the original order.
        #expect(recorder.trackedPackets.count == 1)
        #expect(recorder.quotaReservations.isEmpty)
        #expect(recorder.saveCalls.isEmpty)
        #expect(recorder.deliveredMessages.isEmpty)
    }

    @Test
    func unsupportedMimeIsDroppedBeforeQuotaAndSave() throws {
        let recorder = Recorder()
        recorder.peers = [remotePeerID: makePeerInfo(remotePeerID, nickname: "Alice", isVerified: true)]
        let handler = makeHandler(recorder: recorder)
        let packet = try makeFileTransferPacket(sender: remotePeerID, mimeType: nil, content: Data([0x4D, 0x5A, 0x00, 0x00]))

        handler.handle(packet, from: remotePeerID)

        #expect(recorder.trackedPackets.count == 1)
        #expect(recorder.quotaReservations.isEmpty)
        #expect(recorder.saveCalls.isEmpty)
        #expect(recorder.deliveredMessages.isEmpty)
    }

    @Test
    func saveFailureSkipsDelivery() throws {
        let recorder = Recorder()
        recorder.peers = [remotePeerID: makePeerInfo(remotePeerID, nickname: "Alice", isVerified: true)]
        recorder.saveResult = nil
        let handler = makeHandler(recorder: recorder)
        let packet = try makeFileTransferPacket(sender: remotePeerID, mimeType: "application/pdf", content: Data("%PDF-1.7".utf8))

        handler.handle(packet, from: remotePeerID)

        #expect(recorder.quotaReservations.count == 1)
        #expect(recorder.saveCalls.count == 1)
        #expect(recorder.lastSeenUpdates.isEmpty)
        #expect(recorder.deliveredMessages.isEmpty)
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
        isConnected: Bool = true
    ) -> BLEPeerInfo {
        BLEPeerInfo(
            peerID: peerID,
            nickname: nickname,
            isConnected: isConnected,
            noisePublicKey: nil,
            signingPublicKey: nil,
            isVerifiedNickname: isVerified,
            lastSeen: Date(timeIntervalSince1970: 999)
        )
    }

    private func makeFileTransferPacket(
        sender: PeerID,
        mimeType: String?,
        content: Data,
        ttl: UInt8 = TransportConfig.messageTTLDefault,
        recipientID: Data? = nil
    ) throws -> BitchatPacket {
        let filePacket = BitchatFilePacket(
            fileName: "sample",
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
