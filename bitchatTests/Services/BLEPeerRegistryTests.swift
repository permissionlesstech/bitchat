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
}
