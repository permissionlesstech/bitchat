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
    var groupMeshReachableCount: Int = 0
    var groupNostrReachableCount: Int = 0
    var groupOtherMemberCount: Int = 0

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

    func disappearingTimer(for peerID: PeerID) -> DisappearingTimer {
        chatViewModel.disappearingTimer(for: peerID)
    }

    func setDisappearingTimer(_ timer: DisappearingTimer, for peerID: PeerID) {
        chatViewModel.setDisappearingTimer(timer, for: peerID)
        objectWillChange.send()
    }

    // MARK: - Group Management

    func group(for peerID: PeerID) -> BitchatGroup? {
        chatViewModel.groupStore.group(for: peerID)
    }

    var myNoiseFingerprint: String {
        chatViewModel.myNoiseFingerprint()
    }

    func inviteMember(peerID: PeerID, into groupPeerID: PeerID) -> CommandResult {
        let result = chatViewModel.groupCoordinator.inviteMember(peerID: peerID, into: groupPeerID)
        refreshSelectedConversation()
        return result
    }

    func removeMember(fingerprint: String, from groupPeerID: PeerID) -> CommandResult {
        let result = chatViewModel.groupCoordinator.removeMember(fingerprint: fingerprint, from: groupPeerID)
        refreshSelectedConversation()
        return result
    }

    func leaveGroup(peerID: PeerID) -> CommandResult {
        let result = chatViewModel.groupCoordinator.leaveGroup(peerID: peerID)
        refreshSelectedConversation()
        return result
    }

    // MARK: - Contact Detail Helpers

    func sharedGroups(for peerID: PeerID) -> [BitchatGroup] {
        guard let fingerprint = chatViewModel.getFingerprint(for: peerID) else { return [] }
        return chatViewModel.groupStore.groups.filter { group in
            group.members.contains(where: { $0.fingerprint == fingerprint })
        }
    }

    func isMuted(for peerID: PeerID) -> Bool {
        chatViewModel.isConversationMuted(for: peerID)
    }

    func toggleMute(for peerID: PeerID) {
        let key = autoListenPolicyKey(for: peerID)
        InboxMutedChats.toggle(key)
        objectWillChange.send()
    }

    func autoListenPolicyKey(for peerID: PeerID) -> String {
        if peerID.isGroup {
            return peerID.id
        }
        return chatViewModel.getFingerprint(for: peerID) ?? peerID.id
    }

    func autoListenPolicy(for peerID: PeerID) -> PTTAutoListenPolicy {
        PTTPreferences.shared.chatAutoListenPolicy(for: autoListenPolicyKey(for: peerID))
    }

    func setAutoListenPolicy(_ policy: PTTAutoListenPolicy, for peerID: PeerID) {
        PTTPreferences.shared.setChatAutoListenPolicy(policy, for: autoListenPolicyKey(for: peerID))
        objectWillChange.send()
    }

    func isBlocked(peerID: PeerID) -> Bool {
        if peerID.isGeoDM || peerID.isGeoChat,
           let hex = chatViewModel.fullNostrHex(forSenderPeerID: peerID) {
            return chatViewModel.isGeohashUserBlocked(pubkeyHexLowercased: hex)
        }
        return chatViewModel.isPeerBlocked(peerID)
    }

    func toggleBlock(for peerID: PeerID, displayName: String) {
        if isBlocked(peerID: peerID) {
            if peerID.isGeoDM || peerID.isGeoChat,
               let hex = chatViewModel.fullNostrHex(forSenderPeerID: peerID) {
                chatViewModel.unblockGeohashUser(pubkeyHexLowercased: hex, displayName: displayName)
            } else {
                chatViewModel.unblockMeshPeer(peerID: peerID, displayName: displayName)
            }
        } else {
            if peerID.isGeoDM || peerID.isGeoChat,
               let hex = chatViewModel.fullNostrHex(forSenderPeerID: peerID) {
                chatViewModel.blockGeohashUser(pubkeyHexLowercased: hex, displayName: displayName)
            } else {
                chatViewModel.blockMeshPeer(peerID: peerID, displayName: displayName)
            }
        }
        refreshSelectedConversation()
        objectWillChange.send()
    }

    func clearHistory(for peerID: PeerID) {
        conversations.clear(.directPeer(peerID))
        chatViewModel.flushPersistedPrivateHistorySynchronously()
        objectWillChange.send()
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
        let nextPeerID = conversations.selectedPrivatePeerID
        let nextHeaderState = nextPeerID.flatMap { peerID in
            makeHeaderState(for: peerID)
        }
        if selectedPeerID != nextPeerID {
            selectedPeerID = nextPeerID
        }
        if selectedHeaderState != nextHeaderState {
            selectedHeaderState = nextHeaderState
        }
    }

    private func makeHeaderState(for conversationPeerID: PeerID) -> PrivateConversationHeaderState {
        // Group chats: the "peer" is the whole crew. Name + member count in
        // the header; availability reads as mesh since group traffic floods
        // the local mesh, and the per-peer encryption badge does not apply.
        if conversationPeerID.isGroup {
            let displayName: String
            var meshCount = 0
            var nostrCount = 0
            var otherCount = 0
            if let group = chatViewModel.groupStore.group(for: conversationPeerID) {
                displayName = "#\(group.name) (\(group.members.count))"
                let myFP = chatViewModel.myNoiseFingerprint()
                for member in group.members where member.fingerprint != myFP {
                    otherCount += 1
                    let onMesh = chatViewModel.connectedPeerID(forFingerprint: member.fingerprint) != nil
                    let onNostr = chatViewModel.nostrReachablePeerID(forFingerprint: member.fingerprint) != nil
                    if onMesh {
                        meshCount += 1
                    } else if onNostr {
                        nostrCount += 1
                    }
                }
            } else {
                displayName = String(localized: "common.unknown", comment: "Fallback label for unknown peer")
            }
            let groupAvailability: PrivateConversationAvailability = {
                if meshCount > 0 { return .bluetoothConnected }
                if nostrCount > 0 { return .nostrAvailable }
                return .offline
            }()
            return PrivateConversationHeaderState(
                conversationPeerID: conversationPeerID,
                headerPeerID: conversationPeerID,
                displayName: displayName,
                availability: groupAvailability,
                isFavorite: false,
                encryptionStatus: nil,
                groupMeshReachableCount: meshCount,
                groupNostrReachableCount: nostrCount,
                groupOtherMemberCount: otherCount
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
