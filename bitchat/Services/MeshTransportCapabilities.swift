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
