import SwiftUI

struct MeshPeerList: View {
    @ObservedObject var viewModel: ChatViewModel
    let textColor: Color
    let secondaryTextColor: Color
    let onTapPeer: (PeerID) -> Void
    let onToggleFavorite: (PeerID) -> Void
    let onShowFingerprint: (PeerID) -> Void
    @Environment(\.colorScheme) var colorScheme

    @State private var orderedIDs: [String] = []

    private enum Strings {
        static let noneNearby: LocalizedStringKey = "geohash_people.none_nearby"
        static let blockedTooltip = String(localized: "geohash_people.tooltip.blocked", comment: "Tooltip shown next to a blocked peer indicator")
        static let newMessagesTooltip = String(localized: "mesh_peers.tooltip.new_messages", comment: "Tooltip for the unread messages indicator")
    }

    var body: some View {
        let myPeerID = viewModel.meshService.myPeerID
        let mapped: [(peer: BitchatPeer, isMe: Bool, hasUnread: Bool, enc: EncryptionStatus)] = viewModel.allPeers.map { peer in
            let isMe = peer.peerID == myPeerID
            let hasUnread = viewModel.hasUnreadMessages(for: peer.peerID)
            let enc = viewModel.getEncryptionStatus(for: peer.peerID)
            return (peer, isMe, hasUnread, enc)
        }
        // Stable visual order without mutating state here
        let currentIDs = mapped.map { $0.peer.peerID.id }
        let displayIDs = orderedIDs.filter { currentIDs.contains($0) } + currentIDs.filter { !orderedIDs.contains($0) }
        let peers: [(peer: BitchatPeer, isMe: Bool, hasUnread: Bool, enc: EncryptionStatus)] = displayIDs.compactMap { id in
            mapped.first(where: { $0.peer.peerID.id == id })
        }
        
        if viewModel.allPeers.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text(Strings.noneNearby)
                    .font(.bitchatSystem(size: 14, design: .monospaced))
                    .foregroundColor(secondaryTextColor)
                    .padding(.horizontal)
                    .padding(.top, 12)
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<peers.count, id: \.self) { idx in
                    let item = peers[idx]
                    let peer = item.peer
                    let isMe = item.isMe
                    HStack(spacing: 4) {
                        let assigned = viewModel.colorForMeshPeer(id: peer.peerID, isDark: colorScheme == .dark)
                        let baseColor = isMe ? Color.orange : assigned
                        if isMe {
                            Image(systemName: "person.fill")
                                .font(.bitchatSystem(size: 10))
                                .foregroundColor(baseColor)
                        } else if peer.isConnected {
                            // Mesh-connected peer: radio icon
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.bitchatSystem(size: 10))
                                .foregroundColor(baseColor)
                        } else if peer.isReachable {
                            // Mesh-reachable (relayed): point.3 icon
                            Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                                .font(.bitchatSystem(size: 10))
                                .foregroundColor(baseColor)
                        } else if peer.isMutualFavorite {
                            // Mutual favorite reachable via Nostr: globe icon (purple)
                            Image(systemName: "globe")
                                .font(.bitchatSystem(size: 10))
                                .foregroundColor(.purple)
                        } else {
                            // Fallback icon for others (dimmed)
                            Image(systemName: "person")
                                .font(.bitchatSystem(size: 10))
                                .foregroundColor(secondaryTextColor)
                        }

                        let displayName = isMe ? viewModel.nickname : peer.nickname
                        let (base, suffix) = displayName.splitSuffix()
                        HStack(spacing: 0) {
                            Text(base)
                                .font(.bitchatSystem(size: 14, design: .monospaced))
                                .foregroundColor(baseColor)
                            if !suffix.isEmpty {
                                let suffixColor = isMe ? Color.orange.opacity(0.6) : baseColor.opacity(0.6)
                                Text(suffix)
                                    .font(.bitchatSystem(size: 14, design: .monospaced))
                                    .foregroundColor(suffixColor)
                            }
                        }

                        if !isMe, viewModel.isPeerBlocked(peer.peerID) {
                            Image(systemName: "nosign")
                                .font(.bitchatSystem(size: 10))
                                .foregroundColor(.red)
                                .help(Strings.blockedTooltip)
                        }

                        if !isMe {
                            if peer.isConnected {
                                if let icon = item.enc.icon {
                                    Image(systemName: icon)
                                        .font(.bitchatSystem(size: 10))
                                        .foregroundColor(baseColor)
                                }
                            } else {
                                // Offline: prefer showing verified badge from persisted fingerprints
                                if let fp = viewModel.getFingerprint(for: peer.peerID),
                                   viewModel.verifiedFingerprints.contains(fp) {
                                    Image(systemName: "checkmark.seal.fill")
                                        .font(.bitchatSystem(size: 10))
                                        .foregroundColor(baseColor)
                                } else if let icon = item.enc.icon {
                                    // Fallback to whatever status says (likely lock if we had a past session)
                                    Image(systemName: icon)
                                        .font(.bitchatSystem(size: 10))
                                        .foregroundColor(baseColor)
                                }
                            }
                        }

                        Spacer()

                        // Unread message indicator for this peer
                        if !isMe, item.hasUnread {
                            Image(systemName: "envelope.fill")
                                .font(.bitchatSystem(size: 10))
                                .foregroundColor(.orange)
                                .help(Strings.newMessagesTooltip)
                        }

                        if !isMe {
                            Button(action: { onToggleFavorite(peer.peerID) }) {
                                Image(systemName: (peer.favoriteStatus?.isFavorite ?? false) ? "star.fill" : "star")
                                    .font(.bitchatSystem(size: 12))
                                    .foregroundColor((peer.favoriteStatus?.isFavorite ?? false) ? .yellow : secondaryTextColor)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                    .padding(.top, idx == 0 ? 10 : 0)
                    .contentShape(Rectangle())
                    .onTapGesture { if !isMe { onTapPeer(peer.peerID) } }
                    .onTapGesture(count: 2) { if !isMe { onShowFingerprint(peer.peerID) } }
                }
            }
            // Seed and update order outside result builder
            .onAppear {
                let currentIDs = mapped.map { $0.peer.peerID.id }
                orderedIDs = currentIDs
            }
            .onChange(of: mapped.map { $0.peer.peerID.id }) { ids in
                var newOrder = orderedIDs
                newOrder.removeAll { !ids.contains($0) }
                for id in ids where !newOrder.contains(id) { newOrder.append(id) }
                if newOrder != orderedIDs { orderedIDs = newOrder }
            }
        }
    }
}
