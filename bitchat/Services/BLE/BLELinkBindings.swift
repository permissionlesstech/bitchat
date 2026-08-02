import BitFoundation
import Foundation

/// Identity↔link bindings: which peer each physical link currently
/// belongs to, in both roles, plus each peer's preferred peripheral link
/// for directed sends and fanout collapse.
///
/// Engine-owned (option-B boundary, docs/BLE-ARCHITECTURE-V3.md),
/// alongside `BLELinkAuthState`: *who owns a link* lives on the engine,
/// *what links exist* stays on bleQueue in the physical store. BLEService
/// debug-traps any access off the engine queue.
///
/// Lifecycle contract: bindings are only created for live physical links
/// (callers check liveness through `readLinkState`) and are retired
/// through `peripheralRemoved`/`centralRemoved`/`clear*` on an engine hop
/// queued by the physical teardown. A binding can therefore briefly
/// outlive its departed link; queries that need liveness join against the
/// physical store, and everything converges once the queued retirement
/// runs.
struct BLELinkBindings {
    private var peripheralPeers: [String: PeerID] = [:]
    private var centralPeers: [String: PeerID] = [:]
    /// The peer's most recently bound peripheral link, kept so duplicate-
    /// link fanout collapse stays deterministic (see BLEFanoutSelector).
    private var preferredPeripheral: [PeerID: String] = [:]

    // MARK: - Queries

    func peer(forPeripheralID peripheralID: String) -> PeerID? {
        peripheralPeers[peripheralID]
    }

    func peer(forCentralUUID centralUUID: String) -> PeerID? {
        centralPeers[centralUUID]
    }

    func boundPeer(for link: BLEIngressLinkID) -> PeerID? {
        switch link {
        case .peripheral(let peripheralUUID):
            return peripheralPeers[peripheralUUID]
        case .central(let centralUUID):
            return centralPeers[centralUUID]
        }
    }

    /// Every link bound to the peer, both roles. After a state restoration
    /// the same device can hold several live peripheral links bound to one
    /// peer (it reappears under a fresh UUID while the restored connection
    /// lives on), so this scans all bindings rather than the 1:1 preferred
    /// map.
    func links(to peerID: PeerID?) -> Set<BLEIngressLinkID> {
        guard let peerID else { return [] }
        var links: Set<BLEIngressLinkID> = []
        for (peripheralUUID, boundPeer) in peripheralPeers where boundPeer == peerID {
            links.insert(.peripheral(peripheralUUID))
        }
        for (centralUUID, boundPeer) in centralPeers where boundPeer == peerID {
            links.insert(.central(centralUUID))
        }
        return links
    }

    func hasCentral(boundTo peerID: PeerID) -> Bool {
        centralPeers.values.contains(peerID)
    }

    func preferredPeripheralUUID(for peerID: PeerID) -> String? {
        preferredPeripheral[peerID]
    }

    /// The full preferred-peripheral map, for fanout collapse.
    var preferredPeripheralBindings: [PeerID: String] {
        preferredPeripheral
    }

    /// The full central binding map, for the subscribed-central snapshot.
    var centralPeersByUUID: [String: PeerID] {
        centralPeers
    }

    // MARK: - Binding transitions

    mutating func bindCentral(_ centralUUID: String, to peerID: PeerID) {
        centralPeers[centralUUID] = peerID
    }

    mutating func bindPeripheral(_ peripheralUUID: String, to peerID: PeerID) {
        let previousPeerID = peripheralPeers[peripheralUUID]
        peripheralPeers[peripheralUUID] = peerID
        // Rebinding (peer-ID rotation): drop the retired ID's reverse
        // mapping so the old peer no longer claims this link.
        if let previousPeerID, previousPeerID != peerID,
           preferredPeripheral[previousPeerID] == peripheralUUID {
            preferredPeripheral.removeValue(forKey: previousPeerID)
        }
        preferredPeripheral[peerID] = peripheralUUID
    }

    /// Retires a peripheral link's binding. When the removed link was the
    /// peer's preferred one, the reverse map is repaired onto a surviving
    /// duplicate chosen by the caller from the peer's remaining bound links
    /// (the caller knows physical liveness; prefer a writable survivor —
    /// repairing onto a link mid-service-rediscovery would strand directed
    /// sends until its characteristic comes back).
    mutating func peripheralRemoved(
        _ peripheralUUID: String,
        chooseSurvivor: (_ remainingBoundUUIDs: [String]) -> String?
    ) -> PeerID? {
        guard let peerID = peripheralPeers.removeValue(forKey: peripheralUUID) else {
            return nil
        }
        // Only clear (or repair) the reverse map when it points at the
        // removed link: with duplicate links to one peer, removing a stale
        // duplicate must not strand the peer's surviving bound link.
        if preferredPeripheral[peerID] == peripheralUUID {
            let remaining = peripheralPeers.compactMap { uuid, boundPeer in
                boundPeer == peerID ? uuid : nil
            }
            if let survivorUUID = chooseSurvivor(remaining) {
                preferredPeripheral[peerID] = survivorUUID
            } else {
                preferredPeripheral.removeValue(forKey: peerID)
            }
        }
        return peerID
    }

    mutating func centralRemoved(_ centralUUID: String) -> PeerID? {
        centralPeers.removeValue(forKey: centralUUID)
    }

    /// Drops every peripheral binding; returns the peers that held one.
    mutating func clearPeripherals() -> [PeerID] {
        let peerIDs = Array(peripheralPeers.values)
        peripheralPeers.removeAll()
        preferredPeripheral.removeAll()
        return peerIDs
    }

    /// Drops every central binding; returns the peers that held one.
    mutating func clearCentrals() -> [PeerID] {
        let peerIDs = Array(centralPeers.values)
        centralPeers.removeAll()
        return peerIDs
    }

    mutating func removeAll() {
        peripheralPeers.removeAll()
        centralPeers.removeAll()
        preferredPeripheral.removeAll()
    }
}
