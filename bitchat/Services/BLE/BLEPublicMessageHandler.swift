import BitFoundation
import BitLogger
import Foundation

/// Narrow environment for `BLEPublicMessageHandler`.
///
/// All queue hops (collections registry reads, BLE-queue link-state reads,
/// main-actor UI notification) live inside the closures supplied by
/// `BLEService`, keeping the handler queue-agnostic and synchronously testable.
struct BLEPublicMessageHandlerEnvironment {
    /// Local peer identity at the time the message is handled.
    let localPeerID: () -> PeerID
    /// Local nickname used for sender resolution and collision checks.
    let localNickname: () -> String
    /// Current time source.
    let now: () -> Date
    /// Snapshot of known peers keyed by ID (registry read).
    let peersSnapshot: () -> [PeerID: BLEPeerInfo]
    /// Verifies a packet's signature against a known signing public key.
    let verifyPacketSignature: (_ packet: BitchatPacket, _ signingPublicKey: Data) -> Bool
    /// Resolves a display name from a verified packet signature for peers missing from the registry.
    let signedSenderDisplayName: (_ packet: BitchatPacket, _ peerID: PeerID) -> String?
    /// Tracks the broadcast message packet for gossip sync.
    let trackPacketSeen: (BitchatPacket) -> Void
    /// Direct link state for the peer (BLE-queue read).
    let linkState: (PeerID) -> (hasPeripheral: Bool, hasCentral: Bool)
    /// Resolves and consumes the original message ID for our own re-broadcast.
    let takeSelfBroadcastMessageID: (BitchatPacket) -> String?
    /// Delivers `.publicMessageReceived` to the UI as one main-actor hop.
    let deliverPublicMessage: (
        _ peerID: PeerID,
        _ nickname: String,
        _ content: String,
        _ timestamp: Date,
        _ messageID: String?
    ) -> Void
}

/// Orchestrates inbound public (broadcast) messages: freshness/self-echo
/// policy, sender display-name resolution, gossip tracking, payload decoding,
/// and UI delivery.
final class BLEPublicMessageHandler {
    private let environment: BLEPublicMessageHandlerEnvironment

    init(environment: BLEPublicMessageHandlerEnvironment) {
        self.environment = environment
    }

    func handle(_ packet: BitchatPacket, from peerID: PeerID) {
        let env = environment
        let now = env.now()
        let messageDecision = BLEPublicMessagePolicy.evaluate(
            packet: packet,
            from: peerID,
            localPeerID: env.localPeerID(),
            now: now
        )

        let messagePolicy: BLEPublicMessageAcceptance
        switch messageDecision {
        case .accept(let acceptance):
            messagePolicy = acceptance
        case .reject(.selfEcho):
            return
        case .reject(.staleBroadcast(let ageSeconds)):
            SecureLogger.debug("⏰ Ignoring stale broadcast message from \(peerID.id.prefix(8))… (age: \(ageSeconds)s)", category: .session)
            return
        }

        // Snapshot peers to avoid concurrent mutation while iterating during nickname collision checks.
        let peersSnapshot = env.peersSnapshot()

        // Public messages are always signed by their sender. `senderID` is
        // attacker-controlled, so registry membership alone is NOT proof of
        // identity — a peer in the registry as "verified" could be impersonated
        // by anyone spoofing their senderID. Require a valid packet signature
        // from the claimed sender (our own echoes are exempt; they are matched
        // by self-broadcast tracking below).
        //
        // Verify against the signing key already in the (synchronously-updated)
        // peer registry first: identity-cache persistence is asynchronous, so a
        // message arriving right after a verified announce would otherwise be
        // dropped because `signedSenderDisplayName` only searches the persisted
        // cache. Fall back to that persisted-identity lookup for peers not (yet)
        // in the registry.
        let isSelf = peerID == env.localPeerID()
        let registrySigningKey = peersSnapshot[peerID]?.signingPublicKey
        let verifiedViaRegistry = !isSelf
            && (registrySigningKey.map { env.verifyPacketSignature(packet, $0) } ?? false)
        let signedDisplayName = (isSelf || verifiedViaRegistry) ? nil : env.signedSenderDisplayName(packet, peerID)
        guard isSelf || verifiedViaRegistry || signedDisplayName != nil else {
            SecureLogger.warning("🚫 Dropping public message with missing/invalid signature for claimed sender \(peerID.id.prefix(8))…", category: .security)
            return
        }

        // Authenticity is established; prefer the registry's collision-resolved
        // display name, then the signature-derived name.
        guard let senderNickname = BLEPeerSenderDisplayName.resolveKnownPeer(
            peerID: peerID,
            localPeerID: env.localPeerID(),
            localNickname: env.localNickname(),
            peers: peersSnapshot,
            allowConnectedUnverified: false
        ) ?? signedDisplayName else {
            SecureLogger.warning("🚫 Dropping public message from unknown peer \(peerID.id.prefix(8))…", category: .security)
            return
        }

        if messagePolicy.shouldTrackForSync {
            env.trackPacketSeen(packet)
        }

        guard let content = String(data: packet.payload, encoding: .utf8) else {
            SecureLogger.error("❌ Failed to decode message payload as UTF-8", category: .session)
            return
        }
        // Determine if we have a direct link to the sender
        let directLink = env.linkState(peerID)
        let hasDirectLink = directLink.hasPeripheral || directLink.hasCentral

        let pathTag = hasDirectLink ? "direct" : "mesh"
        SecureLogger.debug("💬 [\(senderNickname)] TTL:\(packet.ttl) (\(pathTag)) chars=\(content.count) bytes=\(packet.payload.count)", category: .session)

        let ts = Date(timeIntervalSince1970: Double(packet.timestamp) / 1000)
        var resolvedSelfMessageID: String? = nil
        if peerID == env.localPeerID() {
            resolvedSelfMessageID = env.takeSelfBroadcastMessageID(packet)
        }
        env.deliverPublicMessage(peerID, senderNickname, content, ts, resolvedSelfMessageID)
    }
}
