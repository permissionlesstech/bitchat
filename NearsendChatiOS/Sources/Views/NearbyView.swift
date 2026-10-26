import SwiftUI

struct NearbyView: View {
    @EnvironmentObject var store: ChatStore
    @State private var chat: Peer?

    var body: some View {
        NavigationStack {
            ZStack {
                SkyBackground()
                ScrollView {
                    VStack(spacing: 16) {
                        PageTitle(text: "Nearby").padding(.top, 8)
                        header
                        Card(padding: 12) { RadarView(peers: store.peers).frame(height: 320) }
                        peerList
                    }.padding(.horizontal, 20).padding(.bottom, 24)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $chat) { p in ThreadView(conversationID: p.id, peer: p) }
        }
    }

    private var statusOK: Bool { store.meshActive && (store.simulated || store.bluetoothState == "ready") }
    private var needsSettings: Bool { !store.simulated && ["off", "unauthorized"].contains(store.bluetoothState) }
    private var statusText: String {
        if !store.meshActive { return "Mesh paused" }
        if store.simulated { return "Demo data · simulator" }
        switch store.bluetoothState {
        case "ready": return "Bluetooth live · offline"
        case "off": return "Bluetooth is off"
        case "unauthorized": return "Bluetooth not allowed"
        case "unsupported": return "Bluetooth unsupported"
        default: return "Starting Bluetooth…"
        }
    }
    private var subtitle: String {
        if !store.simulated && store.bluetoothState == "unauthorized" { return "Allow Bluetooth for Nearsend Chat in Settings" }
        if !store.simulated && store.bluetoothState == "off" { return "Turn Bluetooth on to find people nearby" }
        if store.peers.isEmpty && !store.simulated { return "Open the app on another phone to connect" }
        return ""
    }

    private var header: some View {
        Card {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    StatusPill(text: LocalizedStringKey(statusText), color: statusOK ? Theme.secure : Theme.inkSecondary)
                    if store.peers.count == 1 { Text("1 person in range").font(.title3.weight(.semibold)) }
                    else { Text("\(store.peers.count) people in range").font(.title3.weight(.semibold)) }
                    if !subtitle.isEmpty { Text(LocalizedStringKey(subtitle)).font(.footnote).foregroundStyle(Theme.inkSecondary) }
                    else { Text("\(store.relayedCount) reachable via relay").font(.footnote).foregroundStyle(Theme.inkSecondary) }
                    if needsSettings {
                        Button("Open Settings") { SystemSettings.open() }.font(.footnote.weight(.semibold)).foregroundStyle(Theme.link)
                    }
                }
                Spacer()
                Toggle("Mesh", isOn: $store.meshActive).labelsHidden().tint(Theme.actionBlue)
            }
        }
    }

    private var peerList: some View {
        VStack(spacing: 10) {
            ForEach(store.peers) { p in
                Button { store.ensureConversation(p); chat = p } label: {
                    Card(padding: 12) {
                        HStack(spacing: 12) {
                            Avatar(name: p.name, online: true).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 4) {
                                    Text(verbatim: p.name).font(.headline)
                                    if p.verified { Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.actionBlue).font(.caption).accessibilityLabel("Verified") }
                                }
                                if p.hops == 1 { Text("Direct · \(p.rssi) dBm").font(.footnote).foregroundStyle(Theme.inkSecondary) }
                                else { Text("\(p.hops) hops via relay").font(.footnote).foregroundStyle(Theme.inkSecondary) }
                            }
                            Spacer()
                            SignalBars(rssi: p.rssi, hops: p.hops)
                        }
                    }
                }.buttonStyle(.plain)
            }
        }
    }
}

struct SignalBars: View {
    let rssi: Int
    var hops = 1
    private var level: Int { rssi > -55 ? 4 : rssi > -70 ? 3 : rssi > -82 ? 2 : 1 }
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(i <= level ? Theme.actionBlue : Theme.inkSecondary.opacity(0.3))
                    .frame(width: 4, height: CGFloat(4 + i * 4))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Signal \(level) of 4")
    }
}

struct RadarView: View {
    let peers: [Peer]
    @State private var sweep = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let tail = 0.16 // fraction of a turn the fading tail covers

    var body: some View {
        GeometryReader { g in
            let size = min(g.size.width, g.size.height)
            let c = CGPoint(x: g.size.width / 2, y: g.size.height / 2)
            ZStack {
                ForEach(1...4, id: \.self) { i in
                    Circle().stroke(Theme.ink.opacity(0.10), lineWidth: 1)
                        .frame(width: size * CGFloat(i) / 4, height: size * CGFloat(i) / 4)
                }
                Rectangle().fill(Theme.ink.opacity(0.08)).frame(width: 1, height: size)
                Rectangle().fill(Theme.ink.opacity(0.08)).frame(width: size, height: 1)

                // Thin sweep: a short fading tail that ends in a bright leading edge at 3 o'clock, then rotates.
                ZStack {
                    AngularGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .clear, location: 1 - tail),
                        .init(color: Theme.actionBlue.opacity(0.45), location: 0.999),
                        .init(color: .clear, location: 1),
                    ], center: .center)
                    .mask(Circle())
                    Rectangle().fill(Theme.actionBlue)
                        .frame(width: size / 2, height: 2)
                        .offset(x: size / 4)
                }
                .frame(width: size, height: size)
                .rotationEffect(.degrees(sweep))

                Circle().fill(Theme.actionBlue).frame(width: 14, height: 14)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .shadow(color: Theme.actionBlue.opacity(0.6), radius: 8)

                ForEach(peers) { p in
                    let r = radius(p) * size / 2
                    let a = angle(p)
                    VStack(spacing: 3) {
                        Circle().fill(p.hops == 1 ? Theme.actionBlue : Color.white)
                            .overlay(Circle().stroke(Theme.actionBlue, lineWidth: 2))
                            .frame(width: 13, height: 13)
                        Text(verbatim: p.name).font(.caption2.weight(.medium)).foregroundStyle(Theme.ink)
                    }
                    .position(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
                    .animation(.easeInOut(duration: 1), value: p.rssi)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Radar")
        .accessibilityValue(peers.count == 1 ? "1 person nearby" : "\(peers.count) people nearby")
        .onAppear { if !reduceMotion { withAnimation(.linear(duration: 4).repeatForever(autoreverses: false)) { sweep = 360 } } }
    }

    /// RSSI -40 → near centre, -95 → edge
    private func radius(_ p: Peer) -> CGFloat { CGFloat(min(1, max(0.18, Double(-40 - p.rssi) / 55))) }
    /// Golden-angle spread from the id so people don't bunch together and stay put between updates.
    private func angle(_ p: Peer) -> CGFloat {
        let h = p.id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFFFF }
        return CGFloat((Double(h) * 137.508).truncatingRemainder(dividingBy: 360)) * .pi / 180
    }
}
