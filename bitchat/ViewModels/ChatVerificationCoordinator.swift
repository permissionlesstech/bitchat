import BitFoundation
import BitLogger
import Foundation
import Security

/// The narrow surface `ChatVerificationCoordinator` needs from its owner.
///
/// Follows the `ChatDeliveryContext` exemplar: the coordinator depends on the
/// minimal context it actually uses instead of holding an `unowned` back-ref
/// to the whole `ChatViewModel`. This keeps the coordinator independently
/// testable (see `ChatVerificationCoordinatorContextTests`) and makes its true
/// dependencies explicit.
@MainActor
protocol ChatVerificationContext: AnyObject {
    // MARK: Fingerprints & verification state
    func getFingerprint(for peerID: PeerID) -> String?
    /// The UI-facing verified-fingerprint set (peer identity store backed).
    var verifiedFingerprints: Set<String> { get set }
    /// The persisted verified-fingerprint set from the identity manager.
    func persistedVerifiedFingerprints() -> Set<String>
    /// Persists the verified flag in the identity manager.
    func setIdentityVerified(fingerprint: String, verified: Bool)
    /// Updates the UI-facing verified flag in the peer identity store.
    func setStoredVerified(_ fingerprint: String, verified: Bool)
    func isVerifiedFingerprint(_ fingerprint: String) -> Bool
    func saveIdentityState()
    /// After a fingerprint becomes verified, run a transitive-vouch pass over
    /// currently connected peers (so verifying a peer you're already connected
    /// to sends vouches immediately, and the new identity propagates onward).
    func vouchToConnectedVerifiedPeers()

    // MARK: Encryption status
    func setEncryptionStatus(_ status: EncryptionStatus?, for peerID: PeerID)
    func updateEncryptionStatus(for peerID: PeerID)
    func invalidateEncryptionCache(for peerID: PeerID?)
    /// Signals that verification state changed so observers refresh (e.g. `objectWillChange.send()`).
    func notifyUIChanged()

    // MARK: Peers
    var unifiedPeers: [BitchatPeer] { get }
    var unifiedFavorites: [BitchatPeer] { get }
    /// The peer's current entry in the unified peer service, if known.
    func unifiedPeer(for peerID: PeerID) -> BitchatPeer?
    func unifiedFingerprint(for peerID: PeerID) -> String?
    func resolveNickname(for peerID: PeerID) -> String
    func cachedStablePeerID(for shortPeerID: PeerID) -> PeerID?
    func cacheStablePeerID(_ stablePeerID: PeerID, for shortPeerID: PeerID)

    // MARK: Noise sessions & verification transport
    /// Installs the Noise service's session callbacks (single registration point).
    func installNoiseSessionCallbacks(
        onPeerAuthenticated: @escaping (PeerID, String) -> Void,
        onHandshakeRequired: @escaping (PeerID) -> Void
    )
    /// Resolves the peer's Noise static key from the active Noise session, if any.
    func noiseSessionPublicKeyData(for peerID: PeerID) -> Data?
    /// Our own Noise static public key.
    func noiseStaticPublicKeyData() -> Data
    func hasEstablishedNoiseSession(with peerID: PeerID) -> Bool
    func triggerHandshake(with peerID: PeerID)
    func sendVerifyChallenge(to peerID: PeerID, noiseKeyHex: String, nonceA: Data)
    func sendVerifyResponse(to peerID: PeerID, noiseKeyHex: String, nonceA: Data)

    // MARK: Notifications (shared with `ChatNostrContext`)
    /// Posts a generic local user notification.
    func postLocalNotification(title: String, body: String, identifier: String)
}

extension ChatViewModel: ChatVerificationContext {
    // `getFingerprint(for:)`, `verifiedFingerprints`, `saveIdentityState()`,
    // `updateEncryptionStatus(for:)`, `invalidateEncryptionCache(for:)`,
    // `notifyUIChanged()`, `unifiedPeer(for:)`, `unifiedFingerprint(for:)`,
    // `isVerifiedFingerprint(_:)`, `setEncryptionStatus(_:for:)`,
    // `resolveNickname(for:)`, `cachedStablePeerID(for:)`,
    // `cacheStablePeerID(_:for:)`, `noiseSessionPublicKeyData(for:)`,
    // `hasEstablishedNoiseSession(with:)`, and `triggerHandshake(with:)` are
    // shared requirements with the other contexts or satisfied by existing
    // `ChatViewModel` members. The members below flatten nested service
    // accesses into intent-named calls.

    func persistedVerifiedFingerprints() -> Set<String> {
        identityManager.getVerifiedFingerprints()
    }

    func setIdentityVerified(fingerprint: String, verified: Bool) {
        identityManager.setVerified(fingerprint: fingerprint, verified: verified)
    }

    func setStoredVerified(_ fingerprint: String, verified: Bool) {
        peerIdentityStore.setVerified(fingerprint, verified: verified)
    }

    func vouchToConnectedVerifiedPeers() {
        vouchCoordinator.vouchToConnectedVerifiedPeers()
    }

    var unifiedPeers: [BitchatPeer] {
        unifiedPeerService.peers
    }

    var unifiedFavorites: [BitchatPeer] {
        unifiedPeerService.favorites
    }

    func installNoiseSessionCallbacks(
        onPeerAuthenticated: @escaping (PeerID, String) -> Void,
        onHandshakeRequired: @escaping (PeerID) -> Void
    ) {
        meshService.installNoiseSessionCallbacks(
            onPeerAuthenticated: onPeerAuthenticated,
            onHandshakeRequired: onHandshakeRequired
        )
    }

    func noiseStaticPublicKeyData() -> Data {
        meshService.noiseStaticPublicKeyData()
    }

    func sendVerifyChallenge(to peerID: PeerID, noiseKeyHex: String, nonceA: Data) {
        meshService.sendVerifyChallenge(to: peerID, noiseKeyHex: noiseKeyHex, nonceA: nonceA)
    }

    func sendVerifyResponse(to peerID: PeerID, noiseKeyHex: String, nonceA: Data) {
        meshService.sendVerifyResponse(to: peerID, noiseKeyHex: noiseKeyHex, nonceA: nonceA)
    }

    func postLocalNotification(title: String, body: String, identifier: String) {
        NotificationService.shared.sendLocalNotification(title: title, body: body, identifier: identifier)
    }
}

@MainActor
final class ChatVerificationCoordinator {
    struct PendingVerification {
        let noiseKeyHex: String
        let signKeyHex: String
        let nonceA: Data
        var sent: Bool
    }

    private unowned let context: any ChatVerificationContext
    private var pendingQRVerifications: [PeerID: PendingVerification] = [:]
    private var lastVerifyNonceByPeer: [PeerID: Data] = [:]
    private var lastInboundVerifyChallengeAt: [String: Date] = [:]
    private var lastMutualToastAt: [String: Date] = [:]

    init(context: any ChatVerificationContext) {
        self.context = context
    }

    func verifyFingerprint(for peerID: PeerID) {
        guard let fingerprint = context.getFingerprint(for: peerID) else { return }

        context.setIdentityVerified(fingerprint: fingerprint, verified: true)
        context.saveIdentityState()
        context.setStoredVerified(fingerprint, verified: true)
        context.updateEncryptionStatus(for: peerID)
        // Verifying a peer is a vouch trigger: push attestations to my other
        // connected verified peers (and to this one if already connected).
        context.vouchToConnectedVerifiedPeers()
    }

    func unverifyFingerprint(for peerID: PeerID) {
        guard let fingerprint = context.getFingerprint(for: peerID) else { return }
        context.setIdentityVerified(fingerprint: fingerprint, verified: false)
        context.saveIdentityState()
        context.setStoredVerified(fingerprint, verified: false)
        context.updateEncryptionStatus(for: peerID)
    }

    func loadVerifiedFingerprints() {
        context.verifiedFingerprints = context.persistedVerifiedFingerprints()
        let sample = Array(context.verifiedFingerprints.prefix(TransportConfig.uiFingerprintSampleCount))
            .map { $0.prefix(8) }
            .joined(separator: ", ")
        SecureLogger.info("🔐 Verified loaded: \(context.verifiedFingerprints.count) [\(sample)]", category: .security)

        let offlineFavorites = context.unifiedFavorites.filter { !$0.isConnected }
        for favorite in offlineFavorites {
            let fingerprint = context.unifiedFingerprint(for: favorite.peerID)
            let isVerified = fingerprint.flatMap { context.isVerifiedFingerprint($0) } ?? false
            let shortFingerprint = fingerprint?.prefix(8) ?? "nil"
            SecureLogger.info(
                "⭐️ Favorite offline: \(favorite.nickname) fp=\(shortFingerprint) verified=\(isVerified)",
                category: .security
            )
        }

        context.invalidateEncryptionCache(for: nil)
        context.notifyUIChanged()
    }

    func setupNoiseCallbacks() {
        context.installNoiseSessionCallbacks(
            onPeerAuthenticated: { [weak self] peerID, fingerprint in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }

                    SecureLogger.debug("🔐 Authenticated: \(peerID)", category: .security)

                    if self.context.isVerifiedFingerprint(fingerprint) {
                        self.context.setEncryptionStatus(.noiseVerified, for: peerID)
                    } else {
                        self.context.setEncryptionStatus(.noiseSecured, for: peerID)
                    }

                    self.context.invalidateEncryptionCache(for: peerID)

                    if self.context.cachedStablePeerID(for: peerID) == nil,
                       let keyData = self.context.noiseSessionPublicKeyData(for: peerID) {
                        let stablePeerID = PeerID(hexData: keyData)
                        self.context.cacheStablePeerID(stablePeerID, for: peerID)
                        SecureLogger.debug(
                            "🗺️ Mapped short peerID to Noise key for header continuity: \(peerID) -> \(stablePeerID.id.prefix(8))…",
                            category: .session
                        )
                    }

                    if var pending = self.pendingQRVerifications[peerID], pending.sent == false {
                        self.context.sendVerifyChallenge(
                            to: peerID,
                            noiseKeyHex: pending.noiseKeyHex,
                            nonceA: pending.nonceA
                        )
                        pending.sent = true
                        self.pendingQRVerifications[peerID] = pending
                        SecureLogger.debug("📤 Sent deferred verify challenge to \(peerID) after handshake", category: .security)
                    }
                }
            },
            onHandshakeRequired: { [weak self] peerID in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.context.setEncryptionStatus(.noiseHandshaking, for: peerID)
                    self.context.invalidateEncryptionCache(for: peerID)
                }
            }
        )
    }

    func beginQRVerification(with qr: VerificationService.VerificationQR) -> Bool {
        let targetNoise = qr.noiseKeyHex.lowercased()
        guard let peer = context.unifiedPeers.first(where: {
            $0.noisePublicKey.hexEncodedString().lowercased() == targetNoise
        }) else {
            return false
        }

        let peerID = peer.peerID
        if pendingQRVerifications[peerID] != nil {
            return true
        }

        var nonce = Data(count: 16)
        _ = nonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        var pending = PendingVerification(
            noiseKeyHex: qr.noiseKeyHex,
            signKeyHex: qr.signKeyHex,
            nonceA: nonce,
            sent: false
        )
        pendingQRVerifications[peerID] = pending

        if context.hasEstablishedNoiseSession(with: peerID) {
            context.sendVerifyChallenge(to: peerID, noiseKeyHex: qr.noiseKeyHex, nonceA: nonce)
            pending.sent = true
            pendingQRVerifications[peerID] = pending
        } else {
            context.triggerHandshake(with: peerID)
        }

        return true
    }

    func handleVerifyChallengePayload(from peerID: PeerID, payload: Data) {
        guard let challenge = VerificationService.shared.parseVerifyChallenge(payload) else { return }

        let myNoiseHex = context.noiseStaticPublicKeyData()
            .hexEncodedString()
            .lowercased()
        guard challenge.noiseKeyHex.lowercased() == myNoiseHex else { return }
        guard lastVerifyNonceByPeer[peerID] != challenge.nonceA else { return }

        lastVerifyNonceByPeer[peerID] = challenge.nonceA

        if let fingerprint = context.getFingerprint(for: peerID) {
            lastInboundVerifyChallengeAt[fingerprint] = Date()

            if context.isVerifiedFingerprint(fingerprint) {
                maybeSendMutualVerificationNotification(
                    fingerprint: fingerprint,
                    peerID: peerID,
                    title: "Mutual verification",
                    bodyName: context.unifiedPeer(for: peerID)?.nickname
                        ?? context.resolveNickname(for: peerID),
                    notificationPrefix: "verify-mutual"
                )
            }
        }

        context.sendVerifyResponse(
            to: peerID,
            noiseKeyHex: challenge.noiseKeyHex,
            nonceA: challenge.nonceA
        )
    }

    func handleVerifyResponsePayload(from peerID: PeerID, payload: Data) {
        guard let response = VerificationService.shared.parseVerifyResponse(payload),
              let pending = pendingQRVerifications[peerID],
              response.noiseKeyHex.lowercased() == pending.noiseKeyHex.lowercased(),
              response.nonceA == pending.nonceA else { return }

        let isValid = VerificationService.shared.verifyResponseSignature(
            noiseKeyHex: response.noiseKeyHex,
            nonceA: response.nonceA,
            signature: response.signature,
            signerPublicKeyHex: pending.signKeyHex
        )
        guard isValid else { return }

        pendingQRVerifications.removeValue(forKey: peerID)

        guard let fingerprint = context.getFingerprint(for: peerID) else { return }

        let shortFingerprint = fingerprint.prefix(8)
        SecureLogger.info("🔐 Marking verified fingerprint: \(shortFingerprint)", category: .security)
        context.setIdentityVerified(fingerprint: fingerprint, verified: true)
        context.saveIdentityState()
        context.setStoredVerified(fingerprint, verified: true)

        let peerName = context.unifiedPeer(for: peerID)?.nickname
            ?? context.resolveNickname(for: peerID)
        context.postLocalNotification(
            title: "Verified",
            body: "You verified \(peerName)",
            identifier: "verify-success-\(peerID)-\(UUID().uuidString)"
        )

        if let challengeTime = lastInboundVerifyChallengeAt[fingerprint],
           Date().timeIntervalSince(challengeTime) < 600 {
            maybeSendMutualVerificationNotification(
                fingerprint: fingerprint,
                peerID: peerID,
                title: "Mutual verification",
                bodyName: peerName,
                notificationPrefix: "verify-mutual"
            )
        }

        context.updateEncryptionStatus(for: peerID)
        // QR verification just completed — same vouch trigger as manual verify.
        context.vouchToConnectedVerifiedPeers()
    }
}

private extension ChatVerificationCoordinator {
    func maybeSendMutualVerificationNotification(
        fingerprint: String,
        peerID: PeerID,
        title: String,
        bodyName: String,
        notificationPrefix: String
    ) {
        let now = Date()
        let lastToast = lastMutualToastAt[fingerprint] ?? .distantPast
        guard now.timeIntervalSince(lastToast) > 60 else { return }

        lastMutualToastAt[fingerprint] = now
        context.postLocalNotification(
            title: title,
            body: "You and \(bodyName) verified each other",
            identifier: "\(notificationPrefix)-\(peerID)-\(UUID().uuidString)"
        )
    }
}
