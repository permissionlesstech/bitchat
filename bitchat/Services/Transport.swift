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
    var myPeerID: String { get }
    var myNickname: String { get }
    func setNickname(_ nickname: String)

    // Lifecycle
    func startServices()
    func stopServices()
    func emergencyDisconnectAll()

    // Connectivity and peers
    func isPeerConnected(_ peerID: String) -> Bool
    func isPeerReachable(_ peerID: String) -> Bool
    func peerNickname(peerID: String) -> String?
    func getPeerNicknames() -> [String: String]

    // Protocol utilities
    func getFingerprint(for peerID: String) -> String?
    func getNoiseSessionState(for peerID: String) -> LazyHandshakeState
    func triggerHandshake(with peerID: String)
    func getNoiseService() -> NoiseEncryptionService

    // Messaging
    func sendMessage(_ content: String, mentions: [String])
    func sendPrivateMessage(_ content: String, to peerID: String, recipientNickname: String, messageID: String)
    func sendReadReceipt(_ receipt: ReadReceipt, to peerID: String)
    func sendFavoriteNotification(to peerID: String, isFavorite: Bool)
    func sendBroadcastAnnounce()
    func sendDeliveryAck(for messageID: String, to peerID: String)

    // QR verification (optional for transports)
    func sendVerifyChallenge(to peerID: String, noiseKeyHex: String, nonceA: Data)
    func sendVerifyResponse(to peerID: String, noiseKeyHex: String, nonceA: Data)

    // Peer snapshots (for non-UI services)
    var peerSnapshotPublisher: AnyPublisher<[TransportPeerSnapshot], Never> { get }
    func currentPeerSnapshots() -> [TransportPeerSnapshot]
}

extension Transport {
    func sendVerifyChallenge(to peerID: String, noiseKeyHex: String, nonceA: Data) {}
    func sendVerifyResponse(to peerID: String, noiseKeyHex: String, nonceA: Data) {}
}

protocol TransportPeerEventsDelegate: AnyObject {
    @MainActor func didUpdatePeerSnapshots(_ peers: [TransportPeerSnapshot])
}

extension BLEService: Transport {}
