import SwiftUI

#if os(iOS)
struct GeohashPeopleList: View {
    @ObservedObject var viewModel: ChatViewModel
    let textColor: Color
    let secondaryTextColor: Color
    let onTapPerson: () -> Void
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        Group {
            if viewModel.visibleGeohashPeople().isEmpty {
                Text("nobody around...")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(secondaryTextColor)
                    .padding(.horizontal)
                    .padding(.top, 12)
            } else {
                let myHex: String? = {
                    if case .location(let ch) = LocationChannelManager.shared.selectedChannel,
                       let id = try? NostrIdentityBridge.deriveIdentity(forGeohash: ch.geohash) {
                        return id.publicKeyHex.lowercased()
                    }
                    return nil
                }()
                let ordered = viewModel.visibleGeohashPeople().sorted { a, b in
                    if let me = myHex {
                        if a.id == me && b.id != me { return true }
                        if b.id == me && a.id != me { return false }
                    }
                    return a.lastSeen > b.lastSeen
                }
                let firstID = ordered.first?.id
                ForEach(ordered) { person in
                    HStack(spacing: 4) {
                        let convKey = "nostr_" + String(person.id.prefix(16))
                        if viewModel.unreadPrivateMessages.contains(convKey) {
                            Image(systemName: "envelope.fill").font(.system(size: 12)).foregroundColor(.orange)
                        } else {
                            // For the local user, use a different face icon when teleported
                            let isMe = (person.id == myHex)
                            #if os(iOS)
                            // Consider either the per-session tag (for any peer) or the manager flag for self
                            let teleported = viewModel.teleportedGeo.contains(person.id.lowercased()) || (isMe && LocationChannelManager.shared.teleported)
                            #else
                            let teleported = false
                            #endif
                            let icon = teleported ? "face.dashed" : "face.smiling"
                            let rowColor: Color = isMe ? .orange : textColor
                            Image(systemName: icon).font(.system(size: 12)).foregroundColor(rowColor)
                        }
                        let (base, suffix) = splitSuffix(from: person.displayName)
                        let isMe = person.id == myHex
                        let assignedColor = viewModel.colorForNostrPubkey(person.id, isDark: colorScheme == .dark)
                        HStack(spacing: 0) {
                            let rowColor: Color = isMe ? .orange : assignedColor
                            Text(base)
                                .font(.system(size: 14, design: .monospaced))
                                .fontWeight(isMe ? .bold : .regular)
                                .foregroundColor(rowColor)
                            if !suffix.isEmpty {
                                let suffixColor = isMe ? Color.orange.opacity(0.6) : rowColor.opacity(0.6)
                                Text(suffix)
                                    .font(.system(size: 14, design: .monospaced))
                                    .foregroundColor(suffixColor)
                            }
                            if isMe {
                                Text(" (you)")
                                    .font(.system(size: 14, design: .monospaced))
                                    .foregroundColor(rowColor)
                            }
                        }
                        // Blocked indicator for geohash users
                        if let me = myHex, person.id != me {
                            if viewModel.isGeohashUserBlocked(pubkeyHexLowercased: person.id) {
                                Image(systemName: "nosign")
                                    .font(.system(size: 10))
                                    .foregroundColor(.red)
                                    .help("Blocked in geochash")
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                    .padding(.top, person.id == firstID ? 10 : 0)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if person.id != myHex {
                            viewModel.startGeohashDM(withPubkeyHex: person.id)
                            onTapPerson()
                        }
                    }
                    .contextMenu {
                        if let me = myHex, person.id == me {
                            EmptyView()
                        } else {
                            let blocked = viewModel.isGeohashUserBlocked(pubkeyHexLowercased: person.id)
                            if blocked {
                                Button("Unblock") { viewModel.unblockGeohashUser(pubkeyHexLowercased: person.id, displayName: person.displayName) }
                            } else {
                                Button("Block") { viewModel.blockGeohashUser(pubkeyHexLowercased: person.id, displayName: person.displayName) }
                            }
                        }
                    }
                }
            }
        }
    }
}
#endif

// Helper to split a trailing #abcd suffix
#if os(iOS)
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
#endif
