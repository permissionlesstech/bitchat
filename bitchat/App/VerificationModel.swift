import BitFoundation
import Combine
import Foundation

struct FingerprintPresentationState: Equatable {
    let peerNickname: String
    let encryptionStatus: EncryptionStatus
    let theirFingerprint: String?
    let myFingerprint: String
    let isVerified: Bool
    /// User-assigned local alias (petname), if any — distinct from the
    /// peer-claimed nickname.
    let localPetname: String?
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

    /// Alias field is editable once we know who we're looking at.
    var canEditLocalAlias: Bool {
        theirFingerprint != nil
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

    func identityVerificationCard() -> IdentityVerificationCard {
        IdentityVerificationCard.current(
            nickname: currentNickname,
            npub: try? chatViewModel.idBridge.getCurrentNostrIdentity()?.npub,
            noiseFingerprint: chatViewModel.getMyFingerprint()
        )
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

    /// Persist a local alias for this peer. Empty/whitespace clears it so the
    /// claimed nickname shows again. Display paths prefer `localPetname`
    /// when set (#1439).
    func setLocalPetname(_ petname: String?, for peerID: PeerID) {
        let statusPeerID = chatViewModel.getShortIDForNoiseKey(peerID)
        guard let fingerprint = chatViewModel.getFingerprint(for: statusPeerID) else { return }

        let trimmed = petname?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized: String? = (trimmed?.isEmpty == false) ? trimmed : nil

        let existing = chatViewModel.identityManager.getSocialIdentity(for: fingerprint)
        let claimed = existing?.claimedNickname
            ?? chatViewModel.meshService.peerNickname(peerID: statusPeerID)
            ?? chatViewModel.resolveNickname(for: statusPeerID)
        var identity = existing ?? SocialIdentity(
            fingerprint: fingerprint,
            localPetname: nil,
            claimedNickname: claimed,
            trustLevel: .unknown,
            isFavorite: false,
            isBlocked: false,
            notes: nil
        )
        identity.localPetname = normalized
        // Prefer the mesh-announced name for claimedNickname so we don't
        // persist a previous alias as the "claimed" identity.
        if let announced = chatViewModel.meshService.peerNickname(peerID: statusPeerID),
           !announced.isEmpty {
            identity.claimedNickname = announced
        } else if identity.claimedNickname.isEmpty {
            identity.claimedNickname = claimed
        }
        chatViewModel.identityManager.updateSocialIdentity(identity)
        // Rebuild peer rows so PeerList / DM header pick up the new display name
        // without waiting for an unrelated mesh event.
        chatViewModel.unifiedPeerService.refreshPeers()
        NotificationCenter.default.post(name: Notification.Name("peerStatusUpdated"), object: nil)
        objectWillChange.send()
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
        let localPetname = theirFingerprint
            .flatMap { chatViewModel.identityManager.getSocialIdentity(for: $0)?.localPetname }

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
            localPetname: localPetname,
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
        // Prefer an explicit local alias even when a live peer row exists —
        // peer.displayName already does this once UnifiedPeerService rebuilds,
        // but read social identity directly so the fingerprint sheet header
        // updates before that rebuild lands.
        if let fingerprint = chatViewModel.getFingerprint(for: statusPeerID),
           let pet = chatViewModel.identityManager.getSocialIdentity(for: fingerprint)?.localPetname,
           !pet.isEmpty {
            return pet
        }
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
                if !social.claimedNickname.isEmpty {
                    return social.claimedNickname
                }
            }
        }

        return String(localized: "common.unknown", comment: "Label for an unknown peer")
    }
}
