import BitFoundation
import Combine
import SwiftUI

struct MeshPeerRow: Identifiable, Equatable {
    let peerID: PeerID
    let displayName: String
    let isMe: Bool
    let hasUnread: Bool
    let isBlocked: Bool
    let isFavorite: Bool
    let isConnected: Bool
    let isReachable: Bool
    let isMutualFavorite: Bool
    let encryptionStatus: EncryptionStatus
    let showsVerifiedBadgeWhenOffline: Bool
    /// Vouched-for by someone I verified, without an explicit verification of
    /// mine — rendered as the unfilled seal (verified gets the filled one).
    let showsVouchedBadge: Bool

    var id: String { peerID.id }
}

struct GeohashPersonRow: Identifiable, Equatable {
    let id: String
    let displayName: String
    let isMe: Bool
    let isTeleported: Bool
    let isBlocked: Bool
}

struct GroupChatRow: Identifiable, Equatable {
    let peerID: PeerID
    let name: String
    let memberCount: Int
    let isCreator: Bool
    let hasUnread: Bool

    var id: String { peerID.id }
}

/// A direct conversation whose person is NOT in any roster above it. Without
/// this section, a DM from a passerby became unreachable the moment they went
/// offline: the roster filters to connected/reachable/mutual-favorite, the
/// header envelope only exists while unread, and /msg can't resolve offline
/// strangers — the thread was still in memory with no row anywhere in the UI.
struct RecentChatRow: Identifiable, Equatable {
    let peerID: PeerID
    let displayName: String
    let hasUnread: Bool
    let lastActivity: Date

    var id: String { peerID.id }
}

@MainActor
final class PeerListModel: ObservableObject {
    @Published private(set) var meshRows: [MeshPeerRow] = []
    @Published private(set) var geohashPeople: [GeohashPersonRow] = []
    @Published private(set) var groupRows: [GroupChatRow] = []
    @Published private(set) var recentChatRows: [RecentChatRow] = []
    @Published private(set) var reachableMeshPeerCount = 0
    @Published private(set) var connectedMeshPeerCount = 0
    @Published private(set) var visibleGeohashPeerCount = 0

    private let chatViewModel: ChatViewModel
    private let conversations: ConversationStore
    private let locationChannelsModel: LocationChannelsModel
    private let peerIdentityStore: PeerIdentityStore
    private let locationPresenceStore: LocationPresenceStore
    /// The mesh roster `refresh()` builds rows from. Not published: no view
    /// reads it, and publishing it would re-render on every mesh snapshot.
    private var allPeers: [BitchatPeer] = []
    private var cancellables = Set<AnyCancellable>()
    private var refreshScheduled = false

    init(
        chatViewModel: ChatViewModel,
        conversations: ConversationStore,
        locationChannelsModel: LocationChannelsModel? = nil,
        peerIdentityStore: PeerIdentityStore? = nil,
        locationPresenceStore: LocationPresenceStore? = nil
    ) {
        self.chatViewModel = chatViewModel
        self.conversations = conversations
        self.locationChannelsModel = locationChannelsModel ?? LocationChannelsModel()
        self.peerIdentityStore = peerIdentityStore ?? chatViewModel.peerIdentityStore
        self.locationPresenceStore = locationPresenceStore ?? chatViewModel.locationPresenceStore
        self.allPeers = chatViewModel.allPeers

        bind()
        refresh()
    }

    func colorForMeshPeer(id peerID: PeerID, isDark: Bool) -> Color {
        chatViewModel.colorForMeshPeer(id: peerID, isDark: isDark)
    }

    func colorForGeohashPerson(id: String, isDark: Bool) -> Color {
        chatViewModel.colorForNostrPubkey(id, isDark: isDark)
    }

    func participantCount(for geohash: String) -> Int {
        chatViewModel.geohashParticipantCount(for: geohash)
    }

    func startConversation(with peerID: PeerID) {
        chatViewModel.startPrivateChat(with: peerID)
    }

    func toggleFavorite(peerID: PeerID) {
        chatViewModel.toggleFavorite(peerID: peerID)
    }

    func openGeohashDirectMessage(with pubkeyHex: String) {
        chatViewModel.startGeohashDM(withPubkeyHex: pubkeyHex)
    }

    func blockGeohashUser(pubkeyHexLowercased: String, displayName: String) {
        chatViewModel.blockGeohashUser(
            pubkeyHexLowercased: pubkeyHexLowercased,
            displayName: displayName
        )
    }

    func unblockGeohashUser(pubkeyHexLowercased: String, displayName: String) {
        chatViewModel.unblockGeohashUser(
            pubkeyHexLowercased: pubkeyHexLowercased,
            displayName: displayName
        )
    }

    private func bind() {
        // No equality guard: `BitchatPeer.==` compares only peer IDs, so a
        // rename or a connection, favorite or petname change looks unchanged,
        // and blocking someone republishes identical peers. The refresh is
        // coalesced, and rows are compared in full before they're written.
        chatViewModel.$allPeers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] peers in
                guard let self else { return }
                self.allPeers = peers
                self.setNeedsRefresh()
            }
            .store(in: &cancellables)

        chatViewModel.$nickname
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.setNeedsRefresh()
            }
            .store(in: &cancellables)

        locationPresenceStore.$teleportedGeo
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.setNeedsRefresh()
            }
            .store(in: &cancellables)

        conversations.$unreadConversations
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.setNeedsRefresh()
            }
            .store(in: &cancellables)

        // Direct-conversation changes reorder or create recent-chat rows.
        // Filtered to `.direct` so public-timeline traffic (every mesh or
        // geohash message emits a change) doesn't rebuild the sheet.
        conversations.changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                guard case .direct = Self.changedConversationID(change) else { return }
                self?.setNeedsRefresh()
            }
            .store(in: &cancellables)

        chatViewModel.groupStore.$groups
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.setNeedsRefresh()
            }
            .store(in: &cancellables)

        peerIdentityStore.$encryptionStatuses
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.setNeedsRefresh()
            }
            .store(in: &cancellables)

        peerIdentityStore.$verifiedFingerprints
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.setNeedsRefresh()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: Notification.Name("peerStatusUpdated"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.setNeedsRefresh()
            }
            .store(in: &cancellables)

        chatViewModel.participantTracker.$visiblePeople
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.setNeedsRefresh()
            }
            .store(in: &cancellables)

        locationChannelsModel.$selectedChannel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.setNeedsRefresh()
            }
            .store(in: &cancellables)

        locationChannelsModel.$teleported
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.setNeedsRefresh()
            }
            .store(in: &cancellables)

        locationChannelsModel.$availableChannels
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.setNeedsRefresh()
            }
            .store(in: &cancellables)
    }

    /// Rebuilds the rows now. The geohash roster republishes only when
    /// membership or names change, so its recency order goes stale while the
    /// same people stay active; the people sheet calls this as it opens.
    func refreshNow() {
        refresh()
    }

    /// Coalesces bursts of triggers into one rebuild per main-queue turn: a
    /// participant event republishes the roster and the teleport set, and a
    /// mesh snapshot touches peers, unread and encryption state at once.
    private func setNeedsRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshScheduled = false
                self.refresh()
            }
        }
    }

    private func refresh() {
        let myPeerID = chatViewModel.meshService.myPeerID
        let meshRows = allPeers.map { peer in
            let isMe = peer.peerID == myPeerID
            let fingerprint = isMe ? nil : chatViewModel.getFingerprint(for: peer.peerID)
            let isVerifiedFingerprint = fingerprint.map { peerIdentityStore.isVerified($0) } ?? false
            let verifiedBadge = !peer.isConnected && isVerifiedFingerprint
            // Vouched is subordinate to verified: never show both seals.
            let vouchedBadge = !isVerifiedFingerprint
                && (fingerprint.map { chatViewModel.isVouchedFingerprint($0) } ?? false)

            return MeshPeerRow(
                peerID: peer.peerID,
                displayName: isMe ? chatViewModel.nickname : peer.displayName,
                isMe: isMe,
                hasUnread: chatViewModel.hasUnreadMessages(for: peer.peerID),
                isBlocked: !isMe && chatViewModel.isPeerBlocked(peer.peerID),
                isFavorite: peer.favoriteStatus?.isFavorite ?? false,
                isConnected: peer.isConnected,
                isReachable: peer.isReachable,
                isMutualFavorite: peer.isMutualFavorite,
                encryptionStatus: chatViewModel.getEncryptionStatus(for: peer.peerID),
                showsVerifiedBadgeWhenOffline: verifiedBadge,
                showsVouchedBadge: vouchedBadge
            )
        }

        let meshCounts = meshRows.reduce(into: (reachable: 0, connected: 0)) { counts, row in
            guard !row.isMe else { return }
            if row.isConnected {
                counts.connected += 1
                counts.reachable += 1
            } else if row.isReachable {
                counts.reachable += 1
            }
        }

        let geohashPeople = buildGeohashPeople()
        let groupRows = buildGroupRows()
        let recentChatRows = buildRecentChatRows(meshRows: meshRows, geohashPeople: geohashPeople)

        // Assign only what changed: every @Published write re-renders every
        // view observing this model (root, header, the open sheet).
        if self.meshRows != meshRows { self.meshRows = meshRows }
        if reachableMeshPeerCount != meshCounts.reachable { reachableMeshPeerCount = meshCounts.reachable }
        if connectedMeshPeerCount != meshCounts.connected { connectedMeshPeerCount = meshCounts.connected }
        if self.geohashPeople != geohashPeople { self.geohashPeople = geohashPeople }
        if visibleGeohashPeerCount != geohashPeople.count { visibleGeohashPeerCount = geohashPeople.count }
        if self.groupRows != groupRows { self.groupRows = groupRows }
        if self.recentChatRows != recentChatRows { self.recentChatRows = recentChatRows }
    }

    /// Direct conversations with people absent from the rosters above:
    /// the offline passerby DM, the geoDM from a channel since left. Rows
    /// mirrored under both an ephemeral and a stable peer ID collapse to
    /// one row per identity (newest activity wins), matching how the
    /// private-chat coordinators consolidate on open.
    private func buildRecentChatRows(
        meshRows: [MeshPeerRow],
        geohashPeople: [GeohashPersonRow]
    ) -> [RecentChatRow] {
        // A conversation can be keyed by the stable Noise peer ID while the
        // roster lists the ephemeral one — compare fingerprints too.
        var visibleIdentities = Set<String>()
        for row in meshRows {
            visibleIdentities.insert(row.peerID.id)
            if let fingerprint = chatViewModel.getFingerprint(for: row.peerID) {
                visibleIdentities.insert(fingerprint)
            }
        }
        // Someone visible in the geohash section must not also get a chat
        // row: their GeoDM conversation is keyed by the nostr_ form of the
        // same pubkey the roster lists.
        for person in geohashPeople {
            visibleIdentities.insert(PeerID(nostr_: person.id).id)
        }

        struct Candidate {
            let peerID: PeerID
            let lastActivity: Date
        }
        var bestByIdentity: [String: Candidate] = [:]

        for (id, conversation) in conversations.conversationsByID {
            guard case .direct(let handle) = id else { continue }
            let peerID = handle.routingPeerID
            // Groups have their own section; blocked people get no row.
            guard !peerID.isGroup else { continue }
            guard let lastMessage = conversation.messages.last else { continue }
            guard !chatViewModel.isPeerBlocked(peerID) else { continue }

            let fingerprint = chatViewModel.getFingerprint(for: peerID)
            if visibleIdentities.contains(peerID.id) { continue }
            if let fingerprint, visibleIdentities.contains(fingerprint) { continue }

            let identityKey = fingerprint ?? peerID.id
            if let existing = bestByIdentity[identityKey],
               existing.lastActivity >= lastMessage.timestamp {
                continue
            }
            bestByIdentity[identityKey] = Candidate(peerID: peerID, lastActivity: lastMessage.timestamp)
        }

        return bestByIdentity.values
            .sorted { $0.lastActivity > $1.lastActivity }
            .map { candidate in
                RecentChatRow(
                    peerID: candidate.peerID,
                    displayName: displayName(for: candidate.peerID),
                    hasUnread: chatViewModel.hasUnreadMessages(for: candidate.peerID),
                    lastActivity: candidate.lastActivity
                )
            }
    }

    /// GeoDM conversations resolve through the Nostr mapping —
    /// `resolveNickname` only consults mesh identity sources and would
    /// render a `nostr_…` key as an opaque `anonnost` fallback.
    private func displayName(for peerID: PeerID) -> String {
        if peerID.isGeoDM {
            return chatViewModel.geohashDisplayName(for: peerID)
        }
        return chatViewModel.resolveNickname(for: peerID)
    }

    private static func changedConversationID(_ change: ConversationChange) -> ConversationID {
        switch change {
        case .appended(let id, _),
             .updated(let id, _),
             .statusChanged(let id, _, _),
             .messageRemoved(let id, _),
             .cleared(let id),
             .removed(let id),
             .unreadChanged(let id, _):
            return id
        case .migrated(_, let to):
            return to
        }
    }

    private func buildGroupRows() -> [GroupChatRow] {
        let myFingerprint = chatViewModel.meshService.noiseIdentityFingerprint()
        return chatViewModel.groupStore.groups.map { group in
            GroupChatRow(
                peerID: group.peerID,
                name: group.name,
                memberCount: group.members.count,
                isCreator: group.creatorFingerprint == myFingerprint,
                hasUnread: chatViewModel.hasUnreadMessages(for: group.peerID)
            )
        }
    }

    private func buildGeohashPeople() -> [GeohashPersonRow] {
        let myHex = currentGeohashIdentityHex()
        let teleportedSet = Set(locationPresenceStore.teleportedGeo.map { $0.lowercased() })

        return chatViewModel.visibleGeohashPeople().map { person in
            let isMe = person.id == myHex
            return GeohashPersonRow(
                id: person.id,
                displayName: person.displayName,
                isMe: isMe,
                isTeleported: teleportedSet.contains(person.id.lowercased()) || (isMe && locationChannelsModel.teleported),
                isBlocked: !isMe && chatViewModel.isGeohashUserBlocked(pubkeyHexLowercased: person.id)
            )
        }
    }

    private func currentGeohashIdentityHex() -> String? {
        guard case .location(let channel) = locationChannelsModel.selectedChannel,
              let identity = try? chatViewModel.idBridge.deriveIdentity(forGeohash: channel.geohash) else {
            return nil
        }

        return identity.publicKeyHex.lowercased()
    }
}
