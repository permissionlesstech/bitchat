import SwiftUI

struct ChatsView: View {
    @EnvironmentObject var store: ChatStore
    @State private var path: [String] = UserDefaults.standard.bool(forKey: "openThread") ? [UserDefaults.standard.string(forKey: "threadID") ?? "a"] : []

    private var sorted: [Conversation] {
        store.conversations.sorted {
            if $0.id == publicChannelID { return true }
            if $1.id == publicChannelID { return false }
            return ($0.last?.date ?? .distantPast) > ($1.last?.date ?? .distantPast)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                SkyBackground()
                ScrollView {
                    VStack(spacing: 12) {
                        PageTitle(text: "Chats").padding(.top, 8)
                        if store.conversations.count <= 1 {
                            Card {
                                VStack(spacing: 8) {
                                    Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: 30)).foregroundStyle(Theme.actionBlue)
                                    Text("No private chats yet").font(.headline)
                                    Text("Open Nearby and tap someone to say hi.").font(.footnote).foregroundStyle(Theme.inkSecondary)
                                }.frame(maxWidth: .infinity)
                            }
                        }
                        ForEach(sorted) { c in
                            NavigationLink(value: c.id) { row(c) }.buttonStyle(.plain)
                        }
                    }.padding(.horizontal, 20)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { id in
                if let c = store.conversations.first(where: { $0.id == id }) { ThreadView(conversationID: c.id, peer: c.peer) }
            }
        }
    }

    private func row(_ c: Conversation) -> some View {
        let isPublic = c.id == publicChannelID
        return Card(padding: 12) {
            HStack(spacing: 12) {
                Avatar(name: isPublic ? "#" : c.peer.name, size: 52, online: !isPublic && c.peer.hops == 1).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        if isPublic { Text("Nearby channel").font(.headline) } else { Text(verbatim: c.peer.name).font(.headline) }
                        Spacer()
                        if let d = c.last?.date { Text(d, style: .time).font(.caption).foregroundStyle(Theme.inkSecondary) }
                    }
                    HStack {
                        Text(verbatim: preview(c)).font(.subheadline).foregroundStyle(Theme.inkSecondary).lineLimit(1)
                        Spacer()
                        if c.unread > 0 {
                            Text("\(c.unread)").font(.caption.bold()).foregroundStyle(.white)
                                .padding(.horizontal, 7).padding(.vertical, 3).background(Theme.actionBlue, in: Capsule())
                        }
                    }
                }
            }
        }
    }

    private func preview(_ c: Conversation) -> String {
        guard let m = c.last else { return c.id == publicChannelID ? String(localized: "Public · anyone in range can read this") : "" }
        if let s = m.sender { return "\(s): \(m.text)" }
        return m.text
    }
}
