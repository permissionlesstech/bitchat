import SwiftUI
import BitFoundation

struct MeshPeerList: View {
    @EnvironmentObject private var peerListModel: PeerListModel
    @ThemedPalette private var palette
    let onTapPeer: (PeerID) -> Void
    let onToggleFavorite: (PeerID) -> Void
    let onShowFingerprint: (PeerID) -> Void
    /// Optional so existing call sites (and previews/tests) keep compiling;
    /// when absent the block/unblock context-menu entry is hidden.
    var onToggleBlock: ((MeshPeerRow) -> Void)? = nil
    @Environment(\.colorScheme) var colorScheme

    @State private var orderedIDs: [String] = []
    /// First-ever favorite waiting on the one-time consent dialog.
    @State private var pendingFavorite: MeshPeerRow?

    private enum Strings {
        static let noneNearby: LocalizedStringKey = "geohash_people.none_nearby"
        static let blockedTooltip = String(localized: "geohash_people.tooltip.blocked", comment: "Tooltip shown next to a blocked peer indicator")
        static let newMessagesTooltip = String(localized: "mesh_peers.tooltip.new_messages", comment: "Tooltip for the unread messages indicator")
        static let connected = String(localized: "content.accessibility.connected_mesh", comment: "Accessibility label for mesh-connected peer indicator")
        static let reachable = String(localized: "content.accessibility.reachable_mesh", comment: "Accessibility label for mesh-reachable peer indicator")
        static let nostr = String(localized: "content.accessibility.available_nostr", comment: "Accessibility label for Nostr-available peer indicator")
        static let offline = String(localized: "mesh_peers.state.offline", comment: "State label for a peer that is not currently reachable")
        static let favorite = String(localized: "mesh_peers.state.favorite", comment: "State label for a favorited peer")
        static let unread = String(localized: "mesh_peers.state.unread", comment: "State label for a peer with unread private messages")
        static let blocked = String(localized: "mesh_peers.state.blocked", comment: "State label for a blocked peer")
        static let vouched = String(localized: "mesh_peers.state.vouched", comment: "State label for a peer vouched for by someone the user verified")
        static let favoriteMutual = String(localized: "mesh_peers.state.favorite_mutual", defaultValue: "mutual favorite", comment: "State label for a reciprocated favorite")
        static let favoritePending = String(localized: "mesh_peers.state.favorite_pending", defaultValue: "favorited, not mutual yet", comment: "State label for a favorite the peer has not reciprocated")
        static let favoriteMutualTooltip = String(localized: "mesh_peers.tooltip.favorite_mutual", defaultValue: "mutual favorite — offline messages via nostr work both ways", comment: "Tooltip for the filled star on a reciprocated favorite")
        static let favoritePendingTooltip = String(localized: "mesh_peers.tooltip.favorite_pending", defaultValue: "favorited — offline messaging starts when they favorite you back", comment: "Tooltip for the half star on an unreciprocated favorite")
        static let consentTitle = String(localized: "favorites.consent.title", defaultValue: "add favorite?", comment: "Title of the one-time confirmation before the first favorite")
        static let consentConfirm = String(localized: "favorites.consent.confirm", defaultValue: "add favorite", comment: "Confirm button of the one-time favorite consent dialog")
        static func consentMessage(_ name: String) -> String {
            String(
                format: String(localized: "favorites.consent.message", defaultValue: "this tells %@ right away and shares your nostr key with them. if they favorite you back, you can message each other over the internet when out of mesh range.", comment: "Body of the one-time favorite consent dialog; placeholder is the person's name"),
                locale: .current,
                name
            )
        }
        static let vouchedTooltip = String(localized: "mesh_peers.tooltip.vouched", comment: "Tooltip for the vouched (unfilled seal) badge next to a peer")
        static let addFavorite = String(localized: "content.accessibility.add_favorite", comment: "Accessibility label to add a favorite")
        static let removeFavorite = String(localized: "content.accessibility.remove_favorite", comment: "Accessibility label to remove a favorite")
        static let showFingerprint = String(localized: "mesh_peers.action.fingerprint", comment: "Context menu action that shows a peer's fingerprint/verification screen")
        static let openDMHint = String(localized: "mesh_peers.accessibility.open_dm_hint", comment: "Accessibility hint on a peer row explaining activation opens a private chat")
        static let directMessage = String(localized: "content.actions.direct_message", comment: "Action that opens a private chat with the person")
        static let block = String(localized: "geohash_people.action.block", comment: "Context menu action to block a person")
        static let unblock = String(localized: "geohash_people.action.unblock", comment: "Context menu action to unblock a person")
    }

    var body: some View {
        let currentIDs = peerListModel.meshRows.map(\.id)
        let displayIDs = orderedIDs.filter { currentIDs.contains($0) } + currentIDs.filter { !orderedIDs.contains($0) }
        let peers: [MeshPeerRow] = displayIDs.compactMap { id in
            peerListModel.meshRows.first(where: { $0.id == id })
        }

        Group {
        if peerListModel.meshRows.isEmpty {
            // Match the section's row rhythm (same size, indent, and vertical
            // padding as a peer row) so the empty state reads as the list's
            // only line, not a floating caption.
            Text(Strings.noneNearby)
                .bitchatFont(size: 14)
                .foregroundColor(palette.secondary)
                .padding(.horizontal)
                .padding(.vertical, 4)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<peers.count, id: \.self) { idx in
                    let peer = peers[idx]
                    let isMe = peer.isMe
                    HStack(spacing: 4) {
                        let assigned = peerListModel.colorForMeshPeer(id: peer.peerID, isDark: colorScheme == .dark)
                        let baseColor = isMe ? Color.orange : assigned
                        // Mesh rows keep their leading glyph: unlike the
                        // homogeneous bridge/groups sections, it encodes HOW
                        // the peer is reachable (radio, relayed, nostr-only).
                        if isMe {
                            Image(systemName: "person.fill")
                                .font(.bitchatSystem(size: 10))
                                .foregroundColor(baseColor)
                        } else if peer.isConnected {
                            // Mesh-connected peer: radio icon
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.bitchatSystem(size: 10))
                                .foregroundColor(baseColor)
                                .help(Strings.connected)
                        } else if peer.isReachable {
                            // Mesh-reachable (relayed): point.3 icon
                            Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                                .font(.bitchatSystem(size: 10))
                                .foregroundColor(baseColor)
                                .help(Strings.reachable)
                        } else if peer.isMutualFavorite {
                            // Mutual favorite reachable via Nostr: globe icon (purple)
                            Image(systemName: "globe")
                                .font(.bitchatSystem(size: 10))
                                .foregroundColor(.purple)
                                .help(Strings.nostr)
                        } else {
                            // Offline: slashed variant of the connected glyph
                            // (dimmed) — clearer than a generic person icon.
                            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                                .font(.bitchatSystem(size: 10))
                                .foregroundColor(palette.secondary)
                                .help(Strings.offline)
                        }

                        let (base, suffix) = peer.displayName.splitSuffix()
                        HStack(spacing: 0) {
                            Text(base)
                                .bitchatFont(size: 14)
                                .foregroundColor(baseColor)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if !suffix.isEmpty {
                                let suffixColor = isMe ? Color.orange.opacity(0.6) : baseColor.opacity(0.6)
                                Text(suffix)
                                    .bitchatFont(size: 14)
                                    .foregroundColor(suffixColor)
                            }
                        }

                        if peer.isBlocked {
                            Image(systemName: "nosign")
                                .font(.bitchatSystem(size: 10))
                                .foregroundColor(.red)
                                .help(Strings.blockedTooltip)
                        }

                        if !isMe {
                            if peer.isConnected {
                                if let icon = peer.encryptionStatus.icon {
                                    Image(systemName: icon)
                                        .font(.bitchatSystem(size: 10))
                                        // Optical centering: lock glyph ink is
                                        // bottom-heavy, so geometric centering
                                        // reads low next to the name.
                                        .offset(y: icon.hasPrefix("lock") ? -0.5 : 0)
                                        .foregroundColor(baseColor)
                                }
                            } else {
                                // Offline: prefer showing verified badge from persisted fingerprints
                                if peer.showsVerifiedBadgeWhenOffline {
                                    Image(systemName: "checkmark.seal.fill")
                                        .font(.bitchatSystem(size: 10))
                                        .foregroundColor(baseColor)
                                } else if let icon = peer.encryptionStatus.icon {
                                    // Fallback to whatever status says (likely lock if we had a past session)
                                    Image(systemName: icon)
                                        .font(.bitchatSystem(size: 10))
                                        .offset(y: icon.hasPrefix("lock") ? -0.5 : 0)
                                        .foregroundColor(baseColor)
                                }
                            }

                            // Vouched (transitively verified): unfilled seal,
                            // deliberately distinct from verified's filled one.
                            // Never shown alongside a verified badge.
                            if peer.showsVouchedBadge {
                                Image(systemName: "checkmark.seal")
                                    .font(.bitchatSystem(size: 10))
                                    .foregroundColor(baseColor)
                                    .help(Strings.vouchedTooltip)
                            }
                        }

                        Spacer()

                        // Unread message indicator for this peer
                        if peer.hasUnread {
                            Image(systemName: "envelope.fill")
                                .font(.bitchatSystem(size: 10))
                                .foregroundColor(.orange)
                                .help(Strings.newMessagesTooltip)
                        }

                        if !isMe {
                            Button(action: { requestFavoriteToggle(peer) }) {
                                // Mutuality is the load-bearing state (one-sided
                                // favorites don't enable offline delivery), so it
                                // shows at the point of decision: half star until
                                // reciprocated.
                                Image(systemName: peer.isFavorite
                                    ? (peer.isMutualFavorite ? "star.fill" : "star.leadinghalf.filled")
                                    : "star")
                                    .font(.bitchatSystem(size: 12))
                                    .foregroundColor(peer.isFavorite ? .yellow : palette.secondary)
                                    // Widen the tap target beyond the bare glyph;
                                    // height stays row-bound so neighboring rows
                                    // keep their own taps.
                                    .frame(width: 36)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(favoriteTooltip(for: peer))
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    // count:2 must attach before count:1 or the single tap
                    // shadows it (same ordering the header logo relies on).
                    .onTapGesture(count: 2) { if !isMe { onShowFingerprint(peer.peerID) } }
                    .onTapGesture { if !isMe { onTapPeer(peer.peerID) } }
                    .contextMenu {
                        if !isMe {
                            Button(Strings.directMessage) {
                                onTapPeer(peer.peerID)
                            }
                            Button(peer.isFavorite ? Strings.removeFavorite : Strings.addFavorite) {
                                requestFavoriteToggle(peer)
                            }
                            Button(Strings.showFingerprint) {
                                onShowFingerprint(peer.peerID)
                            }
                            if let onToggleBlock {
                                if peer.isBlocked {
                                    Button(Strings.unblock) {
                                        onToggleBlock(peer)
                                    }
                                } else {
                                    Button(Strings.block, role: .destructive) {
                                        onToggleBlock(peer)
                                    }
                                }
                            }
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityDescription(for: peer))
                    .accessibilityAddTraits(isMe ? [] : .isButton)
                    .accessibilityHint(isMe ? "" : Strings.openDMHint)
                    .accessibilityActions {
                        if !isMe {
                            Button(peer.isFavorite ? Strings.removeFavorite : Strings.addFavorite) {
                                requestFavoriteToggle(peer)
                            }
                            Button(Strings.showFingerprint) {
                                onShowFingerprint(peer.peerID)
                            }
                            if let onToggleBlock {
                                Button(peer.isBlocked ? Strings.unblock : Strings.block) {
                                    onToggleBlock(peer)
                                }
                            }
                        }
                    }
                }
            }
            // Seed and update order outside result builder
            .onAppear {
                orderedIDs = currentIDs
            }
            .onChange(of: currentIDs) { ids in
                var newOrder = orderedIDs
                newOrder.removeAll { !ids.contains($0) }
                for id in ids where !newOrder.contains(id) { newOrder.append(id) }
                if newOrder != orderedIDs { orderedIDs = newOrder }
            }
        }
        }
        .confirmationDialog(
            Text(verbatim: Strings.consentTitle),
            isPresented: Binding(
                get: { pendingFavorite != nil },
                set: { if !$0 { pendingFavorite = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingFavorite
        ) { peer in
            Button(Strings.consentConfirm) {
                FavoriteConsent.acknowledge()
                onToggleFavorite(peer.peerID)
            }
            Button("common.cancel", role: .cancel) {}
        } message: { peer in
            Text(verbatim: Strings.consentMessage(peer.displayName))
        }
    }

    /// Routes every add-favorite entry point (star, context menu, VoiceOver)
    /// through the one-time consent dialog; removals stay immediate.
    private func requestFavoriteToggle(_ peer: MeshPeerRow) {
        if !peer.isFavorite, !FavoriteConsent.isAcknowledged {
            pendingFavorite = peer
        } else {
            onToggleFavorite(peer.peerID)
        }
    }

    /// Tooltip for the star: the mutual/pending copy applies only once the
    /// peer is actually favorited — on an empty star it would claim a
    /// favorite that doesn't exist.
    private func favoriteTooltip(for peer: MeshPeerRow) -> String {
        guard peer.isFavorite else { return Strings.addFavorite }
        return peer.isMutualFavorite ? Strings.favoriteMutualTooltip : Strings.favoritePendingTooltip
    }

    /// One spoken sentence per row: name, how they're reachable, and any
    /// state badges — the visual row is icon soup for VoiceOver otherwise.
    private func accessibilityDescription(for peer: MeshPeerRow) -> String {
        var parts: [String] = [peer.displayName]
        if !peer.isMe {
            if peer.isConnected {
                parts.append(Strings.connected)
            } else if peer.isReachable {
                parts.append(Strings.reachable)
            } else if peer.isMutualFavorite {
                parts.append(Strings.nostr)
            } else {
                parts.append(Strings.offline)
            }
        }
        if peer.showsVouchedBadge { parts.append(Strings.vouched) }
        if peer.isFavorite {
            parts.append(peer.isMutualFavorite ? Strings.favoriteMutual : Strings.favoritePending)
        }
        if peer.hasUnread { parts.append(Strings.unread) }
        if peer.isBlocked { parts.append(Strings.blocked) }
        return parts.joined(separator: ", ")
    }
}
