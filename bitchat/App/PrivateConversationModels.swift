import BitFoundation
import Combine
import Foundation

@MainActor
final class PrivateInboxModel: ObservableObject {
    @Published private(set) var selectedPeerID: PeerID?
    @Published private(set) var unreadPeerIDs: Set<PeerID> = []
    @Published private(set) var messagesByPeerID: [PeerID: [BitchatMessage]] = [:]

    private let conversationStore: ConversationStore
    private var cancellables = Set<AnyCancellable>()

    init(conversationStore: ConversationStore) {
        self.conversationStore = conversationStore

        bind()
        refreshMessages()
    }

    func messages(for peerID: PeerID?) -> [BitchatMessage] {
        guard let peerID else { return [] }
        return messagesByPeerID[peerID] ?? []
    }

    private func bind() {
        conversationStore.$selectedPrivatePeerID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] peerID in
                self?.selectedPeerID = peerID
                self?.refreshMessages()
            }
            .store(in: &cancellables)

        conversationStore.$unreadConversations
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.unreadPeerIDs = self?.conversationStore.unreadDirectPeerIDs() ?? []
                self?.refreshMessages()
            }
            .store(in: &cancellables)

        conversationStore.$messagesByConversation
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshMessages()
            }
            .store(in: &cancellables)

        selectedPeerID = conversationStore.selectedPrivatePeerID
        unreadPeerIDs = conversationStore.unreadDirectPeerIDs()
    }

    private func refreshMessages() {
        var nextMessagesByPeerID = conversationStore.directMessagesByPeerID()
        var peerIDs = Set(nextMessagesByPeerID.keys)
        peerIDs.formUnion(conversationStore.unreadDirectPeerIDs())
        if let selectedPeerID = conversationStore.selectedPrivatePeerID {
            peerIDs.insert(selectedPeerID)
        }

        for peerID in peerIDs where nextMessagesByPeerID[peerID] == nil {
            nextMessagesByPeerID[peerID] = []
        }

        messagesByPeerID = nextMessagesByPeerID
    }
}

enum PrivateConversationAvailability: Equatable {
    case bluetoothConnected
    case meshReachable
    case nostrAvailable
    case offline
}

struct PrivateConversationHeaderState: Equatable {
    let conversationPeerID: PeerID
    let headerPeerID: PeerID
    let displayName: String
    let availability: PrivateConversationAvailability
    let isFavorite: Bool
    let encryptionStatus: EncryptionStatus?

    var supportsFavoriteToggle: Bool {
        !conversationPeerID.isGeoDM
    }
}

@MainActor
final class PrivateConversationModel: ObservableObject {
    @Published private(set) var selectedPeerID: PeerID?
    @Published private(set) var selectedHeaderState: PrivateConversationHeaderState?

    private let chatViewModel: ChatViewModel
    private let conversationStore: ConversationStore
    private let locationChannelsModel: LocationChannelsModel
    private let peerIdentityStore: PeerIdentityStore
    private var cancellables = Set<AnyCancellable>()

    init(
        chatViewModel: ChatViewModel,
        conversationStore: ConversationStore,
        locationChannelsModel: LocationChannelsModel? = nil,
        peerIdentityStore: PeerIdentityStore? = nil
    ) {
        self.chatViewModel = chatViewModel
        self.conversationStore = conversationStore
        self.locationChannelsModel = locationChannelsModel ?? LocationChannelsModel()
        self.peerIdentityStore = peerIdentityStore ?? chatViewModel.peerIdentityStore
        let initialPeerID = conversationStore.selectedPrivatePeerID
        self.selectedPeerID = initialPeerID
        self.selectedHeaderState = initialPeerID.flatMap { peerID in
            makeHeaderState(for: peerID)
        }

        bind()
    }

    func startConversation(with peerID: PeerID) {
        chatViewModel.startPrivateChat(with: peerID)
        refreshSelectedConversation()
    }

    func openConversation(for peerID: PeerID) {
        if peerID.isGeoChat {
            guard let full = chatViewModel.fullNostrHex(forSenderPeerID: peerID) else { return }
            chatViewModel.startGeohashDM(withPubkeyHex: full)
        } else {
            chatViewModel.startPrivateChat(with: peerID)
        }

        refreshSelectedConversation()
    }

    func endConversation() {
        chatViewModel.endPrivateChat()
        refreshSelectedConversation()
    }

    func toggleFavorite(peerID: PeerID) {
        chatViewModel.toggleFavorite(peerID: peerID)
        refreshSelectedConversation()
    }

    func toggleFavoriteForSelectedConversation() {
        guard let headerPeerID = selectedHeaderState?.headerPeerID else { return }
        toggleFavorite(peerID: headerPeerID)
    }

    func markMessagesAsRead(from peerID: PeerID) {
        chatViewModel.markPrivateMessagesAsRead(from: peerID)
    }

    private func bind() {
        conversationStore.$selectedPrivatePeerID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshSelectedConversation()
            }
            .store(in: &cancellables)

        chatViewModel.$allPeers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshSelectedConversation()
            }
            .store(in: &cancellables)

        peerIdentityStore.$encryptionStatuses
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshSelectedConversation()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .favoriteStatusChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshSelectedConversation()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: Notification.Name("peerStatusUpdated"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshSelectedConversation()
            }
            .store(in: &cancellables)

        locationChannelsModel.$selectedChannel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshSelectedConversation()
            }
            .store(in: &cancellables)
    }

    private func refreshSelectedConversation() {
        selectedPeerID = conversationStore.selectedPrivatePeerID
        selectedHeaderState = selectedPeerID.flatMap { peerID in
            makeHeaderState(for: peerID)
        }
    }

    private func makeHeaderState(for conversationPeerID: PeerID) -> PrivateConversationHeaderState {
        let headerPeerID = chatViewModel.getShortIDForNoiseKey(conversationPeerID)
        let peer = chatViewModel.getPeer(byID: headerPeerID)
        let displayName = resolveDisplayName(for: conversationPeerID, headerPeerID: headerPeerID, peer: peer)
        let availability = resolveAvailability(for: headerPeerID, peer: peer)
        let encryptionStatus: EncryptionStatus? = conversationPeerID.isGeoDM
            ? nil
            : chatViewModel.getEncryptionStatus(for: headerPeerID)

        return PrivateConversationHeaderState(
            conversationPeerID: conversationPeerID,
            headerPeerID: headerPeerID,
            displayName: displayName,
            availability: availability,
            isFavorite: chatViewModel.isFavorite(peerID: headerPeerID),
            encryptionStatus: encryptionStatus
        )
    }

    private func resolveDisplayName(
        for conversationPeerID: PeerID,
        headerPeerID: PeerID,
        peer: BitchatPeer?
    ) -> String {
        if conversationPeerID.isGeoDM, case .location(let channel) = locationChannelsModel.selectedChannel {
            return "#\(channel.geohash)/@\(chatViewModel.geohashDisplayName(for: conversationPeerID))"
        }
        if let displayName = peer?.displayName {
            return displayName
        }
        if let nickname = chatViewModel.meshService.peerNickname(peerID: headerPeerID) {
            return nickname
        }
        if let favorite = FavoritesPersistenceService.shared.getFavoriteStatus(
            for: Data(hexString: headerPeerID.id) ?? Data()
        ), !favorite.peerNickname.isEmpty {
            return favorite.peerNickname
        }
        if headerPeerID.id.count == 16 {
            let candidates = chatViewModel.identityManager.getCryptoIdentitiesByPeerIDPrefix(headerPeerID)
            if let identity = candidates.first,
               let social = chatViewModel.identityManager.getSocialIdentity(for: identity.fingerprint) {
                if let pet = social.localPetname, !pet.isEmpty {
                    return pet
                }
                if !social.claimedNickname.isEmpty {
                    return social.claimedNickname
                }
            }
        } else if let noiseKey = headerPeerID.noiseKey {
            let fingerprint = noiseKey.sha256Fingerprint()
            if let social = chatViewModel.identityManager.getSocialIdentity(for: fingerprint) {
                if let pet = social.localPetname, !pet.isEmpty {
                    return pet
                }
                if !social.claimedNickname.isEmpty {
                    return social.claimedNickname
                }
            }
        }

        return String(localized: "common.unknown", comment: "Fallback label for unknown peer")
    }

    private func resolveAvailability(for headerPeerID: PeerID, peer: BitchatPeer?) -> PrivateConversationAvailability {
        if let connectionState = peer?.connectionState {
            switch connectionState {
            case .bluetoothConnected:
                return .bluetoothConnected
            case .meshReachable:
                return .meshReachable
            case .nostrAvailable:
                return .nostrAvailable
            case .offline:
                return .offline
            }
        }

        if chatViewModel.meshService.isPeerReachable(headerPeerID) {
            return .meshReachable
        }
        if let noiseKey = Data(hexString: headerPeerID.id),
           let favoriteStatus = FavoritesPersistenceService.shared.getFavoriteStatus(for: noiseKey),
           favoriteStatus.isMutual {
            return .nostrAvailable
        }
        if chatViewModel.meshService.isPeerConnected(headerPeerID) || chatViewModel.connectedPeers.contains(headerPeerID) {
            return .bluetoothConnected
        }

        return .offline
    }
}
