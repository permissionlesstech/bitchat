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
    /// Local signing key used to authenticate our own gossip-sync replays.
    let localSigningPublicKey: () -> Data
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

    /// Returns `false` when the raw packet fails sender authentication (or is
    /// a live self-echo) and must not be relayed onward. Authentication runs
    /// before the routing decision, so a forged directed packet cannot use a
    /// node that is not its recipient as an unsigned forwarding hop.
    @discardableResult
    func handle(_ packet: BitchatPacket, from peerID: PeerID) -> Bool {
        let env = environment
        let localPeerID = env.localPeerID()
        let peersSnapshot = env.peersSnapshot()

        guard let senderNickname = authenticatedRawSenderNickname(
            packet: packet,
            from: peerID,
            peers: peersSnapshot,
            env: env
        ) else {
            SecureLogger.warning("🚫 Dropping raw file transfer with missing/invalid signature from \(peerID.id.prefix(8))…", category: .security)
            return false
        }

        if BLEFileTransferPolicy.isSelfEcho(packet: packet, from: peerID, localPeerID: localPeerID) {
            return false
        }

        guard let deliveryPlan = BLEFileTransferPolicy.deliveryPlan(packet: packet, localPeerID: localPeerID) else {
            return true
        }

        if deliveryPlan.shouldTrackForSync {
            env.trackPacketSeen(packet)
        }

        _ = storeIncomingPayload(
            packet.payload,
            from: peerID,
            senderNickname: senderNickname,
            timestamp: Date(timeIntervalSince1970: Double(packet.timestamp) / 1000),
            isPrivate: deliveryPlan.isPrivateMessage,
            env: env
        )
        // Once authenticated, a local decode/quota/save failure is not proof
        // that downstream nodes should be denied the valid signed packet.
        return true
    }

    /// Accepts a file packet only after it has been authenticated and
    /// decrypted by the peer's Noise session. The inner packet deliberately
    /// has no redundant signature: Noise supplies sender authentication and
    /// confidentiality, while this handler retains the same validation,
    /// quota, persistence, and UI-delivery behavior as public files.
    @discardableResult
    func handlePrivatePayload(_ payload: Data, from peerID: PeerID, timestamp: Date) -> Bool {
        let env = environment
        let peers = env.peersSnapshot()
        let senderNickname = BLEPeerSenderDisplayName.resolveKnownPeer(
            peerID: peerID,
            localPeerID: env.localPeerID(),
            localNickname: env.localNickname(),
            peers: peers,
            allowConnectedUnverified: true
        ) ?? BLEPeerSenderDisplayName.anonymousNickname(for: peerID)

        return storeIncomingPayload(
            payload,
            from: peerID,
            senderNickname: senderNickname,
            timestamp: timestamp,
            isPrivate: true,
            env: env
        )
    }

    private func storeIncomingPayload(
        _ payload: Data,
        from peerID: PeerID,
        senderNickname: String,
        timestamp: Date,
        isPrivate: Bool,
        env: BLEFileTransferHandlerEnvironment
    ) -> Bool {

        let filePacket: BitchatFilePacket
        let mime: MimeType
        switch BLEIncomingFileValidator.validate(payload: payload) {
        case .success(let acceptance):
            filePacket = acceptance.filePacket
            mime = acceptance.mime
        case .failure(.malformedPayload):
            SecureLogger.error("❌ Failed to decode file transfer payload", category: .session)
            return false
        case .failure(.payloadTooLarge(let bytes)):
            SecureLogger.warning("🚫 Dropping file transfer exceeding size cap (\(bytes) bytes)", category: .security)
            return false
        case .failure(.unsupportedMime(let mimeType, let bytes)):
            SecureLogger.warning("🚫 MIME REJECT: '\(mimeType ?? "<empty>")' not supported. Size=\(bytes)b from \(peerID.id.prefix(8))...", category: .security)
            return false
        case .failure(.magicMismatch(let mime, let bytes, let prefixHex)):
            SecureLogger.warning("🚫 MAGIC REJECT: MIME='\(mime)' size=\(bytes)b prefix=[\(prefixHex)] from \(peerID.id.prefix(8))...", category: .security)
            return false
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
            return false
        }

        if isPrivate {
            env.updatePeerLastSeen(peerID)
        }

        let message = BitchatMessage(
            sender: senderNickname,
            content: "\(mime.category.messagePrefix)\(destination.lastPathComponent)",
            timestamp: timestamp,
            isRelay: false,
            originalSender: nil,
            isPrivate: isPrivate,
            recipientNickname: nil,
            senderPeerID: peerID,
            // Received messages need an explicit status: BitchatMessage
            // defaults private messages to .sending, which the media views
            // render as an in-flight send (empty reveal mask, disabled tap).
            deliveryStatus: isPrivate
                ? .delivered(to: env.localNickname(), at: timestamp)
                : nil
        )

        SecureLogger.debug("📁 Stored incoming media from \(peerID.id.prefix(8))… -> \(destination.lastPathComponent)", category: .session)

        env.deliverMessage(message)
        return true
    }

    /// Every remaining raw file transfer is signed, regardless of whether it
    /// is broadcast, addressed to us, or merely passing through. Registry
    /// signing keys are preferred; persisted identities cover peers that have
    /// rotated or are not currently present in the registry.
    private func authenticatedRawSenderNickname(
        packet: BitchatPacket,
        from peerID: PeerID,
        peers: [PeerID: BLEPeerInfo],
        env: BLEFileTransferHandlerEnvironment
    ) -> String? {
        guard packet.signature != nil else { return nil }

        let localPeerID = env.localPeerID()
        let candidateKey = peerID == localPeerID
            ? env.localSigningPublicKey()
            : peers[peerID]?.signingPublicKey
        let verifiedWithKnownKey = candidateKey.map {
            env.verifyPacketSignature(packet, $0)
        } ?? false
        let signedDisplayName = verifiedWithKnownKey
            ? nil
            : env.signedSenderDisplayName(packet, peerID)
        guard verifiedWithKnownKey || signedDisplayName != nil else { return nil }

        return BLEPeerSenderDisplayName.resolveKnownPeer(
            peerID: peerID,
            localPeerID: localPeerID,
            localNickname: env.localNickname(),
            peers: peers,
            // The packet signature authenticates the announced peer; the old
            // connected-but-unsigned leniency is not involved.
            allowConnectedUnverified: true
        ) ?? signedDisplayName ?? BLEPeerSenderDisplayName.anonymousNickname(for: peerID)
    }
}
