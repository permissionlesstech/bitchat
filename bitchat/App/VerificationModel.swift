import BitFoundation
import Combine
import Foundation

struct FingerprintPresentationState: Equatable {
    let peerNickname: String
    let encryptionStatus: EncryptionStatus
    let theirFingerprint: String?
    let myFingerprint: String
    let isVerified: Bool
    /// Number of currently-valid vouches from peers the user verified
    /// (0 when the peer is explicitly verified — the stronger badge wins).
    let voucherCount: Int
    /// Display names of the (verified) vouchers, where known.
    let voucherNames: [String]

    /// Vouched for by ≥1 peer the user verified (and not explicitly verified).
    var isVouched: Bool { voucherCount > 0 }

    var canToggleVerification: Bool {
        encryptionStatus == .noiseSecured || encryptionStatus == .noiseVerified
    }
}

enum VerificationScanOutcome: Equatable {
    case requested(String)
    case notFound
    case invalid
}

@MainActor
final class VerificationModel: ObservableObject {
    @Published private(set) var currentNickname: String
    @Published private(set) var selectedPeerID: PeerID?

    private let chatViewModel: ChatViewModel
    private let peerIdentityStore: PeerIdentityStore
    private var cancellables = Set<AnyCancellable>()

    init(
        chatViewModel: ChatViewModel,
        privateConversationModel: PrivateConversationModel,
        peerIdentityStore: PeerIdentityStore? = nil
    ) {
        self.chatViewModel = chatViewModel
        self.peerIdentityStore = peerIdentityStore ?? chatViewModel.peerIdentityStore
        self.currentNickname = chatViewModel.nickname
        self.selectedPeerID = privateConversationModel.selectedPeerID

        bind(privateConversationModel: privateConversationModel)
    }

    func myQRString() -> String {
        let npub = try? chatViewModel.idBridge.getCurrentNostrIdentity()?.npub
        return VerificationService.shared.buildMyQRString(nickname: currentNickname, npub: npub) ?? ""
    }

    func verifyScannedPayload(_ payload: String) -> VerificationScanOutcome {
        guard let qr = VerificationService.shared.verifyScannedQR(payload) else {
            return .invalid
        }

        guard chatViewModel.beginQRVerification(with: qr) else {
            return .notFound
        }

        return .requested(qr.nickname)
    }

    func verifyFingerprint(for peerID: PeerID) {
        chatViewModel.verifyFingerprint(for: peerID)
    }

    func unverifyFingerprint(for peerID: PeerID) {
        chatViewModel.unverifyFingerprint(for: peerID)
    }

    func isVerified(peerID: PeerID) -> Bool {
        guard let fingerprint = chatViewModel.getFingerprint(for: peerID) else { return false }
        return peerIdentityStore.isVerified(fingerprint)
    }

    func fingerprintPresentation(for peerID: PeerID) -> FingerprintPresentationState {
        let statusPeerID = chatViewModel.getShortIDForNoiseKey(peerID)
        let encryptionStatus = chatViewModel.getEncryptionStatus(for: statusPeerID)
        let theirFingerprint = chatViewModel.getFingerprint(for: statusPeerID)
        let peerNickname = resolveDisplayName(for: peerID, statusPeerID: statusPeerID)
        let isVerified = theirFingerprint.map { peerIdentityStore.isVerified($0) } ?? false

        // Vouch state is recomputed on read: only vouchers still in the
        // verified set count, so removing a verification silently retires the
        // vouches that peer gave.
        let vouchers: [VouchRecord]
        if !isVerified, let theirFingerprint {
            vouchers = chatViewModel.identityManager.validVouchers(for: theirFingerprint)
        } else {
            vouchers = []
        }
        let voucherNames = vouchers.compactMap { record -> String? in
            guard let social = chatViewModel.identityManager.getSocialIdentity(for: record.voucherFingerprint) else {
                return nil
            }
            if let petname = social.localPetname, !petname.isEmpty { return petname }
            return social.claimedNickname.isEmpty ? nil : social.claimedNickname
        }

        return FingerprintPresentationState(
            peerNickname: peerNickname,
            encryptionStatus: encryptionStatus,
            theirFingerprint: theirFingerprint,
            myFingerprint: chatViewModel.getMyFingerprint(),
            isVerified: isVerified,
            voucherCount: vouchers.count,
            voucherNames: voucherNames
        )
    }

    private func bind(privateConversationModel: PrivateConversationModel) {
        chatViewModel.$nickname
            .receive(on: DispatchQueue.main)
            .assign(to: &$currentNickname)

        privateConversationModel.$selectedPeerID
            .receive(on: DispatchQueue.main)
            .assign(to: &$selectedPeerID)

        peerIdentityStore.$encryptionStatuses
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        peerIdentityStore.$verifiedFingerprints
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        chatViewModel.$allPeers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        // Vouch state changes (ChatVouchCoordinator.notifyPeerTrustChanged)
        // are signalled via this notification rather than a published
        // property, so an open fingerprint sheet refreshes its vouched badge
        // live when a vouch batch is accepted.
        NotificationCenter.default.publisher(for: Notification.Name("peerStatusUpdated"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    private func resolveDisplayName(for peerID: PeerID, statusPeerID: PeerID) -> String {
        if let peer = chatViewModel.getPeer(byID: statusPeerID) {
            return peer.displayName
        }
        if let name = chatViewModel.meshService.peerNickname(peerID: statusPeerID) {
            return name
        }
        if let data = peerID.noiseKey {
            if let favorite = FavoritesPersistenceService.shared.getFavoriteStatus(for: data),
               !favorite.peerNickname.isEmpty {
                return favorite.peerNickname
            }
            let fingerprint = data.sha256Fingerprint()
            if let social = chatViewModel.identityManager.getSocialIdentity(for: fingerprint) {
                if let pet = social.localPetname, !pet.isEmpty {
                    return pet
                }
                if !social.claimedNickname.isEmpty {
                    return social.claimedNickname
                }
            }
        }

        return String(localized: "common.unknown", comment: "Label for an unknown peer")
    }
}
