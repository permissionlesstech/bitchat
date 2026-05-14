import SwiftUI

struct GeohashPeopleList: View {
    @EnvironmentObject private var peerListModel: PeerListModel
    let textColor: Color
    let secondaryTextColor: Color
    let onTapPerson: () -> Void
    @Environment(\.colorScheme) var colorScheme
    @State private var orderedIDs: [String] = []

    private enum Strings {
        static let noneNearby: LocalizedStringKey = "geohash_people.none_nearby"
        static let youSuffix: LocalizedStringKey = "geohash_people.you_suffix"
        static let blockedTooltip = String(localized: "geohash_people.tooltip.blocked", comment: "Tooltip shown next to users blocked in geohash channels")
        static let unblock: LocalizedStringKey = "geohash_people.action.unblock"
        static let block: LocalizedStringKey = "geohash_people.action.block"
    }

    var body: some View {
        if peerListModel.geohashPeople.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text(Strings.noneNearby)
                    .font(.bitchatSystem(size: 14, design: .monospaced))
                    .foregroundColor(secondaryTextColor)
                    .padding(.horizontal)
                    .padding(.top, 12)
            }
        } else {
            let people = peerListModel.geohashPeople
            let currentIDs = people.map(\.id)

            let displayIDs = orderedIDs.filter { currentIDs.contains($0) } + currentIDs.filter { !orderedIDs.contains($0) }
            let nonTele = displayIDs.filter { id in
                !(people.first(where: { $0.id == id })?.isTeleported ?? false)
            }
            let tele = displayIDs.filter { id in
                people.first(where: { $0.id == id })?.isTeleported ?? false
            }
            let finalOrder: [String] = nonTele + tele
            let firstID = finalOrder.first
            let personByID = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) })

            VStack(alignment: .leading, spacing: 0) {
                ForEach(finalOrder.filter { personByID[$0] != nil }, id: \.self) { pid in
                    let person = personByID[pid]!
                    HStack(spacing: 4) {
                        let icon = person.isTeleported ? "face.dashed" : "mappin.and.ellipse"
                        let assignedColor = peerListModel.colorForGeohashPerson(id: person.id, isDark: colorScheme == .dark)
                        let rowColor: Color = person.isMe ? .orange : assignedColor
                        Image(systemName: icon).font(.bitchatSystem(size: 12)).foregroundColor(rowColor)

                        let (base, suffix) = person.displayName.splitSuffix()
                        HStack(spacing: 0) {
                            Text(base)
                                .font(.bitchatSystem(size: 14, design: .monospaced))
                                .fontWeight(person.isMe ? .bold : .regular)
                                .foregroundColor(rowColor)
                            if !suffix.isEmpty {
                                let suffixColor = person.isMe ? Color.orange.opacity(0.6) : rowColor.opacity(0.6)
                                Text(suffix)
                                    .font(.bitchatSystem(size: 14, design: .monospaced))
                                    .foregroundColor(suffixColor)
                            }
                            if person.isMe {
                                Text(Strings.youSuffix)
                                    .font(.bitchatSystem(size: 14, design: .monospaced))
                                    .foregroundColor(rowColor)
                            }
                        }
                        if person.isBlocked {
                            Image(systemName: "nosign")
                                .font(.bitchatSystem(size: 10))
                                .foregroundColor(.red)
                                .help(Strings.blockedTooltip)
                        }
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                    .padding(.top, person.id == firstID ? 10 : 0)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if !person.isMe {
                            peerListModel.openGeohashDirectMessage(with: person.id)
                            onTapPerson()
                        }
                    }
                    .contextMenu {
                        if person.isMe {
                            EmptyView()
                        } else {
                            if person.isBlocked {
                                Button(Strings.unblock) {
                                    peerListModel.unblockGeohashUser(
                                        pubkeyHexLowercased: person.id,
                                        displayName: person.displayName
                                    )
                                }
                            } else {
                                Button(Strings.block) {
                                    peerListModel.blockGeohashUser(
                                        pubkeyHexLowercased: person.id,
                                        displayName: person.displayName
                                    )
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
}
