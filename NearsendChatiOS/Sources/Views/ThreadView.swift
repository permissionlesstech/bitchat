import SwiftUI

struct ThreadView: View {
    @EnvironmentObject var store: ChatStore
    let conversationID: String
    let peer: Peer
    @State private var draft = ""
    @State private var showInfo = false
    @FocusState private var focused: Bool

    private var isPublic: Bool { conversationID == publicChannelID }
    private var messages: [Message] { store.conversations.first { $0.id == conversationID }?.messages ?? [] }
    private var livePeer: Peer { store.peers.first { $0.id == conversationID } ?? peer }
    private var online: Bool { isPublic || store.peers.contains { $0.id == conversationID } }
    private var encrypted: Bool { store.simulated || !livePeer.fingerprint.isEmpty }

    var body: some View {
        ZStack {
            SkyBackground()
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            SkyPill {
                                Label(isPublic ? "Public · anyone in range can read this"
                                      : (encrypted ? "End-to-end encrypted" : "Waiting for encryption keys"),
                                      systemImage: isPublic ? "megaphone.fill" : "lock.fill").font(.caption)
                            }.scaleEffect(0.92).padding(.vertical, 10)
                            ForEach(messages) { m in
                                Bubble(message: m, showSender: isPublic) { store.retry(m.id, in: conversationID) }.id(m.id)
                            }
                        }.padding(.horizontal, 16).padding(.top, 8)
                    }
                    .onChange(of: messages.count) { _, _ in
                        if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
                composer
            }
        }
        .onAppear { store.activeConversation = conversationID; store.markRead(conversationID) }
        .onDisappear { if store.activeConversation == conversationID { store.activeConversation = nil } }
        .onChange(of: messages.count) { _, _ in store.markRead(conversationID) }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    if isPublic { Text("Nearby channel").font(.headline).foregroundStyle(Theme.ink) }
                    else { Text(verbatim: livePeer.name).font(.headline).foregroundStyle(Theme.ink) }
                    subtitle.font(.caption2).foregroundStyle(online ? Theme.secure : Theme.inkSecondary)
                }
            }
            if !isPublic {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showInfo = true } label: { Image(systemName: "info.circle") }.accessibilityLabel("Contact info")
                }
            }
        }
        .sheet(isPresented: $showInfo) { PeerInfoSheet(peer: livePeer).environmentObject(store) }
    }

    @ViewBuilder private var subtitle: some View {
        if isPublic { Text("Public channel") }
        else if !online { Text("Out of range · will send when nearby") }
        else if livePeer.hops == 1 { Text("Direct link") }
        else { Text("\(livePeer.hops) hops") }
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
            .accessibilityLabel("Send")
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
}

struct Bubble: View {
    let message: Message
    var showSender = false
    var onRetry: () -> Void = {}

    var body: some View {
        HStack {
            if message.mine { Spacer(minLength: 60) }
            VStack(alignment: message.mine ? .trailing : .leading, spacing: 3) {
                if showSender, !message.mine, let s = message.sender {
                    Text(verbatim: s).font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.9)).padding(.leading, 6)
                }
                Text(verbatim: message.text)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .foregroundStyle(message.mine ? Color.white : Theme.ink)
                    .modifier(BubbleBackground(mine: message.mine))
                HStack(spacing: 4) {
                    Text(message.date, style: .time)
                    if !message.mine && message.hops > 1 { Text("· \(message.hops) hops") }
                    if message.mine { Image(systemName: icon).accessibilityLabel(LocalizedStringKey(stateName)) }
                    if message.state == .failed { Text("Tap to retry") }
                }.font(.caption2).foregroundStyle(.white.opacity(0.85)).shadow(color: .black.opacity(0.25), radius: 2)
            }
            if !message.mine { Spacer(minLength: 60) }
        }
        .onTapGesture { if message.state == .failed { onRetry() } }
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
    private var stateName: String {
        switch message.state {
        case .sending: "Sending"
        case .sent: "Sent"
        case .relayed: "Relayed"
        case .delivered: "Delivered"
        case .failed: "Failed"
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

/// Fingerprint comparison: two people read their digits to each other in person to rule out an impostor.
struct PeerInfoSheet: View {
    @EnvironmentObject var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    let peer: Peer

    var body: some View {
        ZStack {
            SkyBackground()
            VStack(spacing: 16) {
                Avatar(name: peer.name, size: 80).padding(.top, 24).accessibilityHidden(true)
                Text(verbatim: peer.name).font(.title2.weight(.semibold)).foregroundStyle(.white)
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Their fingerprint", systemImage: "key.fill").font(.subheadline.weight(.semibold))
                        Text(verbatim: peer.fingerprint.isEmpty ? "—" : peer.fingerprint)
                            .font(.system(.title3, design: .monospaced)).foregroundStyle(Theme.link)
                        Text("Ask them to read the digits on their You tab. If they match, nobody is impersonating them.")
                            .font(.footnote).foregroundStyle(Theme.inkSecondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                PrimaryButton(title: peer.verified ? "Remove verification" : "Mark as verified") {
                    store.toggleVerified(peer); dismiss()
                }
                Button("Close") { dismiss() }.foregroundStyle(.white)
                Spacer()
            }.padding(.horizontal, 20)
        }
        .presentationDetents([.medium, .large])
    }
}
