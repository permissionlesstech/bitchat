import BitFoundation
import Foundation
@testable import bitchat

/// A deterministic multi-node mesh over real `BLEService` engines and no
/// CoreBluetooth: nodes are wired edge-to-edge through the outbound packet
/// tap and the production ingress-attribution path (`_test_ingestFrame`),
/// so announces bind links, signatures verify, Noise handshakes complete,
/// and rotation rebinds run exactly the engine code a radio would drive.
///
/// Determinism model: outbound packets are buffered under a lock (the tap
/// fires on each sender's engine); the test thread pumps deliveries and
/// fences every engine between rounds. Timer-driven work (relay jitter,
/// deferred flushes) is released explicitly through each node's
/// `BLEEngineManualScheduler` via `advanceTime`.
///
/// Fidelity boundary: there are no physical links, so per-link fanout
/// planning always reports failure to the sender (directed packets spool)
/// — every capture happens at the pre-planning tap. Protocol-level
/// behavior (attribution, binding, dedup, TTL, relay decisions, sessions)
/// is faithful; link-selection and backpressure behavior is not exercised.
///
/// Announce accounting (opt-in, `init(announceAccounting: true)`; the
/// original suites run without it) makes announce counts a deterministic
/// function of the protocol:
/// - each node's announce throttle reads its manual engine clock, so
///   forced-announce admission follows virtual time, not runner speed;
/// - relays wait one fixed delay instead of random jitter, so a flood
///   reaches every node within its TTL range in hop-count waves rather than
///   depending on which copy wins a race;
/// - a directed frame whose recipient neighbours the sender reaches only
///   that neighbour, as production link selection does — otherwise every
///   handshake and sync request floods the harness;
/// - initial gossip sync is sent by `exchangeInitialSync` instead of
///   production's main-actor hop and wall-clock delay (which land at
///   arbitrary pump positions), and pumping fences each gossip queue.
final class SimulatedMesh {
    struct Node {
        let service: BLEService
        let scheduler: BLEEngineManualScheduler
    }

    private let lock = NSLock()
    private var pendingDeliveries: [(from: Int, packet: BitchatPacket)] = []
    /// Total (packet, receiving-node) deliveries pumped — the storm bound.
    private(set) var deliveredFrameCount = 0
    /// Deliveries of TTL > 0 frames (sync replies excluded), per type.
    private var floodFramesByType: [UInt8: Int] = [:]
    private let announceAccounting: Bool
    /// Fine step while frames flow: link-up delays, relay delays and
    /// announce retries are all tens to hundreds of milliseconds, and a
    /// coarser step collapses them onto one instant of the virtual clock.
    private static let fineStep: TimeInterval = 0.05
    /// Mid-range of the production relay jitter (10–220 ms by degree).
    private static let relayDelay: TimeInterval = 0.1
    /// Each node's throttle clock: this base plus its scheduler's time.
    private static let virtualClockBase = Date(timeIntervalSinceReferenceDate: 0)

    init(announceAccounting: Bool = false) {
        self.announceAccounting = announceAccounting
    }

    private(set) var nodes: [Node] = []
    private var neighbors: [Set<Int>] = []
    private var duplicateLinkEdges: Set<String> = []
    private var emitted: [[BitchatPacket]] = []

    /// Every packet a node has put on the wire — the attacker's capture
    /// buffer for replay tests.
    func emittedPackets(from index: Int) -> [BitchatPacket] {
        lock.lock()
        defer { lock.unlock() }
        return emitted[index]
    }

    @discardableResult
    func addNode(nickname: String) -> Node {
        let keychain = MockKeychain()
        let identityManager = MockIdentityManager(keychain)
        let idBridge = NostrIdentityBridge(keychain: MockKeychainHelper())
        let scheduler = BLEEngineManualScheduler()
        let service = BLEService(
            keychain: keychain,
            idBridge: idBridge,
            identityManager: identityManager,
            initializeBluetoothManagers: false,
            engineScheduler: scheduler
        )
        let index = nodes.count
        let node = Node(service: service, scheduler: scheduler)
        // An earlier node's engine can fire its tap (which reads `emitted`
        // under the lock) while this append reallocates the array.
        lock.lock()
        nodes.append(node)
        neighbors.append([])
        emitted.append([])
        lock.unlock()
        // The tap must be live before `setNickname` below: setNickname
        // force-announces asynchronously on the engine, and if that slot
        // ran in the gap before a later tap install, the announce was
        // emitted invisibly while still stamping the wall-clock announce
        // throttle — swallowing `announceAll`'s forced announce on a
        // starved runner (the CI flake this ordering fixes).
        if announceAccounting {
            service._test_announceClock = { [scheduler] in
                Self.virtualClockBase.addingTimeInterval(scheduler.currentTime)
            }
            service._test_suppressAutoInitialSync = true
            service._test_fixedRelayDelay = Self.relayDelay
        }
        service._test_onOutboundPacket = { [weak self] packet in
            // Runs on the sender's engine; only buffer here — delivering
            // inline would nest one engine inside another.
            guard let self else { return }
            self.lock.lock()
            self.pendingDeliveries.append((from: index, packet: packet))
            self.emitted[index].append(packet)
            self.lock.unlock()
        }
        service.setNickname(nickname)
        return node
    }

    func connect(_ a: Int, _ b: Int) {
        neighbors[a].insert(b)
        neighbors[b].insert(a)
    }

    /// Radio silence: stops delivering between two nodes without reporting
    /// any link event, so existing bindings persist exactly as they do when
    /// a peer walks out of range before its link times out. Lets a test
    /// capture a packet the far side never received.
    func silence(_ a: Int, _ b: Int) {
        neighbors[a].remove(b)
        neighbors[b].remove(a)
    }

    /// Models two live links to the same phone (issue #1538): every frame
    /// from the neighbour arrives twice, on two link IDs that both bind to
    /// the sender.
    ///
    /// Both are central links — the remote's connections to our peripheral
    /// role. That is deliberate and faithful to the defect: central links
    /// are the ones we cannot cancel (they belong to the remote), so they
    /// are exactly the links the peripheral-cancel path cannot reach after
    /// a rotation. Peripheral-role bindings additionally require physical
    /// link state keyed by a real CBPeripheral, which no CB-free harness
    /// can fabricate.
    func connectDuplicateLinks(_ a: Int, _ b: Int) {
        connect(a, b)
        duplicateLinkEdges.insert(Self.edgeKey(a, b))
    }

    /// The synthetic central link a frame from `sender` arrives on at
    /// `receiver`. Stable per directed edge, like a CoreBluetooth central
    /// UUID.
    func linkUUID(from sender: Int, at receiver: Int) -> String {
        "SIM-\(sender)-TO-\(receiver)"
    }

    /// Order-independent edge key.
    private static func edgeKey(_ a: Int, _ b: Int) -> String {
        "\(min(a, b))-\(max(a, b))"
    }

    /// The second link of a duplicate-link edge.
    func duplicateLinkUUID(from sender: Int, at receiver: Int) -> String {
        "SIM-DUP-\(sender)-TO-\(receiver)"
    }

    private func links(from sender: Int, at receiver: Int) -> [BLEIngressLinkID] {
        var links: [BLEIngressLinkID] = [.central(linkUUID(from: sender, at: receiver))]
        if duplicateLinkEdges.contains(Self.edgeKey(sender, receiver)) {
            links.append(.central(duplicateLinkUUID(from: sender, at: receiver)))
        }
        return links
    }

    func forceAnnounce(from index: Int) {
        nodes[index].service._test_forceAnnounce()
        pump()
    }

    /// Pumps buffered deliveries until the mesh is quiescent: no pending
    /// frames and every engine drained. Timer-deferred work stays pending
    /// until `advanceTime`.
    func pump(maxRounds: Int = 64) {
        for _ in 0..<maxRounds {
            lock.lock()
            let batch = pendingDeliveries
            pendingDeliveries.removeAll()
            lock.unlock()

            if batch.isEmpty {
                // Engines may still be running slots that will emit more.
                nodes.forEach { $0.service._test_fenceEngine() }
                if announceAccounting {
                    // Sync requests are answered on each node's gossip
                    // queue, which hands its replies back to the engine.
                    nodes.forEach { $0.service._test_fenceGossip() }
                    nodes.forEach { $0.service._test_fenceEngine() }
                }
                lock.lock()
                let stillEmpty = pendingDeliveries.isEmpty
                lock.unlock()
                if stillEmpty { return }
                continue
            }

            for (from, packet) in batch {
                for receiver in receivers(of: packet, from: from) {
                    for link in links(from: from, at: receiver) {
                        deliveredFrameCount += 1
                        if packet.ttl > 0 {
                            floodFramesByType[packet.type, default: 0] += 1
                        }
                        nodes[receiver].service._test_ingestFrame(packet, link: link)
                    }
                }
            }
            nodes.forEach { $0.service._test_fenceEngine() }
        }
        fatalError("SimulatedMesh.pump did not quiesce in \(maxRounds) rounds — relay storm?")
    }

    /// Advances every node's engine clock (releasing relay jitter, retries,
    /// deferred flushes) and pumps the resulting traffic.
    func advanceTime(by interval: TimeInterval) {
        nodes.forEach { $0.scheduler.advance(by: interval) }
        pump()
    }

    /// Who hears `packet` from `sender`: every neighbour, except that in
    /// announce accounting a directed frame for a neighbour reaches only it.
    private func receivers(of packet: BitchatPacket, from sender: Int) -> Set<Int> {
        guard announceAccounting,
              let recipient = packet.recipientID,
              !recipient.allSatisfy({ $0 == 0xFF }) else {
            return neighbors[sender]
        }
        let recipientID = PeerID(hexData: recipient)
        guard let target = neighbors[sender].first(where: {
            nodes[$0].service.myPeerID == recipientID
        }) else {
            return neighbors[sender]
        }
        return [target]
    }

    /// Full discovery round: every node announces, traffic settles.
    ///
    /// Resets each node's announce throttle first: the throttle window is
    /// wall-clock, so any announce that already ran (setNickname's, in
    /// `addNode`) would otherwise swallow this forced one whenever the two
    /// land within the forced minimum interval — which is always, on any
    /// runner. `forceAnnounce(from:)` deliberately does NOT reset — the
    /// panic-rotation tests pin the production reset behavior through it.
    func announceAll() {
        for node in nodes {
            node.service._test_resetAnnounceThrottle()
            node.service._test_forceAnnounce()
        }
        pump()
    }

    /// Advances scheduler time one second per round until `condition`
    /// holds (or the round budget runs out — the caller's assertion then
    /// reports the real failure). Protocol exchanges normally settle in
    /// one or two rounds; under a heavily loaded parallel suite, engine
    /// slots can interleave with wall-clock-windowed crypto decisions and
    /// need a retry cycle or two more. Deterministic: rounds are scheduler
    /// time, never sleeps.
    func settleUntil(maxRounds: Int = 20, _ condition: () -> Bool) {
        for _ in 0..<maxRounds {
            if condition() { return }
            advanceTime(by: 1)
        }
    }

    // MARK: - Announce accounting

    /// A width×height grid in announce-accounting mode, each node linked to
    /// its 4 orthogonal neighbours — or to all 8 king-move neighbours, which
    /// puts interior nodes in the dense regime where relays clamp TTL —
    /// after a full discovery round has settled.
    static func grid(width: Int, height: Int, kingMoves: Bool) -> SimulatedMesh {
        let mesh = SimulatedMesh(announceAccounting: true)
        for index in 0..<(width * height) {
            mesh.addNode(nickname: "n\(index)")
        }
        func node(_ x: Int, _ y: Int) -> Int { y * width + x }
        for y in 0..<height {
            for x in 0..<width {
                if x + 1 < width { mesh.connect(node(x, y), node(x + 1, y)) }
                if y + 1 < height { mesh.connect(node(x, y), node(x, y + 1)) }
                guard kingMoves, y + 1 < height else { continue }
                if x + 1 < width { mesh.connect(node(x, y), node(x + 1, y + 1)) }
                if x > 0 { mesh.connect(node(x, y), node(x - 1, y + 1)) }
            }
        }
        mesh.announceAll()
        mesh.settle()
        return mesh
    }

    /// Adds a phone that launched a while ago: its launch announce went out
    /// before any link existed, and its throttle owes nothing. Returns the
    /// new node's index.
    func launch(nickname: String) -> Int {
        addNode(nickname: nickname)
        pump()
        let index = nodes.count - 1
        nodes[index].service._test_resetAnnounceThrottle()
        return index
    }

    /// A link coming up: each side runs the production link-up trigger with
    /// its production delay — the central's once our copy of the peer's
    /// characteristic is stored, the peripheral's once the central
    /// subscribed. (The CoreBluetooth callbacks themselves are outside the
    /// harness.)
    func linkUp(central: Int, peripheral: Int) {
        connect(central, peripheral)
        nodes[central].service.scheduleLinkUpAnnounce(
            after: TransportConfig.blePostSubscribeAnnounceDelaySeconds
        )
        nodes[peripheral].service.scheduleLinkUpAnnounce(
            after: TransportConfig.blePostAnnounceDelaySeconds
        )
    }

    /// `central` brings up a link to each of `peripherals` the way phones
    /// do: link-up announces, then — one second after the connection, as
    /// `.peerConnected` schedules it — initial gossip sync both ways, then
    /// traffic settles.
    func join(_ central: Int, linkingTo peripherals: [Int]) {
        for peripheral in peripherals {
            linkUp(central: central, peripheral: peripheral)
        }
        advanceTime(by: 1, inStepsOf: Self.fineStep)
        for peripheral in peripherals {
            exchangeInitialSync(central, peripheral)
        }
        settle()
    }

    /// Both directions of the initial gossip sync between two linked nodes.
    func exchangeInitialSync(_ a: Int, _ b: Int) {
        nodes[a].service._test_requestInitialSyncNow(to: nodes[b].service.myPeerID)
        nodes[b].service._test_requestInitialSyncNow(to: nodes[a].service.myPeerID)
        pump()
    }

    func advanceTime(by interval: TimeInterval, inStepsOf step: TimeInterval) {
        for _ in 0..<Int((interval / step).rounded()) {
            advanceTime(by: step)
        }
    }

    /// Advances in fine steps until a full second passes with no frame
    /// delivered, or ten seconds pass (a mesh that never goes quiet).
    func settle() {
        let quietTarget = Int((1 / Self.fineStep).rounded())
        let cap = Int((10 / Self.fineStep).rounded())
        var quietSteps = 0
        var steps = 0
        while quietSteps < quietTarget, steps < cap {
            let before = deliveredFrameCount
            advanceTime(by: Self.fineStep)
            quietSteps = deliveredFrameCount == before ? quietSteps + 1 : 0
            steps += 1
        }
    }

    /// Announces a node put on the wire under any of its identities: TTL at
    /// the origination value. Relays always decrement it and sync replies
    /// carry TTL 0, so this counts exactly the node's own announces.
    func announceOriginations(from index: Int) -> Int {
        emittedPackets(from: index).filter {
            $0.type == MessageType.announce.rawValue
                && $0.ttl == TransportConfig.messageTTLDefault
        }.count
    }

    /// Deliveries of flooded (TTL > 0) frames of one type over all links.
    func floodFrameCount(ofType type: MessageType) -> Int {
        floodFramesByType[type.rawValue, default: 0]
    }

    /// Whether node `a`'s peer registry holds node `b`.
    func knows(_ a: Int, _ b: Int) -> Bool {
        nodes[a].service._test_knownPeerIDs().contains(nodes[b].service.myPeerID)
    }
}
