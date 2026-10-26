import Foundation

// Cross-platform protocol checks. Run in CI: swiftc Sources/Models/Models.swift Sources/Mesh/MeshCrypto.swift Sources/Mesh/MeshRouter.swift Tests/main.swift
var failures = 0
func check(_ ok: Bool, _ what: String) { print((ok ? "PASS " : "FAIL ") + what); if !ok { failures += 1 } }
func hex(_ s: String) -> Data {
    var d = Data(); var i = s.startIndex
    while i < s.endIndex { let j = s.index(i, offsetBy: 2); d.append(UInt8(s[i..<j], radix: 16)!); i = j }
    return d
}

// 1. Test vectors generated with Python `cryptography` (see PROTOCOL.md): must decrypt, and sealing must reproduce them bit for bit.
let skA = hex("0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20")
let skB = hex("65666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f8081828384")
let combined = hex("c8c9cacbcccdcecfd0d1d2d3b7f7d3789adc70b46a831626878bc5809086ac2253d1ba553d06af4445a5b4c525")
let a = try! MeshCrypto(privateKeyData: skA), b = try! MeshCrypto(privateKeyData: skB)
check(a.publicKey == hex("07a37cbc142093c8b755dc1b10e86cb426374ad16aa853ed0bdfc0b2b86d1c7c"), "public key derivation")
check((try? b.open(combined, peerPK: a.publicKey, myID: "bob", peerID: "alice", aad: "m-1")) == "Hej världen 👋", "decrypt Python vector")
check((try? a.seal("Hej världen 👋", peerPK: b.publicKey, myID: "alice", peerID: "bob", aad: "m-1", nonce: combined.prefix(12))) == combined, "seal reproduces Python vector")
check((try? b.open(combined, peerPK: a.publicKey, myID: "bob", peerID: "alice", aad: "other")) == nil, "wrong AAD rejected")
var tampered = combined; tampered[20] ^= 1
check((try? b.open(tampered, peerPK: a.publicKey, myID: "bob", peerID: "alice", aad: "m-1")) == nil, "tampered ciphertext rejected")
check(a.fingerprint == "AAA8 FFF7 03B5 0B22\n97F4 F6E1 3508 F724", "fingerprint format")
check(MeshRouter.clip(String(repeating: "å", count: 200)).utf8.count <= 180, "clip to 180 UTF-8 bytes")

// 2. Simulated networks.
final class Node {
    let id: String; let router: MeshRouter; let crypto: MeshCrypto
    var texts: [(from: String, text: String, hops: Int)] = []; var pubs: [String] = []; var delivered: [String] = []; var peers: [Peer] = []
    init(_ id: String, net: Net) {
        let c = MeshCrypto()
        self.id = id; self.crypto = c
        router = MeshRouter(id: id, name: id, crypto: c)
        router.transmit = { link, data, done in net.deliver(from: id, to: link, data); done(true) }
        router.onPeers = { [unowned self] in self.peers = $0 }
        router.onText = { [unowned self] f, _, t, h, _ in self.texts.append((f, t, h)) }
        router.onPublic = { [unowned self] _, _, t, _ in self.pubs.append(t) }
        router.onDelivered = { [unowned self] in self.delivered.append($0) }
    }
}
final class Net {
    var nodes: [String: Node] = [:]
    func add(_ id: String) -> Node { let n = Node(id, net: self); nodes[id] = n; return n }
    func deliver(from: String, to: String, _ data: Data) { nodes[to]?.router.receive(data, from: from) }
    func connect(_ x: String, _ y: String) {
        nodes[x]!.router.neighborConnected(link: y, id: y, name: y, pk: nodes[y]!.crypto.publicKey)
        nodes[y]!.router.neighborConnected(link: x, id: x, name: x, pk: nodes[x]!.crypto.publicKey)
    }
    func settle() { for _ in 0..<3 { nodes.values.forEach { $0.router.tick() } } }
}

do { // line A-B-C-D
    let net = Net(); let n = ["A", "B", "C", "D"].map { net.add($0) }
    net.connect("A", "B"); net.connect("B", "C"); net.connect("C", "D"); net.settle()
    check(n[0].peers.first { $0.id == "D" }?.hops == 3, "A sees D at 3 hops")
    var outcome: SendOutcome?
    n[0].router.sendText("hello D", to: "D", msgID: "id-1") { outcome = $0 }
    check(outcome == .sent, "send over 3 hops reports sent")
    check(n[3].texts.count == 1 && n[3].texts[0].text == "hello D" && n[3].texts[0].from == "A", "D receives decrypted text from A")
    check(n[3].texts.first?.hops == 3, "D reports 3 hops")
    check(n[0].delivered == ["id-1"], "A gets delivery ack")
    check(n[1].texts.isEmpty && n[2].texts.isEmpty, "relays cannot read the message")
    n[0].router.sendPublic("hi all", msgID: "pub-1") { _ in }
    check(n[1].pubs == ["hi all"] && n[3].pubs == ["hi all"], "public message reaches every node once")
}
do { // 8-node line: only 5 hops reachable
    let net = Net(); let ids = (0..<8).map { "N\($0)" }; let n = ids.map { net.add($0) }
    for i in 0..<7 { net.connect(ids[i], ids[i + 1]) }; net.settle()
    check(Set(n[0].peers.map { $0.id }) == Set(["N1", "N2", "N3", "N4", "N5"]), "TTL limits reach to 5 hops")
    var outcome: SendOutcome?
    n[0].router.sendText("far", to: "N7", msgID: "id-far") { outcome = $0 }
    check(outcome == .unreachable, "unknown far peer reports unreachable (queued by the app)")
}
do { // triangle: no duplicate delivery
    let net = Net(); let n = ["A", "B", "C"].map { net.add($0) }
    net.connect("A", "B"); net.connect("B", "C"); net.connect("C", "A"); net.settle()
    n[0].router.sendText("once", to: "C", msgID: "id-tri") { _ in }
    n[0].router.sendPublic("loop", msgID: "pub-tri") { _ in }
    check(n[2].texts.count == 1, "no duplicate delivery in a loop")
    check(n[1].pubs.count == 1 && n[2].pubs.count == 1, "public message de-duplicated in a loop")
}
do { // expiry
    let net = Net(); let n = ["A", "B", "C"].map { net.add($0) }
    net.connect("A", "B"); net.connect("B", "C"); net.settle()
    check(n[0].peers.count == 2, "A knows B and C")
    var t = Date(); n[0].router.now = { t }; t = t.addingTimeInterval(60); n[0].router.tick()
    check(n[0].peers.map { $0.id } == ["B"], "relayed peer expires after silence, direct neighbour stays")
    n[0].router.neighborLost(link: "B")
    check(n[0].peers.isEmpty, "neighbour removed when link is lost")
}
print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
