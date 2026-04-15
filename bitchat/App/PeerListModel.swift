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

    var id: String { peerID.id }
}

struct GeohashPersonRow: Identifiable, Equatable {
    let id: String
    let displayName: String
    let isMe: Bool
    let isTeleported: Bool
    let isBlocked: Bool
}

@MainActor
final class PeerListModel: ObservableObject {
    @Published private(set) var allPeers: [BitchatPeer] = []
    @Published private(set) var meshRows: [MeshPeerRow] = []
    @Published private(set) var geohashPeople: [GeohashPersonRow] = []
    @Published private(set) var reachableMeshPeerCount = 0
    @Published private(set) var connectedMeshPeerCount = 0
    @Published private(set) var visibleGeohashPeerCount = 0
    @Published private(set) var renderID = ""

    private let chatViewModel: ChatViewModel
    private let conversationStore: ConversationStore
    private let locationChannelsModel: LocationChannelsModel
    private let peerIdentityStore: PeerIdentityStore
    private let locationPresenceStore: LocationPresenceStore
    private var cancellables = Set<AnyCancellable>()

    init(
        chatViewModel: ChatViewModel,
        conversationStore: ConversationStore,
        locationChannelsModel: LocationChannelsModel? = nil,
        peerIdentityStore: PeerIdentityStore? = nil,
        locationPresenceStore: LocationPresenceStore? = nil
    ) {
        self.chatViewModel = chatViewModel
        self.conversationStore = conversationStore
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
        chatViewModel.$allPeers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] peers in
                self?.allPeers = peers
                self?.refresh()
            }
            .store(in: &cancellables)

        chatViewModel.$nickname
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        locationPresenceStore.$teleportedGeo
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        conversationStore.$unreadConversations
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        peerIdentityStore.$encryptionStatuses
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        peerIdentityStore.$verifiedFingerprints
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: Notification.Name("peerStatusUpdated"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        chatViewModel.participantTracker.$visiblePeople
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        locationChannelsModel.$selectedChannel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        locationChannelsModel.$teleported
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        locationChannelsModel.$availableChannels
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)
    }

    private func refresh() {
        let myPeerID = chatViewModel.meshService.myPeerID
        let meshRows = allPeers.map { peer in
            let isMe = peer.peerID == myPeerID
            let verifiedBadge: Bool
            if !isMe && !peer.isConnected,
               let fingerprint = chatViewModel.getFingerprint(for: peer.peerID) {
                verifiedBadge = peerIdentityStore.isVerified(fingerprint)
            } else {
                verifiedBadge = false
            }

            return MeshPeerRow(
                peerID: peer.peerID,
                displayName: isMe ? chatViewModel.nickname : peer.nickname,
                isMe: isMe,
                hasUnread: chatViewModel.hasUnreadMessages(for: peer.peerID),
                isBlocked: !isMe && chatViewModel.isPeerBlocked(peer.peerID),
                isFavorite: peer.favoriteStatus?.isFavorite ?? false,
                isConnected: peer.isConnected,
                isReachable: peer.isReachable,
                isMutualFavorite: peer.isMutualFavorite,
                encryptionStatus: chatViewModel.getEncryptionStatus(for: peer.peerID),
                showsVerifiedBadgeWhenOffline: verifiedBadge
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

        self.meshRows = meshRows
        reachableMeshPeerCount = meshCounts.reachable
        connectedMeshPeerCount = meshCounts.connected
        self.geohashPeople = geohashPeople
        visibleGeohashPeerCount = geohashPeople.count
        renderID = (
            meshRows.map {
                "\($0.id)-\($0.isConnected)-\($0.isReachable)-\($0.hasUnread)-\($0.isFavorite)-\($0.isBlocked)"
            } +
            geohashPeople.map {
                "geo:\($0.id)-\($0.isTeleported)-\($0.isBlocked)-\($0.displayName)"
            }
        ).joined(separator: "|")
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
