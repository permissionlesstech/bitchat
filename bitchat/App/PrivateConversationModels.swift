import BitFoundation
import Combine
import Foundation

/// Feature model for private (direct) conversations.
///
/// Reads the single-writer `ConversationStore` directly: `messages(for:)`
/// returns the peer's conversation backing array (no mirror dictionary), and
/// the store's typed `changes` subject drives invalidation — a change in the
/// SELECTED peer's conversation republishes this model, while appends to
/// other private chats only surface through the unread set. Direct
/// conversations are keyed by raw routing peer ID; the coordinators'
/// ephemeral/stable mirroring guarantees the selected peer's key always
/// holds the full timeline (see `ConversationID.directPeer`).
@MainActor
final class PrivateInboxModel: ObservableObject {
    @Published private(set) var selectedPeerID: PeerID?
    @Published private(set) var unreadPeerIDs: Set<PeerID> = []

    private let conversations: ConversationStore
    private var cancellables = Set<AnyCancellable>()

    init(conversations: ConversationStore) {
        self.conversations = conversations
        self.selectedPeerID = conversations.selectedPrivatePeerID
        self.unreadPeerIDs = conversations.unreadDirectRoutingPeerIDs()

        bind()
    }

    func messages(for peerID: PeerID?) -> [BitchatMessage] {
        guard let peerID else { return [] }
        return conversations.conversationsByID[.directPeer(peerID)]?.messages ?? []
    }

    private func bind() {
        conversations.$selectedPrivatePeerID
            .dropFirst()
            .sink { [weak self] peerID in
                guard let self, self.selectedPeerID != peerID else { return }
                self.selectedPeerID = peerID
            }
            .store(in: &cancellables)

        conversations.changes
            .sink { [weak self] change in
                self?.apply(change)
            }
            .store(in: &cancellables)
    }

    private func apply(_ change: ConversationChange) {
        switch change {
        case .appended(let id, _),
             .updated(let id, _),
             .statusChanged(let id, _, _),
             .messageRemoved(let id, _),
             .cleared(let id):
            republishIfSelected(id)

        case .unreadChanged(let id, _):
            guard isDirect(id) else { return }
            refreshUnreadPeerIDs()

        case .removed(let id):
            guard isDirect(id) else { return }
            refreshUnreadPeerIDs()
            republishIfSelected(id)

        case .migrated(let source, let destination):
            guard isDirect(source) || isDirect(destination) else { return }
            refreshUnreadPeerIDs()
            republishIfSelected(source)
            republishIfSelected(destination)
        }
    }

    private func republishIfSelected(_ id: ConversationID) {
        guard let selectedPeerID, id == .directPeer(selectedPeerID) else { return }
        objectWillChange.send()
    }

    private func refreshUnreadPeerIDs() {
        let next = conversations.unreadDirectRoutingPeerIDs()
        guard unreadPeerIDs != next else { return }
        unreadPeerIDs = next
    }

    private func isDirect(_ id: ConversationID) -> Bool {
        if case .direct = id { return true }
        return false
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
        !conversationPeerID.isGeoDM && !conversationPeerID.isGroup
    }

    /// Group chats have no single peer identity behind the header: no
    /// fingerprint screen, no per-peer encryption badge.
    var isGroupConversation: Bool {
        conversationPeerID.isGroup
    }
}

@MainActor
final class PrivateConversationModel: ObservableObject {
    @Published private(set) var selectedPeerID: PeerID?
    @Published private(set) var selectedHeaderState: PrivateConversationHeaderState?

    private let chatViewModel: ChatViewModel
    private let conversations: ConversationStore
    private let locationChannelsModel: LocationChannelsModel
    private let peerIdentityStore: PeerIdentityStore
    private var cancellables = Set<AnyCancellable>()

    init(
        chatViewModel: ChatViewModel,
        conversations: ConversationStore,
        locationChannelsModel: LocationChannelsModel? = nil,
        peerIdentityStore: PeerIdentityStore? = nil
    ) {
        self.chatViewModel = chatViewModel
        self.conversations = conversations
        self.locationChannelsModel = locationChannelsModel ?? LocationChannelsModel()
        self.peerIdentityStore = peerIdentityStore ?? chatViewModel.peerIdentityStore
        let initialPeerID = conversations.selectedPrivatePeerID
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
        conversations.$selectedPrivatePeerID
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

        chatViewModel.groupStore.$groups
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
        selectedPeerID = conversations.selectedPrivatePeerID
        selectedHeaderState = selectedPeerID.flatMap { peerID in
            makeHeaderState(for: peerID)
        }
    }

    private func makeHeaderState(for conversationPeerID: PeerID) -> PrivateConversationHeaderState {
        // Group chats: the "peer" is the whole crew. Name + member count in
        // the header; availability reads as mesh since group traffic floods
        // the local mesh, and the per-peer encryption badge does not apply.
        if conversationPeerID.isGroup {
            let displayName: String
            if let group = chatViewModel.groupStore.group(for: conversationPeerID) {
                displayName = "#\(group.name) (\(group.members.count))"
            } else {
                displayName = String(localized: "common.unknown", comment: "Fallback label for unknown peer")
            }
            return PrivateConversationHeaderState(
                conversationPeerID: conversationPeerID,
                headerPeerID: conversationPeerID,
                displayName: displayName,
                availability: .meshReachable,
                isFavorite: false,
                encryptionStatus: nil
            )
        }

        let headerPeerID = chatViewModel.getShortIDForNoiseKey(conversationPeerID)
        let peer = chatViewModel.getPeer(byID: headerPeerID)
        let displayName = resolveDisplayName(for: conversationPeerID, headerPeerID: headerPeerID, peer: peer)
        // Geo DMs are always routed over Nostr (NIP-17); their nostr_ keys
        // never resolve to a reachable mesh peer, so resolveAvailability would
        // report .offline. Report .nostrAvailable so the header shows the
        // globe instead of a misleading "offline" tag.
        let availability = conversationPeerID.isGeoDM
            ? .nostrAvailable
            : resolveAvailability(for: headerPeerID, peer: peer)
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
