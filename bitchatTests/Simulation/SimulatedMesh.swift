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
final class SimulatedMesh {
    struct Node {
        let service: BLEService
        let scheduler: BLEEngineManualScheduler
    }

    private let lock = NSLock()
    private var pendingDeliveries: [(from: Int, packet: BitchatPacket)] = []
    /// Total (packet, receiving-node) deliveries pumped — the storm bound.
    private(set) var deliveredFrameCount = 0
    /// The same deliveries split by packet type. A whole-mesh frame budget
    /// silently includes announce traffic, and announce *admission* is the one
    /// decision the manual scheduler does not own: `sendAnnounceNow` asks
    /// `announceThrottle.shouldSend(force:now: Date())` (BLEService), so
    /// whether a scheduled re-announce reaches the wire depends on real
    /// elapsed seconds, not on `advanceTime`. Burn 0.2s of wall clock in the
    /// middle of a test — the forced-announce window is 0.15s — and announce
    /// deliveries rise (measured: 22 → 36) while every other type is
    /// unchanged. A test that drains the mesh to quiet before it measures
    /// absorbs that into its baseline; one that cannot has a budget moving
    /// with runner load. Counting per type lets a test bound the traffic it
    /// is actually about either way.
    private var deliveredFrameCountsByType: [UInt8: Int] = [:]

    /// Deliveries of one packet type — the storm bound for a specific kind of
    /// traffic, immune to unrelated announce frames.
    /// Unlocked deliberately, matching `deliveredFrameCount` above: both
    /// counters are written only by `pump` on the test thread (the outbound
    /// tap touches `pendingDeliveries`/`emitted`, never these). Taking the
    /// lock here would advertise a protection the writer does not hold.
    func deliveredFrameCount(ofType type: MessageType) -> Int {
        deliveredFrameCountsByType[type.rawValue] ?? 0
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
            engineScheduler: scheduler,
            // Announce admission reads this, so the throttle window moves
            // with `advanceTime` instead of with however long the runner
            // took to get here.
            dateProvider: { scheduler.currentDate }
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
        // emitted invisibly while still stamping the announce throttle —
        // swallowing `announceAll`'s forced announce.
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
                lock.lock()
                let stillEmpty = pendingDeliveries.isEmpty
                lock.unlock()
                if stillEmpty { return }
                continue
            }

            for (from, packet) in batch {
                for receiver in neighbors[from] {
                    for link in links(from: from, at: receiver) {
                        deliveredFrameCount += 1
                        deliveredFrameCountsByType[packet.type, default: 0] += 1
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

    /// Full discovery round: every node announces, traffic settles.
    ///
    /// Resets each node's announce throttle first: `setNickname`'s announce
    /// in `addNode` lands at the same simulated instant as this one, well
    /// inside the forced minimum interval, and would otherwise swallow it.
    /// (Advancing time would clear the window too, but it would also
    /// release scheduled work that callers of `announceAll` have not asked
    /// for yet.) `forceAnnounce(from:)` deliberately does NOT reset — the
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
}
