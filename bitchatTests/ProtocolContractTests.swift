import Testing
import Foundation
import Combine
import CoreBluetooth
@testable import bitchat

private final class DefaultDelegateProbe: BitchatDelegate {
    func didReceiveMessage(_ message: BitchatMessage) {}
    func didConnectToPeer(_ peerID: PeerID) {}
    func didDisconnectFromPeer(_ peerID: PeerID) {}
    func didUpdatePeerList(_ peers: [PeerID]) {}
    func didUpdateBluetoothState(_ state: CBManagerState) {}
}

private final class DefaultTransportProbe: Transport {
    weak var delegate: BitchatDelegate?
    weak var peerEventsDelegate: TransportPeerEventsDelegate?

    let subject = CurrentValueSubject<[TransportPeerSnapshot], Never>([])
    let myPeerID = PeerID(str: "0011223344556677")
    var myNickname = "Tester"
    private let keychain = MockKeychain()
    private(set) var sentMessages: [(content: String, mentions: [String])] = []

    var peerSnapshotPublisher: AnyPublisher<[TransportPeerSnapshot], Never> {
        subject.eraseToAnyPublisher()
    }

    func currentPeerSnapshots() -> [TransportPeerSnapshot] { subject.value }
    func setNickname(_ nickname: String) { myNickname = nickname }
    func startServices() {}
    func stopServices() {}
    func emergencyDisconnectAll() {}
    func isPeerConnected(_ peerID: PeerID) -> Bool { false }
    func isPeerReachable(_ peerID: PeerID) -> Bool { false }
    func peerNickname(peerID: PeerID) -> String? { nil }
    func getPeerNicknames() -> [PeerID: String] { [:] }
    func getFingerprint(for peerID: PeerID) -> String? { nil }
    func getNoiseSessionState(for peerID: PeerID) -> LazyHandshakeState { .none }
    func triggerHandshake(with peerID: PeerID) {}
    func getNoiseService() -> NoiseEncryptionService { NoiseEncryptionService(keychain: keychain) }
    func sendMessage(_ content: String, mentions: [String]) { sentMessages.append((content, mentions)) }
    func sendPrivateMessage(_ content: String, to peerID: PeerID, recipientNickname: String, messageID: String) {}
    func sendReadReceipt(_ receipt: ReadReceipt, to peerID: PeerID) {}
    func sendFavoriteNotification(to peerID: PeerID, isFavorite: Bool) {}
    func sendBroadcastAnnounce() {}
    func sendDeliveryAck(for messageID: String, to peerID: PeerID) {}
}

struct ProtocolContractTests {
    @Test
    func commandInfo_exposesAliasesPlaceholdersAndGeoVariants() {
        #expect(CommandInfo.message.id == "dm")
        #expect(CommandInfo.message.alias == "/dm")
        #expect(CommandInfo.message.placeholder != nil)
        #expect(CommandInfo.clear.placeholder == nil)
        #expect(CommandInfo.favorite.description.isEmpty == false)
        #expect(CommandInfo.all(isGeoPublic: false, isGeoDM: false).contains(.favorite) == false)
        #expect(CommandInfo.all(isGeoPublic: true, isGeoDM: false).contains(.favorite))
        #expect(CommandInfo.all(isGeoPublic: false, isGeoDM: true).contains(.unfavorite))
    }

    @Test
    func protocolEnums_andDelegateDefaults_haveStableContracts() {
        let delegate = DefaultDelegateProbe()
        let peerID = PeerID(str: "8899aabbccddeeff")

        #expect(MessageType.requestSync.description == "requestSync")
        #expect(NoisePayloadType.verifyResponse.description == "verifyResponse")
        #expect(DeliveryStatus.sending.displayText == "Sending...")
        #expect(DeliveryStatus.sent.displayText == "Sent")
        #expect(DeliveryStatus.delivered(to: "Alice", at: Date()).displayText == "Delivered to Alice")
        #expect(DeliveryStatus.read(by: "Bob", at: Date()).displayText == "Read by Bob")
        #expect(DeliveryStatus.failed(reason: "oops").displayText == "Failed: oops")
        #expect(DeliveryStatus.partiallyDelivered(reached: 1, total: 3).displayText == "Delivered to 1/3")
        #expect(delegate.isFavorite(fingerprint: "fp") == false)

        delegate.didUpdateMessageDeliveryStatus("msg-1", status: .sent)
        delegate.didReceiveNoisePayload(from: peerID, type: .privateMessage, payload: Data(), timestamp: Date())
        delegate.didReceivePublicMessage(from: peerID, nickname: "Alice", content: "hi", timestamp: Date(), messageID: "msg-1")
    }

    @Test
    func transportDefaults_forwardOrNoOp() {
        let probe = DefaultTransportProbe()
        let peerID = PeerID(str: "0123456789abcdef")
        let filePacket = BitchatFilePacket(
            fileName: "voice.m4a",
            fileSize: 4,
            mimeType: "audio/mp4",
            content: Data([1, 2, 3, 4])
        )

        probe.sendMessage("hello", mentions: ["@alice"], messageID: "msg-1", timestamp: Date())
        probe.sendVerifyChallenge(to: peerID, noiseKeyHex: "abcd", nonceA: Data([0x01]))
        probe.sendVerifyResponse(to: peerID, noiseKeyHex: "abcd", nonceA: Data([0x02]))
        probe.sendFileBroadcast(filePacket, transferId: "tx-1")
        probe.sendFilePrivate(filePacket, to: peerID, transferId: "tx-2")
        probe.cancelTransfer("tx-3")
        probe.declinePendingFile(id: "pending")

        #expect(probe.sentMessages.count == 1)
        #expect(probe.sentMessages.first?.content == "hello")
        #expect(probe.acceptPendingFile(id: "pending") == nil)
    }

    @Test
    func previewMessage_exposesStableSampleShape() {
        let preview = BitchatMessage.preview

        #expect(preview.sender == "John Doe")
        #expect(preview.content == "Hello")
        #expect(preview.deliveryStatus == .sent)
        #expect(preview.isPrivate == false)
    }
}
