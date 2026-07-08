import BitFoundation
import BitLogger
import Foundation

/// Narrow environment for `BLEFileTransferHandler`.
///
/// All queue hops (collections registry reads/writes, main-actor UI
/// notification) live inside the closures supplied by `BLEService`, keeping
/// the handler queue-agnostic and synchronously testable.
struct BLEFileTransferHandlerEnvironment {
    /// Local peer identity at the time the transfer is handled.
    let localPeerID: () -> PeerID
    /// Local nickname used for sender resolution and collision checks.
    let localNickname: () -> String
    /// Snapshot of known peers keyed by ID (registry read).
    let peersSnapshot: () -> [PeerID: BLEPeerInfo]
    /// Resolves a display name from a verified packet signature for peers missing from the registry.
    let signedSenderDisplayName: (_ packet: BitchatPacket, _ peerID: PeerID) -> String?
    /// Tracks the broadcast file packet for gossip sync.
    let trackPacketSeen: (BitchatPacket) -> Void
    /// Enforces the incoming-media storage quota before saving (BCH-01-002).
    let enforceStorageQuota: (_ reservingBytes: Int) -> Void
    /// Persists the validated file to the incoming-media store; returns the destination URL.
    let saveIncomingFile: (
        _ data: Data,
        _ preferredName: String?,
        _ subdirectory: String,
        _ fallbackExtension: String?,
        _ defaultPrefix: String
    ) -> URL?
    /// Updates the registry last-seen timestamp for the peer (async barrier write).
    let updatePeerLastSeen: (PeerID) -> Void
    /// Delivers `.messageReceived` to the UI as one main-actor hop.
    let deliverMessage: (BitchatMessage) -> Void
}

/// Orchestrates inbound file transfers: self-echo policy, sender display-name
/// resolution, delivery planning, payload validation, quota-checked storage,
/// and UI delivery.
final class BLEFileTransferHandler {
    private let environment: BLEFileTransferHandlerEnvironment

    init(environment: BLEFileTransferHandlerEnvironment) {
        self.environment = environment
    }

    func handle(_ packet: BitchatPacket, from peerID: PeerID) {
        let env = environment
        if BLEFileTransferPolicy.isSelfEcho(packet: packet, from: peerID, localPeerID: env.localPeerID()) { return }

        let peersSnapshot = env.peersSnapshot()
        guard let senderNickname = BLEPeerSenderDisplayName.resolveKnownPeer(
            peerID: peerID,
            localPeerID: env.localPeerID(),
            localNickname: env.localNickname(),
            peers: peersSnapshot,
            allowConnectedUnverified: true
        ) ?? env.signedSenderDisplayName(packet, peerID) else {
            SecureLogger.warning("🚫 Dropping file transfer from unverified or unknown peer \(peerID.id.prefix(8))…", category: .security)
            return
        }

        guard let deliveryPlan = BLEFileTransferPolicy.deliveryPlan(packet: packet, localPeerID: env.localPeerID()) else {
            return
        }
        if deliveryPlan.shouldTrackForSync {
            env.trackPacketSeen(packet)
        }

        let filePacket: BitchatFilePacket
        let mime: MimeType
        switch BLEIncomingFileValidator.validate(payload: packet.payload) {
        case .success(let acceptance):
            filePacket = acceptance.filePacket
            mime = acceptance.mime
        case .failure(.malformedPayload):
            SecureLogger.error("❌ Failed to decode file transfer payload", category: .session)
            return
        case .failure(.payloadTooLarge(let bytes)):
            SecureLogger.warning("🚫 Dropping file transfer exceeding size cap (\(bytes) bytes)", category: .security)
            return
        case .failure(.unsupportedMime(let mimeType, let bytes)):
            SecureLogger.warning("🚫 MIME REJECT: '\(mimeType ?? "<empty>")' not supported. Size=\(bytes)b from \(peerID.id.prefix(8))...", category: .security)
            return
        case .failure(.magicMismatch(let mime, let bytes, let prefixHex)):
            SecureLogger.warning("🚫 MAGIC REJECT: MIME='\(mime)' size=\(bytes)b prefix=[\(prefixHex)] from \(peerID.id.prefix(8))...", category: .security)
            return
        }

        // BCH-01-002: Enforce storage quota before saving
        env.enforceStorageQuota(filePacket.content.count)

        guard let destination = env.saveIncomingFile(
            filePacket.content,
            filePacket.fileName,
            "\(mime.category.mediaDir)/incoming",
            mime.defaultExtension,
            mime.category.rawValue
        ) else {
            return
        }

        if deliveryPlan.isPrivateMessage {
            env.updatePeerLastSeen(peerID)
        }

        let ts = Date(timeIntervalSince1970: Double(packet.timestamp) / 1000)
        let message = BitchatMessage(
            sender: senderNickname,
            content: "\(mime.category.messagePrefix)\(destination.lastPathComponent)",
            timestamp: ts,
            isRelay: false,
            originalSender: nil,
            isPrivate: deliveryPlan.isPrivateMessage,
            recipientNickname: nil,
            senderPeerID: peerID,
            // Received messages need an explicit status: BitchatMessage
            // defaults private messages to .sending, which the media views
            // render as an in-flight send (empty reveal mask, disabled tap).
            deliveryStatus: deliveryPlan.isPrivateMessage
                ? .delivered(to: env.localNickname(), at: ts)
                : nil
        )

        SecureLogger.debug("📁 Stored incoming media from \(peerID.id.prefix(8))… -> \(destination.lastPathComponent)", category: .session)

        env.deliverMessage(message)
    }
}
