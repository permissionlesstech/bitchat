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

/// Outcome of a `/ping` probe over the mesh.
struct MeshPingResult: Equatable {
    /// Round-trip time in milliseconds.
    let rttMs: Int
    /// Total hops to the peer (1 = directly connected), derived from the
    /// pong's TTL decrements; nil when the reply carried inconsistent TTLs.
    let hops: Int?
}

/// Undirected mesh link between two peers, normalized so `(a, b)` and
/// `(b, a)` collapse to one edge.
struct MeshTopologyEdge: Hashable {
    let a: PeerID
    let b: PeerID

    init(_ first: PeerID, _ second: PeerID) {
        if first < second {
            a = first
            b = second
        } else {
            a = second
            b = first
        }
    }
}

/// Point-in-time view of the mesh graph learned from gossiped announces
/// (each announce carries up to 10 `directNeighbors`).
struct MeshTopologySnapshot: Equatable {
    let localPeerID: PeerID
    let nodes: [PeerID]
    let edges: [MeshTopologyEdge]
}

enum TransportEvent: @unchecked Sendable {
    case messageReceived(BitchatMessage)
    case publicMessageReceived(peerID: PeerID, nickname: String, content: String, timestamp: Date, messageID: String?)
    case noisePayloadReceived(peerID: PeerID, type: NoisePayloadType, payload: Data, timestamp: Date)
    /// Encrypted group broadcast (MessageType 0x25). Opaque here — the group
    /// coordinator decrypts and authenticates against the roster.
    case groupMessageReceived(payload: Data, timestamp: Date)
    /// Public live-voice burst packet (MessageType 0x29), already
    /// signature-verified against the claimed sender.
    case publicVoiceFrameReceived(peerID: PeerID, nickname: String, payload: Data, timestamp: Date)
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
    /// Whether a send to this peer can complete an end-to-end encrypted
    /// delivery right now (e.g. an established Noise session). Distinct from
    /// connectivity: a "connected" link binding alone is forgeable — link
    /// bindings heal on signature-verified "direct" announces, but directness
    /// rides on the unsigned TTL, so a replayed announce can wear an absent
    /// peer's ID on the replayer's link. Routers must not trust a connected
    /// link outright without this.
    func canDeliverSecurely(to peerID: PeerID) -> Bool
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

    // Live voice / push-to-talk (mesh transports only): one encoded
    // `VoiceBurstPacket`, fire-and-forget inside the Noise session. Frames are
    // only useful now — transports drop them (never queue) when no
    // established session exists.
    func sendVoiceFrame(_ burstContent: Data, to peerID: PeerID)
    // Public-mesh counterpart: signed ephemeral broadcast, never synced.
    func sendVoiceFrameBroadcast(_ burstContent: Data)

    // Courier store-and-forward (mesh transports only): seal a message to the
    // recipient's static key and hand it to connected couriers for physical
    // delivery while the recipient is offline. Returns false when the
    // transport cannot courier (no connected courier, or unsupported).
    func sendCourierMessage(_ content: String, messageID: String, recipientNoiseKey: Data, via couriers: [PeerID]) -> Bool

    // Private groups (mesh transports only): creator-signed state travels
    // 1:1 over Noise sessions; group messages flood like public broadcasts.
    func sendGroupInvite(_ statePayload: Data, to peerID: PeerID)
    func sendGroupKeyUpdate(_ statePayload: Data, to peerID: PeerID)
    func broadcastGroupMessage(_ envelope: Data)

    // Bulletin board (mesh transports only): broadcast a pre-signed board
    // payload (post or tombstone) so it spreads over relay and gossip sync.
    func sendBoardPayload(_ payload: Data)

    // Mesh diagnostics (optional for transports). Defaults are inert so
    // queue-backed transports (e.g. NostrTransport) stay untouched.
    /// Sends a directed ping probe; the completion fires exactly once on the
    /// main actor with the measured result, or nil on timeout/unsupported.
    func sendMeshPing(to peerID: PeerID, completion: @escaping @MainActor (MeshPingResult?) -> Void)
    /// Estimated intermediate hops toward `peerID` from gossiped topology
    /// ([] = direct link, nil = no known path).
    func computeMeshPath(to peerID: PeerID) -> [PeerID]?
    /// Current mesh graph for the topology map; nil when unsupported.
    func currentMeshTopology() -> MeshTopologySnapshot?

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

    // Store-and-forward archive (mesh transports only): the public messages
    // this device is carrying for gossip sync, decoded for display as
    // "heard here earlier" timeline echoes.
    func collectArchivedPublicMessages(completion: @escaping @MainActor ([ArchivedPublicMessage]) -> Void)
    /// Drops any carried public messages from a (newly blocked) sender so
    /// they can't resurface as archived echoes on a later launch.
    func purgeArchivedPublicMessages(from peerID: PeerID)
}

/// A carried public mesh message from the store-and-forward window, decoded
/// for display. `packetIdHex` is stable across launches so echo rows keep a
/// deterministic message ID.
struct ArchivedPublicMessage {
    let packetIdHex: String
    let senderPeerID: PeerID
    let senderNickname: String
    let content: String
    let timestamp: Date
}

extension BitchatMessage {
    /// Echo rows are minted locally with this prefix (packet-id derived, so
    /// stable across launches); the timeline dims them.
    static let archivedEchoIDPrefix = "echo-"

    var isArchivedEcho: Bool {
        id.hasPrefix(Self.archivedEchoIDPrefix)
    }
}

extension Transport {
    // Reachability implies prompt delivery for transports that hand packets
    // straight to the radio; queue-backed transports override this.
    func canDeliverPromptly(to peerID: PeerID) -> Bool { isPeerReachable(peerID) }

    // Transports without a forgeable link-binding layer (everything but the
    // BLE mesh) have no stronger delivery signal than prompt delivery.
    func canDeliverSecurely(to peerID: PeerID) -> Bool { canDeliverPromptly(to: peerID) }

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
    func sendGroupInvite(_ statePayload: Data, to peerID: PeerID) {}
    func sendGroupKeyUpdate(_ statePayload: Data, to peerID: PeerID) {}
    func broadcastGroupMessage(_ envelope: Data) {}
    func peerCapabilities(_ peerID: PeerID) -> PeerCapabilities { [] }
    func sendVouchAttestations(_ payload: Data, to peerID: PeerID) {}
    func addPeerAuthenticatedObserver(_ handler: @escaping (PeerID, String) -> Void) {}
    func sendCourierMessage(_ content: String, messageID: String, recipientNoiseKey: Data, via couriers: [PeerID]) -> Bool { false }
    func sendBoardPayload(_ payload: Data) {}
    func sendVoiceFrame(_ burstContent: Data, to peerID: PeerID) {}
    func sendVoiceFrameBroadcast(_ burstContent: Data) {}

    // Mesh diagnostics are mesh-transport-only; other transports report
    // "no reply"/"no path" rather than pretending to measure anything.
    func sendMeshPing(to peerID: PeerID, completion: @escaping @MainActor (MeshPingResult?) -> Void) {
        Task { @MainActor in completion(nil) }
    }
    func computeMeshPath(to peerID: PeerID) -> [PeerID]? { nil }
    func currentMeshTopology() -> MeshTopologySnapshot? { nil }
    func sendFileBroadcast(_ packet: BitchatFilePacket, transferId: String) {}
    func sendFilePrivate(_ packet: BitchatFilePacket, to peerID: PeerID, transferId: String) {}
    func cancelTransfer(_ transferId: String) {}

    func sendMessage(_ content: String, mentions: [String], messageID: String, timestamp: Date) {
        sendMessage(content, mentions: mentions)
    }

    func acceptPendingFile(id: String) -> URL? { nil }
    func declinePendingFile(id: String) {}

    func collectArchivedPublicMessages(completion: @escaping @MainActor ([ArchivedPublicMessage]) -> Void) {
        Task { @MainActor in completion([]) }
    }

    func purgeArchivedPublicMessages(from peerID: PeerID) {}
}

protocol TransportPeerEventsDelegate: AnyObject {
    @MainActor func didUpdatePeerSnapshots(_: [TransportPeerSnapshot])
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
        case let .groupMessageReceived(payload, timestamp):
            didReceiveGroupMessage(payload: payload, timestamp: timestamp)
        case let .publicVoiceFrameReceived(peerID, nickname, payload, timestamp):
            didReceivePublicVoiceFrame(from: peerID, nickname: nickname, payload: payload, timestamp: timestamp)
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
