import BitFoundation
import BitLogger
import Foundation

/// Narrow environment for `BLEAnnounceHandler`.
///
/// All queue hops (collections barrier, BLE-queue link-state reads, main-actor
/// UI notification, delayed re-announce) live inside the closures supplied by
/// `BLEService`, keeping the handler queue-agnostic and synchronously testable.
struct BLEAnnounceHandlerEnvironment {
    /// Local peer identity at the time the announce is handled.
    let localPeerID: () -> PeerID
    /// TTL value used for direct (non-relayed) packets.
    let messageTTL: UInt8
    /// Current time source.
    let now: () -> Date
    /// Noise public key already recorded for the peer, if any (registry read).
    let existingNoisePublicKey: (PeerID) -> Data?
    /// Verifies the packet signature against the announced signing key.
    let verifySignature: (_ packet: BitchatPacket, _ signingPublicKey: Data) -> Bool
    /// Direct link state for the peer (BLE-queue read).
    let linkState: (PeerID) -> (hasPeripheral: Bool, hasCentral: Bool)
    /// Runs the registry mutation phase under the collections barrier.
    let withRegistryBarrier: (() -> Void) -> Void
    /// Upserts the verified announce into the peer registry.
    /// Must only be called from inside `withRegistryBarrier`.
    let upsertVerifiedAnnounce: (
        _ peerID: PeerID,
        _ announcement: AnnouncementPacket,
        _ isConnected: Bool,
        _ now: Date
    ) -> BLEPeerAnnounceUpdate
    /// Debounced reconnect-log decision.
    /// Must only be called from inside `withRegistryBarrier`.
    let shouldEmitReconnectLog: (_ peerID: PeerID, _ now: Date) -> Bool
    /// Records verified direct-neighbor claims in the mesh topology.
    let updateTopology: (_ peerID: PeerID, _ neighbors: [Data]) -> Void
    /// Persists the announced cryptographic identity for offline verification.
    let persistIdentity: (AnnouncementPacket) -> Void
    /// Announce-back dedup check.
    let dedupContains: (String) -> Bool
    /// Announce-back dedup marking.
    let dedupMarkProcessed: (String) -> Void
    /// Delivers the announce UI events as one ordered main-actor hop:
    /// `.peerConnected` (if flagged) → initial gossip sync scheduling (if
    /// flagged) → peer-ID snapshot + data publish + `.peerListUpdated`.
    /// A single closure keeps the original in-order delivery guarantee that
    /// separate unstructured tasks would not provide.
    let deliverAnnounceUIEvents: (
        _ peerID: PeerID,
        _ notifyPeerConnected: Bool,
        _ scheduleInitialSync: Bool
    ) -> Void
    /// Tracks the announce packet for gossip sync.
    let trackPacketSeen: (BitchatPacket) -> Void
    /// Reciprocates the announce for bidirectional discovery.
    let sendAnnounceBack: () -> Void
    /// Schedules a delayed re-announce (afterglow) after the given delay.
    let scheduleAfterglow: (TimeInterval) -> Void
}

/// Orchestrates inbound announce packets: preflight validation, signature
/// trust, registry/topology updates, identity persistence, UI notification,
/// gossip tracking, and the reciprocal announce response.
final class BLEAnnounceHandler {
    private let environment: BLEAnnounceHandlerEnvironment

    init(environment: BLEAnnounceHandlerEnvironment) {
        self.environment = environment
    }

    func handle(_ packet: BitchatPacket, from peerID: PeerID) {
        let env = environment
        let now = env.now()
        let preflight = BLEAnnouncePreflightPolicy.evaluate(
            packet: packet,
            from: peerID,
            localPeerID: env.localPeerID(),
            now: now
        )

        let announcement: AnnouncementPacket
        switch preflight {
        case .accept(let acceptance):
            announcement = acceptance.announcement
        case .reject(.malformed):
            SecureLogger.error("❌ Failed to decode announce packet from \(peerID.id.prefix(8))…", category: .session)
            return
        case .reject(.senderMismatch(let derivedFromKey)):
            SecureLogger.warning("⚠️ Announce sender mismatch: derived \(derivedFromKey.id.prefix(8))… vs packet \(peerID.id.prefix(8))…", category: .security)
            return
        case .reject(.selfAnnounce):
            return
        case .reject(.stale(let ageSeconds)):
            SecureLogger.debug("⏰ Ignoring stale announce from \(peerID.id.prefix(8))… (age: \(ageSeconds)s)", category: .session)
            return
        }

        // Suppress announce logs to reduce noise

        // Precompute signature verification outside barrier to reduce contention
        let existingNoisePublicKey = env.existingNoisePublicKey(peerID)
        let hasSignature = packet.signature != nil
        let signatureValid: Bool
        if hasSignature {
            signatureValid = env.verifySignature(packet, announcement.signingPublicKey)
            if !signatureValid {
                SecureLogger.warning("⚠️ Signature verification for announce failed \(peerID.id.prefix(8))", category: .security)
            }
        } else {
            signatureValid = false
        }
        let trustDecision = BLEAnnounceTrustPolicy.evaluate(
            hasSignature: hasSignature,
            signatureValid: signatureValid,
            existingNoisePublicKey: existingNoisePublicKey,
            announcedNoisePublicKey: announcement.noisePublicKey
        )
        if case .reject(.keyMismatch) = trustDecision {
            SecureLogger.warning("⚠️ Announce key mismatch for \(peerID.id.prefix(8))… — keeping unverified", category: .security)
        }
        let verifiedAnnounce = trustDecision.isVerified

        var isNewPeer = false
        var isReconnectedPeer = false
        let directLinkState = env.linkState(peerID)
        let isDirectAnnounce = packet.ttl == env.messageTTL

        env.withRegistryBarrier {
            let hasPeripheralConnection = directLinkState.hasPeripheral
            let hasCentralSubscription = directLinkState.hasCentral

            // Require verified announce; ignore otherwise (no backward compatibility)
            if !verifiedAnnounce {
                SecureLogger.warning("❌ Ignoring unverified announce from \(peerID.id.prefix(8))…", category: .security)
                // Reset flags to prevent post-barrier code from acting on unverified announces
                isNewPeer = false
                isReconnectedPeer = false
                return
            }

            let update = env.upsertVerifiedAnnounce(
                peerID,
                announcement,
                isDirectAnnounce || hasPeripheralConnection || hasCentralSubscription,
                now
            )
            isNewPeer = update.isNewPeer
            isReconnectedPeer = update.wasDisconnected

            // Log connection status only for direct connectivity changes; debounce to reduce spam
            if isDirectAnnounce || hasPeripheralConnection || hasCentralSubscription {
                let now = env.now()
                if update.isNewPeer {
                    SecureLogger.debug("🆕 New peer: \(announcement.nickname)", category: .session)
                } else if update.wasDisconnected {
                    if env.shouldEmitReconnectLog(peerID, now) {
                        SecureLogger.debug("🔄 Peer \(announcement.nickname) reconnected", category: .session)
                    }
                } else if let previousNickname = update.previousNickname, previousNickname != announcement.nickname {
                    SecureLogger.debug("🔄 Peer \(peerID.id.prefix(8))… changed nickname: \(previousNickname) -> \(announcement.nickname)", category: .session)
                }
            }
        }

        // Update topology with verified neighbor claims (only for authenticated announces)
        if verifiedAnnounce, let neighbors = announcement.directNeighbors {
            env.updateTopology(peerID, neighbors)
        }

        // Persist cryptographic identity and signing key for robust offline
        // verification — only for verified announces. Persisting unverified
        // announces would let an attacker who replays a victim's noisePublicKey
        // overwrite the victim's stored signing key/nickname (identity poisoning).
        if verifiedAnnounce {
            env.persistIdentity(announcement)
        }

        let announceBackID = "announce-back-\(peerID)"
        let shouldSendBack = !env.dedupContains(announceBackID)
        if shouldSendBack {
            env.dedupMarkProcessed(announceBackID)
        }
        let responsePlan = BLEAnnounceResponsePolicy.plan(
            isDirectAnnounce: isDirectAnnounce,
            isNewPeer: isNewPeer,
            isReconnectedPeer: isReconnectedPeer,
            shouldSendAnnounceBack: shouldSendBack
        )

        // Only notify of connection for new or reconnected peers when it is a
        // direct announce; the list update always follows in the same hop.
        env.deliverAnnounceUIEvents(
            peerID,
            responsePlan.shouldNotifyPeerConnected,
            responsePlan.shouldNotifyPeerConnected && responsePlan.shouldScheduleInitialSync
        )

        // Track for sync (include our own and others' announces)
        env.trackPacketSeen(packet)

        if responsePlan.shouldSendAnnounceBack {
            // Reciprocate announce for bidirectional discovery
            // Force send to ensure the peer receives our announce
            env.sendAnnounceBack()
        }

        // Afterglow: on first-seen peers, schedule a short re-announce to push presence one more hop
        if responsePlan.shouldScheduleAfterglow {
            let delay = Double.random(in: 0.3...0.6)
            env.scheduleAfterglow(delay)
        }
    }
}
