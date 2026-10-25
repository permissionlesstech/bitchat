import BitFoundation
import Foundation
import Testing
@testable import bitchat

@Suite("BLE peer registry tests")
struct BLEPeerRegistryTests {
    @Test("upserted announces track new, reconnect, and rename transitions")
    func upsertVerifiedAnnounceTracksTransitions() throws {
        var registry = BLEPeerRegistry()
        let peerID = PeerID(str: "1122334455667788")
        let firstSeen = Date(timeIntervalSince1970: 100)

        let firstResult = registry.upsertVerifiedAnnounce(
            peerID: peerID,
            nickname: "alice",
            noisePublicKey: Data([1, 2, 3]),
            signingPublicKey: Data([4, 5, 6]),
            isConnected: true,
            now: firstSeen
        )
        let first = try #require(firstResult)

        #expect(first.isNewPeer)
        #expect(!first.wasDisconnected)
        #expect(first.previousNickname == nil)
        #expect(registry.connectedPeerIDs == [peerID])
        #expect(registry.nickname(for: peerID, connectedOnly: true) == "alice")

        registry.markDisconnected(peerID)
        let reconnectResult = registry.upsertVerifiedAnnounce(
            peerID: peerID,
            nickname: "alice-renamed",
            noisePublicKey: Data([1, 2, 3]),
            signingPublicKey: Data([4, 5, 6]),
            isConnected: true,
            now: firstSeen.addingTimeInterval(1)
        )
        let reconnect = try #require(reconnectResult)

        #expect(!reconnect.isNewPeer)
        #expect(reconnect.wasDisconnected)
        #expect(reconnect.previousNickname == "alice")
        #expect(registry.info(for: peerID)?.nickname == "alice-renamed")
    }

    @Test("pinned signing key cannot be silently replaced by a later announce")
    func upsertVerifiedAnnounceRefusesToReplacePinnedSigningKey() throws {
        var registry = BLEPeerRegistry()
        let peerID = PeerID(str: "1122334455667788")
        let noiseKey = Data(repeating: 0x11, count: 32)
        let victimSigningKey = Data(repeating: 0x42, count: 32)
        let attackerSigningKey = Data(repeating: 0x66, count: 32)
        let firstSeen = Date(timeIntervalSince1970: 100)

        let pinResult = registry.upsertVerifiedAnnounce(
            peerID: peerID,
            nickname: "victim",
            noisePublicKey: noiseKey,
            signingPublicKey: victimSigningKey,
            isConnected: true,
            now: firstSeen
        )
        #expect(pinResult != nil)

        // Attacker replays the victim's noiseKey/peerID with their own
        // signing key and nickname; the upsert must be refused wholesale.
        let attack = registry.upsertVerifiedAnnounce(
            peerID: peerID,
            nickname: "attacker",
            noisePublicKey: noiseKey,
            signingPublicKey: attackerSigningKey,
            isConnected: true,
            now: firstSeen.addingTimeInterval(1)
        )

        #expect(attack == nil)
        let info = try #require(registry.info(for: peerID))
        #expect(info.nickname == "victim")
        #expect(info.signingPublicKey == victimSigningKey)

        // A legitimate re-announce with the pinned key is still accepted.
        let legit = registry.upsertVerifiedAnnounce(
            peerID: peerID,
            nickname: "victim-renamed",
            noisePublicKey: noiseKey,
            signingPublicKey: victimSigningKey,
            isConnected: true,
            now: firstSeen.addingTimeInterval(2)
        )
        #expect(legit != nil)
        #expect(registry.info(for: peerID)?.nickname == "victim-renamed")
    }

    @Test("announce without a signing key keeps the pinned key")
    func upsertVerifiedAnnounceKeepsPinnedSigningKeyWhenAnnounceOmitsIt() throws {
        var registry = BLEPeerRegistry()
        let peerID = PeerID(str: "1122334455667788")
        let noiseKey = Data(repeating: 0x11, count: 32)
        let signingKey = Data(repeating: 0x42, count: 32)
        let firstSeen = Date(timeIntervalSince1970: 100)

        let initialResult = registry.upsertVerifiedAnnounce(
            peerID: peerID,
            nickname: "alice",
            noisePublicKey: noiseKey,
            signingPublicKey: signingKey,
            isConnected: true,
            now: firstSeen
        )
        #expect(initialResult != nil)

        let update = registry.upsertVerifiedAnnounce(
            peerID: peerID,
            nickname: "alice",
            noisePublicKey: noiseKey,
            signingPublicKey: nil,
            isConnected: true,
            now: firstSeen.addingTimeInterval(1)
        )

        #expect(update != nil)
        #expect(registry.info(for: peerID)?.signingPublicKey == signingKey)
    }

    @Test("registry preserves absent versus explicit empty capabilities")
    func capabilitiesPresenceIsPreserved() {
        var registry = BLEPeerRegistry()
        let oldPeer = PeerID(str: "1122334455667788")
        let modernPeer = PeerID(str: "8877665544332211")

        _ = registry.upsertVerifiedAnnounce(
            peerID: oldPeer,
            nickname: "old",
            noisePublicKey: Data(repeating: 0x11, count: 32),
            signingPublicKey: Data(repeating: 0x12, count: 32),
            isConnected: true,
            now: Date(),
            capabilities: nil
        )
        _ = registry.upsertVerifiedAnnounce(
            peerID: modernPeer,
            nickname: "modern",
            noisePublicKey: Data(repeating: 0x21, count: 32),
            signingPublicKey: Data(repeating: 0x22, count: 32),
            isConnected: true,
            now: Date(),
            capabilities: []
        )

        #expect(registry.capabilities(for: oldPeer).isEmpty)
        #expect(!registry.capabilitiesWereExplicitlyAdvertised(for: oldPeer))
        #expect(registry.capabilities(for: modernPeer).isEmpty)
        #expect(registry.capabilitiesWereExplicitlyAdvertised(for: modernPeer))
    }

    @Test("reachability keeps recent verified offline peers only when mesh is attached")
    func reachabilityRequiresMeshAttachmentForOfflinePeers() {
        let offlinePeer = PeerID(str: "1122334455667788")
        let connectedPeer = PeerID(str: "8877665544332211")
        let now = Date()

        var isolatedRegistry = BLEPeerRegistry()
        isolatedRegistry.upsert(BLEPeerInfo(
            peerID: offlinePeer,
            nickname: "offline",
            isConnected: false,
            noisePublicKey: nil,
            signingPublicKey: nil,
            isVerifiedNickname: true,
            lastSeen: now
        ))

        #expect(!isolatedRegistry.isReachable(offlinePeer, now: now))

        var attachedRegistry = isolatedRegistry
        attachedRegistry.upsert(BLEPeerInfo(
            peerID: connectedPeer,
            nickname: "connected",
            isConnected: true,
            noisePublicKey: nil,
            signingPublicKey: nil,
            isVerifiedNickname: true,
            lastSeen: now
        ))

        #expect(attachedRegistry.isReachable(offlinePeer, now: now))
    }

    @Test("connectivity reconciliation disconnects inactive peers and prunes expired offline peers")
    func reconcileConnectivityUpdatesAndPrunesPeerState() {
        var registry = BLEPeerRegistry()
        let inactiveConnectedPeer = PeerID(str: "1122334455667788")
        let expiredOfflinePeer = PeerID(str: "8877665544332211")
        let now = Date()

        registry.upsert(BLEPeerInfo(
            peerID: inactiveConnectedPeer,
            nickname: "inactive",
            isConnected: true,
            noisePublicKey: nil,
            signingPublicKey: nil,
            isVerifiedNickname: true,
            lastSeen: now.addingTimeInterval(-TransportConfig.blePeerInactivityTimeoutSeconds - 1)
        ))
        registry.upsert(BLEPeerInfo(
            peerID: expiredOfflinePeer,
            nickname: "expired",
            isConnected: false,
            noisePublicKey: nil,
            signingPublicKey: nil,
            isVerifiedNickname: true,
            lastSeen: .distantPast
        ))

        let changes = registry.reconcileConnectivity(now: now, linkStates: [:])

        #expect(changes.disconnectedPeerIDs == [inactiveConnectedPeer])
        #expect(changes.removedPeers.map(\.peerID) == [expiredOfflinePeer])
        #expect(registry.info(for: inactiveConnectedPeer)?.isConnected == false)
        #expect(registry.info(for: expiredOfflinePeer) == nil)
    }

    // MARK: - Stored connected count

    @Test("connected count matches a recount across random mutations")
    func connectedCountMatchesRecountAcrossRandomMutations() {
        var rng = RegistrySeededGenerator(seed: 0xB1E5_C0DE)
        var registry = BLEPeerRegistry()
        let noiseKeys = (0..<24).map { index in Data((0..<32).map { UInt8(truncatingIfNeeded: index &* 37 &+ $0) }) }
        let peerIDs = noiseKeys.map { PeerID(publicKey: $0) }
        let pinnedSigningKeys = peerIDs.indices.map { Data(repeating: UInt8($0 + 1), count: 32) }
        let unknownPeerID = PeerID(str: "feedfacefeedface")
        var now = Date(timeIntervalSince1970: 10_000)

        for _ in 0..<2_000 {
            let index = Int.random(in: 0..<peerIDs.count, using: &rng)
            let peerID = peerIDs[index]
            now = now.addingTimeInterval(Double.random(in: 0...20, using: &rng))
            switch Int.random(in: 0..<20, using: &rng) {
            case 0..<5:
                // Mostly the pinned key; occasionally an impersonation the
                // registry must refuse without touching the entry.
                let refused = Int.random(in: 0..<8, using: &rng) == 0
                _ = registry.upsertVerifiedAnnounce(
                    peerID: peerID,
                    nickname: "peer\(index)",
                    noisePublicKey: noiseKeys[index],
                    signingPublicKey: refused ? Data(repeating: 0xEE, count: 32) : pinnedSigningKeys[index],
                    isConnected: Bool.random(using: &rng),
                    now: now
                )
            case 5..<7:
                registry.upsert(BLEPeerInfo(
                    peerID: peerID,
                    nickname: "raw\(index)",
                    isConnected: Bool.random(using: &rng),
                    noisePublicKey: noiseKeys[index],
                    signingPublicKey: nil,
                    isVerifiedNickname: Bool.random(using: &rng),
                    lastSeen: now.addingTimeInterval(-Double.random(in: 0...120, using: &rng))
                ))
            case 7..<9:
                registry.markConnected(peerID)
            case 9..<11:
                registry.markDisconnected(peerID)
            case 11..<13:
                registry.updateLastSeen(peerID, at: now)
            case 13..<15:
                registry.remove(peerID)
            case 15:
                registry.bindAuthenticatedSigningPublicKey(pinnedSigningKeys[index], for: PeerID(hexData: noiseKeys[index]))
            case 16:
                if Int.random(in: 0..<10, using: &rng) == 0 {
                    registry.removeAll()
                }
            default:
                var linkStates: [PeerID: BLEPeerLinkPresence] = [:]
                for candidate in peerIDs where Bool.random(using: &rng) {
                    linkStates[candidate] = BLEPeerLinkPresence(
                        hasPeripheral: Bool.random(using: &rng),
                        hasCentral: Bool.random(using: &rng)
                    )
                }
                _ = registry.reconcileConnectivity(now: now, linkStates: linkStates)
            }

            let snapshot = registry.snapshotByID
            #expect(registry.connectedCount == snapshot.values.filter(\.isConnected).count)
            let probes = [peerID, PeerID(hexData: noiseKeys[index]), unknownPeerID]
            for probe in probes {
                #expect(registry.isReachable(probe, now: now) == Self.referenceIsReachable(probe, in: snapshot, now: now))
            }
        }
    }

    @Test("reconciliation disconnects a stale peer without removing it in the same pass")
    func reconcileDisconnectsBeforeRemoving() {
        var registry = BLEPeerRegistry()
        let stalePeer = PeerID(str: "1122334455667788")
        let livePeer = PeerID(str: "8877665544332211")
        let now = Date(timeIntervalSince1970: 10_000)
        for (peerID, lastSeen) in [(stalePeer, Date.distantPast), (livePeer, now)] {
            registry.upsert(BLEPeerInfo(
                peerID: peerID,
                nickname: "peer",
                isConnected: true,
                noisePublicKey: nil,
                signingPublicKey: nil,
                isVerifiedNickname: true,
                lastSeen: lastSeen
            ))
        }
        #expect(registry.connectedCount == 2)

        let first = registry.reconcileConnectivity(now: now, linkStates: [:])
        #expect(first.disconnectedPeerIDs == [stalePeer])
        #expect(first.removedPeers.isEmpty)
        #expect(registry.connectedCount == 1)

        let second = registry.reconcileConnectivity(now: now, linkStates: [:])
        #expect(second.removedPeers.map(\.peerID) == [stalePeer])
        #expect(registry.connectedCount == 1)
        #expect(registry.isReachable(livePeer, now: now))
    }

    @Test("removing a disconnected peer leaves the connected count alone")
    func removingDisconnectedPeerKeepsCount() {
        var registry = BLEPeerRegistry()
        let connected = PeerID(str: "1122334455667788")
        let offline = PeerID(str: "8877665544332211")
        let now = Date(timeIntervalSince1970: 10_000)
        for (peerID, isConnected) in [(connected, true), (offline, false)] {
            registry.upsert(BLEPeerInfo(
                peerID: peerID,
                nickname: "peer",
                isConnected: isConnected,
                noisePublicKey: nil,
                signingPublicKey: nil,
                isVerifiedNickname: true,
                lastSeen: now
            ))
        }

        registry.remove(offline)
        #expect(registry.connectedCount == 1)
        registry.remove(connected)
        #expect(registry.connectedCount == 0)
        #expect(!registry.isReachable(offline, now: now))
    }

    /// `isReachable` as it was before the count was stored: a scan for any
    /// connected peer on every call.
    private static func referenceIsReachable(
        _ peerID: PeerID,
        in peers: [PeerID: BLEPeerInfo],
        now: Date
    ) -> Bool {
        guard let info = peers[peerID.toShort()] else { return false }
        if info.isConnected { return true }
        guard peers.values.contains(where: \.isConnected) else { return false }
        let retention: TimeInterval = info.isVerifiedNickname
            ? TransportConfig.bleReachabilityRetentionVerifiedSeconds
            : TransportConfig.bleReachabilityRetentionUnverifiedSeconds
        return now.timeIntervalSince(info.lastSeen) <= retention
    }
}

/// SplitMix64: a deterministic stream so a failing mutation sequence replays.
private struct RegistrySeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
