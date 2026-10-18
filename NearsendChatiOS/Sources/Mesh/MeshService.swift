import Foundation
import Combine

/// Transport boundary. A real implementation (CoreBluetooth + Noise XX) plugs in here.
protocol MeshTransport {
    func start()
    func stop()
    func send(_ text: String, to peerID: String)
}

/// UI-facing state. Backed by simulated data until a transport is wired in.
@MainActor
final class ChatStore: ObservableObject {
    @Published var peers: [Peer] = []
    @Published var conversations: [Conversation] = []
    @Published var nickname = "anon-\(Int.random(in: 1000...9999))"
    @Published var meshActive = true
    @Published var simulated = true

    init() { seed(); drift() }

    var relayedCount: Int { peers.filter { $0.hops > 1 }.count }

    func send(_ text: String, in id: String) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        let m = Message(text: text, date: .now, mine: true, state: .sending)
        conversations[i].messages.append(m)
        let mid = m.id
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            update(mid, in: id, .sent)
            try? await Task.sleep(for: .milliseconds(900))
            update(mid, in: id, .delivered)
        }
    }

    private func update(_ mid: UUID, in id: String, _ s: DeliveryState) {
        guard let i = conversations.firstIndex(where: { $0.id == id }),
              let j = conversations[i].messages.firstIndex(where: { $0.id == mid }) else { return }
        conversations[i].messages[j].state = s
    }

    private func seed() {
        peers = [
            Peer(id: "a", name: "Maja", hops: 1, rssi: -48, verified: true),
            Peer(id: "b", name: "Erik", hops: 1, rssi: -66),
            Peer(id: "c", name: "Noor", hops: 2, rssi: -78),
            Peer(id: "d", name: "Luca", hops: 3, rssi: -88),
            Peer(id: "e", name: "Sofia", hops: 2, rssi: -72, verified: true),
        ]
        let now = Date()
        conversations = [
            Conversation(id: "a", peer: peers[0], messages: [
                Message(text: "Are you at the north gate?", date: now.addingTimeInterval(-900), mine: false),
                Message(text: "Yes, by the water stand", date: now.addingTimeInterval(-840), mine: true),
                Message(text: "Coming now 👋", date: now.addingTimeInterval(-60), mine: false)], unread: 1),
            Conversation(id: "c", peer: peers[2], messages: [
                Message(text: "Relayed through Erik, nice range", date: now.addingTimeInterval(-7200), mine: false, hops: 2)]),
        ]
    }

    private func drift() {
        Task { while true {
            try? await Task.sleep(for: .seconds(2.5))
            for i in peers.indices { peers[i].rssi = max(-95, min(-40, peers[i].rssi + Int.random(in: -3...3))) }
        } }
    }
}
