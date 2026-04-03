import BitLogger
import Foundation
import Security

@MainActor
final class VerificationStore: ObservableObject, VerificationStoreProtocol {
    private struct PendingVerification {
        let noiseKeyHex: String
        let signKeyHex: String
        let nonceA: Data
        let startedAt: Date
        var sent: Bool
    }

    private let meshService: Transport
    private let peerStore: UnifiedPeerService
    private let peerPresentationStore: PeerPresentationStore
    private let sessionStore: SessionStore
    private let idBridge: NostrIdentityBridge

    private var pendingQRVerifications: [PeerID: PendingVerification] = [:]
    private var lastVerifyNonceByPeer: [PeerID: Data] = [:]
    private var lastInboundVerifyChallengeAt: [String: Date] = [:]
    private var lastMutualToastAt: [String: Date] = [:]

    init(
        meshService: Transport,
        peerStore: UnifiedPeerService,
        peerPresentationStore: PeerPresentationStore,
        sessionStore: SessionStore,
        idBridge: NostrIdentityBridge
    ) {
        self.meshService = meshService
        self.peerStore = peerStore
        self.peerPresentationStore = peerPresentationStore
        self.sessionStore = sessionStore
        self.idBridge = idBridge

        VerificationService.shared.configure(with: meshService.getNoiseService())
    }

    func myQRString() -> String {
        let npub = try? idBridge.getCurrentNostrIdentity()?.npub
        return VerificationService.shared.buildMyQRString(nickname: sessionStore.nickname, npub: npub) ?? ""
    }

    func warmQRCodeCache() {
        _ = myQRString()
    }

    func beginQRVerification(with qr: VerificationService.VerificationQR) -> Bool {
        let targetNoise = qr.noiseKeyHex.lowercased()
        guard let peer = peerStore.peers.first(where: { $0.noisePublicKey.hexEncodedString().lowercased() == targetNoise }) else {
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

        if meshService.getNoiseService().hasEstablishedSession(with: peerID) {
            meshService.sendVerifyChallenge(to: peerID, noiseKeyHex: qr.noiseKeyHex, nonceA: nonce)
            pending.sent = true
            pendingQRVerifications[peerID] = pending
        } else {
            meshService.triggerHandshake(with: peerID)
        }

        return true
    }

    func handlePeerAuthenticated(_ peerID: PeerID) {
        guard var pending = pendingQRVerifications[peerID], pending.sent == false else { return }
        meshService.sendVerifyChallenge(to: peerID, noiseKeyHex: pending.noiseKeyHex, nonceA: pending.nonceA)
        pending.sent = true
        pendingQRVerifications[peerID] = pending
        SecureLogger.debug("📤 Sent deferred verify challenge to \(peerID) after handshake", category: .security)
    }

    func handleVerificationPayload(_ type: NoisePayloadType, payload: Data, from peerID: PeerID) {
        switch type {
        case .verifyChallenge:
            handleVerifyChallenge(payload, from: peerID)
        case .verifyResponse:
            handleVerifyResponse(payload, from: peerID)
        case .privateMessage, .readReceipt, .delivered:
            return
        }
    }
}

private extension VerificationStore {
    func handleVerifyChallenge(_ payload: Data, from peerID: PeerID) {
        guard let tlv = VerificationService.shared.parseVerifyChallenge(payload) else { return }

        let myNoiseHex = meshService.getNoiseService().getStaticPublicKeyData().hexEncodedString().lowercased()
        guard tlv.noiseKeyHex.lowercased() == myNoiseHex else { return }

        if let lastNonce = lastVerifyNonceByPeer[peerID], lastNonce == tlv.nonceA {
            return
        }
        lastVerifyNonceByPeer[peerID] = tlv.nonceA

        if let fingerprint = peerPresentationStore.fingerprint(for: peerID) {
            lastInboundVerifyChallengeAt[fingerprint] = Date()

            if peerPresentationStore.isVerified(peerID: peerID) {
                sendMutualVerificationNotification(
                    peerID: peerID,
                    displayName: peerPresentationStore.displayName(for: peerID),
                    fingerprint: fingerprint
                )
            }
        }

        meshService.sendVerifyResponse(to: peerID, noiseKeyHex: tlv.noiseKeyHex, nonceA: tlv.nonceA)
    }

    func handleVerifyResponse(_ payload: Data, from peerID: PeerID) {
        guard let response = VerificationService.shared.parseVerifyResponse(payload) else { return }
        guard let pending = pendingQRVerifications[peerID] else { return }
        guard response.noiseKeyHex.lowercased() == pending.noiseKeyHex.lowercased(),
              response.nonceA == pending.nonceA else {
            return
        }

        let verifiedSignature = VerificationService.shared.verifyResponseSignature(
            noiseKeyHex: response.noiseKeyHex,
            nonceA: response.nonceA,
            signature: response.signature,
            signerPublicKeyHex: pending.signKeyHex
        )
        guard verifiedSignature else { return }

        pendingQRVerifications.removeValue(forKey: peerID)

        guard let fingerprint = peerPresentationStore.fingerprint(for: peerID) else { return }

        SecureLogger.info("🔐 Marking verified fingerprint: \(fingerprint.prefix(8))", category: .security)
        peerPresentationStore.verifyFingerprint(for: peerID)

        let displayName = peerPresentationStore.displayName(for: peerID)
        NotificationService.shared.sendLocalNotification(
            title: "Verified",
            body: "You verified \(displayName)",
            identifier: "verify-success-\(peerID)-\(UUID().uuidString)"
        )

        if let challengeTime = lastInboundVerifyChallengeAt[fingerprint],
           Date().timeIntervalSince(challengeTime) < 600 {
            sendMutualVerificationNotification(
                peerID: peerID,
                displayName: displayName,
                fingerprint: fingerprint
            )
        }
    }

    func sendMutualVerificationNotification(peerID: PeerID, displayName: String, fingerprint: String) {
        let now = Date()
        let lastToast = lastMutualToastAt[fingerprint] ?? .distantPast
        guard now.timeIntervalSince(lastToast) > 60 else { return }

        lastMutualToastAt[fingerprint] = now
        NotificationService.shared.sendLocalNotification(
            title: "Mutual verification",
            body: "You and \(displayName) verified each other",
            identifier: "verify-mutual-\(peerID)-\(UUID().uuidString)"
        )
    }
}
