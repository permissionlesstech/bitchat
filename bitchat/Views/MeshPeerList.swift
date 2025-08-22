import SwiftUI

struct MeshPeerList: View {
    @ObservedObject var viewModel: ChatViewModel
    let textColor: Color
    let secondaryTextColor: Color
    let onTapPeer: (String) -> Void
    let onToggleFavorite: (String) -> Void
    let onShowFingerprint: (String) -> Void
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        Group {
            if viewModel.allPeers.isEmpty {
                Text("nobody around...")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(secondaryTextColor)
                    .padding(.horizontal)
                    .padding(.top, 12)
            } else {
                let myPeerID = viewModel.meshService.myPeerID
                let mapped: [(peer: BitchatPeer, isMe: Bool, hasUnread: Bool, enc: EncryptionStatus)] = viewModel.allPeers.map { peer in
                    let isMe = peer.id == myPeerID
                    let hasUnread = viewModel.hasUnreadMessages(for: peer.id)
                    let enc = viewModel.getEncryptionStatus(for: peer.id)
                    return (peer, isMe, hasUnread, enc)
                }
                let peers = mapped.sorted { lhs, rhs in
                    let lFav = lhs.peer.favoriteStatus?.isFavorite ?? false
                    let rFav = rhs.peer.favoriteStatus?.isFavorite ?? false
                    if lFav != rFav { return lFav }
                    let lhsName = lhs.isMe ? viewModel.nickname : lhs.peer.nickname
                    let rhsName = rhs.isMe ? viewModel.nickname : rhs.peer.nickname
                    return lhsName < rhsName
                }

                ForEach(0..<peers.count, id: \.self) { idx in
                    let item = peers[idx]
                    let peer = item.peer
                    let isMe = item.isMe
                    let hasUnread = item.hasUnread
                    HStack(spacing: 4) {
                        if isMe {
                            Image(systemName: "person.fill").font(.system(size: 10)).foregroundColor(textColor)
                        } else if hasUnread {
                            Image(systemName: "envelope.fill").font(.system(size: 12)).foregroundColor(.orange)
                        } else {
                            switch peer.connectionState {
                            case .bluetoothConnected:
                                Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 10)).foregroundColor(textColor)
                            case .nostrAvailable:
                                Image(systemName: "globe").font(.system(size: 10)).foregroundColor(.purple)
                            case .offline:
                                if peer.favoriteStatus?.isFavorite ?? false {
                                    Image(systemName: "moon.fill").font(.system(size: 10)).foregroundColor(.gray)
                                } else {
                                    Image(systemName: "person").font(.system(size: 10)).foregroundColor(.gray)
                                }
                            }
                        }

                        let displayName = isMe ? viewModel.nickname : peer.nickname
                        let (base, suffix) = splitSuffix(from: displayName)
                        let assigned = viewModel.colorForMeshPeer(id: peer.id, isDark: colorScheme == .dark)
                        let baseColor = isMe ? Color.orange : assigned
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

                        if let icon = item.enc.icon, !isMe {
                            Image(systemName: icon)
                                .font(.system(size: 10))
                                .foregroundColor(item.enc == .noiseVerified || item.enc == .noiseSecured ? textColor : (item.enc == .noiseHandshaking ? .orange : .red))
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
