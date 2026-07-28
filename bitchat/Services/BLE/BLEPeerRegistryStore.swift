import BitFoundation
import Foundation

/// Lock-backed shared ownership of the peer registry, readable from any
/// queue or the main actor without hopping onto a transport queue.
///
/// Mutations come only from the transport's own serial queues — the
/// engine, plus the bleQueue link-drop paths that mark a peer
/// disconnected — and the lock serializes them against each other and
/// against readers, so the main actor answers questions like
/// `isPeerConnected` without blocking behind in-flight transport work.
/// Every `BLEPeerRegistry` mutation is a single whole-transition method,
/// so a reader between two mutations always observes a valid pre- or
/// post-state, never a torn one.
///
/// Closures passed to `read`/`mutate` run under the (non-recursive) lock
/// and must not call back into the store.
final class BLEPeerRegistryStore: @unchecked Sendable {
    private let lock = NSLock()
    private var registry = BLEPeerRegistry()

    /// One consistent view across multiple registry reads.
    func read<T>(_ body: (BLEPeerRegistry) -> T) -> T {
        lock.withLock { body(registry) }
    }

    func mutate<T>(_ body: (inout BLEPeerRegistry) -> T) -> T {
        lock.withLock { body(&registry) }
    }

    // MARK: - Single-question reads

    var isEmpty: Bool { read { $0.isEmpty } }
    var peerIDs: [PeerID] { read { $0.peerIDs } }
    var connectedCount: Int { read { $0.connectedCount } }
    var connectedPeerIDs: [PeerID] { read { $0.connectedPeerIDs } }
    var connectedRoutingData: [Data] { read { $0.connectedRoutingData } }
    var snapshotByID: [PeerID: BLEPeerInfo] { read { $0.snapshotByID } }

    func info(for peerID: PeerID) -> BLEPeerInfo? {
        read { $0.info(for: peerID) }
    }

    func isConnected(_ peerID: PeerID) -> Bool {
        read { $0.isConnected(peerID) }
    }

    func isReachable(_ peerID: PeerID, now: Date) -> Bool {
        read { $0.isReachable(peerID, now: now) }
    }

    func nickname(for peerID: PeerID, connectedOnly: Bool) -> String? {
        read { $0.nickname(for: peerID, connectedOnly: connectedOnly) }
    }

    func fingerprint(for peerID: PeerID) -> String? {
        read { $0.fingerprint(for: peerID) }
    }

    func capabilities(for peerID: PeerID) -> PeerCapabilities {
        read { $0.capabilities(for: peerID) }
    }

    func advertisedBridgeGeohash() -> String? {
        read { $0.advertisedBridgeGeohash() }
    }

    func displayNicknames(selfNickname: String) -> [PeerID: String] {
        read { $0.displayNicknames(selfNickname: selfNickname) }
    }

    func transportSnapshots(selfNickname: String) -> [TransportPeerSnapshot] {
        read { $0.transportSnapshots(selfNickname: selfNickname) }
    }

    /// Peers advertising `capability` that are reachable now, in one
    /// consistent view.
    func reachablePeers(advertising capability: PeerCapabilities, now: Date) -> [PeerID] {
        read { registry in
            registry.peers(advertising: capability)
                .filter { registry.isReachable($0, now: now) }
        }
    }
}
