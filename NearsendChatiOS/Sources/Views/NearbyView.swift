import SwiftUI

struct NearbyView: View {
    @EnvironmentObject var store: ChatStore
    @State private var selected: Peer?
    @State private var chat: Peer?

    var body: some View {
        NavigationStack {
            ZStack {
                Backdrop()
                ScrollView {
                    VStack(spacing: 20) {
                        header
                        RadarView(peers: store.peers, selected: $selected)
                            .frame(height: 340)
                        peerList
                    }.padding(.horizontal, 20).padding(.bottom, 24)
                }
            }
            .navigationTitle("Nearby")
            .navigationDestination(item: $chat) { p in ThreadView(conversationID: p.id, peer: p) }
        }
    }

    private var header: some View {
        Card {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    StatusPill(text: store.meshActive ? "Mesh active · offline" : "Mesh paused", color: store.meshActive ? Theme.mint : Theme.warn)
                    Text("\(store.peers.count) people in range").font(.title3.weight(.semibold))
                    Text("\(store.relayedCount) reachable via relay").font(.footnote).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Toggle("", isOn: $store.meshActive).labelsHidden()
            }
        }
    }

    private var peerList: some View {
        VStack(spacing: 10) {
            ForEach(store.peers.sorted { $0.rssi > $1.rssi }) { p in
                Button { chat = p } label: {
                    Card(padding: 12) {
                        HStack(spacing: 12) {
                            Avatar(name: p.name, online: true)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 4) {
                                    Text(p.name).font(.headline)
                                    if p.verified { Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.cyan).font(.caption) }
                                }
                                Text(p.hops == 1 ? "Direct · \(p.rssi) dBm" : "\(p.hops) hops via relay")
                                    .font(.footnote).foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            SignalBars(rssi: p.rssi)
                        }
                    }
                }.buttonStyle(.plain)
            }
        }
    }
}

struct SignalBars: View {
    let rssi: Int
    private var level: Int { rssi > -55 ? 4 : rssi > -70 ? 3 : rssi > -82 ? 2 : 1 }
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(i <= level ? Theme.mint : Color.white.opacity(0.15))
                    .frame(width: 4, height: CGFloat(4 + i * 4))
            }
        }
    }
}

struct RadarView: View {
    let peers: [Peer]
    @Binding var selected: Peer?
    @State private var sweep = 0.0

    var body: some View {
        GeometryReader { g in
            let size = min(g.size.width, g.size.height)
            let c = CGPoint(x: g.size.width / 2, y: g.size.height / 2)
            ZStack {
                ForEach(1...4, id: \.self) { i in
                    Circle().stroke(Color.white.opacity(0.07), lineWidth: 1)
                        .frame(width: size * CGFloat(i) / 4, height: size * CGFloat(i) / 4)
                }
                AngularGradient(colors: [Theme.mint.opacity(0.0), Theme.mint.opacity(0.35)], center: .center, angle: .degrees(-60))
                    .clipShape(Circle())
                    .frame(width: size, height: size)
                    .rotationEffect(.degrees(sweep))
                    .mask(Circle().frame(width: size, height: size))
                Circle().fill(Theme.accent).frame(width: 14, height: 14)
                    .shadow(color: Theme.mint, radius: 10)
                ForEach(peers) { p in
                    let r = radius(p) * size / 2
                    let a = angle(p)
                    VStack(spacing: 3) {
                        Circle().fill(p.hops == 1 ? Theme.mint : Theme.violet).frame(width: 12, height: 12)
                            .shadow(color: (p.hops == 1 ? Theme.mint : Theme.violet).opacity(0.8), radius: 8)
                        Text(p.name).font(.caption2).foregroundStyle(Theme.textSecondary)
                    }
                    .position(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
                    .animation(.easeInOut(duration: 1), value: p.rssi)
                }
            }
        }
        .onAppear { withAnimation(.linear(duration: 4).repeatForever(autoreverses: false)) { sweep = 360 } }
    }

    /// RSSI -40 → near centre, -95 → edge
    private func radius(_ p: Peer) -> CGFloat {
        CGFloat(min(1, max(0.18, Double(-40 - p.rssi) / 55)))
    }
    private func angle(_ p: Peer) -> CGFloat {
        CGFloat(abs(p.id.hashValue % 360)) * .pi / 180
    }
}
