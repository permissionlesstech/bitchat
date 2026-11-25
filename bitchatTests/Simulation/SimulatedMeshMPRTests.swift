//
// SimulatedMeshMPRTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation
import Testing
@testable import bitchat

/// End-to-end deterministic multi-node MPR tests over real `BLEService` engines
/// (using `SimulatedMesh` with manual scheduler time — no sleeps, no flakiness).
@Suite(.serialized)
struct SimulatedMeshMPRTests {
    /// Two full-clique clusters connected by a single bridge node:
    /// Cluster A: {0 (origin), 1, 2, 3 (bridge)}
    /// Cluster B: {3 (bridge), 4, 5}
    /// All nodes run two discovery rounds so every node learns the full 2-hop
    /// confirmed topology via TLV 0x04 before the broadcast message is sent.
    @Test
    func twoClustersWithSingleBridgeDeliverWithoutNonBridgeRelays() async {
        let mesh = SimulatedMesh()
        let origin = mesh.addNode(nickname: "origin")
        _ = mesh.addNode(nickname: "a1")
        _ = mesh.addNode(nickname: "a2")
        _ = mesh.addNode(nickname: "bridge")
        let clusterB1 = mesh.addNode(nickname: "b1")
        let clusterB2 = mesh.addNode(nickname: "b2")

        // Cluster A clique: 0, 1, 2, 3
        for a in 0..<4 {
            for b in (a + 1)..<4 {
                mesh.connect(a, b)
            }
        }
        // Cluster B clique: 3, 4, 5
        mesh.connect(3, 4)
        mesh.connect(3, 5)
        mesh.connect(4, 5)

        // Two announce rounds: round 1 establishes direct links; round 2
        // propagates populated TLV 0x04 neighbor lists across 2 hops.
        settleDiscovery(mesh)

        let captureB1 = MPRPublicMessageCapture()
        let captureB2 = MPRPublicMessageCapture()
        clusterB1.service.eventDelegate = captureB1
        clusterB2.service.eventDelegate = captureB2

        let a1MessagesBefore = countOutboundPublicMessages(mesh, nodeIndex: 1)
        let a2MessagesBefore = countOutboundPublicMessages(mesh, nodeIndex: 2)
        let bridgeMessagesBefore = countOutboundPublicMessages(mesh, nodeIndex: 3)

        origin.service.sendMessage("bridge-test", mentions: [])
        mesh.pump()
        mesh.advanceTime(by: 2)
        mesh.advanceTime(by: 2)

        // Both nodes in Cluster B receive the message exactly once (zero partitions).
        #expect(await captureB1.drainedCount(content: "bridge-test") == 1)
        #expect(await captureB2.drainedCount(content: "bridge-test") == 1)

        // Bridge relayed once; non-bridge Cluster A nodes suppressed redundant relays.
        #expect(countOutboundPublicMessages(mesh, nodeIndex: 3) - bridgeMessagesBefore == 1)
        #expect(countOutboundPublicMessages(mesh, nodeIndex: 1) - a1MessagesBefore == 0)
        #expect(countOutboundPublicMessages(mesh, nodeIndex: 2) - a2MessagesBefore == 0)
    }

    /// 5-node full clique: every node is directly connected to every other node
    /// (networkSize = 4 > 3), so `N2(origin)` is empty and ZERO non-origin nodes
    /// perform redundant relays.
    @Test
    func fullCliqueProducesZeroRedundantPublicMessageRelays() async {
        let mesh = SimulatedMesh()
        for i in 0..<5 {
            mesh.addNode(nickname: "n\(i)")
        }
        for i in 0..<5 {
            for j in (i + 1)..<5 {
                mesh.connect(i, j)
            }
        }

        settleDiscovery(mesh)

        let captures = (1..<5).map { idx -> MPRPublicMessageCapture in
            let cap = MPRPublicMessageCapture()
            mesh.nodes[idx].service.eventDelegate = cap
            return cap
        }

        let beforeCounts = (1..<5).map { countOutboundPublicMessages(mesh, nodeIndex: $0) }

        mesh.nodes[0].service.sendMessage("clique-only", mentions: [])
        mesh.pump()
        mesh.advanceTime(by: 2)
        mesh.advanceTime(by: 2)

        for (offset, capture) in captures.enumerated() {
            #expect(await capture.drainedCount(content: "clique-only") == 1)
            let relaysEmitted = countOutboundPublicMessages(mesh, nodeIndex: offset + 1) - beforeCounts[offset]
            #expect(relaysEmitted == 0)
        }
    }

    /// Separate local-delivery vs. relay dedup:
    /// Node M is connected to P1 (non-electing hop) and P2 (electing hop) plus
    /// downstream leaf L. When a signed public message arrives first from P1,
    /// M delivers locally once and MPR-suppresses the relay. When the exact
    /// same signed packet arrives later from P2 (which elects M as its sole
    /// cover for L), M relays it ONCE without double-delivering locally.
    @Test
    func suppressedAuthenticatedPacketRelaysOnceWhenLaterArrivingFromElectingHop() async {
        let mesh = SimulatedMesh()
        // 0: P1 (non-electing previous hop; P1 connects to M, C1, C2, and L)
        // 1: P2 (electing previous hop; P2 connects to M, C1, C2 — NOT to L)
        // 2: M  (connects to P1, P2, C1, C2, and L)
        // 3: C1 (filler peer to push networkSize > 3)
        // 4: C2 (filler peer)
        // 5: L  (downstream leaf connected to P1 and M, NOT P2)
        let p1 = mesh.addNode(nickname: "p1")
        let p2 = mesh.addNode(nickname: "p2")
        let m = mesh.addNode(nickname: "m")
        _ = mesh.addNode(nickname: "c1")
        _ = mesh.addNode(nickname: "c2")
        let leaf = mesh.addNode(nickname: "leaf")

        let edges = [
            (0, 2), (0, 3), (0, 4), (0, 5), // P1 sees M, C1, C2, L
            (1, 2), (1, 3), (1, 4),         // P2 sees M, C1, C2 (NOT L)
            (2, 3), (2, 4), (2, 5),         // M sees P1, P2, C1, C2, L
            (3, 4)
        ]
        for (a, b) in edges {
            mesh.connect(a, b)
        }
        settleDiscovery(mesh)

        // Silence automatic mesh propagation around M so we can inject the
        // exact ingress order: first from P1 (non-electing), then from P2 (electing).
        for other in [0, 1, 3, 4, 5] {
            mesh.silence(2, other)
        }

        let captureM = MPRPublicMessageCapture()
        m.service.eventDelegate = captureM

        let signedPacket = p1.service.signPacketForBroadcast(BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: p1.service.myPeerID.routingData ?? Data(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: Data("dual-hop".utf8),
            signature: nil,
            ttl: TransportConfig.messageTTLDefault
        ))

        let mRelaysBefore = countOutboundPublicMessages(mesh, nodeIndex: 2)

        // 1. First arrival from P1: L is already in N1(P1), so M is NOT in MPR(P1).
        //    M delivers locally once and suppresses the relay.
        let linkFromP1 = BLEIngressLinkID.central(mesh.linkUUID(from: 0, at: 2))
        m.service._test_ingestFrame(signedPacket, link: linkFromP1)
        mesh.pump()
        mesh.advanceTime(by: 2)

        #expect(await captureM.drainedCount(content: "dual-hop") == 1)
        #expect(countOutboundPublicMessages(mesh, nodeIndex: 2) - mRelaysBefore == 0)

        // 2. Second arrival from P2 (with decremented hop TTL): L is in N2(P2)
        //    and M is its sole cover -> M is elected MPR(P2) and relays once,
        //    still without double-delivering locally.
        var fromP2Copy = signedPacket
        fromP2Copy.ttl = TransportConfig.messageTTLDefault - 1
        let linkFromP2 = BLEIngressLinkID.central(mesh.linkUUID(from: 1, at: 2))
        m.service._test_ingestFrame(fromP2Copy, link: linkFromP2)
        mesh.pump()
        mesh.advanceTime(by: 2)

        #expect(countOutboundPublicMessages(mesh, nodeIndex: 2) - mRelaysBefore == 1)
        #expect(await captureM.drainedCount(content: "dual-hop") == 1)

        // 3. A third arrival from P2 must not re-relay (terminal .relayed state).
        m.service._test_ingestFrame(fromP2Copy, link: linkFromP2)
        mesh.pump()
        mesh.advanceTime(by: 2)
        #expect(countOutboundPublicMessages(mesh, nodeIndex: 2) - mRelaysBefore == 1)
        _ = (p2, leaf)
    }

    @Test
    func disconnectPrunesDirectEdgeAndSchedulesTopologyChangeAnnounce() {
        let mesh = SimulatedMesh()
        let a = mesh.addNode(nickname: "alice")
        let b = mesh.addNode(nickname: "bob")
        let c = mesh.addNode(nickname: "carol")
        mesh.connect(0, 1)
        mesh.connect(0, 2)

        settleDiscovery(mesh)
        #expect(a.service._test_topologyTracker.isFreshConfirmedNeighbor(a.service.myPeerID, b.service.myPeerID))

        let announcesBefore = countOutboundAnnounces(mesh, nodeIndex: 0)
        a.service._test_resetAnnounceThrottle()

        // Drop Alice's only link to Bob while Carol remains connected.
        let bobLinkOnAlice = mesh.linkUUID(from: 1, at: 0)
        a.service.emitLinkEvent(.centralLinkEnded(centralUUID: bobLinkOnAlice))
        a.service._test_fenceEngine()

        // Direct edge (Alice, Bob) is immediately pruned from Alice's topology.
        #expect(!a.service._test_topologyTracker.isFreshConfirmedNeighbor(a.service.myPeerID, b.service.myPeerID))
        #expect(a.service._test_topologyTracker.isFreshConfirmedNeighbor(a.service.myPeerID, c.service.myPeerID))

        // Advancing scheduler past the 0.5s topology-change delay emits a prompt announce.
        mesh.advanceTime(by: TransportConfig.bleTopologyChangeAnnounceDelaySeconds + 0.1)
        #expect(countOutboundAnnounces(mesh, nodeIndex: 0) > announcesBefore)
    }

    // MARK: - Helpers

    private func settleDiscovery(_ mesh: SimulatedMesh) {
        for _ in 0..<2 {
            mesh.announceAll()
            drainQuiet(mesh)
        }
    }

    private func drainQuiet(_ mesh: SimulatedMesh) {
        var settled = mesh.deliveredFrameCount
        for _ in 0..<20 {
            mesh.advanceTime(by: 2)
            let now = mesh.deliveredFrameCount
            if now == settled { break }
            settled = now
        }
    }

    private func countOutboundPublicMessages(_ mesh: SimulatedMesh, nodeIndex: Int) -> Int {
        mesh.emittedPackets(from: nodeIndex).filter {
            $0.type == MessageType.message.rawValue
        }.count
    }

    private func countOutboundAnnounces(_ mesh: SimulatedMesh, nodeIndex: Int) -> Int {
        mesh.emittedPackets(from: nodeIndex).filter {
            $0.type == MessageType.announce.rawValue
        }.count
    }
}

private final class MPRPublicMessageCapture: TransportEventDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var contents: [String] = []

    func didReceiveTransportEvent(_ event: TransportEvent) {
        guard case let .publicMessageReceived(_, _, content, _, _) = event else { return }
        lock.lock()
        contents.append(content)
        lock.unlock()
    }

    private func count(content: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return contents.filter { $0 == content }.count
    }

    func drainedCount(content: String, drains: Int = 50) async -> Int {
        for _ in 0..<drains {
            if count(content: content) > 0 { break }
            await MainActor.run {}
        }
        return count(content: content)
    }
}
