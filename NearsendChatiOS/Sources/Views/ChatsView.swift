import SwiftUI

struct ChatsView: View {
    @EnvironmentObject var store: ChatStore
    @State private var query = ""
    @State private var path: [String] = UserDefaults.standard.bool(forKey: "openThread") ? ["a"] : []

    private var filtered: [Conversation] {
        query.isEmpty ? store.conversations : store.conversations.filter { $0.peer.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                SkyBackground()
                ScrollView {
                    VStack(spacing: 12) {
                        PageTitle(text: "Chats").padding(.top, 8)
                        if filtered.isEmpty {
                            Card {
                                VStack(spacing: 8) {
                                    Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: 36)).foregroundStyle(Theme.actionBlue)
                                    Text("No conversations yet").font(.headline)
                                    Text("Open Nearby and tap someone to say hi.").font(.footnote).foregroundStyle(Theme.inkSecondary)
                                }.frame(maxWidth: .infinity)
                            }
                        }
                        ForEach(filtered) { c in
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
        Card(padding: 12) {
            HStack(spacing: 12) {
                Avatar(name: c.peer.name, size: 52, online: c.peer.hops == 1)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(c.peer.name).font(.headline)
                        Spacer()
                        if let d = c.last?.date { Text(d, style: .time).font(.caption).foregroundStyle(Theme.inkSecondary) }
                    }
                    HStack {
                        Text(c.last?.text ?? "").font(.subheadline).foregroundStyle(Theme.inkSecondary).lineLimit(1)
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
}
