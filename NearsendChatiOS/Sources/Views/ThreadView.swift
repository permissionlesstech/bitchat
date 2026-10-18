import SwiftUI

struct ThreadView: View {
    @EnvironmentObject var store: ChatStore
    let conversationID: String
    let peer: Peer
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var messages: [Message] { store.conversations.first { $0.id == conversationID }?.messages ?? [] }

    var body: some View {
        ZStack {
            Backdrop()
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            encryptionNote
                            ForEach(messages) { m in Bubble(message: m).id(m.id) }
                        }.padding(.horizontal, 16).padding(.top, 8)
                    }
                    .onChange(of: messages.count) { _, _ in
                        if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
                composer
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(peer.name).font(.headline)
                    Text(peer.hops == 1 ? "Direct link" : "\(peer.hops) hops").font(.caption2).foregroundStyle(Theme.mint)
                }
            }
        }
    }

    private var encryptionNote: some View {
        Label("Offline · end-to-end encryption planned", systemImage: "lock.fill")
            .font(.caption).foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.white.opacity(0.05), in: Capsule())
            .padding(.vertical, 10)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...5).focused($focused)
                .padding(.horizontal, 16).padding(.vertical, 11)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.stroke))
            Button {
                let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                store.send(t, in: conversationID); draft = ""
            } label: {
                Image(systemName: "arrow.up").font(.system(size: 17, weight: .bold)).foregroundStyle(.black)
                    .frame(width: 44, height: 44).background(Theme.accent, in: Circle())
            }
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }
}

struct Bubble: View {
    let message: Message
    var body: some View {
        HStack {
            if message.mine { Spacer(minLength: 60) }
            VStack(alignment: message.mine ? .trailing : .leading, spacing: 3) {
                Text(message.text)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .foregroundStyle(message.mine ? Color.black : Color.white)
                    .background(
                        message.mine ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.surface),
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(message.mine ? .clear : Theme.stroke))
                HStack(spacing: 4) {
                    Text(message.date, style: .time)
                    if message.mine { Image(systemName: icon) }
                }.font(.caption2).foregroundStyle(Theme.textSecondary)
            }
            if !message.mine { Spacer(minLength: 60) }
        }
    }
    private var icon: String {
        switch message.state {
        case .sending: "clock"
        case .sent: "checkmark"
        case .relayed: "arrow.triangle.branch"
        case .delivered: "checkmark.circle.fill"
        }
    }
}
