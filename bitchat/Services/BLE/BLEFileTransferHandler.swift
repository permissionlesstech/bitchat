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
    /// Verifies a packet's signature against a candidate signing key (registry path).
    let verifyPacketSignature: (_ packet: BitchatPacket, _ signingPublicKey: Data) -> Bool
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

    /// Returns `false` when the packet fails sender authentication and must
    /// not be relayed onward. Every other outcome returns `true`: files
    /// directed to another peer are forwarded untouched, and local-only drops
    /// (malformed payload, quota, save failure) don't affect multi-hop
    /// delivery to nodes that may handle them fine.
    @discardableResult
    func handle(_ packet: BitchatPacket, from peerID: PeerID) -> Bool {
        let env = environment
        if BLEFileTransferPolicy.isSelfEcho(packet: packet, from: peerID, localPeerID: env.localPeerID()) { return true }

        guard let deliveryPlan = BLEFileTransferPolicy.deliveryPlan(packet: packet, localPeerID: env.localPeerID()) else {
            return true
        }

        let peersSnapshot = env.peersSnapshot()
        guard let senderNickname = resolveSenderNickname(
            packet: packet,
            from: peerID,
            isBroadcast: !deliveryPlan.isPrivateMessage,
            peers: peersSnapshot,
            env: env
        ) else {
            SecureLogger.warning("🚫 Dropping file transfer from unverified or unknown peer \(peerID.id.prefix(8))…", category: .security)
            return false
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
            return true
        case .failure(.payloadTooLarge(let bytes)):
            SecureLogger.warning("🚫 Dropping file transfer exceeding size cap (\(bytes) bytes)", category: .security)
            return true
        case .failure(.unsupportedMime(let mimeType, let bytes)):
            SecureLogger.warning("🚫 MIME REJECT: '\(mimeType ?? "<empty>")' not supported. Size=\(bytes)b from \(peerID.id.prefix(8))...", category: .security)
            return true
        case .failure(.magicMismatch(let mime, let bytes, let prefixHex)):
            SecureLogger.warning("🚫 MAGIC REJECT: MIME='\(mime)' size=\(bytes)b prefix=[\(prefixHex)] from \(peerID.id.prefix(8))...", category: .security)
            return true
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
            return true
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
        return true
    }

    /// Resolves the authenticated display name for a file transfer's sender.
    ///
    /// Directed (private) transfers are addressed to us specifically and keep
    /// the lenient connected-peer path. Broadcast transfers carry an
    /// attacker-controllable `senderID` exactly like public messages and public
    /// voice frames — registry membership alone is NOT proof of identity, so a
    /// valid packet signature from the claimed sender is required before we
    /// trust it. Without this, a peer that observed a public voice burst could
    /// spoof a broadcast `voice_<burstID>.m4a` note under the talker's ID and
    /// overwrite the signature-verified live bubble with attacker audio.
    private func resolveSenderNickname(
        packet: BitchatPacket,
        from peerID: PeerID,
        isBroadcast: Bool,
        peers: [PeerID: BLEPeerInfo],
        env: BLEFileTransferHandlerEnvironment
    ) -> String? {
        guard isBroadcast else {
            return BLEPeerSenderDisplayName.resolveKnownPeer(
                peerID: peerID,
                localPeerID: env.localPeerID(),
                localNickname: env.localNickname(),
                peers: peers,
                allowConnectedUnverified: true
            ) ?? env.signedSenderDisplayName(packet, peerID)
        }

        // Our own broadcasts replayed back via gossip sync (ttl==0) are
        // trivially authentic and cannot be verified against the peer registry
        // or identity cache, so exempt self exactly as `BLEPublicMessageHandler`
        // does. Verify against the signing key already in the
        // (synchronously-updated) registry first, then fall back to the
        // persisted-identity signature lookup for peers not yet cached there.
        let isSelf = peerID == env.localPeerID()
        let registrySigningKey = peers[peerID]?.signingPublicKey
        let verifiedViaRegistry = !isSelf && (registrySigningKey.map { env.verifyPacketSignature(packet, $0) } ?? false)
        let signedDisplayName = (isSelf || verifiedViaRegistry) ? nil : env.signedSenderDisplayName(packet, peerID)
        guard isSelf || verifiedViaRegistry || signedDisplayName != nil else { return nil }

        return BLEPeerSenderDisplayName.resolveKnownPeer(
            peerID: peerID,
            localPeerID: env.localPeerID(),
            localNickname: env.localNickname(),
            peers: peers,
            allowConnectedUnverified: false
        ) ?? signedDisplayName
    }
}
