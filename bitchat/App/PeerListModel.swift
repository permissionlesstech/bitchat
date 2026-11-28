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

/// Persists pinned chat keys for the Chats inbox. Cleared on panic wipe.
enum InboxPinnedChats {
    static let storageKey = "inbox.pinnedChatKeys"

    static func pinnedKeys(in defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: storageKey) ?? [])
    }

    static func isPinned(_ key: String, in defaults: UserDefaults = .standard) -> Bool {
        pinnedKeys(in: defaults).contains(key)
    }

    @discardableResult
    static func toggle(_ key: String, in defaults: UserDefaults = .standard) -> Bool {
        var keys = pinnedKeys(in: defaults)
        let nowPinned: Bool
        if keys.contains(key) {
            keys.remove(key)
            nowPinned = false
        } else {
            keys.insert(key)
            nowPinned = true
        }
        defaults.set(Array(keys).sorted(), forKey: storageKey)
        return nowPinned
    }

    static func unpin(_ key: String, in defaults: UserDefaults = .standard) {
        var keys = pinnedKeys(in: defaults)
        guard keys.remove(key) != nil else { return }
        defaults.set(Array(keys).sorted(), forKey: storageKey)
    }

    static func clear(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }
}

/// Persists muted chat keys for the Chats inbox. Cleared on panic wipe.
enum InboxMutedChats {
    static let storageKey = "inbox.mutedChatKeys"

    static func mutedKeys(in defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: storageKey) ?? [])
    }

    static func isMuted(_ key: String, in defaults: UserDefaults = .standard) -> Bool {
        mutedKeys(in: defaults).contains(key)
    }

    @discardableResult
    static func toggle(_ key: String, in defaults: UserDefaults = .standard) -> Bool {
        var keys = mutedKeys(in: defaults)
        let nowMuted: Bool
        if keys.contains(key) {
            keys.remove(key)
            nowMuted = false
        } else {
            keys.insert(key)
            nowMuted = true
        }
        defaults.set(Array(keys).sorted(), forKey: storageKey)
        return nowMuted
    }

    static func unmute(_ key: String, in defaults: UserDefaults = .standard) {
        var keys = mutedKeys(in: defaults)
        guard keys.remove(key) != nil else { return }
        defaults.set(Array(keys).sorted(), forKey: storageKey)
    }

    static func clear(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }
}

/// Unified row for the Inbox-first Chats tab: combines private groups,
/// mutual friends, and any active DM threads in pinned + recency order.
struct InboxChatRow: Identifiable, Equatable {
    enum Reachability: Equatable {
        case meshConnected
        case meshReachable
        case nostr
        case offline
        case group
    }

    let peerID: PeerID
    let pinKey: String
    let displayName: String
    let subtitle: String
    let lastActivity: Date?
    let hasUnread: Bool
    let isPinned: Bool
    let isMuted: Bool
    let isGroup: Bool
    let memberCount: Int
    let isFavorite: Bool
    let reachability: Reachability
    let disappearingTimer: DisappearingTimer

    var id: String { peerID.id }
}

/// Eligible contact that can be added to a private encrypted group
/// (connected over BLE mesh or reachable via Nostr with a pinned signing key).
struct GroupInviteCandidate: Identifiable, Equatable {
    let peerID: PeerID
    let fingerprint: String
    let displayName: String
    let isMeshConnected: Bool
    let isNostrReachable: Bool

    var id: String { fingerprint }
}

@MainActor
final class PeerListModel: ObservableObject {
    @Published private(set) var meshRows: [MeshPeerRow] = []
    @Published private(set) var geohashPeople: [GeohashPersonRow] = []
    @Published private(set) var groupRows: [GroupChatRow] = []
    @Published private(set) var recentChatRows: [RecentChatRow] = []
    @Published private(set) var inboxRows: [InboxChatRow] = []
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

    func colorForPeer(id peerID: PeerID, isDark: Bool) -> Color {
        chatViewModel.colorForPeer(id: peerID, isDark: isDark)
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

    /// Contacts that have a cryptographic signing key and are reachable over
    /// BLE mesh or Nostr, excluding any fingerprints already in `excludingFingerprints`.
    func groupInviteCandidates(excludingFingerprints: Set<String> = []) -> [GroupInviteCandidate] {
        let myFingerprint = chatViewModel.myNoiseFingerprint()
        var byFingerprint: [String: GroupInviteCandidate] = [:]

        // 1. Live/known mesh peers
        for peer in allPeers where peer.peerID != chatViewModel.meshService.myPeerID {
            guard !chatViewModel.isPeerBlocked(peer.peerID),
                  let identity = chatViewModel.cryptoIdentity(for: peer.peerID),
                  identity.fingerprint != myFingerprint,
                  !excludingFingerprints.contains(identity.fingerprint) else { continue }
            let meshConnected = chatViewModel.isPeerConnected(peer.peerID)
            let nostrReachable = chatViewModel.nostrReachablePeerID(forFingerprint: identity.fingerprint) != nil
            guard meshConnected || nostrReachable else { continue }
            byFingerprint[identity.fingerprint] = GroupInviteCandidate(
                peerID: peer.peerID,
                fingerprint: identity.fingerprint,
                displayName: peer.displayName,
                isMeshConnected: meshConnected,
                isNostrReachable: nostrReachable
            )
        }

        // 2. Nostr favorites with pinned signing keys (e.g. added via Friend Invite)
        for (noiseKey, rel) in FavoritesPersistenceService.shared.favorites {
            guard rel.peerNostrPublicKey != nil else { continue }
            let peerID = PeerID(hexData: noiseKey)
            guard !chatViewModel.isPeerBlocked(peerID),
                  let identity = chatViewModel.cryptoIdentity(for: peerID),
                  identity.fingerprint != myFingerprint,
                  !excludingFingerprints.contains(identity.fingerprint) else { continue }
            let meshConnected = chatViewModel.connectedPeerID(forFingerprint: identity.fingerprint) != nil
            if let existing = byFingerprint[identity.fingerprint] {
                byFingerprint[identity.fingerprint] = GroupInviteCandidate(
                    peerID: existing.peerID,
                    fingerprint: identity.fingerprint,
                    displayName: existing.displayName,
                    isMeshConnected: existing.isMeshConnected || meshConnected,
                    isNostrReachable: true
                )
            } else {
                byFingerprint[identity.fingerprint] = GroupInviteCandidate(
                    peerID: peerID,
                    fingerprint: identity.fingerprint,
                    displayName: rel.peerNickname,
                    isMeshConnected: meshConnected,
                    isNostrReachable: true
                )
            }
        }

        return byFingerprint.values.sorted {
            if $0.isMeshConnected != $1.isMeshConnected { return $0.isMeshConnected }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    func createGroup(named name: String, memberPeerIDs: [PeerID]) -> CommandResult {
        chatViewModel.groupCoordinator.createGroup(named: name, initialMemberPeerIDs: memberPeerIDs)
    }

    func togglePin(for row: InboxChatRow) {
        InboxPinnedChats.toggle(row.pinKey)
        refresh()
    }

    func toggleMute(for row: InboxChatRow) {
        InboxMutedChats.toggle(row.pinKey)
        refresh()
    }

    func toggleUnread(for row: InboxChatRow) {
        chatViewModel.setInboxConversationUnread(!row.hasUnread, for: row.peerID, pinKey: row.pinKey)
        refresh()
    }

    func deleteInboxChat(_ row: InboxChatRow) {
        chatViewModel.deleteInboxConversation(
            peerID: row.peerID,
            pinKey: row.pinKey,
            isGroup: row.isGroup
        )
        refresh()
    }

    /// Filters `inboxRows` by contact/group name, preview text, or any
    /// stored message content inside that conversation.
    func filteredInboxRows(matching query: String) -> [InboxChatRow] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return inboxRows }

        var results: [InboxChatRow] = []
        for row in inboxRows {
            if row.displayName.localizedCaseInsensitiveContains(trimmed)
                || row.subtitle.localizedCaseInsensitiveContains(trimmed) {
                results.append(row)
                continue
            }
            if let snippet = latestMatchingMessageSnippet(for: row, query: trimmed) {
                results.append(
                    InboxChatRow(
                        peerID: row.peerID,
                        pinKey: row.pinKey,
                        displayName: row.displayName,
                        subtitle: snippet,
                        lastActivity: row.lastActivity,
                        hasUnread: row.hasUnread,
                        isPinned: row.isPinned,
                        isMuted: row.isMuted,
                        isGroup: row.isGroup,
                        memberCount: row.memberCount,
                        isFavorite: row.isFavorite,
                        reachability: row.reachability,
                        disappearingTimer: row.disappearingTimer
                    )
                )
            }
        }
        return results
    }

    private func latestMatchingMessageSnippet(for row: InboxChatRow, query: String) -> String? {
        var bestMessage: BitchatMessage?
        let targetFingerprint = row.isGroup
            ? nil
            : (chatViewModel.getFingerprint(for: row.peerID) ?? (row.pinKey != row.peerID.id ? row.pinKey : nil))

        for (id, conversation) in conversations.conversationsByID {
            guard case .direct(let handle) = id else { continue }
            let candidate = handle.routingPeerID
            let matchesConversation: Bool
            if row.isGroup {
                matchesConversation = (candidate == row.peerID)
            } else if candidate == row.peerID {
                matchesConversation = true
            } else if let targetFingerprint,
                      chatViewModel.getFingerprint(for: candidate) == targetFingerprint {
                matchesConversation = true
            } else {
                matchesConversation = false
            }
            guard matchesConversation else { continue }

            if let hit = conversation.messages.last(where: { $0.content.localizedCaseInsensitiveContains(query) }) {
                if bestMessage == nil || hit.timestamp > bestMessage!.timestamp {
                    bestMessage = hit
                }
            }
        }
        return bestMessage?.content
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

        chatViewModel.encryptedHistoryStore.$timers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.setNeedsRefresh()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .favoriteStatusChanged)
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
        let inboxRows = buildInboxRows(meshRows: meshRows, groupRows: groupRows)

        // Assign only what changed: every @Published write re-renders every
        // view observing this model (root, header, the open sheet).
        if self.meshRows != meshRows { self.meshRows = meshRows }
        if reachableMeshPeerCount != meshCounts.reachable { reachableMeshPeerCount = meshCounts.reachable }
        if connectedMeshPeerCount != meshCounts.connected { connectedMeshPeerCount = meshCounts.connected }
        if self.geohashPeople != geohashPeople { self.geohashPeople = geohashPeople }
        if visibleGeohashPeerCount != geohashPeople.count { visibleGeohashPeerCount = geohashPeople.count }
        if self.groupRows != groupRows { self.groupRows = groupRows }
        if self.recentChatRows != recentChatRows { self.recentChatRows = recentChatRows }
        if self.inboxRows != inboxRows { self.inboxRows = inboxRows }
    }

    private func buildInboxRows(meshRows: [MeshPeerRow], groupRows: [GroupChatRow]) -> [InboxChatRow] {
        var rowsByKey: [String: InboxChatRow] = [:]
        let pinnedKeys = InboxPinnedChats.pinnedKeys()
        let mutedKeys = InboxMutedChats.mutedKeys()

        // 1. Groups
        for group in groupRows {
            let lastMsg = conversations.conversationsByID[.directPeer(group.peerID)]?.messages.last
            let preview = lastMsg.map { "\($0.sender): \($0.content)" }
                ?? String(
                    format: String(localized: "inbox.group.members", defaultValue: "%lld members · hybrid E2E", comment: "Subtitle for a group with no messages yet"),
                    locale: .current,
                    group.memberCount
                )
            let key = group.peerID.id
            rowsByKey[key] = InboxChatRow(
                peerID: group.peerID,
                pinKey: key,
                displayName: group.name,
                subtitle: preview,
                lastActivity: lastMsg?.timestamp,
                hasUnread: group.hasUnread,
                isPinned: pinnedKeys.contains(key),
                isMuted: mutedKeys.contains(key),
                isGroup: true,
                memberCount: group.memberCount,
                isFavorite: false,
                reachability: .group,
                disappearingTimer: chatViewModel.disappearingTimer(for: group.peerID)
            )
        }

        // Index mesh rows by fingerprint & peerID for status lookup.
        var meshByFingerprint: [String: MeshPeerRow] = [:]
        var meshByPeerID: [PeerID: MeshPeerRow] = [:]
        for row in meshRows where !row.isMe {
            meshByPeerID[row.peerID] = row
            if let fp = chatViewModel.getFingerprint(for: row.peerID) {
                meshByFingerprint[fp] = row
            }
        }

        // Helper to resolve latest DM message across ephemeral + stable peer IDs
        func latestDirectMessage(for peerID: PeerID, fingerprint: String?) -> BitchatMessage? {
            var latest = conversations.conversationsByID[.directPeer(peerID)]?.messages.last
            if let fingerprint {
                for (id, conv) in conversations.conversationsByID {
                    guard case .direct(let handle) = id,
                          let msg = conv.messages.last,
                          chatViewModel.getFingerprint(for: handle.routingPeerID) == fingerprint else { continue }
                    if latest == nil || msg.timestamp > latest!.timestamp {
                        latest = msg
                    }
                }
            }
            return latest
        }

        // 2. Mutual favorites / invited friends (always shown in Inbox even before first message)
        for (noiseKey, rel) in FavoritesPersistenceService.shared.favorites where rel.isFavorite {
            let peerID = PeerID(hexData: noiseKey)
            guard !chatViewModel.isPeerBlocked(peerID) else { continue }
            let fingerprint = noiseKey.sha256Fingerprint()
            let meshRow = meshByFingerprint[fingerprint]
            let targetPeerID = meshRow?.peerID ?? peerID
            let lastMsg = latestDirectMessage(for: targetPeerID, fingerprint: fingerprint)
            let reachability: InboxChatRow.Reachability = {
                if meshRow?.isConnected == true { return .meshConnected }
                if meshRow?.isReachable == true { return .meshReachable }
                if rel.peerNostrPublicKey != nil { return .nostr }
                return .offline
            }()
            let fallbackSubtitle: String = {
                switch reachability {
                case .meshConnected:
                    return String(localized: "inbox.status.nearby_ble", defaultValue: "Nearby over Bluetooth", comment: "Subtitle for a friend reachable over Bluetooth")
                case .meshReachable:
                    return String(localized: "inbox.status.mesh_relayed", defaultValue: "Reachable on mesh", comment: "Subtitle for a friend reachable via multi-hop mesh")
                case .nostr:
                    return String(localized: "inbox.status.nostr_ready", defaultValue: "Encrypted over Nostr · tap to chat", comment: "Subtitle for a friend ready over Nostr")
                case .offline, .group:
                    return String(localized: "inbox.status.offline", defaultValue: "Offline · messages queue automatically", comment: "Subtitle for an offline friend")
                }
            }()
            let row = InboxChatRow(
                peerID: targetPeerID,
                pinKey: fingerprint,
                displayName: meshRow?.displayName ?? rel.peerNickname,
                subtitle: lastMsg?.content ?? fallbackSubtitle,
                lastActivity: lastMsg?.timestamp ?? rel.lastUpdated,
                hasUnread: chatViewModel.hasUnreadMessages(for: targetPeerID),
                isPinned: pinnedKeys.contains(fingerprint),
                isMuted: mutedKeys.contains(fingerprint),
                isGroup: false,
                memberCount: 0,
                isFavorite: true,
                reachability: reachability,
                disappearingTimer: chatViewModel.disappearingTimer(for: targetPeerID)
            )
            rowsByKey[fingerprint] = row
        }

        // 3. Any other direct conversations that have messages (e.g. mesh passerby or GeoDM)
        for (id, conversation) in conversations.conversationsByID {
            guard case .direct(let handle) = id else { continue }
            let peerID = handle.routingPeerID
            guard !peerID.isGroup,
                  let lastMsg = conversation.messages.last,
                  !chatViewModel.isPeerBlocked(peerID) else { continue }
            let fingerprint = chatViewModel.getFingerprint(for: peerID)
            let key = fingerprint ?? peerID.id
            if let existing = rowsByKey[key] {
                if let existingDate = existing.lastActivity, existingDate >= lastMsg.timestamp {
                    continue
                }
            }
            let meshRow = meshByPeerID[peerID] ?? fingerprint.flatMap { meshByFingerprint[$0] }
            let reachability: InboxChatRow.Reachability = {
                if meshRow?.isConnected == true { return .meshConnected }
                if meshRow?.isReachable == true { return .meshReachable }
                if peerID.isGeoDM { return .nostr }
                return .offline
            }()
            rowsByKey[key] = InboxChatRow(
                peerID: meshRow?.peerID ?? peerID,
                pinKey: key,
                displayName: meshRow?.displayName ?? displayName(for: peerID),
                subtitle: lastMsg.content,
                lastActivity: lastMsg.timestamp,
                hasUnread: chatViewModel.hasUnreadMessages(for: peerID),
                isPinned: pinnedKeys.contains(key),
                isMuted: mutedKeys.contains(key),
                isGroup: false,
                memberCount: 0,
                isFavorite: meshRow?.isFavorite ?? false,
                reachability: reachability,
                disappearingTimer: chatViewModel.disappearingTimer(for: peerID)
            )
        }

        return rowsByKey.values.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            if lhs.hasUnread != rhs.hasUnread { return lhs.hasUnread }
            let lDate = lhs.lastActivity ?? .distantPast
            let rDate = rhs.lastActivity ?? .distantPast
            if lDate != rDate { return lDate > rDate }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
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
