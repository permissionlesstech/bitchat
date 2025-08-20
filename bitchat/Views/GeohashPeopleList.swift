import SwiftUI

#if os(iOS)
struct GeohashPeopleList: View {
    @ObservedObject var viewModel: ChatViewModel
    let textColor: Color
    let secondaryTextColor: Color
    let onTapPerson: () -> Void

    var body: some View {
        Group {
            if viewModel.geohashPeople.isEmpty {
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
                let ordered = viewModel.geohashPeople.sorted { a, b in
                    if let me = myHex {
                        if a.id == me && b.id != me { return true }
                        if b.id == me && a.id != me { return false }
                    }
                    return a.lastSeen > b.lastSeen
                }
                ForEach(ordered) { person in
                    HStack(spacing: 4) {
                        let convKey = "nostr_" + String(person.id.prefix(16))
                        if viewModel.unreadPrivateMessages.contains(convKey) {
                            Image(systemName: "envelope.fill").font(.system(size: 12)).foregroundColor(.orange)
                        } else {
                            Image(systemName: "person.fill").font(.system(size: 10)).foregroundColor(textColor)
                        }
                        Text(person.displayName + (person.id == myHex ? " (you)" : ""))
                            .font(.system(size: 14, design: .monospaced))
                            .fontWeight(person.id == myHex ? .bold : .regular)
                            .foregroundColor(textColor)
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if person.id != myHex {
                            viewModel.startGeohashDM(withPubkeyHex: person.id)
                            onTapPerson()
                        }
                    }
                }
            }
        }
    }
}
#endif

