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
    /// Whether the peer's announce was signature-verified (courier tier gate).
    let isVerified: Bool

    init(
        peerID: PeerID,
        nickname: String,
        isConnected: Bool,
        noisePublicKey: Data?,
        lastSeen: Date,
        isVerified: Bool = false
    ) {
        self.peerID = peerID
        self.nickname = nickname
        self.isConnected = isConnected
        self.noisePublicKey = noisePublicKey
        self.lastSeen = lastSeen
        self.isVerified = isVerified
    }
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
    /// Whether a send to this peer is likely to leave the device promptly.
    /// Distinct from reachability: Nostr claims any favorite with a known
    /// npub as reachable even with no relay connection, where a send only
    /// joins a queue waiting for internet that may never come.
    func canDeliverPromptly(to peerID: PeerID) -> Bool
    func peerNickname(peerID: PeerID) -> String?
    func getPeerNicknames() -> [PeerID: String]

    // Protocol utilities
    func getFingerprint(for peerID: PeerID) -> String?
    func getNoiseSessionState(for peerID: PeerID) -> LazyHandshakeState
    func triggerHandshake(with peerID: PeerID)

    // Noise identity/session access. Narrow, purpose-named wrappers so the
    // underlying NoiseEncryptionService (and its peer-binding/session
    // orchestration) is never exposed outside the transport.
    /// The remote static public key of the Noise session with `peerID`, if established.
    func noiseSessionPublicKeyData(for peerID: PeerID) -> Data?
    /// Fingerprint of our own Noise static identity key.
    func noiseIdentityFingerprint() -> String
    /// Our Noise static public key (Curve25519 key agreement).
    func noiseStaticPublicKeyData() -> Data
    /// Our Noise signing public key (Ed25519).
    func noiseSigningPublicKeyData() -> Data
    /// Signs `data` with our Noise signing key.
    func noiseSignData(_ data: Data) -> Data?
    /// Verifies an Ed25519 `signature` over `data` against `publicKey`.
    func noiseVerifySignature(_ signature: Data, for data: Data, publicKey: Data) -> Bool
    /// Registers session-lifecycle callbacks (peer authenticated / handshake required).
    func installNoiseSessionCallbacks(
        onPeerAuthenticated: @escaping (PeerID, String) -> Void,
        onHandshakeRequired: @escaping (PeerID) -> Void
    )

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

    // Courier store-and-forward (mesh transports only): seal a message to the
    // recipient's static key and hand it to connected couriers for physical
    // delivery while the recipient is offline. Returns false when the
    // transport cannot courier (no connected courier, or unsupported).
    func sendCourierMessage(_ content: String, messageID: String, recipientNoiseKey: Data, via couriers: [PeerID]) -> Bool

    // QR verification (optional for transports)
    func sendVerifyChallenge(to peerID: PeerID, noiseKeyHex: String, nonceA: Data)
    func sendVerifyResponse(to peerID: PeerID, noiseKeyHex: String, nonceA: Data)

    // Vouching / transitive verification (optional for transports)
    /// Capabilities the peer advertised in its last verified announce;
    /// empty for peers that predate the capabilities TLV.
    func peerCapabilities(_ peerID: PeerID) -> PeerCapabilities
    /// Sends an encoded vouch-attestation batch inside the Noise session.
    func sendVouchAttestations(_ payload: Data, to peerID: PeerID)
    /// Appends a peer-authenticated observer. Unlike
    /// `installNoiseSessionCallbacks` this never touches the (single-slot)
    /// handshake-required callback, so secondary features can observe
    /// session establishment without disturbing the primary registration.
    func addPeerAuthenticatedObserver(_ handler: @escaping (PeerID, String) -> Void)

    // Pending file management (BCH-01-002: files held in memory until user accepts)
    func acceptPendingFile(id: String) -> URL?
    func declinePendingFile(id: String)
}

extension Transport {
    // Reachability implies prompt delivery for transports that hand packets
    // straight to the radio; queue-backed transports override this.
    func canDeliverPromptly(to peerID: PeerID) -> Bool { isPeerReachable(peerID) }

    // Noise identity hooks default to inert for transports that do not carry
    // Noise sessions (e.g. NostrTransport).
    func noiseSessionPublicKeyData(for peerID: PeerID) -> Data? { nil }
    func noiseIdentityFingerprint() -> String { "" }
    func noiseStaticPublicKeyData() -> Data { Data() }
    func noiseSigningPublicKeyData() -> Data { Data() }
    func noiseSignData(_ data: Data) -> Data? { nil }
    func noiseVerifySignature(_ signature: Data, for data: Data, publicKey: Data) -> Bool { false }
    func installNoiseSessionCallbacks(
        onPeerAuthenticated: @escaping (PeerID, String) -> Void,
        onHandshakeRequired: @escaping (PeerID) -> Void
    ) {}

    func sendVerifyChallenge(to peerID: PeerID, noiseKeyHex: String, nonceA: Data) {}
    func sendVerifyResponse(to peerID: PeerID, noiseKeyHex: String, nonceA: Data) {}
    func peerCapabilities(_ peerID: PeerID) -> PeerCapabilities { [] }
    func sendVouchAttestations(_ payload: Data, to peerID: PeerID) {}
    func addPeerAuthenticatedObserver(_ handler: @escaping (PeerID, String) -> Void) {}
    func sendCourierMessage(_ content: String, messageID: String, recipientNoiseKey: Data, via couriers: [PeerID]) -> Bool { false }
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
