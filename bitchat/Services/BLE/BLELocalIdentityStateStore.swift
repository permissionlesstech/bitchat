import BitFoundation
import Foundation

struct BLELocalIdentitySnapshot: Equatable, Sendable {
    let peerID: PeerID
    let peerIDData: Data
    let nickname: String
}

/// Lock-backed local identity state shared by the transport's message,
/// Bluetooth, maintenance, and main-actor entry points.
///
/// `peerID` and its binary wire representation must change as one unit during
/// panic rotation. A snapshot also gives announce construction one consistent
/// view of the nickname and identity instead of reading three independently
/// mutable properties across queues.
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
            nickname: nickname
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
                nickname: nickname
            )
        }
    }

    func replacePeerIdentity(with peerID: PeerID) {
        lock.withLock {
            state = BLELocalIdentitySnapshot(
                peerID: peerID,
                peerIDData: Data(hexString: peerID.id) ?? Data(),
                nickname: state.nickname
            )
        }
    }
}
