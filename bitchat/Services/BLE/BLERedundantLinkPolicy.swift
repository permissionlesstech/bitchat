import BitFoundation
import Foundation

/// Decides which central-role connections (peripheral links we own) are
/// redundant duplicates of a peer's live link.
///
/// One connection per role per peer is the normal dual-role topology (each
/// device is both central and peripheral). After a BLE state-restoration
/// relaunch, though, the same phone can reappear under a fresh peripheral
/// UUID while the restored connection lives on — leaving several live
/// central-role connections to one peer, each carrying every packet
/// (field-verified: 2-3x airtime on all traffic). Only same-role duplicates
/// are retired; the peer's central-role subscription on our peripheral
/// manager is its own connection to manage, and it runs the same policy.
enum BLERedundantLinkPolicy {
    struct PeripheralLink: Equatable {
        let uuid: String
        let peerID: PeerID?
        let isConnected: Bool

        init(uuid: String, peerID: PeerID?, isConnected: Bool) {
            self.uuid = uuid
            self.peerID = peerID
            self.isConnected = isConnected
        }
    }

    /// The link to keep when a peer has several connected bound peripheral
    /// links, or nil when there is nothing to consolidate. Prefers the
    /// ingress link of the verified direct announce that triggered the check
    /// (the strongest liveness proof available), falling back to the peer's
    /// most recently bound link.
    static func keptPeripheralUUID(
        ingressPeripheralUUID: String?,
        mostRecentlyBoundUUID: String?,
        links: [PeripheralLink],
        peerID: PeerID
    ) -> String? {
        let bound = links.filter { $0.peerID == peerID && $0.isConnected }
        guard bound.count > 1 else { return nil }

        if let ingressPeripheralUUID, bound.contains(where: { $0.uuid == ingressPeripheralUUID }) {
            return ingressPeripheralUUID
        }
        if let mostRecentlyBoundUUID, bound.contains(where: { $0.uuid == mostRecentlyBoundUUID }) {
            return mostRecentlyBoundUUID
        }
        return nil
    }

    /// Connected peripheral links bound to the peer other than the kept one.
    static func peripheralUUIDsToRetire(
        links: [PeripheralLink],
        peerID: PeerID,
        keeping keptUUID: String
    ) -> [String] {
        links
            .filter { $0.peerID == peerID && $0.isConnected && $0.uuid != keptUUID }
            .map(\.uuid)
    }
}
