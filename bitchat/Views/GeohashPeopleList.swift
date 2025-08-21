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
                        let (base, suffix) = splitSuffix(from: person.displayName)
                        let isMe = person.id == myHex
                        HStack(spacing: 0) {
                            Text(base)
                                .font(.system(size: 14, design: .monospaced))
                                .fontWeight(isMe ? .bold : .regular)
                                .foregroundColor(textColor)
                            if !suffix.isEmpty {
                                Text(suffix)
                                    .font(.system(size: 14, design: .monospaced))
                                    .foregroundColor(Color.secondary.opacity(0.6))
                            }
                            if isMe {
                                Text(" (you)")
                                    .font(.system(size: 14, design: .monospaced))
                                    .foregroundColor(textColor)
                            }
                        }
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
