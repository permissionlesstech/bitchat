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

    #if os(iOS)
    /// A person opened a DM from a list of people: a people popover's row,
    /// or a message list's "direct message". The DM already open counts
    /// too, though opening it again changes no selection: the split layout
    /// takes each as a DM opening (E1), which the selection alone can't
    /// tell it. Refused opens (a blocked peer's) and the layout's own
    /// reopenings don't fire.
    let conversationChosen = PassthroughSubject<Void, Never>()
    #endif

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

    /// Opens the DM with a message's sender, from a message list showing
    /// `origin`: the list's own conversation (its DM, or its timeline's
    /// channel). A refusal (a blocked peer's DM doesn't open) lands there,
    /// not in whatever is selected: on the split layout that can be the
    /// other pane's conversation. A geohash participant's DM opens as
    /// before; only the selected geohash's list shows one, and the
    /// selection is its own.
    func openConversation(for peerID: PeerID, from origin: ConversationTarget) {
        if peerID.isGeoChat {
            guard let full = chatViewModel.fullNostrHex(forSenderPeerID: peerID) else { return }
            chatViewModel.startGeohashDM(withPubkeyHex: full)
            refreshSelectedConversation()
            #if os(iOS)
            reportChoice(of: PeerID(nostr_: full))
            #endif
        } else {
            chatViewModel.startPrivateChat(with: peerID, from: origin)
            refreshSelectedConversation()
            #if os(iOS)
            reportChoice(of: peerID)
            #endif
        }
    }

    func endConversation() {
        chatViewModel.endPrivateChat()
        refreshSelectedConversation()
    }

    #if os(iOS)
    /// Whether a DM a fold set aside can open again on unfold. While folded
    /// a group can be left (or we removed from it) and a peer blocked;
    /// reopening those would bring back an empty group chat where every
    /// send fails, or post a refusal instead of a conversation.
    func canReopenConversation(with peerID: PeerID) -> Bool {
        if peerID.isGroup {
            return chatViewModel.groupStore.group(for: peerID) != nil
        }
        return !chatViewModel.isPeerBlocked(peerID)
    }

    /// Whether two peer IDs name one DM: equal, or the same person across a
    /// peer-ID handoff (the selection moving from a short mesh ID to the
    /// Noise key's ID or to a new short ID). Compared the way drafts and
    /// held mics are, so the split layout's panes treat a handoff as the
    /// conversation they already show.
    func isSameConversation(_ lhs: PeerID, _ rhs: PeerID) -> Bool {
        chatViewModel.isSameDirectConversation(lhs, rhs)
    }

    /// Opens the DM with `peerID` from a list that lists `origin`'s people.
    /// A refusal (a blocked peer's DM doesn't open) lands in `origin`, not
    /// in whatever is selected: on the split layout that can be the other
    /// pane's conversation.
    func startConversation(with peerID: PeerID, from origin: ConversationTarget) {
        chatViewModel.startPrivateChat(with: peerID, from: origin)
        refreshSelectedConversation()
        reportChoice(of: peerID)
    }

    /// A person's open of `peerID`'s DM went through: it is the one open
    /// now (`conversationChosen`).
    private func reportChoice(of peerID: PeerID) {
        guard selectedPeerID == peerID else { return }
        conversationChosen.send()
    }
    #endif

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
        // Geo DMs are always routed through BitChat private envelopes over
        // Nostr; their nostr_ keys never resolve to a reachable mesh peer, so
        // resolveAvailability would report .offline. Report .nostrAvailable
        // so the header shows the globe instead of a misleading "offline" tag.
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
        // Local alias wins over a live peer row's announced nickname.
        if headerPeerID.id.count == 16 {
            let candidates = chatViewModel.identityManager.getCryptoIdentitiesByPeerIDPrefix(headerPeerID)
            if let identity = candidates.first,
               let social = chatViewModel.identityManager.getSocialIdentity(for: identity.fingerprint),
               let pet = social.localPetname, !pet.isEmpty {
                return pet
            }
        } else if let noiseKey = headerPeerID.noiseKey {
            let fingerprint = noiseKey.sha256Fingerprint()
            if let social = chatViewModel.identityManager.getSocialIdentity(for: fingerprint),
               let pet = social.localPetname, !pet.isEmpty {
                return pet
            }
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
               let social = chatViewModel.identityManager.getSocialIdentity(for: identity.fingerprint),
               !social.claimedNickname.isEmpty {
                return social.claimedNickname
            }
        } else if let noiseKey = headerPeerID.noiseKey {
            let fingerprint = noiseKey.sha256Fingerprint()
            if let social = chatViewModel.identityManager.getSocialIdentity(for: fingerprint),
               !social.claimedNickname.isEmpty {
                return social.claimedNickname
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
           favoriteStatus.isMutual,
           // No stored recipient key means no Nostr delivery — and the
           // "end-to-end encrypted" caption keys off .nostrAvailable.
           favoriteStatus.peerNostrPublicKey != nil {
            return .nostrAvailable
        }
        if chatViewModel.meshService.isPeerConnected(headerPeerID) || chatViewModel.connectedPeers.contains(headerPeerID) {
            return .bluetoothConnected
        }

        return .offline
    }
}
