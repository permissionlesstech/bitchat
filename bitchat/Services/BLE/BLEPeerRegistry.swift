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
    var capabilities: PeerCapabilities = []
    /// Distinguishes an old client that omitted the capabilities TLV from a
    /// modern client that explicitly advertised a set without a given bit.
    var capabilitiesWereExplicitlyAdvertised: Bool = false
    /// Rendezvous cell from the peer's announce when it advertises `.bridge`.
    var bridgeGeohash: String?
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

    /// Connected entries in `peers`. Every writer goes through `store` and
    /// `drop`, which keep it exact, so `isReachable` (asked once per listed
    /// peer per peer-list update) and the per-packet relay-degree reads are
    /// O(1) instead of a full scan.
    private(set) var connectedCount = 0

    private mutating func store(_ info: BLEPeerInfo, forKey key: PeerID) {
        let previous = peers.updateValue(info, forKey: key)
        if previous?.isConnected == true { connectedCount -= 1 }
        if info.isConnected { connectedCount += 1 }
    }

    @discardableResult
    private mutating func drop(_ key: PeerID) -> BLEPeerInfo? {
        let removed = peers.removeValue(forKey: key)
        if removed?.isConnected == true { connectedCount -= 1 }
        return removed
    }

    #if DEBUG
    /// Full recount, for checking the stored `connectedCount` in tests.
    var recountedConnectedCount: Int {
        peers.values.filter(\.isConnected).count
    }
    #endif

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
        connectedCount = 0
    }

    func info(for peerID: PeerID) -> BLEPeerInfo? {
        peers[peerID]
    }

    mutating func upsert(_ info: BLEPeerInfo) {
        store(info, forKey: info.peerID)
    }

    @discardableResult
    mutating func remove(_ peerID: PeerID) -> BLEPeerInfo? {
        drop(peerID)
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

    func capabilities(for peerID: PeerID) -> PeerCapabilities {
        peers[peerID.toShort()]?.capabilities ?? []
    }

    func capabilitiesWereExplicitlyAdvertised(for peerID: PeerID) -> Bool {
        peers[peerID.toShort()]?.capabilitiesWereExplicitlyAdvertised == true
    }

    /// Peers whose last verified announce advertised the given capability.
    func peers(advertising capability: PeerCapabilities) -> [PeerID] {
        peers.values.filter { $0.capabilities.contains(capability) }.map(\.peerID)
    }

    /// A rendezvous cell advertised by any bridge-capable peer, if one is
    /// known — lets location-less devices join the island's rendezvous.
    func advertisedBridgeGeohash() -> String? {
        peers.values
            .filter { $0.capabilities.contains(.bridge) }
            .compactMap(\.bridgeGeohash)
            .first
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
                lastSeen: info.lastSeen,
                isVerified: info.isVerifiedNickname
            )
        }
    }

    mutating func markDisconnected(_ peerID: PeerID) {
        guard var info = peers[peerID] else { return }
        info.isConnected = false
        store(info, forKey: peerID)
    }

    /// Flips an already-known peer to connected. Returns false when the peer
    /// is unknown or already connected (nothing changed).
    @discardableResult
    mutating func markConnected(_ peerID: PeerID) -> Bool {
        guard var info = peers[peerID], !info.isConnected else { return false }
        info.isConnected = true
        store(info, forKey: peerID)
        return true
    }

    mutating func updateLastSeen(_ peerID: PeerID, at date: Date) {
        guard var peer = peers[peerID] else { return }
        peer.lastSeen = date
        store(peer, forKey: peerID)
    }

    /// Replaces the announcement signing key only after the surrounding Noise
    /// session proved possession of this peer's static key.
    mutating func bindAuthenticatedSigningPublicKey(_ key: Data, for peerID: PeerID) {
        guard var peer = peers[peerID.toShort()] else { return }
        peer.signingPublicKey = key
        store(peer, forKey: peer.peerID)
    }

    /// Applies a verified announce to the registry.
    ///
    /// TOFU signing-key pinning: once a signing key has been bound to this
    /// peer entry, an announce carrying a *different* signing key is refused
    /// (returns `nil`) and the existing record is left untouched. PeerIDs are
    /// derived from the (public) noise key, so without pinning an attacker
    /// could replay a victim's noiseKey/peerID with their own signing key and
    /// silently take over the victim's mesh identity and nickname.
    mutating func upsertVerifiedAnnounce(
        peerID: PeerID,
        nickname: String,
        noisePublicKey: Data,
        signingPublicKey: Data?,
        isConnected: Bool,
        now: Date,
        capabilities: PeerCapabilities? = nil,
        bridgeGeohash: String? = nil
    ) -> BLEPeerAnnounceUpdate? {
        let existing = peers[peerID]

        if let pinnedSigningKey = existing?.signingPublicKey,
           let announcedSigningKey = signingPublicKey,
           pinnedSigningKey != announcedSigningKey {
            return nil
        }

        let update = BLEPeerAnnounceUpdate(
            isNewPeer: existing == nil,
            wasDisconnected: existing?.isConnected == false,
            previousNickname: existing?.nickname
        )

        store(BLEPeerInfo(
            peerID: existing?.peerID ?? peerID,
            nickname: nickname.normalizedNickname,
            isConnected: isConnected,
            noisePublicKey: noisePublicKey,
            // Never drop an already-pinned signing key.
            signingPublicKey: signingPublicKey ?? existing?.signingPublicKey,
            isVerifiedNickname: true,
            lastSeen: now,
            capabilities: capabilities ?? [],
            capabilitiesWereExplicitlyAdvertised: capabilities != nil,
            bridgeGeohash: bridgeGeohash
        ), forKey: peerID)

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
                    store(updated, forKey: peerID)
                    changes.disconnectedPeerIDs.append(peerID)
                }
            }

            if !peer.isConnected && age > retention {
                drop(peerID)
                changes.removedPeers.append(BLERemovedPeer(peerID: peerID, nickname: peer.nickname))
            }
        }

        return changes
    }
}
