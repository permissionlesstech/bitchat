import BitFoundation
import BitLogger
import Foundation

/// Narrow environment for `BLENoisePacketHandler`.
///
/// All queue hops (collections barrier writes, main-actor UI notification)
/// and every `noiseService.*` crypto call live inside the closures supplied by
/// `BLEService`, keeping the handler queue-agnostic and synchronously testable.
struct BLENoisePacketHandlerEnvironment {
    /// Local peer identity at the time the packet is handled.
    let localPeerID: () -> PeerID
    /// Local peer ID bytes used as the sender of handshake responses.
    let localPeerIDData: () -> Data
    /// TTL value used for direct (non-relayed) packets.
    let messageTTL: UInt8
    /// Current time source.
    let now: () -> Date
    /// Processes an inbound handshake message, returning an optional response payload (crypto).
    let processHandshakeMessage: (_ peerID: PeerID, _ message: Data) throws -> Data?
    /// Whether any Noise session (established or pending) exists for the peer (crypto).
    let hasNoiseSession: (PeerID) -> Bool
    /// Initiates a fresh Noise handshake with the peer (crypto + send).
    let initiateHandshake: (PeerID) -> Void
    /// Broadcasts a packet on the mesh (caller is already on the message queue).
    let broadcastPacket: (BitchatPacket) -> Void
    /// Updates the registry last-seen timestamp for the peer (async barrier write).
    let updatePeerLastSeen: (PeerID) -> Void
    /// Decrypts an encrypted payload from the peer (crypto).
    let decrypt: (_ payload: Data, _ peerID: PeerID) throws -> Data
    /// Clears the peer's Noise session after an unrecoverable decrypt failure (crypto).
    let clearSession: (PeerID) -> Void
    /// Delivers `.noisePayloadReceived` to the UI as one main-actor hop.
    let deliverNoisePayload: (
        _ peerID: PeerID,
        _ type: NoisePayloadType,
        _ payload: Data,
        _ timestamp: Date
    ) -> Void
}

/// Orchestrates the Noise session domain for inbound packets: handshake
/// processing (with response), encrypted payload decryption and dispatch,
/// and session recovery on decrypt failure.
final class BLENoisePacketHandler {
    private let environment: BLENoisePacketHandlerEnvironment

    init(environment: BLENoisePacketHandlerEnvironment) {
        self.environment = environment
    }

    func handleHandshake(_ packet: BitchatPacket, from peerID: PeerID) {
        let env = environment
        // Use NoiseEncryptionService for handshake processing
        if PeerID(hexData: packet.recipientID) == env.localPeerID() {
            // Handshake is for us
            do {
                if let response = try env.processHandshakeMessage(peerID, packet.payload) {
                    // Send response
                    let responsePacket = BitchatPacket(
                        type: MessageType.noiseHandshake.rawValue,
                        senderID: env.localPeerIDData(),
                        recipientID: Data(hexString: peerID.id),
                        timestamp: UInt64(env.now().timeIntervalSince1970 * 1000),
                        payload: response,
                        signature: nil,
                        ttl: env.messageTTL
                    )
                    // We're on messageQueue from delegate callback
                    env.broadcastPacket(responsePacket)
                }

                // Session establishment will trigger onPeerAuthenticated callback
                // which will send any pending messages at the right time
            } catch {
                SecureLogger.error("Failed to process handshake: \(error)")
                // Try initiating a new handshake
                if !env.hasNoiseSession(peerID) {
                    env.initiateHandshake(peerID)
                }
            }
        }
    }

    func handleEncrypted(_ packet: BitchatPacket, from peerID: PeerID) {
        let env = environment
        guard let recipientID = PeerID(hexData: packet.recipientID) else {
            SecureLogger.warning("⚠️ Encrypted message has no recipient ID", category: .session)
            return
        }

        if recipientID != env.localPeerID() {
            SecureLogger.debug("🔐 Encrypted message not for me (for \(recipientID.id.prefix(8))…, I am \(env.localPeerID().id.prefix(8))…)", category: .session)
            return
        }

        // Update lastSeen for the peer we received from (important for private messages)
        env.updatePeerLastSeen(peerID)

        do {
            let decrypted = try env.decrypt(packet.payload, peerID)
            guard decrypted.count > 0 else { return }

            // First byte indicates the payload type
            let payloadType = decrypted[0]
            let payloadData = decrypted.dropFirst()

            guard let noisePayloadType = NoisePayloadType(rawValue: payloadType) else {
                SecureLogger.warning("⚠️ Unknown noise payload type: \(payloadType)")
                return
            }

            SecureLogger.debug("🔐 Decrypted noise payload type \(noisePayloadType.description) from \(peerID.id.prefix(8))…", category: .session)

            let ts = Date(timeIntervalSince1970: Double(packet.timestamp) / 1000)
            env.deliverNoisePayload(peerID, noisePayloadType, Data(payloadData), ts)
        } catch NoiseEncryptionError.sessionNotEstablished {
            // We received an encrypted message before establishing a session with this peer.
            // Trigger a handshake so future messages can be decrypted.
            SecureLogger.debug("🔑 Encrypted message from \(peerID.id.prefix(8))… without session; initiating handshake")
            if !env.hasNoiseSession(peerID) {
                env.initiateHandshake(peerID)
            }
        } catch {
            // Decryption failed - clear the corrupted session and re-initiate handshake
            // This handles cases where session state got out of sync (nonce mismatch, etc.)
            SecureLogger.error("❌ Failed to decrypt message from \(peerID.id.prefix(8))…: \(error) - clearing session and re-initiating handshake")
            env.clearSession(peerID)
            env.initiateHandshake(peerID)
        }
    }
}
