import BitFoundation
import Foundation

enum BLEPeerSenderDisplayName {
    static func resolveKnownPeer(
        peerID: PeerID,
        localPeerID: PeerID,
        localNickname: String,
        peers: [PeerID: BLEPeerInfo],
        allowConnectedUnverified: Bool
    ) -> String? {
        if peerID == localPeerID {
            return localNickname
        }

        guard let info = peers[peerID] else { return nil }

        if info.isVerifiedNickname {
            return collisionResolvedName(
                displayName: info.nickname,
                collisionNickname: info.nickname,
                peerID: peerID,
                localNickname: localNickname,
                peers: peers
            )
        }

        if allowConnectedUnverified, info.isConnected {
            let displayName = info.nickname.isEmpty ? anonymousNickname(for: peerID) : info.nickname
            return collisionResolvedName(
                displayName: displayName,
                collisionNickname: info.nickname,
                peerID: peerID,
                localNickname: localNickname,
                peers: peers
            )
        }

        return nil
    }

    static func anonymousNickname(for peerID: PeerID) -> String {
        "anon" + String(peerID.id.prefix(4))
    }

    private static func collisionResolvedName(
        displayName: String,
        collisionNickname: String,
        peerID: PeerID,
        localNickname: String,
        peers: [PeerID: BLEPeerInfo]
    ) -> String {
        // Folded, for the same reason as `PeerDisplayNameResolver`: the suffix
        // exists to make namesakes distinguishable, so a case variant or a
        // fullwidth Ｍ has to count as a collision. This is the second place
        // collisions are counted — it feeds sender names on file transfers —
        // and it had the same exact-match blind spot.
        let target = PeerDisplayNameResolver.collisionKey(collisionNickname)
        let hasCollision = peers.values.contains {
            $0.isConnected && PeerDisplayNameResolver.collisionKey($0.nickname) == target
                && $0.peerID != peerID
        } || PeerDisplayNameResolver.collisionKey(localNickname) == target

        guard hasCollision else { return displayName }
        return displayName + "#" + String(peerID.id.prefix(4))
    }
}
