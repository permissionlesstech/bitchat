import Foundation

enum SendOutcome { case sent, unreachable, failed }

/// Wire packet (JSON). See PROTOCOL.md. Optional fields are omitted when nil.
struct Packet: Codable {
    var v: Int = 2
    var t: String            // "ann" | "msg" | "pub" | "ack"
    var id: String
    var src: String
    var dst: String? = nil
    var ttl: Int
    var ts: Int64
    var n: String? = nil     // sender nickname
    var pk: String? = nil    // ann: base64 X25519 public key
    var ct: String? = nil    // msg: base64 sealed text
    var tx: String? = nil    // pub: plain text
    var ref: String? = nil   // ack: id of the message being acknowledged
}

/// Multi-hop relay. Transport independent: the BLE layer (or a test harness) feeds packets in and
/// provides `transmit`. Peers announce themselves every few seconds; announcements, public messages and
/// direct messages are flooded with a hop limit and de-duplicated by packet id.
final class MeshRouter {
    static let startTTL = 5
    static let maxTextBytes = 180
    static let peerTimeout: TimeInterval = 40

    private struct PeerInfo { var name: String; var pk: Data; var hops: Int; var lastSeen: Date; var direct: Bool }

    let myID: String
    var myName: String
    private let crypto: MeshCrypto
    var now: () -> Date = { Date() }

    var transmit: ((_ link: String, _ data: Data, _ done: @escaping (Bool) -> Void) -> Void)?
    var onPeers: (([Peer]) -> Void)?
    var onText: ((_ from: String, _ name: String, _ text: String, _ hops: Int, _ msgID: String) -> Void)?
    var onPublic: ((_ from: String, _ name: String, _ text: String, _ id: String) -> Void)?
    var onDelivered: ((_ msgID: String) -> Void)?

    private var links: [String: String] = [:]      // link id -> peer id (direct neighbours)
    private var peers: [String: PeerInfo] = [:]
    private var rssi: [String: Int] = [:]
    private var seen = Set<String>()
    private var seenOrder: [String] = []
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(id: String, name: String, crypto: MeshCrypto) { myID = id; myName = name; self.crypto = crypto }

    static func clip(_ s: String) -> String {
        var out = ""; var n = 0
        for ch in s { let c = ch.utf8.count; if n + c > maxTextBytes { break }; out.append(ch); n += c }
        return out
    }

    // MARK: neighbours

    func neighborConnected(link: String, id: String, name: String, pk: Data) {
        guard id != myID, pk.count == 32 else { return }
        links[link] = id
        peers[id] = PeerInfo(name: name, pk: pk, hops: 1, lastSeen: now(), direct: true)
        emitPeers()
        sendAnnounce(to: [link])
    }

    func neighborLost(link: String) {
        guard let id = links.removeValue(forKey: link) else { return }
        if !links.values.contains(id) { peers.removeValue(forKey: id); rssi.removeValue(forKey: id) }
        emitPeers()
    }

    func updateRSSI(link: String, rssi value: Int) {
        guard let id = links[link] else { return }
        rssi[id] = value
        emitPeers()
    }

    // MARK: periodic

    /// Call every ~8 seconds: floods our announcement and forgets relayed peers we stopped hearing about.
    func tick() {
        let cutoff = now().addingTimeInterval(-Self.peerTimeout)
        let before = peers.count
        peers = peers.filter { $0.value.direct || $0.value.lastSeen > cutoff }
        if peers.count != before { emitPeers() }
        sendAnnounce(to: Array(links.keys))
    }

    private func sendAnnounce(to targets: [String]) {
        var p = Packet(t: "ann", id: UUID().uuidString, src: myID, ttl: Self.startTTL, ts: ms())
        p.n = myName; p.pk = crypto.publicKey.base64EncodedString()
        remember(p.id)
        guard let data = try? encoder.encode(p) else { return }
        for l in targets { transmit?(l, data) { _ in } }
    }

    // MARK: sending

    func sendText(_ text: String, to dst: String, msgID: String, completion: @escaping (SendOutcome) -> Void) {
        guard let info = peers[dst] else { completion(.unreachable); return }
        guard let ct = try? crypto.seal(Self.clip(text), peerPK: info.pk, myID: myID, peerID: dst, aad: msgID) else { completion(.failed); return }
        var p = Packet(t: "msg", id: msgID, src: myID, dst: dst, ttl: Self.startTTL, ts: ms())
        p.n = myName; p.ct = ct.base64EncodedString()
        remember(msgID)
        route(p, except: nil, completion: completion)
    }

    func sendPublic(_ text: String, msgID: String, completion: @escaping (SendOutcome) -> Void) {
        var p = Packet(t: "pub", id: msgID, src: myID, dst: nil, ttl: Self.startTTL, ts: ms())
        p.n = myName; p.tx = Self.clip(text)
        remember(msgID)
        route(p, except: nil, completion: completion)
    }

    // MARK: receiving

    func receive(_ data: Data, from link: String?) {
        guard let p = try? decoder.decode(Packet.self, from: data), p.v == 2, p.src != myID, !seen.contains(p.id) else { return }
        remember(p.id)
        let hops = max(1, Self.startTTL + 1 - p.ttl)
        switch p.t {
        case "ann":
            guard let s = p.pk, let pk = Data(base64Encoded: s), pk.count == 32 else { return }
            let direct = peers[p.src]?.direct ?? false
            peers[p.src] = PeerInfo(name: p.n ?? "?", pk: pk, hops: direct ? 1 : hops, lastSeen: now(), direct: direct)
            emitPeers()
            forward(p, from: link)
        case "msg":
            if p.dst == myID {
                guard let info = peers[p.src], let s = p.ct, let ct = Data(base64Encoded: s),
                      let text = try? crypto.open(ct, peerPK: info.pk, myID: myID, peerID: p.src, aad: p.id) else { return }
                onText?(p.src, p.n ?? info.name, text, hops, p.id)
                var ack = Packet(t: "ack", id: UUID().uuidString, src: myID, dst: p.src, ttl: Self.startTTL, ts: ms())
                ack.ref = p.id
                remember(ack.id)
                route(ack, except: nil) { _ in }
            } else { forward(p, from: link) }
        case "pub":
            if let tx = p.tx { onPublic?(p.src, p.n ?? "?", tx, p.id) }
            forward(p, from: link)
        case "ack":
            if p.dst == myID, let ref = p.ref { onDelivered?(ref) } else { forward(p, from: link) }
        default: break
        }
    }

    // MARK: internals

    private func forward(_ p: Packet, from link: String?) {
        guard p.ttl > 1 else { return }
        var q = p; q.ttl -= 1
        route(q, except: link, completion: nil)
    }

    /// Sends straight to the destination if it is a neighbour, otherwise floods to all other neighbours.
    private func route(_ p: Packet, except: String?, completion: ((SendOutcome) -> Void)?) {
        var targets = links.keys.filter { $0 != except }
        if let dst = p.dst, let direct = links.first(where: { $0.value == dst })?.key { targets = [direct] }
        guard !targets.isEmpty, let data = try? encoder.encode(p) else { completion?(targets.isEmpty ? .unreachable : .failed); return }
        var pending = targets.count; var ok = false
        for l in targets {
            transmit?(l, data) { success in
                if success { ok = true }
                pending -= 1
                if pending == 0 { completion?(ok ? .sent : .failed) }
            }
        }
    }

    private func emitPeers() {
        onPeers?(peers.map { id, i in
            let r = i.direct ? (rssi[id] ?? -80) : -70 - 8 * i.hops
            return Peer(id: id, name: i.name, hops: i.hops, rssi: min(-40, max(-95, r)), fingerprint: MeshCrypto.fingerprint(i.pk))
        }.sorted { $0.id < $1.id })
    }

    private func remember(_ id: String) {
        seen.insert(id); seenOrder.append(id)
        if seenOrder.count > 1500 { seen.remove(seenOrder.removeFirst()) }
    }
    private func ms() -> Int64 { Int64(now().timeIntervalSince1970 * 1000) }
}
