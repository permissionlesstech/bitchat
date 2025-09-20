import Foundation
import Combine

/// Abstract transport interface used by ChatViewModel and services.
/// BLEService implements this protocol; a future Nostr transport can too.
struct TransportPeerSnapshot: Equatable, Hashable {
    let id: String
    let nickname: String
    let isConnected: Bool
    let noisePublicKey: Data?
    let lastSeen: Date
}

protocol Transport: AnyObject {
    // Peer events (preferred over publishers for UI)
    var peerEventsDelegate: TransportPeerEventsDelegate? { get set }
    // Event sink
    var delegate: BitchatDelegate? { get set }

    // Identity
    var myPeer: Peer { get }
    var myNickname: String { get }
    func setNickname(_ nickname: String)

    // Lifecycle
    func startServices()
    func stopServices()
    func emergencyDisconnectAll()

    // Connectivity and peers
    func isPeerConnected(_ peer: Peer) -> Bool
    func isPeerReachable(_ peer: Peer) -> Bool
    func peerNickname(peer: Peer) -> String?
    func getPeerNicknames() -> [Peer: String]

    // Protocol utilities
    func getFingerprint(for peer: Peer) -> String?
    func getNoiseSessionState(for peer: Peer) -> LazyHandshakeState
    func triggerHandshake(with peer: Peer)
    func getNoiseService() -> NoiseEncryptionService

    // Messaging
    func sendMessage(_ content: String, mentions: [String])
    func sendPrivateMessage(_ content: String, to peer: Peer, recipientNickname: String, messageID: String)
    func sendReadReceipt(_ receipt: ReadReceipt, to peer: Peer)
    func sendFavoriteNotification(to peer: Peer, isFavorite: Bool)
    func sendBroadcastAnnounce()
    func sendDeliveryAck(for messageID: String, to peer: Peer)

    // QR verification (optional for transports)
    func sendVerifyChallenge(to peer: Peer, noiseKeyHex: String, nonceA: Data)
    func sendVerifyResponse(to peer: Peer, noiseKeyHex: String, nonceA: Data)

    // Peer snapshots (for non-UI services)
    var peerSnapshotPublisher: AnyPublisher<[TransportPeerSnapshot], Never> { get }
    func currentPeerSnapshots() -> [TransportPeerSnapshot]
}

extension Transport {
    func sendVerifyChallenge(to peer: Peer, noiseKeyHex: String, nonceA: Data) {}
    func sendVerifyResponse(to peer: Peer, noiseKeyHex: String, nonceA: Data) {}
}

protocol TransportPeerEventsDelegate: AnyObject {
    @MainActor func didUpdatePeerSnapshots(_ peers: [TransportPeerSnapshot])
}

extension BLEService: Transport {}
