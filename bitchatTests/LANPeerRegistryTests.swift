//
// LANPeerRegistryTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Testing
import BitFoundation
@testable import bitchat

struct LANPeerRegistryTests {

    private func makePeerID(_ suffix: String) -> PeerID {
        PeerID(str: String(repeating: "a", count: 15) + suffix)
    }

    private func makeRegistry() -> LANPeerRegistry {
        var timeouts = LANPeerRegistry.Timeouts.standard
        timeouts.discovery = 30
        timeouts.handshake = 10
        timeouts.idle = 120
        return LANPeerRegistry(timeouts: timeouts)
    }

    @Test("A peer walks from discovered to handshaking to authenticated")
    func happyPath() {
        let registry = makeRegistry()
        let peerID = makePeerID("1")
        let start = Date(timeIntervalSince1970: 1_000)

        #expect(registry.discover(peerID: peerID, nickname: "alice", now: start) != nil)
        #expect(registry.state(of: peerID) == .discovered)

        #expect(registry.beginHandshake(peerID: peerID, now: start.addingTimeInterval(1)) != nil)
        #expect(registry.state(of: peerID) == .handshaking)

        #expect(
            registry.authenticate(
                peerID: peerID,
                nickname: "alice",
                noisePublicKey: Data(repeating: 0x11, count: 32),
                isVerified: true,
                now: start.addingTimeInterval(2)
            ) != nil
        )
        #expect(registry.state(of: peerID) == .authenticated)

        let snapshots = registry.snapshots(now: start.addingTimeInterval(2))
        #expect(snapshots.count == 1)
        #expect(snapshots.first?.peerID == peerID)
        #expect(snapshots.first?.isConnected == true)
        #expect(snapshots.first?.nickname == "alice")
        #expect(snapshots.first?.isVerified == true)
        #expect(snapshots.first?.noisePublicKey == Data(repeating: 0x11, count: 32))
    }

    @Test("A disconnected peer is no longer connected but stays known")
    func disconnect() {
        let registry = makeRegistry()
        let peerID = makePeerID("2")
        let start = Date(timeIntervalSince1970: 2_000)

        _ = registry.discover(peerID: peerID, now: start)
        _ = registry.authenticate(peerID: peerID, now: start)
        #expect(registry.state(of: peerID) == .authenticated)

        _ = registry.disconnect(peerID: peerID, now: start.addingTimeInterval(5))
        #expect(registry.state(of: peerID) == .disconnected)

        let snapshots = registry.snapshots(now: start.addingTimeInterval(5))
        #expect(snapshots.count == 1)
        #expect(snapshots.first?.isConnected == false)
    }

    @Test("A peer that never completes the handshake times out")
    func handshakeTimeout() {
        let registry = makeRegistry()
        let peerID = makePeerID("3")
        let start = Date(timeIntervalSince1970: 3_000)

        _ = registry.discover(peerID: peerID, now: start)
        _ = registry.beginHandshake(peerID: peerID, now: start)

        #expect(registry.expireStalePeers(now: start.addingTimeInterval(5)).isEmpty)
        #expect(registry.state(of: peerID) == .handshaking)

        let expired = registry.expireStalePeers(now: start.addingTimeInterval(11))
        #expect(expired == [peerID])
        #expect(registry.state(of: peerID) == .timedOut)
    }

    @Test("A discovered peer that never answers times out")
    func discoveryTimeout() {
        let registry = makeRegistry()
        let peerID = makePeerID("4")
        let start = Date(timeIntervalSince1970: 4_000)

        _ = registry.discover(peerID: peerID, now: start)
        let expired = registry.expireStalePeers(now: start.addingTimeInterval(31))
        #expect(expired == [peerID])
        #expect(registry.state(of: peerID) == .timedOut)
    }

    @Test("An authenticated peer that goes silent is dropped, not kept alive")
    func idleTimeout() {
        let registry = makeRegistry()
        let peerID = makePeerID("5")
        let start = Date(timeIntervalSince1970: 5_000)

        _ = registry.discover(peerID: peerID, now: start)
        _ = registry.authenticate(peerID: peerID, now: start)

        let expired = registry.expireStalePeers(now: start.addingTimeInterval(121))
        #expect(expired == [peerID])
        #expect(registry.state(of: peerID) == .disconnected)
    }

    @Test("Traffic keeps an authenticated peer alive")
    func trafficRefreshesIdleTimer() {
        let registry = makeRegistry()
        let peerID = makePeerID("6")
        let start = Date(timeIntervalSince1970: 6_000)

        _ = registry.discover(peerID: peerID, now: start)
        _ = registry.authenticate(peerID: peerID, now: start)
        registry.markTraffic(peerID: peerID, now: start.addingTimeInterval(100))

        #expect(registry.expireStalePeers(now: start.addingTimeInterval(150)).isEmpty)
        #expect(registry.state(of: peerID) == .authenticated)
    }

    @Test("A repeated discovery never downgrades an authenticated peer")
    func duplicateDiscovery() {
        let registry = makeRegistry()
        let peerID = makePeerID("7")
        let start = Date(timeIntervalSince1970: 7_000)

        _ = registry.discover(peerID: peerID, nickname: "alice", now: start)
        _ = registry.authenticate(peerID: peerID, nickname: "alice", now: start)

        _ = registry.discover(peerID: peerID, nickname: "alice", now: start.addingTimeInterval(1))
        #expect(registry.state(of: peerID) == .authenticated)
        #expect(registry.peers.count == 1)
    }

    @Test("A peer seen again after a disconnect starts a new handshake")
    func rediscoveryAfterDisconnect() {
        let registry = makeRegistry()
        let peerID = makePeerID("8")
        let start = Date(timeIntervalSince1970: 8_000)

        _ = registry.discover(peerID: peerID, now: start)
        _ = registry.authenticate(peerID: peerID, now: start)
        _ = registry.disconnect(peerID: peerID, now: start.addingTimeInterval(1))

        _ = registry.discover(peerID: peerID, now: start.addingTimeInterval(2))
        #expect(registry.state(of: peerID) == .discovered)
    }

    @Test("The peer table is bounded")
    func capacity() {
        var timeouts = LANPeerRegistry.Timeouts.standard
        timeouts.capacity = 2
        let registry = LANPeerRegistry(timeouts: timeouts)
        let start = Date(timeIntervalSince1970: 9_000)

        #expect(registry.discover(peerID: makePeerID("1"), now: start) != nil)
        #expect(registry.discover(peerID: makePeerID("2"), now: start) != nil)
        #expect(registry.discover(peerID: makePeerID("3"), now: start) == nil)
        #expect(registry.peers.count == 2)
    }

    @Test("The hello signing key is retained for public-message verification")
    func signingKeyIsRetained() {
        let registry = makeRegistry()
        let peerID = makePeerID("b")
        let start = Date(timeIntervalSince1970: 11_000)
        let signingKey = Data(repeating: 0x22, count: 32)

        _ = registry.discover(peerID: peerID, now: start)
        _ = registry.authenticate(
            peerID: peerID,
            signingPublicKey: signingKey,
            now: start
        )

        #expect(registry.peers[peerID]?.signingPublicKey == signingKey)
    }

    @Test("Stopping the transport clears every peer snapshot")
    func removeAll() {
        let registry = makeRegistry()
        let start = Date(timeIntervalSince1970: 12_000)
        _ = registry.discover(peerID: makePeerID("c"), now: start)
        _ = registry.authenticate(peerID: makePeerID("c"), now: start)

        registry.removeAll()
        #expect(registry.peers.isEmpty)
        #expect(registry.snapshots(now: start).isEmpty)
    }

    @Test("Timed out peers disappear from the published snapshots")
    func timedOutPeersAreNotPublished() {
        let registry = makeRegistry()
        let peerID = makePeerID("a")
        let start = Date(timeIntervalSince1970: 10_000)

        _ = registry.discover(peerID: peerID, now: start)
        _ = registry.expireStalePeers(now: start.addingTimeInterval(31))
        #expect(registry.snapshots(now: start.addingTimeInterval(31)).isEmpty)
    }
}
