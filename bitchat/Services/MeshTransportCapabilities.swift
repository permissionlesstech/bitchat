import BitFoundation
import CoreBluetooth
import Foundation

/// Optional transport capabilities, discovered with `as?` instead of casting
/// to a concrete transport class. `Transport` stays the contract every
/// transport genuinely implements; a capability protocol here is the
/// contract for one mesh-only feature surface, so app wiring depends on the
/// feature it needs rather than on `BLEService` itself.

/// Radio-state reporting for transports backed by a local radio.
protocol BluetoothStateReporting: AnyObject {
    func getCurrentBluetoothState() -> CBManagerState
}

/// Panic-mode lifecycle for transports that own durable identity state.
/// A transport implementing this owns its own restart sequencing:
/// `completePanicReset` decides whether services come back, so generic
/// `startServices()` calls after a panic belong only to transports that
/// don't implement it.
protocol PanicResettingTransport: AnyObject {
    /// Quiesces the radio and drains in-flight work ahead of a panic wipe.
    func suspendForPanicReset()
    /// Finishes a panic wipe, optionally restarting services.
    func completePanicReset(restartServices: Bool)
    /// Rotates the transport identity as part of a panic reset.
    func resetIdentityForPanic(currentNickname: String, restartServices: Bool)
}

/// File and private-media transfer over a mesh transport, including the
/// capability-proof policy that gates encrypted private media.
protocol MeshFileTransferring: AnyObject {
    func sendFileBroadcast(_ packet: BitchatFilePacket, transferId: String)
    func sendFilePrivate(
        _ packet: BitchatFilePacket,
        to peerID: PeerID,
        transferId: String,
        allowLegacyFallback: Bool
    )
    /// Automatic whole-file retry is admitted only while this exact Noise
    /// generation authenticates bit 9. It must never queue across a session
    /// replacement or enter the signed raw legacy path.
    func sendFilePrivateReceiptRetry(
        _ packet: BitchatFilePacket,
        to peerID: PeerID,
        transferId: String
    )
    func cancelTransfer(_ transferId: String)
    func privateMediaSendPolicy(to peerID: PeerID) -> PrivateMediaSendPolicy
    /// The exact current Noise generation that authenticated both encrypted
    /// private media (bit 8) and durable receipts/retry (bit 9).
    func authenticatedPrivateMediaReceiptSessionGeneration(to peerID: PeerID) -> UUID?
    func resolvePrivateMediaSendPolicy(
        to peerID: PeerID,
        completion: @escaping @MainActor (PrivateMediaSendPolicy) -> Void
    )
}

/// Live voice / push-to-talk: one encoded `VoiceBurstPacket`,
/// fire-and-forget inside the Noise session (private) or as a signed
/// ephemeral broadcast (public). Frames are only useful now — the
/// transport drops them (never queues) without an established session.
protocol MeshVoiceStreaming: AnyObject {
    func sendVoiceFrame(_ burstContent: Data, to peerID: PeerID)
    func sendVoiceFrameBroadcast(_ burstContent: Data)
}

/// Courier store-and-forward: seal a message to the recipient's static
/// key and hand it to connected couriers for physical delivery while the
/// recipient is offline. Returns false when the transport cannot courier.
protocol MeshCourierTransporting: AnyObject {
    @discardableResult
    func sendCourierMessage(_ content: String, messageID: String, recipientNoiseKey: Data, via couriers: [PeerID]) -> Bool
}

/// Private groups: creator-signed state travels 1:1 over Noise sessions;
/// group messages flood like public broadcasts.
protocol MeshGroupMessaging: AnyObject {
    func sendGroupInvite(_ statePayload: Data, to peerID: PeerID)
    func sendGroupKeyUpdate(_ statePayload: Data, to peerID: PeerID)
    func broadcastGroupMessage(_ envelope: Data)
}

/// Bulletin board: broadcast a pre-signed board payload (post or
/// tombstone) so it spreads over relay and gossip sync.
protocol MeshBoardBroadcasting: AnyObject {
    func sendBoardPayload(_ payload: Data)
}

/// Mesh diagnostics (/ping, /trace, topology map).
protocol MeshDiagnosing: AnyObject {
    /// Sends a directed ping probe; the completion fires exactly once on
    /// the main actor with the measured result, or nil on timeout.
    func sendMeshPing(to peerID: PeerID, completion: @escaping @MainActor (MeshPingResult?) -> Void)
    /// Estimated intermediate hops toward `peerID` from gossiped topology
    /// ([] = direct link, nil = no known path).
    func computeMeshPath(to peerID: PeerID) -> [PeerID]?
    /// Current mesh graph for the topology map.
    func currentMeshTopology() -> MeshTopologySnapshot?
}

/// QR verification and transitive vouching over the Noise session.
protocol MeshVerifying: AnyObject {
    func sendVerifyChallenge(to peerID: PeerID, noiseKeyHex: String, nonceA: Data)
    func sendVerifyResponse(to peerID: PeerID, noiseKeyHex: String, nonceA: Data)
    /// Sends an encoded vouch-attestation batch inside the Noise session.
    func sendVouchAttestations(_ payload: Data, to peerID: PeerID)
}

/// Store-and-forward archive: the public messages this device is carrying
/// for gossip sync, decoded for display as "heard here earlier" echoes.
protocol MeshPublicArchiving: AnyObject {
    func collectArchivedPublicMessages(completion: @escaping @MainActor ([ArchivedPublicMessage]) -> Void)
    /// Drops any carried public messages from a (newly blocked) sender so
    /// they can't resurface as archived echoes on a later launch.
    func purgeArchivedPublicMessages(from peerID: PeerID)
    /// Erases the whole carried public-message archive, on disk included.
    func purgeAllArchivedPublicMessages()
}

/// Internet-gateway and geohash-bridge wiring surface (BLE mesh today).
/// Everything the gateway/bridge/courier services need from the mesh
/// transport, so their bootstrap wiring never touches the concrete class.
protocol MeshBridgingTransport: AnyObject {
    // Runtime-advertised capability bits
    func setLocalCapability(_ capability: PeerCapabilities, enabled: Bool)
    func setLocalBridgeGeohash(_ cell: String?)
    func advertisedBridgeGeohash() -> String?

    // Peers currently advertising bridging roles
    func reachableGatewayPeers() -> [PeerID]
    func reachableBridgePeers() -> [PeerID]

    // Gateway carrier packets (mesh <-> Nostr uplink/downlink)
    @discardableResult
    func sendNostrCarrier(_ payload: Data, to gatewayPeer: PeerID) -> Bool
    func broadcastNostrCarrier(_ payload: Data)
    /// Sink for received carrier packets (set once by app wiring; called on
    /// the main actor after transport-level checks).
    var onNostrCarrierPacket: (@MainActor (_ payload: Data, _ from: PeerID, _ directedToUs: Bool) -> Void)? { get set }

    // Bridge courier drops (sealed envelopes carried across the bridge)
    func sealBridgeCourierEnvelope(_ content: String, messageID: String, recipientNoiseKey: Data) -> CourierEnvelope?
    @discardableResult
    func openBridgedCourierEnvelope(_ envelope: CourierEnvelope) -> Bool
    @discardableResult
    func deliverBridgedEnvelope(_ envelope: CourierEnvelope, to peerID: PeerID) -> Bool
    func myNoiseStaticPublicKey() -> Data
    func verifiedPeersWithNoiseKeys() -> [(peerID: PeerID, noiseKey: Data)]
    /// Fired (off-main) when a signature-verified announce is processed.
    var onVerifiedPeerAnnounce: ((_ peerID: PeerID) -> Void)? { get set }
}
