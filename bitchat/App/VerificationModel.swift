import BitFoundation
import Combine
import Foundation

struct FingerprintPresentationState: Equatable {
    let statusPeerID: PeerID
    let peerNickname: String
    let encryptionStatus: EncryptionStatus
    let theirFingerprint: String?
    let myFingerprint: String
    let isVerified: Bool

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
    private var cancellables = Set<AnyCancellable>()

    init(chatViewModel: ChatViewModel, privateConversationModel: PrivateConversationModel) {
        self.chatViewModel = chatViewModel
        self.currentNickname = chatViewModel.nickname
        self.selectedPeerID = privateConversationModel.selectedPeerID

        bind(privateConversationModel: privateConversationModel)
    }

    func myQRString() -> String {
        let npub = try? chatViewModel.idBridge.getCurrentNostrIdentity()?.npub
        return VerificationService.shared.buildMyQRString(nickname: currentNickname, npub: npub) ?? ""
    }

    func beginQRVerification(with qr: VerificationService.VerificationQR) -> Bool {
        chatViewModel.beginQRVerification(with: qr)
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
        return chatViewModel.verifiedFingerprints.contains(fingerprint)
    }

    func fingerprintPresentation(for peerID: PeerID) -> FingerprintPresentationState {
        let statusPeerID = chatViewModel.getShortIDForNoiseKey(peerID)
        let encryptionStatus = chatViewModel.getEncryptionStatus(for: statusPeerID)
        let theirFingerprint = chatViewModel.getFingerprint(for: statusPeerID)
        let peerNickname = resolveDisplayName(for: peerID, statusPeerID: statusPeerID)

        return FingerprintPresentationState(
            statusPeerID: statusPeerID,
            peerNickname: peerNickname,
            encryptionStatus: encryptionStatus,
            theirFingerprint: theirFingerprint,
            myFingerprint: chatViewModel.getMyFingerprint(),
            isVerified: theirFingerprint.map { chatViewModel.verifiedFingerprints.contains($0) } ?? false
        )
    }

    private func bind(privateConversationModel: PrivateConversationModel) {
        chatViewModel.$nickname
            .receive(on: DispatchQueue.main)
            .assign(to: &$currentNickname)

        privateConversationModel.$selectedPeerID
            .receive(on: DispatchQueue.main)
            .assign(to: &$selectedPeerID)

        chatViewModel.$peerEncryptionStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        chatViewModel.$verifiedFingerprints
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
