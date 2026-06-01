import BitFoundation
import Foundation

struct BLEPeerInfo: Equatable {
    let peerID: PeerID
    var nickname: String
    var isConnected: Bool
    var noisePublicKey: Data?
    var signingPublicKey: Data?
    var isVerifiedNickname: Bool
    var lastSeen: Date
}

struct BLEPeerAnnounceUpdate: Equatable {
    let isNewPeer: Bool
    let wasDisconnected: Bool
    let previousNickname: String?
}

struct BLEPeerLinkPresence: Equatable {
    var hasPeripheral: Bool
    var hasCentral: Bool
}

struct BLERemovedPeer: Equatable {
    let peerID: PeerID
    let nickname: String
}

struct BLEPeerConnectivityChanges: Equatable {
    var disconnectedPeerIDs: [PeerID] = []
    var removedPeers: [BLERemovedPeer] = []
}

struct BLEPeerRegistry {
    private var peers: [PeerID: BLEPeerInfo] = [:]

    var isEmpty: Bool {
        peers.isEmpty
    }

    var count: Int {
        peers.count
    }

    var peerIDs: [PeerID] {
        Array(peers.keys)
    }

    var connectedCount: Int {
        peers.values.filter(\.isConnected).count
    }

    var connectedPeerIDs: [PeerID] {
        peers.values.compactMap { $0.isConnected ? $0.peerID : nil }
    }

    var connectedRoutingData: [Data] {
        peers.values.filter(\.isConnected).compactMap { $0.peerID.routingData }
    }

    var snapshotByID: [PeerID: BLEPeerInfo] {
        peers
    }

    mutating func removeAll() {
        peers.removeAll()
    }

    func info(for peerID: PeerID) -> BLEPeerInfo? {
        peers[peerID]
    }

    mutating func upsert(_ info: BLEPeerInfo) {
        peers[info.peerID] = info
    }

    @discardableResult
    mutating func remove(_ peerID: PeerID) -> BLEPeerInfo? {
        peers.removeValue(forKey: peerID)
    }

    func isConnected(_ peerID: PeerID) -> Bool {
        peers[peerID.toShort()]?.isConnected ?? false
    }

    func isReachable(_ peerID: PeerID, now: Date) -> Bool {
        let shortID = peerID.toShort()
        let meshAttached = connectedCount > 0
        guard let info = peers[shortID] else { return false }
        if info.isConnected { return true }
        guard meshAttached else { return false }

        let retention: TimeInterval = info.isVerifiedNickname
            ? TransportConfig.bleReachabilityRetentionVerifiedSeconds
            : TransportConfig.bleReachabilityRetentionUnverifiedSeconds
        return now.timeIntervalSince(info.lastSeen) <= retention
    }

    func nickname(for peerID: PeerID, connectedOnly: Bool) -> String? {
        guard let peer = peers[peerID] else { return nil }
        if connectedOnly && !peer.isConnected { return nil }
        return peer.nickname
    }

    func fingerprint(for peerID: PeerID) -> String? {
        peers[peerID]?.noisePublicKey?.sha256Fingerprint()
    }

    func displayNicknames(selfNickname: String) -> [PeerID: String] {
        let connected = peers.filter { $0.value.isConnected }
        let tuples = connected.map { ($0.key, $0.value.nickname, true) }
        return PeerDisplayNameResolver.resolve(tuples, selfNickname: selfNickname)
    }

    func transportSnapshots(selfNickname: String) -> [TransportPeerSnapshot] {
        let snapshot = Array(peers.values)
        let resolvedNames = PeerDisplayNameResolver.resolve(
            snapshot.map { ($0.peerID, $0.nickname, $0.isConnected) },
            selfNickname: selfNickname
        )
        return snapshot.map { info in
            TransportPeerSnapshot(
                peerID: info.peerID,
                nickname: resolvedNames[info.peerID] ?? info.nickname,
                isConnected: info.isConnected,
                noisePublicKey: info.noisePublicKey,
                lastSeen: info.lastSeen
            )
        }
    }

    func collisionResolvedNickname(for peerID: PeerID, selfNickname: String) -> String? {
        guard let info = peers[peerID], info.isVerifiedNickname else { return nil }
        let hasCollision = peers.values.contains {
            $0.isConnected && $0.nickname == info.nickname && $0.peerID != peerID
        } || selfNickname == info.nickname
        return hasCollision ? info.nickname + "#" + String(peerID.id.prefix(4)) : info.nickname
    }

    mutating func markDisconnected(_ peerID: PeerID) {
        guard var info = peers[peerID] else { return }
        info.isConnected = false
        peers[peerID] = info
    }

    mutating func updateLastSeen(_ peerID: PeerID, at date: Date) {
        guard var peer = peers[peerID] else { return }
        peer.lastSeen = date
        peers[peerID] = peer
    }

    mutating func upsertVerifiedAnnounce(
        peerID: PeerID,
        nickname: String,
        noisePublicKey: Data,
        signingPublicKey: Data?,
        isConnected: Bool,
        now: Date
    ) -> BLEPeerAnnounceUpdate {
        let existing = peers[peerID]
        let update = BLEPeerAnnounceUpdate(
            isNewPeer: existing == nil,
            wasDisconnected: existing?.isConnected == false,
            previousNickname: existing?.nickname
        )

        peers[peerID] = BLEPeerInfo(
            peerID: existing?.peerID ?? peerID,
            nickname: nickname,
            isConnected: isConnected,
            noisePublicKey: noisePublicKey,
            signingPublicKey: signingPublicKey,
            isVerifiedNickname: true,
            lastSeen: now
        )

        return update
    }

    mutating func reconcileConnectivity(
        now: Date,
        linkStates: [PeerID: BLEPeerLinkPresence]
    ) -> BLEPeerConnectivityChanges {
        var changes = BLEPeerConnectivityChanges()

        for (peerID, peer) in Array(peers) {
            let age = now.timeIntervalSince(peer.lastSeen)
            let retention: TimeInterval = peer.isVerifiedNickname
                ? TransportConfig.bleReachabilityRetentionVerifiedSeconds
                : TransportConfig.bleReachabilityRetentionUnverifiedSeconds

            if peer.isConnected && age > TransportConfig.blePeerInactivityTimeoutSeconds {
                let state = linkStates[peerID] ?? BLEPeerLinkPresence(hasPeripheral: false, hasCentral: false)
                if !state.hasPeripheral && !state.hasCentral {
                    var updated = peer
                    updated.isConnected = false
                    peers[peerID] = updated
                    changes.disconnectedPeerIDs.append(peerID)
                }
            }

            if !peer.isConnected && age > retention {
                peers.removeValue(forKey: peerID)
                changes.removedPeers.append(BLERemovedPeer(peerID: peerID, nickname: peer.nickname))
            }
        }

        return changes
    }
}
