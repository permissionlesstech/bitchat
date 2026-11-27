import BitFoundation
import Foundation

struct BLEPeerEventDebouncer {
    private static let maxTrackedPeers = 512
    private var lastEmitByPeer = BoundedCache<PeerID, Date>(capacity: maxTrackedPeers)

    var count: Int {
        lastEmitByPeer.count
    }

    @discardableResult
    mutating func shouldEmit(peerID: PeerID, now: Date, minimumInterval: TimeInterval) -> Bool {
        if let lastEmit = lastEmitByPeer.value(for: peerID),
           now.timeIntervalSince(lastEmit) < minimumInterval {
            return false
        }

        lastEmitByPeer.set(peerID, value: now, refreshOrder: true)
        return true
    }

    mutating func removeAll() {
        lastEmitByPeer.removeAll()
    }
}
