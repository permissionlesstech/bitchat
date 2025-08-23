import SwiftUI

#if os(iOS)
struct GeohashPeopleList: View {
    @ObservedObject var viewModel: ChatViewModel
    let textColor: Color
    let secondaryTextColor: Color
    let onTapPerson: () -> Void
    @Environment(\.colorScheme) var colorScheme
    @State private var orderedIDs: [String] = []

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
                let people = viewModel.visibleGeohashPeople()
                let currentIDs = people.map { $0.id }
                var newOrder = orderedIDs
                // Remove disappeared
                newOrder.removeAll { !currentIDs.contains($0) }
                // Append new in arrival order
                for id in currentIDs where !newOrder.contains(id) { newOrder.append(id) }
                if newOrder != orderedIDs { orderedIDs = newOrder }

                // Partition teleported to the end while preserving relative order
                #if os(iOS)
                let teleportedSet = Set(viewModel.teleportedGeo.map { $0.lowercased() })
                let meTeleported: Set<String> = (LocationChannelManager.shared.teleported ? (myHex.map { Set([$0]) }) : nil) ?? Set<String>()
                let isTeleported: (String) -> Bool = { id in teleportedSet.contains(id.lowercased()) || meTeleported.contains(id) }
                #else
                let isTeleported: (String) -> Bool = { _ in false }
                #endif
                let stableOrdered = orderedIDs.filter { currentIDs.contains($0) }
                let nonTele = stableOrdered.filter { !isTeleported($0) }
                let tele = stableOrdered.filter { isTeleported($0) }
                let finalOrder: [String] = nonTele + tele
                let firstID = finalOrder.first
                // Only iterate over IDs that still exist; lookup person by ID
                let personByID = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) })
                ForEach(finalOrder.filter { personByID[$0] != nil }, id: \.self) { pid in
                    let person = personByID[pid]!
                    HStack(spacing: 4) {
                        // Icon should match peer color; default to map pin; dashed face for teleported
                        let isMe = (person.id == myHex)
                        #if os(iOS)
                        let teleported = viewModel.teleportedGeo.contains(person.id.lowercased()) || (isMe && LocationChannelManager.shared.teleported)
                        #else
                        let teleported = false
                        #endif
                        let icon = teleported ? "face.dashed" : "mappin"
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
        .onAppear {
            orderedIDs = viewModel.visibleGeohashPeople().map { $0.id }
        }
        .onChange(of: viewModel.visibleGeohashPeople().map { $0.id }) { _ in
            // Ordering adjusted within body render
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
