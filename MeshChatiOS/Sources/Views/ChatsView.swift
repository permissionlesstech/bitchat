import SwiftUI

struct ChatsView: View {
    @EnvironmentObject var store: MeshStore
    @State private var query = ""
    @State private var path: [String] = UserDefaults.standard.bool(forKey: "openThread") ? ["a"] : []

    private var filtered: [Conversation] {
        query.isEmpty ? store.conversations : store.conversations.filter { $0.peer.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Backdrop()
                if filtered.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: 44, weight: .light)).foregroundStyle(Theme.accent)
                        Text("No conversations yet").font(.headline)
                        Text("Open Nearby and tap someone to say hi.").font(.footnote).foregroundStyle(Theme.textSecondary)
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(filtered) { c in
                                NavigationLink(value: c.id) { row(c) }.buttonStyle(.plain)
                            }
                        }.padding(.horizontal, 20)
                    }
                }
            }
            .navigationDestination(for: String.self) { id in
                if let c = store.conversations.first(where: { $0.id == id }) { ThreadView(conversationID: c.id, peer: c.peer) }
            }
            .navigationTitle("Chats")
            .searchable(text: $query, prompt: "Search")
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
                        if let d = c.last?.date { Text(d, style: .time).font(.caption).foregroundStyle(Theme.textSecondary) }
                    }
                    HStack {
                        Text(c.last?.text ?? "").font(.subheadline).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        Spacer()
                        if c.unread > 0 {
                            Text("\(c.unread)").font(.caption.bold()).foregroundStyle(.black)
                                .padding(.horizontal, 7).padding(.vertical, 3).background(Theme.accent, in: Capsule())
                        }
                    }
                }
            }
        }
    }
}
