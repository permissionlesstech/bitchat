import BitFoundation
import Foundation
import Combine
import CoreBluetooth

/// Abstract transport interface used by ChatViewModel and services.
/// BLEService implements this protocol; a future Nostr transport can too.
struct TransportPeerSnapshot: Equatable, Hashable {
    let peerID: PeerID
    let nickname: String
    let isConnected: Bool
    let noisePublicKey: Data?
    let lastSeen: Date
}

enum TransportEvent: @unchecked Sendable {
    case messageReceived(BitchatMessage)
    case publicMessageReceived(peerID: PeerID, nickname: String, content: String, timestamp: Date, messageID: String?)
    case noisePayloadReceived(peerID: PeerID, type: NoisePayloadType, payload: Data, timestamp: Date)
    case peerConnected(PeerID)
    case peerDisconnected(PeerID)
    case peerListUpdated([PeerID])
    case peerSnapshotsUpdated([TransportPeerSnapshot])
    case messageDeliveryStatusUpdated(messageID: String, status: DeliveryStatus)
    case bluetoothStateUpdated(CBManagerState)
}

protocol TransportEventDelegate: AnyObject {
    @MainActor func didReceiveTransportEvent(_ event: TransportEvent)
}

protocol Transport: AnyObject {
    // Event sink
    var delegate: BitchatDelegate? { get set }
    // Typed event sink for transport-domain events. Prefer this over BitchatDelegate for new code.
    var eventDelegate: TransportEventDelegate? { get set }
    // Peer events (preferred over publishers for UI)
    var peerEventsDelegate: TransportPeerEventsDelegate? { get set }
    
    // Peer snapshots (for non-UI services)
    var peerSnapshotPublisher: AnyPublisher<[TransportPeerSnapshot], Never> { get }
    func currentPeerSnapshots() -> [TransportPeerSnapshot]

    // Identity
    var myPeerID: PeerID { get }
    var myNickname: String { get }
    func setNickname(_ nickname: String)

    // Lifecycle
    func startServices()
    func stopServices()
    func emergencyDisconnectAll()

    // Connectivity and peers
    func isPeerConnected(_ peerID: PeerID) -> Bool
    func isPeerReachable(_ peerID: PeerID) -> Bool
    func peerNickname(peerID: PeerID) -> String?
    func getPeerNicknames() -> [PeerID: String]

    // Protocol utilities
    func getFingerprint(for peerID: PeerID) -> String?
    func getNoiseSessionState(for peerID: PeerID) -> LazyHandshakeState
    func triggerHandshake(with peerID: PeerID)
    func getNoiseService() -> NoiseEncryptionService

    // Messaging
    func sendMessage(_ content: String, mentions: [String])
    func sendMessage(_ content: String, mentions: [String], messageID: String, timestamp: Date)
    func sendPrivateMessage(_ content: String, to peerID: PeerID, recipientNickname: String, messageID: String)
    func sendReadReceipt(_ receipt: ReadReceipt, to peerID: PeerID)
    func sendFavoriteNotification(to peerID: PeerID, isFavorite: Bool)
    func sendBroadcastAnnounce()
    func sendDeliveryAck(for messageID: String, to peerID: PeerID)
    func sendFileBroadcast(_ packet: BitchatFilePacket, transferId: String)
    func sendFilePrivate(_ packet: BitchatFilePacket, to peerID: PeerID, transferId: String)
    func cancelTransfer(_ transferId: String)

    // QR verification (optional for transports)
    func sendVerifyChallenge(to peerID: PeerID, noiseKeyHex: String, nonceA: Data)
    func sendVerifyResponse(to peerID: PeerID, noiseKeyHex: String, nonceA: Data)

    // Pending file management (BCH-01-002: files held in memory until user accepts)
    func acceptPendingFile(id: String) -> URL?
    func declinePendingFile(id: String)
}

extension Transport {
    func sendVerifyChallenge(to peerID: PeerID, noiseKeyHex: String, nonceA: Data) {}
    func sendVerifyResponse(to peerID: PeerID, noiseKeyHex: String, nonceA: Data) {}
    func sendFileBroadcast(_ packet: BitchatFilePacket, transferId: String) {}
    func sendFilePrivate(_ packet: BitchatFilePacket, to peerID: PeerID, transferId: String) {}
    func cancelTransfer(_ transferId: String) {}

    func sendMessage(_ content: String, mentions: [String], messageID: String, timestamp: Date) {
        sendMessage(content, mentions: mentions)
    }

    func acceptPendingFile(id: String) -> URL? { nil }
    func declinePendingFile(id: String) {}
}

protocol TransportPeerEventsDelegate: AnyObject {
    @MainActor func didUpdatePeerSnapshots(_ peers: [TransportPeerSnapshot])
}

extension BitchatDelegate {
    @MainActor
    func receiveTransportEvent(_ event: TransportEvent) {
        switch event {
        case .messageReceived(let message):
            didReceiveMessage(message)
        case let .publicMessageReceived(peerID, nickname, content, timestamp, messageID):
            didReceivePublicMessage(
                from: peerID,
                nickname: nickname,
                content: content,
                timestamp: timestamp,
                messageID: messageID
            )
        case let .noisePayloadReceived(peerID, type, payload, timestamp):
            didReceiveNoisePayload(from: peerID, type: type, payload: payload, timestamp: timestamp)
        case .peerConnected(let peerID):
            didConnectToPeer(peerID)
        case .peerDisconnected(let peerID):
            didDisconnectFromPeer(peerID)
        case .peerListUpdated(let peers):
            didUpdatePeerList(peers)
        case .peerSnapshotsUpdated:
            break
        case let .messageDeliveryStatusUpdated(messageID, status):
            didUpdateMessageDeliveryStatus(messageID, status: status)
        case .bluetoothStateUpdated(let state):
            didUpdateBluetoothState(state)
        }
    }
}

extension BLEService: Transport {}
