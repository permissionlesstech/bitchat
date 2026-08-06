import BitFoundation
import Foundation

struct BLELocalIdentitySnapshot: Equatable, Sendable {
    let peerID: PeerID
    let peerIDData: Data
    let nickname: String
    /// Runtime-toggled capability bits (e.g. the internet-gateway toggle)
    /// ORed into `PeerCapabilities.localSupported` for every announce.
    let runtimeCapabilities: PeerCapabilities
    /// Rendezvous cell advertised while bridging; rides announces only
    /// while the `.bridge` capability is enabled.
    let bridgeGeohash: String?

    var advertisedCapabilities: PeerCapabilities {
        PeerCapabilities.localSupported.union(runtimeCapabilities)
    }

    var advertisedBridgeGeohash: String? {
        runtimeCapabilities.contains(.bridge) ? bridgeGeohash : nil
    }
}

/// Lock-backed local identity state shared by the transport's message,
/// Bluetooth, maintenance, and main-actor entry points.
///
/// `peerID` and its binary wire representation must change as one unit during
/// panic rotation. A snapshot also gives announce construction one consistent
/// view of the nickname, identity, and advertised capabilities instead of
/// reading independently mutable properties across queues.
final class BLELocalIdentityStateStore: @unchecked Sendable {
    private let lock = NSLock()
    private var state: BLELocalIdentitySnapshot

    init(
        peerID: PeerID = PeerID(str: ""),
        nickname: String = "anon"
    ) {
        state = BLELocalIdentitySnapshot(
            peerID: peerID,
            peerIDData: Data(hexString: peerID.id) ?? Data(),
            nickname: nickname,
            runtimeCapabilities: [],
            bridgeGeohash: nil
        )
    }

    func snapshot() -> BLELocalIdentitySnapshot {
        lock.withLock { state }
    }

    func setNickname(_ nickname: String) {
        lock.withLock {
            state = BLELocalIdentitySnapshot(
                peerID: state.peerID,
                peerIDData: state.peerIDData,
                nickname: nickname,
                runtimeCapabilities: state.runtimeCapabilities,
                bridgeGeohash: state.bridgeGeohash
            )
        }
    }

    func replacePeerIdentity(with peerID: PeerID) {
        lock.withLock {
            state = BLELocalIdentitySnapshot(
                peerID: peerID,
                peerIDData: Data(hexString: peerID.id) ?? Data(),
                nickname: state.nickname,
                runtimeCapabilities: state.runtimeCapabilities,
                bridgeGeohash: state.bridgeGeohash
            )
        }
    }

    /// Flips a runtime capability bit. Returns whether anything changed.
    @discardableResult
    func setCapability(_ capability: PeerCapabilities, enabled: Bool) -> Bool {
        lock.withLock {
            var capabilities = state.runtimeCapabilities
            if enabled {
                capabilities.insert(capability)
            } else {
                capabilities.remove(capability)
            }
            guard capabilities != state.runtimeCapabilities else { return false }
            state = BLELocalIdentitySnapshot(
                peerID: state.peerID,
                peerIDData: state.peerIDData,
                nickname: state.nickname,
                runtimeCapabilities: capabilities,
                bridgeGeohash: state.bridgeGeohash
            )
            return true
        }
    }

    /// Sets the bridged rendezvous cell. Returns whether anything changed.
    @discardableResult
    func setBridgeGeohash(_ cell: String?) -> Bool {
        lock.withLock {
            guard cell != state.bridgeGeohash else { return false }
            state = BLELocalIdentitySnapshot(
                peerID: state.peerID,
                peerIDData: state.peerIDData,
                nickname: state.nickname,
                runtimeCapabilities: state.runtimeCapabilities,
                bridgeGeohash: cell
            )
            return true
        }
    }
}
