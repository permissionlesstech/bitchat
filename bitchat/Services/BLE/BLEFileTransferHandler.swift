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
    /// Resolves the durable receiver decision for a stable private-media ID.
    let privateMediaReceiptState: (
        _ messageID: String
    ) -> BLEPrivateMediaReceiptState
    /// Atomically records a stable private-media ID after the payload save.
    let commitPrivateMediaFile: (_ messageID: String, _ storedURL: URL) -> Bool
    /// Rolls back a saved payload when its durable receipt commit fails.
    let removeIncomingFile: (_ storedURL: URL) -> Void
    /// Releases the allocator's save-to-UI ownership guard after synchronous
    /// conversation insertion has completed.
    let finishIncomingFileDelivery: (_ storedURL: URL) -> Void
    /// Checks the authenticated sender before any private-media disk work.
    let isPrivateMediaSenderBlocked: (PeerID) -> Bool
    /// Updates the registry last-seen timestamp for the peer (async barrier write).
    let updatePeerLastSeen: (PeerID) -> Void
    /// Acknowledges stable private media only after its synchronous
    /// conversation delivery has completed.
    let acknowledgePrivateMedia: (_ messageID: String, _ peerID: PeerID) -> Void
    /// Delivers `.messageReceived` as one main-actor hop while
    /// `shouldDeliver` remains true before and after the synchronous sink.
    /// The completion authorizes the stable-media ACK. Finalization runs after
    /// every delivery attempt, including rejection, so allocator ownership
    /// cannot leak indefinitely.
    let deliverMessage: (
        _ message: BitchatMessage,
        _ shouldDeliver: @escaping () -> Bool,
        _ completion: @escaping () -> Void,
        _ finalization: @escaping (TransportEventDeliveryOutcome) -> Void
    ) -> Void
}

/// Process-lifetime reservation cache for stable private-media IDs.
///
/// The first arrival reserves its ID before quota enforcement. Concurrent
/// arrivals remain coalesced in memory, while accepted state is resolved from
/// the durable ID-to-file ledger so it survives relaunch and becomes retryable
/// if quota cleanup removed the file.
private final class PrivateMediaArrivalDeduplicator {
    enum Reservation {
        case reserved
        case pending
        case accepted(URL)
        case tombstoned
        case unavailable
    }

    private let lock = NSLock()
    private var pending: Set<String> = []

    func reserve(
        _ messageID: String,
        receiptState: () -> BLEPrivateMediaReceiptState
    ) -> Reservation {
        lock.lock()
        defer { lock.unlock() }
        if pending.contains(messageID) {
            return .pending
        }

        switch receiptState() {
        case .accepted(let existingURL):
            return .accepted(existingURL)
        case .tombstoned:
            return .tombstoned
        case .unavailable:
            return .unavailable
        case .absent:
            break
        }

        pending.insert(messageID)
        return .reserved
    }

    func finish(_ messageID: String) {
        lock.lock()
        defer { lock.unlock() }
        pending.remove(messageID)
    }
}

/// Orchestrates inbound file transfers: self-echo policy, sender display-name
/// resolution, delivery planning, payload validation, quota-checked storage,
/// and UI delivery.
final class BLEFileTransferHandler {
    private let environment: BLEFileTransferHandlerEnvironment
    private let privateMediaArrivals = PrivateMediaArrivalDeduplicator()

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
            usesDurableReceipts: false,
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
            // Every authenticated Noise private-file keeps the stable ID/ACK
            // contract introduced with capability bit 8. Bit 9 advertises
            // sender-side automatic retry support; it must not downgrade
            // prior iOS clients to random IDs or single-check delivery.
            usesDurableReceipts: true,
            env: env
        )
    }

    private func storeIncomingPayload(
        _ payload: Data,
        from peerID: PeerID,
        senderNickname: String,
        timestamp: Date,
        isPrivate: Bool,
        usesDurableReceipts: Bool,
        env: BLEFileTransferHandlerEnvironment
    ) -> Bool {

        let localPeerID = env.localPeerID()
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

        if isPrivate, env.isPrivateMediaSenderBlocked(peerID) {
            SecureLogger.debug(
                "🚫 Dropping private media from blocked peer \(peerID.id.prefix(8))… before disk write",
                category: .security
            )
            return true
        }

        let messageID = usesDurableReceipts
            ? PrivateMediaMessageIdentity.stableID(
                for: filePacket,
                senderPeerID: peerID,
                recipientPeerID: localPeerID
            )
            : nil
        if let messageID {
            switch privateMediaArrivals.reserve(
                messageID,
                receiptState: { env.privateMediaReceiptState(messageID) }
            ) {
            case .reserved:
                break
            case .pending:
                // The first arrival has not reached durable storage yet.
                // Coalesce this retry without ACKing so a failed first save
                // remains retryable by the sender.
                SecureLogger.debug(
                    "📁 Coalesced in-flight private media id=\(messageID.prefix(12))… from \(peerID.id.prefix(8))…",
                    category: .session
                )
                return true
            case .accepted(let existingFile):
                env.updatePeerLastSeen(peerID)
                let message = incomingMessage(
                    messageID: messageID,
                    senderNickname: senderNickname,
                    timestamp: timestamp,
                    isPrivate: true,
                    peerID: peerID,
                    destination: existingFile,
                    category: storedMediaCategory(
                        for: existingFile,
                        fallback: mime.category
                    ),
                    env: env
                )
                SecureLogger.debug(
                    "📁 Restored durable private media duplicate id=\(messageID.prefix(12))… from \(peerID.id.prefix(8))… -> \(existingFile.lastPathComponent)",
                    category: .session
                )
                deliverStableMessage(
                    message,
                    messageID: messageID,
                    peerID: peerID,
                    expectedURL: existingFile,
                    env: env
                )
                return true
            case .tombstoned:
                // Explicit deletion is a durable terminal receiver decision.
                env.updatePeerLastSeen(peerID)
                env.acknowledgePrivateMedia(messageID, peerID)
                SecureLogger.debug(
                    "📁 Dropped explicitly deleted private media id=\(messageID.prefix(12))… from \(peerID.id.prefix(8))…",
                    category: .session
                )
                return true
            case .unavailable:
                // Never turn an unreadable ledger into an empty ledger. A
                // directory-level failure clears on retry; a quarantined
                // record keeps exactly this ID fail-closed while every other
                // payload still flows.
                SecureLogger.warning(
                    "📁 Withholding private media id=\(messageID.prefix(12))… while durable receipt state is unavailable",
                    category: .session
                )
                return true
            }
        }
        defer {
            if let messageID {
                privateMediaArrivals.finish(messageID)
            }
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

        if let messageID,
           !env.commitPrivateMediaFile(messageID, destination) {
            // A payload without its durable ID mapping cannot safely suppress
            // a retry after relaunch. Roll it back and withhold UI/ACK.
            env.removeIncomingFile(destination)
            return false
        }

        if isPrivate {
            env.updatePeerLastSeen(peerID)
        }

        let message = incomingMessage(
            messageID: messageID,
            senderNickname: senderNickname,
            timestamp: timestamp,
            isPrivate: isPrivate,
            peerID: peerID,
            destination: destination,
            category: mime.category,
            env: env
        )

        SecureLogger.debug("📁 Stored incoming media from \(peerID.id.prefix(8))… -> \(destination.lastPathComponent)", category: .session)

        if let messageID {
            deliverStableMessage(
                message,
                messageID: messageID,
                peerID: peerID,
                expectedURL: destination,
                env: env
            )
        } else {
            env.deliverMessage(
                message,
                { true },
                {},
                { outcome in
                    if outcome == .rejected {
                        // Raw media has no durable receipt that can redeliver
                        // it later. Do not leave a newly saved, UI-unowned file
                        // available for a stale fallback path to misidentify.
                        env.removeIncomingFile(destination)
                    } else {
                        // Plain delegates are invoked without synchronous
                        // insertion confirmation. Preserve the payload for
                        // that supported delivery path.
                        env.finishIncomingFileDelivery(destination)
                    }
                }
            )
        }
        return true
    }

    private func deliverStableMessage(
        _ message: BitchatMessage,
        messageID: String,
        peerID: PeerID,
        expectedURL: URL,
        env: BLEFileTransferHandlerEnvironment
    ) {
        env.deliverMessage(
            message,
            {
                guard case .accepted(let resolvedURL) =
                        env.privateMediaReceiptState(messageID) else {
                    return false
                }
                return resolvedURL.standardizedFileURL
                    == expectedURL.standardizedFileURL
            },
            {
                env.acknowledgePrivateMedia(messageID, peerID)
            },
            { _ in
                env.finishIncomingFileDelivery(expectedURL)
            }
        )
    }

    private func incomingMessage(
        messageID: String?,
        senderNickname: String,
        timestamp: Date,
        isPrivate: Bool,
        peerID: PeerID,
        destination: URL,
        category: MimeType.Category,
        env: BLEFileTransferHandlerEnvironment
    ) -> BitchatMessage {
        BitchatMessage(
            id: messageID,
            sender: senderNickname,
            content: "\(category.messagePrefix)\(destination.lastPathComponent)",
            timestamp: timestamp,
            isRelay: false,
            originalSender: nil,
            isPrivate: isPrivate,
            recipientNickname: nil,
            senderPeerID: peerID,
            // Received messages need an explicit status: BitchatMessage
            // defaults private messages to .sending, which media views render
            // as an in-flight send.
            deliveryStatus: isPrivate
                ? .delivered(to: env.localNickname(), at: timestamp)
                : nil
        )
    }

    /// The durable URL is authoritative during reconstruction. A sender that
    /// reuses a stable filename with a different MIME type must not change how
    /// the already-stored payload renders.
    private func storedMediaCategory(
        for url: URL,
        fallback: MimeType.Category
    ) -> MimeType.Category {
        let mediaDirectory = url
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .lastPathComponent
        switch mediaDirectory {
        case MimeType.Category.audio.mediaDir:
            return .audio
        case MimeType.Category.image.mediaDir:
            return .image
        case MimeType.Category.file.mediaDir:
            return .file
        default:
            return fallback
        }
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
