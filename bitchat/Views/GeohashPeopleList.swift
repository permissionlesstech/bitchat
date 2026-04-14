import SwiftUI

struct GeohashPeopleList: View {
    let geohashPeopleStore: GeohashPeopleStore
    @ObservedObject private var locationManager: LocationChannelManager
    @ObservedObject var sessionStore: SessionStore
    @ObservedObject var participantStore: GeohashParticipantTracker
    let textColor: Color
    let secondaryTextColor: Color
    let onTapPerson: () -> Void
    @Environment(\.colorScheme) var colorScheme
    @State private var orderedIDs: [String] = []

    init(
        geohashPeopleStore: GeohashPeopleStore,
        locationManager: LocationChannelManager = .shared,
        sessionStore: SessionStore,
        participantStore: GeohashParticipantTracker,
        textColor: Color,
        secondaryTextColor: Color,
        onTapPerson: @escaping () -> Void
    ) {
        self.geohashPeopleStore = geohashPeopleStore
        _locationManager = ObservedObject(wrappedValue: locationManager)
        _sessionStore = ObservedObject(wrappedValue: sessionStore)
        _participantStore = ObservedObject(wrappedValue: participantStore)
        self.textColor = textColor
        self.secondaryTextColor = secondaryTextColor
        self.onTapPerson = onTapPerson
    }

    private enum Strings {
        static let noneNearby: LocalizedStringKey = "geohash_people.none_nearby"
        static let youSuffix: LocalizedStringKey = "geohash_people.you_suffix"
        static let blockedTooltip = String(localized: "geohash_people.tooltip.blocked", comment: "Tooltip shown next to users blocked in geohash channels")
        static let unblock: LocalizedStringKey = "geohash_people.action.unblock"
        static let block: LocalizedStringKey = "geohash_people.action.block"
    }

    var body: some View {
        let people = participantStore.visiblePeople

        if people.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text(Strings.noneNearby)
                    .font(.bitchatSystem(size: 14, design: .monospaced))
                    .foregroundColor(secondaryTextColor)
                    .padding(.horizontal)
                    .padding(.top, 12)
            }
        } else {
            let myHex = geohashPeopleStore.currentIdentityHex()
            let currentIDs = people.map { $0.id }

            let teleportedSet = Set(sessionStore.teleportedGeo.map { $0.lowercased() })
            let isTeleportedID: (String) -> Bool = { id in
                if teleportedSet.contains(id.lowercased()) { return true }
                if let me = myHex, id == me, locationManager.teleported { return true }
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
                        let teleported = sessionStore.teleportedGeo.contains(person.id.lowercased()) || (isMe && locationManager.teleported)
                        let icon = teleported ? "face.dashed" : "mappin.and.ellipse"
                        let assignedColor = geohashPeopleStore.color(for: person.id, isDark: colorScheme == .dark)
                        let rowColor: Color = isMe ? .orange : assignedColor
                        Image(systemName: icon).font(.bitchatSystem(size: 12)).foregroundColor(rowColor)

                        let (base, suffix) = person.displayName.splitSuffix()
                        HStack(spacing: 0) {
                            Text(base)
                                .font(.bitchatSystem(size: 14, design: .monospaced))
                                .fontWeight(isMe ? .bold : .regular)
                                .foregroundColor(rowColor)
                            if !suffix.isEmpty {
                                let suffixColor = isMe ? Color.orange.opacity(0.6) : rowColor.opacity(0.6)
                                Text(suffix)
                                    .font(.bitchatSystem(size: 14, design: .monospaced))
                                    .foregroundColor(suffixColor)
                            }
                            if isMe {
                                Text(Strings.youSuffix)
                                    .font(.bitchatSystem(size: 14, design: .monospaced))
                                    .foregroundColor(rowColor)
                            }
                        }
                        if let me = myHex, person.id != me {
                            if geohashPeopleStore.isBlocked(person.id) {
                                Image(systemName: "nosign")
                                    .font(.bitchatSystem(size: 10))
                                    .foregroundColor(.red)
                                    .help(Strings.blockedTooltip)
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
                            geohashPeopleStore.startDirectMessage(withPubkeyHex: person.id)
                            onTapPerson()
                        }
                    }
                    .contextMenu {
                        if let me = myHex, person.id == me {
                            EmptyView()
                        } else {
                            let blocked = geohashPeopleStore.isBlocked(person.id)
                            if blocked {
                                Button(Strings.unblock) { geohashPeopleStore.unblock(pubkeyHexLowercased: person.id, displayName: person.displayName) }
                            } else {
                                Button(Strings.block) { geohashPeopleStore.block(pubkeyHexLowercased: person.id, displayName: person.displayName) }
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
