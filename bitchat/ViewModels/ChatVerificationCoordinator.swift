import BitFoundation
import BitLogger
import Foundation
import Security

@MainActor
final class ChatVerificationCoordinator {
    struct PendingVerification {
        let noiseKeyHex: String
        let signKeyHex: String
        let nonceA: Data
        let startedAt: Date
        var sent: Bool
    }

    private unowned let viewModel: ChatViewModel
    private var pendingQRVerifications: [PeerID: PendingVerification] = [:]
    private var lastVerifyNonceByPeer: [PeerID: Data] = [:]
    private var lastInboundVerifyChallengeAt: [String: Date] = [:]
    private var lastMutualToastAt: [String: Date] = [:]

    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
    }

    func verifyFingerprint(for peerID: PeerID) {
        guard let fingerprint = viewModel.getFingerprint(for: peerID) else { return }

        viewModel.identityManager.setVerified(fingerprint: fingerprint, verified: true)
        viewModel.saveIdentityState()
        viewModel.peerIdentityStore.setVerified(fingerprint, verified: true)
        viewModel.updateEncryptionStatus(for: peerID)
    }

    func unverifyFingerprint(for peerID: PeerID) {
        guard let fingerprint = viewModel.getFingerprint(for: peerID) else { return }
        viewModel.identityManager.setVerified(fingerprint: fingerprint, verified: false)
        viewModel.saveIdentityState()
        viewModel.peerIdentityStore.setVerified(fingerprint, verified: false)
        viewModel.updateEncryptionStatus(for: peerID)
    }

    func loadVerifiedFingerprints() {
        viewModel.peerIdentityStore.setVerifiedFingerprints(viewModel.identityManager.getVerifiedFingerprints())
        let sample = Array(viewModel.peerIdentityStore.verifiedFingerprints.prefix(TransportConfig.uiFingerprintSampleCount))
            .map { $0.prefix(8) }
            .joined(separator: ", ")
        SecureLogger.info("🔐 Verified loaded: \(viewModel.peerIdentityStore.verifiedFingerprints.count) [\(sample)]", category: .security)

        let offlineFavorites = viewModel.unifiedPeerService.favorites.filter { !$0.isConnected }
        for favorite in offlineFavorites {
            let fingerprint = viewModel.unifiedPeerService.getFingerprint(for: favorite.peerID)
            let isVerified = fingerprint.flatMap { viewModel.peerIdentityStore.isVerified($0) } ?? false
            let shortFingerprint = fingerprint?.prefix(8) ?? "nil"
            SecureLogger.info(
                "⭐️ Favorite offline: \(favorite.nickname) fp=\(shortFingerprint) verified=\(isVerified)",
                category: .security
            )
        }

        viewModel.invalidateEncryptionCache()
        viewModel.objectWillChange.send()
    }

    func setupNoiseCallbacks() {
        let noiseService = viewModel.meshService.getNoiseService()

        noiseService.onPeerAuthenticated = { [weak self] peerID, fingerprint in
            DispatchQueue.main.async {
                guard let self else { return }

                SecureLogger.debug("🔐 Authenticated: \(peerID)", category: .security)

                if self.viewModel.peerIdentityStore.isVerified(fingerprint) {
                    self.viewModel.peerIdentityStore.setEncryptionStatus(.noiseVerified, for: peerID)
                } else {
                    self.viewModel.peerIdentityStore.setEncryptionStatus(.noiseSecured, for: peerID)
                }

                self.viewModel.invalidateEncryptionCache(for: peerID)

                if self.viewModel.cachedStablePeerID(for: peerID) == nil,
                   let keyData = self.viewModel.meshService.getNoiseService().getPeerPublicKeyData(peerID) {
                    let stablePeerID = PeerID(hexData: keyData)
                    self.viewModel.cacheStablePeerID(stablePeerID, for: peerID)
                    SecureLogger.debug(
                        "🗺️ Mapped short peerID to Noise key for header continuity: \(peerID) -> \(stablePeerID.id.prefix(8))…",
                        category: .session
                    )
                }

                if var pending = self.pendingQRVerifications[peerID], pending.sent == false {
                    self.viewModel.meshService.sendVerifyChallenge(
                        to: peerID,
                        noiseKeyHex: pending.noiseKeyHex,
                        nonceA: pending.nonceA
                    )
                    pending.sent = true
                    self.pendingQRVerifications[peerID] = pending
                    SecureLogger.debug("📤 Sent deferred verify challenge to \(peerID) after handshake", category: .security)
                }
            }
        }

        noiseService.onHandshakeRequired = { [weak self] peerID in
            DispatchQueue.main.async {
                guard let self else { return }
                self.viewModel.peerIdentityStore.setEncryptionStatus(.noiseHandshaking, for: peerID)
                self.viewModel.invalidateEncryptionCache(for: peerID)
            }
        }
    }

    func beginQRVerification(with qr: VerificationService.VerificationQR) -> Bool {
        let targetNoise = qr.noiseKeyHex.lowercased()
        guard let peer = viewModel.unifiedPeerService.peers.first(where: {
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
            startedAt: Date(),
            sent: false
        )
        pendingQRVerifications[peerID] = pending

        let noise = viewModel.meshService.getNoiseService()
        if noise.hasEstablishedSession(with: peerID) {
            viewModel.meshService.sendVerifyChallenge(to: peerID, noiseKeyHex: qr.noiseKeyHex, nonceA: nonce)
            pending.sent = true
            pendingQRVerifications[peerID] = pending
        } else {
            viewModel.meshService.triggerHandshake(with: peerID)
        }

        return true
    }

    func handleVerifyChallengePayload(from peerID: PeerID, payload: Data) {
        guard let challenge = VerificationService.shared.parseVerifyChallenge(payload) else { return }

        let myNoiseHex = viewModel.meshService
            .getNoiseService()
            .getStaticPublicKeyData()
            .hexEncodedString()
            .lowercased()
        guard challenge.noiseKeyHex.lowercased() == myNoiseHex else { return }
        guard lastVerifyNonceByPeer[peerID] != challenge.nonceA else { return }

        lastVerifyNonceByPeer[peerID] = challenge.nonceA

        if let fingerprint = viewModel.getFingerprint(for: peerID) {
            lastInboundVerifyChallengeAt[fingerprint] = Date()

            if viewModel.peerIdentityStore.isVerified(fingerprint) {
                maybeSendMutualVerificationNotification(
                    fingerprint: fingerprint,
                    peerID: peerID,
                    title: "Mutual verification",
                    bodyName: viewModel.unifiedPeerService.getPeer(by: peerID)?.nickname
                        ?? viewModel.resolveNickname(for: peerID),
                    notificationPrefix: "verify-mutual"
                )
            }
        }

        viewModel.meshService.sendVerifyResponse(
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

        guard let fingerprint = viewModel.getFingerprint(for: peerID) else { return }

        let shortFingerprint = fingerprint.prefix(8)
        SecureLogger.info("🔐 Marking verified fingerprint: \(shortFingerprint)", category: .security)
        viewModel.identityManager.setVerified(fingerprint: fingerprint, verified: true)
        viewModel.saveIdentityState()
        viewModel.peerIdentityStore.setVerified(fingerprint, verified: true)

        let peerName = viewModel.unifiedPeerService.getPeer(by: peerID)?.nickname
            ?? viewModel.resolveNickname(for: peerID)
        NotificationService.shared.sendLocalNotification(
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

        viewModel.updateEncryptionStatus(for: peerID)
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
        NotificationService.shared.sendLocalNotification(
            title: title,
            body: "You and \(bodyName) verified each other",
            identifier: "\(notificationPrefix)-\(peerID)-\(UUID().uuidString)"
        )
    }
}
