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
    private let usePlannedLinkDelivery: Bool
    private var pendingDeliveries: [(from: Int, packet: BitchatPacket)] = []
    private var pendingPlannedDeliveries: [(from: Int, to: Int, link: BLEIngressLinkID, packet: BitchatPacket)] = []
    /// Total (packet, receiving-node) deliveries pumped — the storm bound.
    private(set) var deliveredFrameCount = 0

    private(set) var nodes: [Node] = []
    private var neighbors: [Set<Int>] = []
    private var duplicateLinkEdges: Set<String> = []
    private var droppedPrimaryLinks: Set<String> = []
    private var emitted: [[BitchatPacket]] = []
    private var plannedTransmissions: [[(to: Int, packet: BitchatPacket)]] = []

    init(usePlannedLinkDelivery: Bool = false) {
        self.usePlannedLinkDelivery = usePlannedLinkDelivery
    }

    /// Every packet a node has put on the wire — the attacker's capture
    /// buffer for replay tests.
    func emittedPackets(from index: Int) -> [BitchatPacket] {
        lock.lock()
        defer { lock.unlock() }
        return emitted[index]
    }

    /// Every per-target transmission selected by `sendOnAllLinks` when
    /// `usePlannedLinkDelivery` is enabled.
    func plannedTransmissions(from index: Int) -> [(to: Int, packet: BitchatPacket)] {
        lock.lock()
        defer { lock.unlock() }
        return plannedTransmissions[index]
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
        plannedTransmissions.append([])
        lock.unlock()
        if usePlannedLinkDelivery {
            service._test_virtualCentralIDs = { [weak self] in
                self?.activeVirtualCentralIDs(at: index) ?? []
            }
            service._test_onPlannedLinks = { [weak self, weak service] packet, selection in
                guard let self, let service else { return }
                let pad = BLEOutboundPacketPolicy.padsBLEFrame(for: packet.type)
                let encodedLength = packet.toBinaryData(padding: pad)?.count
                self.lock.lock()
                var deliveredAny = false
                for selectedUUID in selection.centralIDs.sorted() {
                    guard let (target, isDuplicate) = self.decodeVirtualCentralLink(selectedUUID, at: index),
                          self.neighbors[index].contains(target) else {
                        continue
                    }
                    if let mtu = service._test_virtualCentralMTU?(selectedUUID),
                       let encodedLength,
                       encodedLength > mtu {
                        // Drop frames whose encoded wire length exceeds the
                        // simulated link's physical MTU, matching BLE GATT limits.
                        continue
                    }
                    deliveredAny = true
                    let receiverLinkUUID = isDuplicate
                        ? self.duplicateLinkUUID(from: index, at: target)
                        : self.linkUUID(from: index, at: target)
                    self.pendingPlannedDeliveries.append((
                        from: index,
                        to: target,
                        link: .central(receiverLinkUUID),
                        packet: packet
                    ))
                    self.plannedTransmissions[index].append((to: target, packet: packet))
                }
                if deliveredAny || !selection.peripheralIDs.isEmpty {
                    self.emitted[index].append(packet)
                }
                self.lock.unlock()
            }
        } else {
            // The tap must be live before `setNickname` below: setNickname
            // force-announces asynchronously on the engine, and if that slot
            // ran in the gap before a later tap install, the announce was
            // emitted invisibly while still stamping the wall-clock announce
            // throttle — swallowing `announceAll`'s forced announce on a
            // starved runner (the CI flake this ordering fixes).
            service._test_onOutboundPacket = { [weak self] packet in
                // Runs on the sender's engine; only buffer here — delivering
                // inline would nest one engine inside another.
                guard let self else { return }
                self.lock.lock()
                self.pendingDeliveries.append((from: index, packet: packet))
                self.emitted[index].append(packet)
                self.lock.unlock()
            }
        }
        service.setNickname(nickname)
        return node
    }

    func connect(_ a: Int, _ b: Int) {
        lock.lock()
        neighbors[a].insert(b)
        neighbors[b].insert(a)
        lock.unlock()
    }

    /// Radio silence: stops delivering between two nodes without reporting
    /// any link event, so existing bindings persist exactly as they do when
    /// a peer walks out of range before its link times out. Lets a test
    /// capture a packet the far side never received.
    func silence(_ a: Int, _ b: Int) {
        lock.lock()
        neighbors[a].remove(b)
        neighbors[b].remove(a)
        lock.unlock()
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
        lock.lock()
        neighbors[a].insert(b)
        neighbors[b].insert(a)
        duplicateLinkEdges.insert(Self.edgeKey(a, b))
        lock.unlock()
    }

    /// Removes only the primary link of a duplicate-link edge while keeping
    /// the second link active (simulating single-link drop on a multi-link peer).
    func dropPrimaryDuplicateLink(_ a: Int, _ b: Int) {
        lock.lock()
        droppedPrimaryLinks.insert(Self.edgeKey(a, b))
        lock.unlock()
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
        lock.lock()
        let key = Self.edgeKey(sender, receiver)
        let hasDup = duplicateLinkEdges.contains(key)
        let primaryDropped = droppedPrimaryLinks.contains(key)
        lock.unlock()
        var result: [BLEIngressLinkID] = []
        if !primaryDropped {
            result.append(.central(linkUUID(from: sender, at: receiver)))
        }
        if hasDup {
            result.append(.central(duplicateLinkUUID(from: sender, at: receiver)))
        }
        return result
    }

    private func activeVirtualCentralIDs(at nodeIndex: Int) -> [String] {
        lock.lock()
        let peerIndices = neighbors[nodeIndex].sorted()
        let dupEdges = duplicateLinkEdges
        let droppedPrimary = droppedPrimaryLinks
        lock.unlock()
        var ids: [String] = []
        ids.reserveCapacity(peerIndices.count)
        for peer in peerIndices {
            let key = Self.edgeKey(peer, nodeIndex)
            if !droppedPrimary.contains(key) {
                ids.append(linkUUID(from: peer, at: nodeIndex))
            }
            if dupEdges.contains(key) {
                ids.append(duplicateLinkUUID(from: peer, at: nodeIndex))
            }
        }
        return ids
    }

    private func decodeVirtualCentralLink(_ uuid: String, at receiver: Int) -> (peer: Int, isDuplicate: Bool)? {
        let suffix = "-TO-\(receiver)"
        guard uuid.hasSuffix(suffix) else { return nil }
        let body = uuid.dropLast(suffix.count)
        if body.hasPrefix("SIM-DUP-"), let peer = Int(body.dropFirst("SIM-DUP-".count)) {
            return (peer, true)
        }
        if body.hasPrefix("SIM-"), let peer = Int(body.dropFirst("SIM-".count)) {
            return (peer, false)
        }
        return nil
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
            let plannedBatch = pendingPlannedDeliveries
            pendingPlannedDeliveries.removeAll()
            lock.unlock()

            if batch.isEmpty && plannedBatch.isEmpty {
                // Engines may still be running slots that will emit more.
                nodes.forEach { $0.service._test_fenceEngine() }
                lock.lock()
                let stillEmpty = pendingDeliveries.isEmpty && pendingPlannedDeliveries.isEmpty
                lock.unlock()
                if stillEmpty { return }
                continue
            }

            for (from, packet) in batch {
                lock.lock()
                let peerIndices = Array(neighbors[from])
                lock.unlock()
                for receiver in peerIndices {
                    for link in links(from: from, at: receiver) {
                        deliveredFrameCount += 1
                        nodes[receiver].service._test_ingestFrame(packet, link: link)
                    }
                }
            }
            for delivery in plannedBatch {
                deliveredFrameCount += 1
                nodes[delivery.to].service._test_ingestFrame(delivery.packet, link: delivery.link)
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
}
