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
            SkyBackground()
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            SkyPill { Label("Offline · end-to-end encryption planned", systemImage: "lock.fill").font(.caption) }
                                .scaleEffect(0.92).padding(.vertical, 10)
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
        .onAppear { store.ensureConversation(peer); store.markRead(conversationID) }
        .onChange(of: messages.count) { _, _ in store.markRead(conversationID) }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(peer.name).font(.headline).foregroundStyle(Theme.ink)
                    Text(peer.hops == 1 ? "Direct link" : "\(peer.hops) hops").font(.caption2).foregroundStyle(Theme.secure)
                }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...5).focused($focused).foregroundStyle(Theme.ink)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .glass(radius: Theme.rField)
            Button {
                let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                store.send(t, in: conversationID); draft = ""
            } label: {
                Image(systemName: "arrow.up").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(Theme.actionBlue, in: RoundedRectangle(cornerRadius: Theme.rButton, style: .continuous))
            }
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial)
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
                    .foregroundStyle(message.mine ? Color.white : Theme.ink)
                    .modifier(BubbleBackground(mine: message.mine))
                HStack(spacing: 4) {
                    Text(message.date, style: .time)
                    if message.mine { Image(systemName: icon) }
                }.font(.caption2).foregroundStyle(.white.opacity(0.85)).shadow(color: .black.opacity(0.25), radius: 2)
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
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

private struct BubbleBackground: ViewModifier {
    let mine: Bool
    func body(content: Content) -> some View {
        if mine {
            content.background(Theme.actionBlue, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        } else {
            content.glass(radius: 20)
        }
    }
}
