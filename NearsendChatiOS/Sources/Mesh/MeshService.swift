import Foundation
import SwiftUI

private struct SavedState: Codable {
    var nickname: String
    var conversations: [Conversation]
    var verified: [String]
}

/// UI-facing state. On a real iPhone it is driven by `BLETransport` + `MeshRouter`; the iOS Simulator has no
/// Bluetooth, so there it shows demo data instead. Conversations are saved on the device.
@MainActor
final class ChatStore: ObservableObject {
    /// One store per process. The app delegate starts it on a background relaunch, before any screen exists.
    static let shared = ChatStore()

    @Published var peers: [Peer] = []
    @Published var conversations: [Conversation] = []
    @Published var nickname: String {
        didSet { UserDefaults.standard.set(nickname, forKey: "nickname"); save() }
    }
    @Published var meshActive = true {
        didSet {
            guard !simulated, oldValue != meshActive else { return }
            if meshActive { transport?.start() } else { transport?.stop(); peers = [] }
        }
    }
    @Published var bluetoothState = "starting"   // starting | ready | off | unauthorized | unsupported
    @Published private(set) var myFingerprint = "A3F1 9C02 7BD4 E58A\n11C0 4F6E 92AB 3D77"
    @Published private(set) var verified: Set<String> = []

    let simulated: Bool
    var activeConversation: String?
    private var deviceID: String
    private var transport: BLETransport?
    private var router: MeshRouter?
    private var started = false
    private var timer: Timer?
    private var inflight = Set<String>()

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
        load()
        #endif
        ensurePublicChannel()
    }

    var relayedCount: Int { peers.filter { $0.hops > 1 }.count }
    var unreadTotal: Int { conversations.reduce(0) { $0 + $1.unread } }

    // MARK: lifecycle

    /// Called once onboarding is done, so the Bluetooth permission prompt appears at a sensible moment.
    func startIfNeeded() {
        guard !simulated, !started else { return }
        started = true
        Notifier.requestPermission()
        let crypto = KeyStore.loadOrCreate()
        myFingerprint = crypto.fingerprint
        let r = MeshRouter(id: deviceID, name: nickname, crypto: crypto)
        let t = BLETransport(id: deviceID, name: nickname, publicKey: crypto.publicKey)
        r.transmit = { [weak t] link, data, done in if let t { t.write(link: link, data: data, done: done) } else { done(false) } }
        r.onPeers = { [weak self] p in Task { @MainActor in self?.setPeers(p) } }
        r.onText = { [weak self] from, name, text, hops, id in Task { @MainActor in self?.receiveText(from: from, name: name, text: text, hops: hops, id: id) } }
        r.onPublic = { [weak self] from, name, text, id in Task { @MainActor in self?.receivePublic(from: from, name: name, text: text, id: id) } }
        r.onDelivered = { [weak self] id in Task { @MainActor in self?.markDelivered(id) } }
        t.onNeighbor = { link, id, name, pk in r.neighborConnected(link: link, id: id, name: name, pk: pk) }
        t.onLost = { r.neighborLost(link: $0) }
        t.onPacket = { r.receive($0, from: nil) }
        t.onRSSI = { r.updateRSSI(link: $0, rssi: $1) }
        t.onState = { [weak self] s in Task { @MainActor in self?.bluetoothState = s } }
        router = r; transport = t
        if meshActive { t.start() }
        timer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak r] _ in r?.tick() }
    }

    func applyNickname() {
        router?.myName = nickname
        transport?.setName(nickname)
    }

    /// Panic wipe: forget every message, key and setting. The phone gets a brand-new identity.
    func wipeAll() {
        transport?.stop(); timer?.invalidate()
        router = nil; transport = nil; started = false; inflight = []
        KeyStore.wipe()
        try? FileManager.default.removeItem(at: Self.fileURL)
        let d = UserDefaults.standard
        ["nickname", "deviceID", "onboarded", "tab"].forEach { d.removeObject(forKey: $0) }
        deviceID = UUID().uuidString; d.set(deviceID, forKey: "deviceID")
        verified = []; peers = []; conversations = []
        myFingerprint = simulated ? myFingerprint : ""
        nickname = "anon-\(Int.random(in: 1000...9999))"
        ensurePublicChannel()
        if simulated { seed() } else { startIfNeeded() }
    }

    // MARK: conversations

    private func index(_ id: String) -> Int? { conversations.firstIndex { $0.id == id } }

    func ensureConversation(_ peer: Peer) {
        if index(peer.id) == nil { conversations.append(Conversation(id: peer.id, peer: peer, messages: [])) }
    }

    func markRead(_ id: String) {
        if let i = index(id), conversations[i].unread > 0 { conversations[i].unread = 0; save() }
    }

    func toggleVerified(_ peer: Peer) {
        guard !peer.fingerprint.isEmpty else { return }
        if verified.contains(peer.fingerprint) { verified.remove(peer.fingerprint) } else { verified.insert(peer.fingerprint) }
        peers = peers.map { var p = $0; p.verified = verified.contains(p.fingerprint); return p }
        save()
    }

    func send(_ text: String, in id: String) {
        guard let i = index(id) else { return }
        let m = Message(text: text, date: .now, mine: true, state: .sending)
        conversations[i].messages.append(m)
        save()
        if simulated {
            Task {
                try? await Task.sleep(for: .milliseconds(600)); update(m.id, in: id, .sent)
                try? await Task.sleep(for: .milliseconds(900)); update(m.id, in: id, .delivered)
            }
        } else if id == publicChannelID {
            if let router {
                router.sendPublic(text, msgID: m.id) { [weak self] outcome in
                    Task { @MainActor in self?.update(m.id, in: id, outcome == .sent ? .sent : .failed) }
                }
            } else { update(m.id, in: id, .failed) }
        } else {
            trySend(m, to: id)
        }
    }

    func retry(_ messageID: String, in id: String) {
        guard let i = index(id), let j = conversations[i].messages.firstIndex(where: { $0.id == messageID }) else { return }
        conversations[i].messages[j].state = .sending
        conversations[i].messages[j].date = .now
        flushOutbox()
    }

    private func trySend(_ m: Message, to id: String) {
        guard let router, !inflight.contains(m.id) else { return }
        inflight.insert(m.id)
        router.sendText(m.text, to: id, msgID: m.id) { [weak self] outcome in
            Task { @MainActor in
                guard let self else { return }
                self.inflight.remove(m.id)
                switch outcome {
                case .sent: self.update(m.id, in: id, .sent)
                case .failed: self.update(m.id, in: id, .failed)
                case .unreachable: break          // stays queued until the person comes into range
                }
            }
        }
    }

    /// Sends queued messages whose recipient is now reachable; gives up after 10 minutes.
    private func flushOutbox() {
        guard !simulated else { return }
        for c in conversations where c.id != publicChannelID {
            for m in c.messages where m.mine && m.state == .sending {
                if Date().timeIntervalSince(m.date) > 600 { update(m.id, in: c.id, .failed) }
                else if peers.contains(where: { $0.id == c.id }) { trySend(m, to: c.id) }
            }
        }
    }

    private func setPeers(_ list: [Peer]) {
        let known = Set(peers.map { $0.id })
        var mapped = list.map { p -> Peer in var q = p; q.verified = verified.contains(q.fingerprint); return q }
        mapped.sort { $0.hops == $1.hops ? $0.rssi > $1.rssi : $0.hops < $1.hops }
        if mapped.contains(where: { !known.contains($0.id) }) { Notifier.peerHaptic() }
        peers = mapped
        for p in mapped { if let i = index(p.id) { conversations[i].peer = p } }
        flushOutbox()
    }

    private func receiveText(from: String, name: String, text: String, hops: Int, id: String) {
        let peer = peers.first { $0.id == from } ?? Peer(id: from, name: name, hops: hops, rssi: -80)
        ensureConversation(peer)
        guard let i = index(from), !conversations[i].messages.contains(where: { $0.id == id }) else { return }
        conversations[i].messages.append(Message(id: id, text: text, date: .now, mine: false, hops: hops))
        if activeConversation != from { conversations[i].unread += 1 }
        Notifier.notify(title: name, body: text)
        Notifier.messageHaptic()
        save()
    }

    private func receivePublic(from: String, name: String, text: String, id: String) {
        guard let i = index(publicChannelID), !conversations[i].messages.contains(where: { $0.id == id }) else { return }
        conversations[i].messages.append(Message(id: id, text: text, date: .now, mine: false, sender: name))
        if activeConversation != publicChannelID { conversations[i].unread += 1 }
        Notifier.notify(title: "#nearby · \(name)", body: text)
        save()
    }

    private func markDelivered(_ id: String) {
        for c in conversations where c.messages.contains(where: { $0.id == id }) { update(id, in: c.id, .delivered) }
    }

    private func update(_ mid: String, in id: String, _ s: DeliveryState) {
        guard let i = index(id), let j = conversations[i].messages.firstIndex(where: { $0.id == mid }) else { return }
        if conversations[i].messages[j].state == .delivered && s != .delivered { return }   // never downgrade
        conversations[i].messages[j].state = s
        save()
    }

    private func ensurePublicChannel() {
        if index(publicChannelID) == nil {
            conversations.insert(Conversation(id: publicChannelID, peer: Peer(id: publicChannelID, name: "Nearby", hops: 1, rssi: -50), messages: []), at: 0)
        }
    }

    // MARK: persistence

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("chat.json")
    }

    private func save() {
        guard !simulated else { return }
        let state = SavedState(nickname: nickname, conversations: conversations, verified: Array(verified))
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: Self.fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL), let s = try? JSONDecoder().decode(SavedState.self, from: data) else { return }
        conversations = s.conversations
        verified = Set(s.verified)
        // Messages still marked "sending" stay queued; they are retried when the person is next in range.
    }

    // MARK: demo data (simulator)

    private func seed() {
        peers = [
            Peer(id: "a", name: "Maja", hops: 1, rssi: -48, verified: true, fingerprint: "DEMO"),
            Peer(id: "b", name: "Erik", hops: 1, rssi: -66),
            Peer(id: "c", name: "Noor", hops: 2, rssi: -78),
            Peer(id: "d", name: "Luca", hops: 3, rssi: -88),
            Peer(id: "e", name: "Sofia", hops: 2, rssi: -72, verified: true),
        ]
        let now = Date()
        conversations = [
            Conversation(id: publicChannelID, peer: Peer(id: publicChannelID, name: "Nearby", hops: 1, rssi: -50), messages: [
                Message(text: "Anyone near the main stage?", date: now.addingTimeInterval(-300), mine: false, sender: "Luca"),
                Message(text: "Yes, by the left speaker", date: now.addingTimeInterval(-240), mine: true, state: .sent)], unread: 0),
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
