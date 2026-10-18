import Foundation
import Combine

/// UI-facing state. On a real iPhone it is driven by `BLETransport`; the iOS Simulator has no Bluetooth,
/// so there it shows demo data instead.
@MainActor
final class ChatStore: ObservableObject {
    @Published var peers: [Peer] = []
    @Published var conversations: [Conversation] = []
    @Published var nickname: String {
        didSet { UserDefaults.standard.set(nickname, forKey: "nickname") }
    }
    @Published var meshActive = true {
        didSet {
            guard !simulated, oldValue != meshActive else { return }
            if meshActive { transport?.start() } else { transport?.stop(); peers = [] }
        }
    }
    @Published var bluetoothState = "starting"   // starting | ready | off | unauthorized | unsupported

    let simulated: Bool
    let deviceID: String
    private var transport: BLETransport?
    private var started = false

    init() {
        let d = UserDefaults.standard
        nickname = d.string(forKey: "nickname") ?? "anon-\(Int.random(in: 1000...9999))"
        if d.string(forKey: "deviceID") == nil { d.set(UUID().uuidString, forKey: "deviceID") }
        deviceID = d.string(forKey: "deviceID") ?? UUID().uuidString
        #if targetEnvironment(simulator)
        simulated = true
        seed(); drift()
        #else
        simulated = false
        #endif
    }

    var relayedCount: Int { peers.filter { $0.hops > 1 }.count }

    /// Called once onboarding is done, so the Bluetooth permission prompt appears at a sensible moment.
    func startIfNeeded() {
        guard !simulated, !started else { return }
        started = true
        let t = BLETransport(id: deviceID, name: nickname)
        t.onPeers = { [weak self] p in Task { @MainActor in self?.peers = p } }
        t.onState = { [weak self] s in Task { @MainActor in self?.bluetoothState = s } }
        t.onMessage = { [weak self] id, name, text in Task { @MainActor in self?.receive(id, name, text) } }
        transport = t
        t.start()
    }

    func applyNickname() { transport?.setName(nickname) }

    func ensureConversation(_ peer: Peer) {
        if !conversations.contains(where: { $0.id == peer.id }) {
            conversations.insert(Conversation(id: peer.id, peer: peer, messages: []), at: 0)
        }
    }

    func markRead(_ id: String) {
        if let i = conversations.firstIndex(where: { $0.id == id }), conversations[i].unread > 0 { conversations[i].unread = 0 }
    }

    func send(_ text: String, in id: String) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        let m = Message(text: text, date: .now, mine: true, state: .sending)
        conversations[i].messages.append(m)
        if simulated {
            Task {
                try? await Task.sleep(for: .milliseconds(600)); update(m.id, in: id, .sent)
                try? await Task.sleep(for: .milliseconds(900)); update(m.id, in: id, .delivered)
            }
        } else {
            transport?.send(text, to: id) { [weak self] ok in
                Task { @MainActor in self?.update(m.id, in: id, ok ? .delivered : .failed) }
            } ?? update(m.id, in: id, .failed)
        }
    }

    private func receive(_ id: String, _ name: String, _ text: String) {
        let peer = peers.first { $0.id == id } ?? Peer(id: id, name: name, hops: 1, rssi: -70)
        ensureConversation(peer)
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[i].messages.append(Message(text: text, date: .now, mine: false))
        conversations[i].unread += 1
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
