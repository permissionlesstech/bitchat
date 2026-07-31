import BitFoundation
import BitLogger
import Foundation

/// The narrow surface `ChatVouchCoordinator` needs from its owner.
///
/// Follows the `ChatDeliveryContext` exemplar: the coordinator depends on the
/// minimal context it actually uses instead of holding an `unowned` back-ref
/// to the whole `ChatViewModel`. This keeps the coordinator independently
/// testable (see `ChatVouchCoordinatorContextTests`) and makes its true
/// dependencies explicit.
@MainActor
protocol ChatVouchContext: AnyObject {
    // MARK: Identity & trust state
    func getFingerprint(for peerID: PeerID) -> String?
    func isVerifiedFingerprint(_ fingerprint: String) -> Bool
    /// The peer's announce-bound Ed25519 signing key, if known this session.
    func signingKey(forFingerprint fingerprint: String) -> Data?
    /// Verified fingerprints ordered most recently verified first.
    func recentlyVerifiedFingerprints(limit: Int, excluding fingerprint: String) -> [String]
    /// Stores an accepted vouch (identity manager enforces the storage gates).
    @discardableResult
    func recordVouch(voucheeFingerprint: String, voucherFingerprint: String, timestamp: Date) -> Bool
    func lastVouchBatchSent(to fingerprint: String) -> Date?
    func markVouchBatchSent(to fingerprint: String, at date: Date)

    // MARK: Transport
    func peerCapabilities(for peerID: PeerID) -> PeerCapabilities
    /// PeerIDs with a currently established mesh session (used to run a vouch
    /// pass over peers we are already connected to when we verify someone).
    func connectedPeerIDs() -> [PeerID]
    /// Appends a session-established observer (additive; never displaces the
    /// verification coordinator's callbacks).
    func addPeerAuthenticatedObserver(_ handler: @escaping (PeerID, String) -> Void)
    /// Signs `data` with our Noise (Ed25519) signing key.
    func noiseSignData(_ data: Data) -> Data?
    func sendVouchAttestations(_ payload: Data, to peerID: PeerID)

    // MARK: UI refresh
    /// Signals that derived trust state changed so peer list / fingerprint
    /// views recompute badges.
    func notifyPeerTrustChanged()
}

extension ChatViewModel: ChatVouchContext {
    // `getFingerprint(for:)` and `isVerifiedFingerprint(_:)` are shared
    // requirements with the verification context and satisfied by existing
    // `ChatViewModel` members. The members below flatten nested service
    // accesses into intent-named calls.

    func signingKey(forFingerprint fingerprint: String) -> Data? {
        identityManager.signingPublicKey(forFingerprint: fingerprint)
    }

    func recentlyVerifiedFingerprints(limit: Int, excluding fingerprint: String) -> [String] {
        identityManager.mostRecentlyVerifiedFingerprints(limit: limit, excluding: fingerprint)
    }

    @discardableResult
    func recordVouch(voucheeFingerprint: String, voucherFingerprint: String, timestamp: Date) -> Bool {
        identityManager.recordVouch(
            voucheeFingerprint: voucheeFingerprint,
            voucherFingerprint: voucherFingerprint,
            timestamp: timestamp
        )
    }

    func lastVouchBatchSent(to fingerprint: String) -> Date? {
        identityManager.lastVouchBatchSent(to: fingerprint)
    }

    func markVouchBatchSent(to fingerprint: String, at date: Date) {
        identityManager.markVouchBatchSent(to: fingerprint, at: date)
    }

    func peerCapabilities(for peerID: PeerID) -> PeerCapabilities {
        meshService.peerCapabilities(peerID)
    }

    func connectedPeerIDs() -> [PeerID] {
        Array(connectedPeers)
    }

    func addPeerAuthenticatedObserver(_ handler: @escaping (PeerID, String) -> Void) {
        meshService.addPeerAuthenticatedObserver(handler)
    }

    func noiseSignData(_ data: Data) -> Data? {
        meshService.noiseSignData(data)
    }

    func sendVouchAttestations(_ payload: Data, to peerID: PeerID) {
        meshService.sendVouchAttestations(payload, to: peerID)
    }

    func notifyPeerTrustChanged() {
        // PeerListModel refreshes on this notification; the view-model change
        // covers FingerprintView / VerificationModel consumers.
        NotificationCenter.default.post(name: Notification.Name("peerStatusUpdated"), object: nil)
        notifyUIChanged()
    }
}

/// Transitive verification ("vouching"): when a Noise session comes up with a
/// peer I verified, I attest — over that authenticated, encrypted session —
/// to the other identities I have verified. Receivers accept such vouches
/// only from peers *they* verified, giving a serverless
/// verified-by-people-you-verified tier (`TrustLevel.vouched`).
@MainActor
final class ChatVouchCoordinator {
    /// Minimum spacing between vouch batches to the same peer (persisted).
    static let batchInterval: TimeInterval = 24 * 60 * 60

    private unowned let context: any ChatVouchContext

    init(context: any ChatVouchContext) {
        self.context = context
    }

    /// Registers the session-established hook. Additive alongside the
    /// verification coordinator's callbacks; call once at bootstrap.
    func setupNoiseCallbacks() {
        context.addPeerAuthenticatedObserver { [weak self] peerID, fingerprint in
            DispatchQueue.main.async { [weak self] in
                self?.peerAuthenticated(peerID, fingerprint: fingerprint)
            }
        }
    }

    /// Trigger — session established: on a Noise session coming up with a peer
    /// I verified, attempt to send a vouch batch. Kept as the historical entry
    /// point; the real work lives in `attemptVouch`.
    func peerAuthenticated(_ peerID: PeerID, fingerprint: String, now: Date = Date()) {
        attemptVouch(to: peerID, fingerprint: fingerprint, now: now)
    }

    /// Trigger — verified announce processed: a peer's `.vouch` capability
    /// arrives on its *announce*, which is handled independently of the Noise
    /// handshake. This is invoked on every peer-list update (fired after each
    /// verified announce), so it closes the capability race — the batch that
    /// `peerAuthenticated` couldn't send (capabilities not yet known) goes out
    /// once the capability-bearing announce lands. Throttled per peer.
    func peersUpdated(_ peerIDs: [PeerID], now: Date = Date()) {
        for peerID in peerIDs {
            guard let fingerprint = context.getFingerprint(for: peerID) else { continue }
            attemptVouch(to: peerID, fingerprint: fingerprint, now: now)
        }
    }

    /// Trigger — local verification completed: the user just verified a peer.
    /// Run a vouch pass over every currently connected peer I verified. This
    /// makes vouching fire when verifying someone already connected (whose
    /// session is authenticated, so `peerAuthenticated` never re-fires), and it
    /// propagates the newly-verified identity to my other verified peers.
    /// Throttled per peer by `batchInterval`, so it can't spam.
    func vouchToConnectedVerifiedPeers(now: Date = Date()) {
        var sentCount = 0
        for peerID in context.connectedPeerIDs() {
            guard let fingerprint = context.getFingerprint(for: peerID) else { continue }
            if attemptVouch(to: peerID, fingerprint: fingerprint, now: now) {
                sentCount += 1
            }
        }
        if sentCount > 0 {
            SecureLogger.info(
                "🪪 verify-triggered vouch pass sent to \(sentCount) connected peer(s)",
                category: .security
            )
        }
    }

    /// Exchange policy shared by every trigger: to a peer I verified, send
    /// attestations for up to `VouchAttestation.maxBatchCount` *other* verified
    /// fingerprints (most recently verified first), at most once per peer per
    /// `batchInterval`. Returns whether a batch was actually sent.
    @discardableResult
    func attemptVouch(to peerID: PeerID, fingerprint: String, now: Date = Date()) -> Bool {
        guard context.isVerifiedFingerprint(fingerprint) else { return false }

        // Capability gate, race-tolerant: a peer's `.vouch` bit is carried on
        // its announce, processed independently of the Noise handshake, so at
        // authentication time the capability set is frequently still empty.
        // Treat an empty/unknown set as eligible — the payload is a Noise
        // `0x12` (`NoisePayloadType.vouch`) that non-supporting peers harmlessly
        // ignore, so sending on an unknown set is safe and avoids the race
        // dropping the batch. Only skip when the peer advertised a non-empty
        // capability set that explicitly lacks `.vouch`.
        let capabilities = context.peerCapabilities(for: peerID)
        if !capabilities.isEmpty, !capabilities.contains(.vouch) { return false }

        if let lastSent = context.lastVouchBatchSent(to: fingerprint),
           now.timeIntervalSince(lastSent) < Self.batchInterval {
            return false
        }

        let candidates = context.recentlyVerifiedFingerprints(
            limit: VouchAttestation.maxBatchCount,
            excluding: fingerprint
        )
        var attestations: [VouchAttestation] = []
        for candidate in candidates {
            // Only fingerprints whose announce-bound signing key we know can
            // be anchored to a concrete identity; skip the rest.
            guard let fingerprintData = Data(hexString: candidate),
                  fingerprintData.count == VouchAttestation.fingerprintSize,
                  let signingKey = context.signingKey(forFingerprint: candidate),
                  signingKey.count == VouchAttestation.signingKeySize,
                  let attestation = VouchAttestation.build(
                      voucheeFingerprint: fingerprintData,
                      voucheeSigningKey: signingKey,
                      timestampMs: UInt64(now.timeIntervalSince1970 * 1000),
                      sign: context.noiseSignData
                  ) else {
                continue
            }
            attestations.append(attestation)
        }

        guard !attestations.isEmpty,
              let payload = VouchAttestation.encodeList(attestations) else { return false }
        context.sendVouchAttestations(payload, to: peerID)
        context.markVouchBatchSent(to: fingerprint, at: now)
        SecureLogger.debug(
            "🪪 Sent \(attestations.count) vouch attestation(s) to \(peerID.id.prefix(8))…",
            category: .security
        )
        return true
    }

    /// Accept policy: process inbound vouches only from a sender I verified,
    /// only with a valid Ed25519 signature under the sender's announce-bound
    /// signing key, and only within the validity window. Self-vouches and
    /// vouches for already-verified peers are dropped by the identity
    /// manager's storage gates.
    func handleVouchPayload(from peerID: PeerID, payload: Data, now: Date = Date()) {
        guard let senderFingerprint = context.getFingerprint(for: peerID),
              context.isVerifiedFingerprint(senderFingerprint) else {
            SecureLogger.debug(
                "🪪 Ignoring vouch payload from unverified peer \(peerID.id.prefix(8))…",
                category: .security
            )
            return
        }
        guard let senderSigningKey = context.signingKey(forFingerprint: senderFingerprint) else {
            SecureLogger.debug(
                "🪪 No signing key for vouching peer \(peerID.id.prefix(8))…; dropping batch",
                category: .security
            )
            return
        }

        var acceptedCount = 0
        for attestation in VouchAttestation.decodeList(from: payload) {
            guard attestation.verifySignature(voucherSigningKey: senderSigningKey),
                  !attestation.isExpired(now: now) else { continue }
            let stored = context.recordVouch(
                voucheeFingerprint: attestation.voucheeFingerprintHex,
                voucherFingerprint: senderFingerprint,
                timestamp: attestation.timestamp
            )
            if stored { acceptedCount += 1 }
        }

        if acceptedCount > 0 {
            SecureLogger.info(
                "🪪 Accepted \(acceptedCount) vouch(es) from \(senderFingerprint.prefix(8))…",
                category: .security
            )
            context.notifyPeerTrustChanged()
        }
    }
}
