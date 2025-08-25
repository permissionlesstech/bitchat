import SwiftUI

struct GeohashPeopleList: View {
    @ObservedObject var viewModel: ChatViewModel
    let textColor: Color
    let secondaryTextColor: Color
    let onTapPerson: () -> Void
    @Environment(\.colorScheme) var colorScheme
    @State private var orderedIDs: [String] = []

    var body: some View {
        if viewModel.visibleGeohashPeople().isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("nobody around...")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(secondaryTextColor)
                    .padding(.horizontal)
                    .padding(.top, 12)
            }
        } else {
            let myHex: String? = {
                if case .location(let ch) = LocationChannelManager.shared.selectedChannel,
                   let id = try? NostrIdentityBridge.deriveIdentity(forGeohash: ch.geohash) {
                    return id.publicKeyHex.lowercased()
                }
                return nil
            }()
            let people = viewModel.visibleGeohashPeople()
            let currentIDs = people.map { $0.id }

            let teleportedSet = Set(viewModel.teleportedGeo.map { $0.lowercased() })
            let isTeleportedID: (String) -> Bool = { id in
                if teleportedSet.contains(id.lowercased()) { return true }
                if let me = myHex, id == me, LocationChannelManager.shared.teleported { return true }
                return false
            }

            let displayIDs = orderedIDs.filter { currentIDs.contains($0) } + currentIDs.filter { !orderedIDs.contains($0) }
            let nonTele = displayIDs.filter { !isTeleportedID($0) }
            let tele = displayIDs.filter { isTeleportedID($0) }
            let finalOrder: [String] = nonTele + tele
            let firstID = finalOrder.first
            let personByID = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) })

            VStack(alignment: .leading, spacing: 0) {
                ForEach(finalOrder.filter { personByID[$0] != nil }, id: \.self) { pid in
                    let person = personByID[pid]!
                    HStack(spacing: 4) {
                        let isMe = (person.id == myHex)
                        let teleported = viewModel.teleportedGeo.contains(person.id.lowercased()) || (isMe && LocationChannelManager.shared.teleported)
                        let icon = teleported ? "face.dashed" : "mappin.and.ellipse"
                        let assignedColor = viewModel.colorForNostrPubkey(person.id, isDark: colorScheme == .dark)
                        let rowColor: Color = isMe ? .orange : assignedColor
                        Image(systemName: icon).font(.system(size: 12)).foregroundColor(rowColor)

                        let (base, suffix) = splitSuffix(from: person.displayName)
                        HStack(spacing: 0) {
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
