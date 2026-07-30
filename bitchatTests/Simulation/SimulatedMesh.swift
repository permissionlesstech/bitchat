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

    private(set) var nodes: [Node] = []
    private var neighbors: [Set<Int>] = []

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
        nodes.append(node)
        neighbors.append([])
        service.setNickname(nickname)
        service._test_onOutboundPacket = { [weak self] packet in
            // Runs on the sender's engine; only buffer here — delivering
            // inline would nest one engine inside another.
            guard let self else { return }
            self.lock.lock()
            self.pendingDeliveries.append((from: index, packet: packet))
            self.lock.unlock()
        }
        return node
    }

    func connect(_ a: Int, _ b: Int) {
        neighbors[a].insert(b)
        neighbors[b].insert(a)
    }

    /// The synthetic link a frame from `sender` arrives on at `receiver`.
    /// Stable per directed edge, like a CoreBluetooth central UUID.
    func linkUUID(from sender: Int, at receiver: Int) -> String {
        "SIM-\(sender)-TO-\(receiver)"
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
                    deliveredFrameCount += 1
                    nodes[receiver].service._test_ingestFrame(
                        packet,
                        link: .central(linkUUID(from: from, at: receiver))
                    )
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
    func announceAll() {
        for node in nodes {
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
