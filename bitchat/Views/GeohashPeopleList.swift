import SwiftUI

struct GeohashPeopleList: View {
    @ObservedObject var viewModel: ChatViewModel
    let textColor: Color
    let secondaryTextColor: Color
    let onTapPerson: () -> Void
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        let people = viewModel.visibleGeohashPeople()
        return Group {
            if people.isEmpty {
                Text("nobody around...")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(secondaryTextColor)
                    .padding(.horizontal)
                    .padding(.top, 12)
            } else {
                GeohashPeopleInnerList(
                    people: people,
                    myHex: currentMyGeoHex(),
                    isDark: colorScheme == .dark,
                    viewModel: viewModel,
                    onTapPerson: onTapPerson
                )
            }
        }
    }
}

private struct GeohashPeopleInnerList: View {
    let people: [ChatViewModel.GeoPerson]
    let myHex: String?
    let isDark: Bool
    let viewModel: ChatViewModel
    let onTapPerson: () -> Void

    var body: some View {
        let firstID = people.first?.id
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(people) { person in
                row(for: person, firstID: firstID)
            }
        }
    }

    private func row(for person: ChatViewModel.GeoPerson, firstID: String?) -> some View {
        let assignedColor = viewModel.colorForNostrPubkey(person.id, isDark: isDark)
        let isMe = person.id == myHex
        let convKey = "nostr_" + String(person.id.prefix(16))
        return HStack(spacing: 4) {
            if viewModel.unreadPrivateMessages.contains(convKey) {
                Image(systemName: "envelope.fill").font(.system(size: 12)).foregroundColor(.orange)
            } else {
                let teleported = viewModel.teleportedGeo.contains(person.id.lowercased()) || (isMe && LocationChannelManager.shared.teleported)
                let icon = teleported ? "face.dashed" : "face.smiling"
                let rowColor: Color = isMe ? .orange : assignedColor
                Image(systemName: icon).font(.system(size: 12)).foregroundColor(rowColor)
            }
            let (base, suffix) = splitSuffix(from: person.displayName)
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

private func currentMyGeoHex() -> String? {
    if case .location(let ch) = LocationChannelManager.shared.selectedChannel,
       let id = try? NostrIdentityBridge.deriveIdentity(forGeohash: ch.geohash) {
        return id.publicKeyHex.lowercased()
    }
    return nil
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
