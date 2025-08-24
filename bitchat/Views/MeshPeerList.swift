import SwiftUI

struct MeshPeerList: View {
    @ObservedObject var viewModel: ChatViewModel
    let textColor: Color
    let secondaryTextColor: Color
    let onTapPeer: (String) -> Void
    let onToggleFavorite: (String) -> Void
    let onShowFingerprint: (String) -> Void
    @Environment(\.colorScheme) var colorScheme

    @State private var orderedIDs: [String] = []

    var body: some View {
        if viewModel.allPeers.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("nobody around...")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(secondaryTextColor)
                    .padding(.horizontal)
                    .padding(.top, 12)
            }
        } else {
            let myPeerID = viewModel.meshService.myPeerID
            let mapped: [(peer: BitchatPeer, isMe: Bool, hasUnread: Bool, enc: EncryptionStatus)] = viewModel.allPeers.map { peer in
                let isMe = peer.id == myPeerID
                let hasUnread = viewModel.hasUnreadMessages(for: peer.id)
                let enc = viewModel.getEncryptionStatus(for: peer.id)
                return (peer, isMe, hasUnread, enc)
            }
            // Stable visual order without mutating state here
            let currentIDs = mapped.map { $0.peer.id }
            let displayIDs = orderedIDs.filter { currentIDs.contains($0) } + currentIDs.filter { !orderedIDs.contains($0) }
            let peers: [(peer: BitchatPeer, isMe: Bool, hasUnread: Bool, enc: EncryptionStatus)] = displayIDs.compactMap { id in
                mapped.first(where: { $0.peer.id == id })
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<peers.count, id: \.self) { idx in
                    let item = peers[idx]
                    let peer = item.peer
                    let isMe = item.isMe
                    HStack(spacing: 4) {
                        let assigned = viewModel.colorForMeshPeer(id: peer.id, isDark: colorScheme == .dark)
                        let baseColor = isMe ? Color.orange : assigned
                        if isMe {
                            Image(systemName: "person.fill").font(.system(size: 10)).foregroundColor(baseColor)
                        } else {
                            Image(systemName: "mappin.and.ellipse").font(.system(size: 10)).foregroundColor(baseColor)
                        }

                        let displayName = isMe ? viewModel.nickname : peer.nickname
                        let (base, suffix) = splitSuffix(from: displayName)
                        HStack(spacing: 0) {
                            Text(base)
                                .font(.system(size: 14, design: .monospaced))
                                .foregroundColor(baseColor)
                            if !suffix.isEmpty {
                                let suffixColor = isMe ? Color.orange.opacity(0.6) : baseColor.opacity(0.6)
                                Text(suffix)
                                    .font(.system(size: 14, design: .monospaced))
                                    .foregroundColor(suffixColor)
                            }
                        }

                        if !isMe, viewModel.isPeerBlocked(peer.id) {
                            Image(systemName: "nosign")
                                .font(.system(size: 10))
                                .foregroundColor(.red)
                                .help("Blocked")
                        }

                        if let icon = item.enc.icon, !isMe {
                            Image(systemName: icon)
                                .font(.system(size: 10))
                                .foregroundColor(baseColor)
                        }

                        Spacer()

                        if !isMe {
                            Button(action: { onToggleFavorite(peer.id) }) {
                                Image(systemName: (peer.favoriteStatus?.isFavorite ?? false) ? "star.fill" : "star")
                                    .font(.system(size: 12))
                                    .foregroundColor((peer.favoriteStatus?.isFavorite ?? false) ? .yellow : secondaryTextColor)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                    .padding(.top, idx == 0 ? 10 : 0)
                    .contentShape(Rectangle())
                    .onTapGesture { if !isMe { onTapPeer(peer.id) } }
                    .onTapGesture(count: 2) { if !isMe { onShowFingerprint(peer.id) } }
                }
            }
            // Seed and update order outside result builder
            .onAppear {
                let currentIDs = mapped.map { $0.peer.id }
                orderedIDs = currentIDs
            }
            .onChange(of: mapped.map { $0.peer.id }) { ids in
                var newOrder = orderedIDs
                newOrder.removeAll { !ids.contains($0) }
                for id in ids where !newOrder.contains(id) { newOrder.append(id) }
                if newOrder != orderedIDs { orderedIDs = newOrder }
            }
        }
    }
}

// Helper to split a trailing #abcd suffix
private func splitSuffix(from name: String) -> (String, String) {
    guard name.count >= 5 else { return (name, "") }
    let suffix = String(name.suffix(5))
    if suffix.first == "#", suffix.dropFirst().allSatisfy({ c in
        ("0"..."9").contains(String(c)) || ("a"..."f").contains(String(c)) || ("A"..."F").contains(String(c))
    }) {
        let base = String(name.dropLast(5))
        return (base, suffix)
    }
    return (name, "")
}
