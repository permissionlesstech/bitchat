//
// SimulatedMeshMPRTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Combine
import CryptoKit
import Foundation
import Testing
@testable import bitchat

/// End-to-end deterministic multi-node MPR tests over real `BLEService` engines
/// (using `SimulatedMesh(usePlannedLinkDelivery: true)` with manual scheduler
/// time — exercises MPR selection, relay lifecycle, neighbor pruning, and
/// `BLEOutboundLinkPlanner` end to end with no sleeps or flakiness).
@Suite(.serialized)
struct SimulatedMeshMPRTests {
    /// Two full-clique clusters connected by a single bridge node:
    /// Cluster A: {0 (origin), 1, 2, 3 (bridge)}
    /// Cluster B: {3 (bridge), 4, 5}
    /// All nodes run two discovery rounds so every node learns the full 2-hop
    /// confirmed topology via TLV 0x04 before the broadcast message is sent.
    @Test
    func twoClustersWithSingleBridgeDeliverWithoutNonBridgeRelays() async {
        let mesh = SimulatedMesh(usePlannedLinkDelivery: true)
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
        let bridgePlannedBefore = mesh.plannedTransmissions(from: 3).count

        origin.service.sendMessage("bridge-test", mentions: [])
        mesh.pump()
        mesh.advanceTime(by: 2)
        mesh.advanceTime(by: 2)

        // Both nodes in Cluster B receive the message exactly once (zero partitions).
        #expect(await captureB1.drainedCount(content: "bridge-test", on: clusterB1.service) == 1)
        #expect(await captureB2.drainedCount(content: "bridge-test", on: clusterB2.service) == 1)

        // Bridge relayed once; non-bridge Cluster A nodes suppressed redundant relays.
        #expect(countOutboundPublicMessages(mesh, nodeIndex: 3) - bridgeMessagesBefore == 1)
        #expect(countOutboundPublicMessages(mesh, nodeIndex: 1) - a1MessagesBefore == 0)
        #expect(countOutboundPublicMessages(mesh, nodeIndex: 2) - a2MessagesBefore == 0)

        // Neighbor pruning verified on planned links: bridge transmitted ONLY
        // to Cluster B (nodes 4 & 5) and pruned all Cluster A peers (0, 1, 2).
        let bridgeMessageTargets = Set(
            mesh.plannedTransmissions(from: 3)
                .dropFirst(bridgePlannedBefore)
                .filter { $0.packet.type == MessageType.message.rawValue }
                .map(\.to)
        )
        #expect(bridgeMessageTargets == [4, 5])
    }

    /// 5-node full clique: every node is directly connected to every other node
    /// (networkSize = 4 > 3), so `N2(origin)` is empty and ZERO non-origin nodes
    /// perform redundant relays.
    @Test
    func fullCliqueProducesZeroRedundantPublicMessageRelays() async {
        let mesh = SimulatedMesh(usePlannedLinkDelivery: true)
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
            #expect(await capture.drainedCount(content: "clique-only", on: mesh.nodes[offset + 1].service) == 1)
            let relaysEmitted = countOutboundPublicMessages(mesh, nodeIndex: offset + 1) - beforeCounts[offset]
            #expect(relaysEmitted == 0)
        }
    }

    /// Regression for R1-SPEC-06: symmetric relay candidates M and N both cover
    /// T from P (`P-M`, `P-N`, `M-T`, `N-T`, `P-X`; 4 known peers with fresh
    /// claims). `scheduleRelayIfNeeded` must stamp `refreshLocalTopology(at: now)`
    /// with the exact evaluation clock `now` so neither candidate rejects its
    /// own local entry as future-dated and double-suppresses the broadcast.
    @Test
    func symmetricCandidatesDoNotDoubleSuppressOnLocalTopologyRefresh() async {
        let mesh = SimulatedMesh(usePlannedLinkDelivery: true)
        let p = mesh.addNode(nickname: "p")
        _ = mesh.addNode(nickname: "m")
        _ = mesh.addNode(nickname: "n")
        let t = mesh.addNode(nickname: "t")
        _ = mesh.addNode(nickname: "x")

        // P-M, P-N, M-T, N-T, P-X
        mesh.connect(0, 1)
        mesh.connect(0, 2)
        mesh.connect(1, 3)
        mesh.connect(2, 3)
        mesh.connect(0, 4)

        settleDiscovery(mesh)

        let captureT = MPRPublicMessageCapture()
        t.service.eventDelegate = captureT

        let mBefore = countOutboundPublicMessages(mesh, nodeIndex: 1)
        let nBefore = countOutboundPublicMessages(mesh, nodeIndex: 2)

        p.service.sendMessage("symmetric-mpr", mentions: [])
        mesh.pump()
        mesh.advanceTime(by: 2)
        mesh.advanceTime(by: 2)

        // Exactly one of M or N must elect itself and deliver to T.
        let mRelays = countOutboundPublicMessages(mesh, nodeIndex: 1) - mBefore
        let nRelays = countOutboundPublicMessages(mesh, nodeIndex: 2) - nBefore
        #expect(mRelays + nRelays == 1)
        #expect(await captureT.drainedCount(content: "symmetric-mpr", on: t.service) == 1)
    }

    /// Separate local-delivery vs. relay dedup (R1-STD-03, R1-SPEC-05):
    /// Deterministic 8-node graph where `MPR(P1) == {C1, C2}` (strictly excludes
    /// M, independent of peer IDs) and `MPR(P2)` mandatorily includes M as the
    /// sole cover of L. Verifies both elections explicitly, confirms M suppresses
    /// from P1, relays once via planned links (pruning P2/C1/C2) when arriving
    /// from P2, delivers locally once, and never re-relays on a 3rd arrival.
    @Test
    func suppressedAuthenticatedPacketRelaysOnceWhenLaterArrivingFromElectingHop() async {
        let (mesh, indices) = makeDualHopLifecycleMesh()
        let p1 = mesh.nodes[indices.p1]
        let p2 = mesh.nodes[indices.p2]
        let m = mesh.nodes[indices.m]
        let leaf = mesh.nodes[indices.leaf]

        // Assert the live settled election on M's tracker before injecting packets.
        let mprOfP1 = MPRSelector.selectMPRs(
            previousHopPeerID: p1.service.myPeerID,
            topology: m.service._test_topologyTracker,
            coverageK: 1
        )
        let mprOfP2 = MPRSelector.selectMPRs(
            previousHopPeerID: p2.service.myPeerID,
            topology: m.service._test_topologyTracker,
            coverageK: 1
        )
        #expect(!mprOfP1.contains(m.service.myPeerID))
        #expect(mprOfP2.contains(m.service.myPeerID))

        let captureM = MPRPublicMessageCapture()
        let captureLeaf = MPRPublicMessageCapture()
        m.service.eventDelegate = captureM
        leaf.service.eventDelegate = captureLeaf

        let signedPacket = p2.service.signPacketForBroadcast(BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: p2.service.myPeerID.routingData ?? Data(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: Data("dual-hop".utf8),
            signature: nil,
            ttl: TransportConfig.messageTTLDefault
        ))

        let mRelaysBefore = countOutboundPublicMessages(mesh, nodeIndex: indices.m)
        let mPlannedBefore = mesh.plannedTransmissions(from: indices.m).count

        // 1. First arrival from non-electing P1: M delivers locally once and suppresses.
        var fromP1Copy = signedPacket
        fromP1Copy.ttl = TransportConfig.messageTTLDefault - 1
        let linkFromP1 = BLEIngressLinkID.central(mesh.linkUUID(from: indices.p1, at: indices.m))
        m.service._test_ingestFrame(fromP1Copy, link: linkFromP1)
        mesh.pump()
        mesh.advanceTime(by: 2)

        #expect(await captureM.drainedCount(content: "dual-hop", on: m.service) == 1)
        #expect(countOutboundPublicMessages(mesh, nodeIndex: indices.m) - mRelaysBefore == 0)

        // 2. Second arrival from electing P2: M relays once without double-delivering locally.
        let linkFromP2 = BLEIngressLinkID.central(mesh.linkUUID(from: indices.p2, at: indices.m))
        m.service._test_ingestFrame(signedPacket, link: linkFromP2)
        mesh.pump()
        mesh.advanceTime(by: 2)

        #expect(countOutboundPublicMessages(mesh, nodeIndex: indices.m) - mRelaysBefore == 1)
        #expect(await captureM.drainedCount(content: "dual-hop", on: m.service) == 1)
        #expect(await captureLeaf.drainedCount(content: "dual-hop", on: leaf.service) == 1)

        // Planned link pruning check: M must prune P2 (origin/prevHop), C1, and C2
        // (fresh confirmed neighbors of P2), while transmitting to L.
        let mTargets = Set(
            mesh.plannedTransmissions(from: indices.m)
                .dropFirst(mPlannedBefore)
                .filter { $0.packet.type == MessageType.message.rawValue }
                .map(\.to)
        )
        #expect(mTargets.contains(indices.leaf))
        #expect(!mTargets.contains(indices.p2))
        #expect(!mTargets.contains(indices.c1))
        #expect(!mTargets.contains(indices.c2))

        // 3. A third arrival from P2 must not re-relay (terminal .relayed state)
        //    and must not double-deliver locally on M or Leaf.
        m.service._test_ingestFrame(signedPacket, link: linkFromP2)
        mesh.pump()
        mesh.advanceTime(by: 2)
        #expect(countOutboundPublicMessages(mesh, nodeIndex: indices.m) - mRelaysBefore == 1)
        #expect(await captureM.drainedCount(content: "dual-hop", on: m.service) == 1)
        #expect(await captureLeaf.drainedCount(content: "dual-hop", on: leaf.service) == 1)
    }

    /// Regression for R1-STD-01, R1-SPEC-01, and R2-STD-02: valid signed broadcast
    /// fragments enter 2-covered MPR (`k = 2`), store an `authenticatedDigest`
    /// when suppressed on a non-electing hop, and reopen once on a matching
    /// duplicate from an electing hop both within AND after the 3s ingress-link
    /// window — driven by a deterministic injected clock (`_test_now`) that
    /// exercises real `BLEIngressLinkRegistry` TTL expiry without sleeps.
    /// Tampered copies cannot reopen suppression, and unsigned broadcast
    /// fragments fail closed to pruned flood rather than suppressing.
    @Test
    func suppressedSignedBroadcastFragmentReopensWithinAndAfterIngressWindow() {
        let (mesh, indices) = makeDualHopLifecycleMesh()
        let p1 = mesh.nodes[indices.p1]
        let p2 = mesh.nodes[indices.p2]
        let m = mesh.nodes[indices.m]

        // Pin M's clock deterministically so runner pauses can never push a
        // within-window check past the 3s ingress lifetime, and advancing the
        // clock exercises real `BLEIngressLinkRegistry.recordIfNew` expiry.
        var clock = Date()
        m.service._test_now = { clock }

        // Verify k = 2 MPR elections explicitly on M's live topology.
        let mpr2P1 = MPRSelector.selectMPRs(
            previousHopPeerID: p1.service.myPeerID,
            topology: m.service._test_topologyTracker,
            coverageK: 2,
            now: clock
        )
        let mpr2P2 = MPRSelector.selectMPRs(
            previousHopPeerID: p2.service.myPeerID,
            topology: m.service._test_topologyTracker,
            coverageK: 2,
            now: clock
        )
        #expect(!mpr2P1.contains(m.service.myPeerID))
        #expect(mpr2P2.contains(m.service.myPeerID))

        let linkFromP1 = BLEIngressLinkID.central(mesh.linkUUID(from: indices.p1, at: indices.m))
        let linkFromP2 = BLEIngressLinkID.central(mesh.linkUUID(from: indices.p2, at: indices.m))
        let baseTs = UInt64(clock.timeIntervalSince1970 * 1000)

        func makeFragmentPayload(tag: UInt8) -> Data {
            // Minimal valid 13-byte fragment header + 8-byte chunk payload
            var data = Data(repeating: tag, count: 8) // fragmentID
            data.append(contentsOf: [0x00, 0x00])     // index 0
            data.append(contentsOf: [0x00, 0x02])     // total 2 (incomplete -> won't reassemble)
            data.append(MessageType.fileTransfer.rawValue)
            data.append(Data(repeating: tag, count: 8))
            return data
        }

        // Case 1: Within the 3s ingress-link window (duplicate gate in attributeAndHandlePacket).
        let signedFrag1 = p2.service.signPacketForBroadcast(BitchatPacket(
            type: MessageType.fragment.rawValue,
            senderID: p2.service.myPeerID.routingData ?? Data(),
            recipientID: nil,
            timestamp: baseTs,
            payload: makeFragmentPayload(tag: 0xA1),
            signature: nil,
            ttl: TransportConfig.messageTTLDefault
        ))
        let fragsBefore1 = countOutboundFragments(mesh, nodeIndex: indices.m)

        var fromP1Frag1 = signedFrag1
        fromP1Frag1.ttl = TransportConfig.messageTTLDefault - 1
        m.service._test_ingestFrame(fromP1Frag1, link: linkFromP1)
        mesh.pump()
        mesh.advanceTime(by: 2)
        #expect(countOutboundFragments(mesh, nodeIndex: indices.m) - fragsBefore1 == 0)

        // Exact matching duplicate from electing hop P2 within 3s window (+0.5s) -> relays once.
        clock = clock.addingTimeInterval(0.5)
        m.service._test_ingestFrame(signedFrag1, link: linkFromP2)
        mesh.pump()
        mesh.advanceTime(by: 2)
        #expect(countOutboundFragments(mesh, nodeIndex: indices.m) - fragsBefore1 == 1)

        // Additional copy from P2 must not re-relay (terminal .relayed).
        m.service._test_ingestFrame(signedFrag1, link: linkFromP2)
        mesh.pump()
        mesh.advanceTime(by: 2)
        #expect(countOutboundFragments(mesh, nodeIndex: indices.m) - fragsBefore1 == 1)

        // Case 2: After the 3s ingress-link window expires (fragments bypass global dedup).
        let signedFrag2 = p2.service.signPacketForBroadcast(BitchatPacket(
            type: MessageType.fragment.rawValue,
            senderID: p2.service.myPeerID.routingData ?? Data(),
            recipientID: nil,
            timestamp: baseTs + 10,
            payload: makeFragmentPayload(tag: 0xB2),
            signature: nil,
            ttl: TransportConfig.messageTTLDefault
        ))
        let fragsBefore2 = countOutboundFragments(mesh, nodeIndex: indices.m)

        var fromP1Frag2 = signedFrag2
        fromP1Frag2.ttl = TransportConfig.messageTTLDefault - 1
        m.service._test_ingestFrame(fromP1Frag2, link: linkFromP1)
        mesh.pump()
        mesh.advanceTime(by: 2)
        #expect(countOutboundFragments(mesh, nodeIndex: indices.m) - fragsBefore2 == 0)

        // Advance clock past real ingress record lifetime (> 3s) without clearing directly.
        clock = clock.addingTimeInterval(TransportConfig.bleIngressRecordLifetimeSeconds + 1.0)

        // A tampered copy (wrong signature, same messageID) must NOT reopen suppression.
        var tamperedFrag2 = signedFrag2
        tamperedFrag2.signature = Data(repeating: 0xFF, count: 64)
        m.service._test_ingestFrame(tamperedFrag2, link: linkFromP2)
        mesh.pump()
        mesh.advanceTime(by: 2)
        #expect(countOutboundFragments(mesh, nodeIndex: indices.m) - fragsBefore2 == 0)

        // Advance past ingress window again; exact valid copy reopens once.
        clock = clock.addingTimeInterval(TransportConfig.bleIngressRecordLifetimeSeconds + 1.0)
        m.service._test_ingestFrame(signedFrag2, link: linkFromP2)
        mesh.pump()
        mesh.advanceTime(by: 2)
        #expect(countOutboundFragments(mesh, nodeIndex: indices.m) - fragsBefore2 == 1)

        // Even after another ingress-link expiry, a subsequent copy never re-relays once terminal.
        clock = clock.addingTimeInterval(TransportConfig.bleIngressRecordLifetimeSeconds + 1.0)
        m.service._test_ingestFrame(signedFrag2, link: linkFromP2)
        mesh.pump()
        mesh.advanceTime(by: 2)
        #expect(countOutboundFragments(mesh, nodeIndex: indices.m) - fragsBefore2 == 1)

        // Case 3: Unsigned broadcast fragment fails closed to prunedFlood (relays
        // even from non-electing P1, reaching P2 which is in N2(P1) and not pruned).
        let unsignedFrag = BitchatPacket(
            type: MessageType.fragment.rawValue,
            senderID: p1.service.myPeerID.routingData ?? Data(),
            recipientID: nil,
            timestamp: baseTs + 20,
            payload: makeFragmentPayload(tag: 0xC3),
            signature: nil,
            ttl: TransportConfig.messageTTLDefault - 1
        )
        let fragsBefore3 = countOutboundFragments(mesh, nodeIndex: indices.m)
        m.service._test_ingestFrame(unsignedFrag, link: linkFromP1)
        mesh.pump()
        mesh.advanceTime(by: 2)
        #expect(countOutboundFragments(mesh, nodeIndex: indices.m) - fragsBefore3 == 1)
    }

    /// Regression for R1-STD-02 & R1-SPEC-02:
    /// 1. An unchanged verified ANNOUNCE from a stale direct originator (expired
    ///    entry still present in `meshTopology`) must conservatively flood, not
    ///    be MPR-suppressed.
    /// 2. A routine unchanged verified ANNOUNCE from a fresh indirect originator
    ///    (whose `peerRegistry` entry has `isConnected == false`) must use MPR
    ///    rather than perpetually triggering reconnect conservative flooding.
    @Test
    func staleOriginAnnounceFloodsConservativelyWhileFreshIndirectAnnounceUsesMPR() {
        let mesh = SimulatedMesh(usePlannedLinkDelivery: true)
        // Cluster A clique {0 (origin), 1 (a1), 2 (a2), 3 (bridge)} + Cluster B {3, 4 (b1), 5 (b2)}
        let origin = mesh.addNode(nickname: "origin")
        let a1 = mesh.addNode(nickname: "a1")
        _ = mesh.addNode(nickname: "a2")
        _ = mesh.addNode(nickname: "bridge")
        let b1 = mesh.addNode(nickname: "b1")
        _ = mesh.addNode(nickname: "b2")

        for a in 0..<4 {
            for b in (a + 1)..<4 {
                mesh.connect(a, b)
            }
        }
        mesh.connect(3, 4)
        mesh.connect(3, 5)
        mesh.connect(4, 5)
        settleDiscovery(mesh)

        // Verify a1 is NOT elected MPR for origin (Cluster A clique with sole bridge 3).
        let mprOrigin = MPRSelector.selectMPRs(
            previousHopPeerID: origin.service.myPeerID,
            topology: a1.service._test_topologyTracker,
            coverageK: 1
        )
        #expect(!mprOrigin.contains(a1.service.myPeerID))

        // Part 1: Fresh indirect origin (b1 is 2 hops from a1 -> isConnected == false
        // in a1's peerRegistry). When b1 sends a routine unchanged ANNOUNCE relayed
        // via bridge (node 3), a1 is NOT in MPR(bridge) because bridge connects directly
        // to origin, a1, a2, b1, b2 (N2(bridge) is empty). a1 MUST suppress it rather
        // than treating indirect b1 as a reconnected peer.
        let mprBridge = MPRSelector.selectMPRs(
            previousHopPeerID: mesh.nodes[3].service.myPeerID,
            topology: a1.service._test_topologyTracker,
            coverageK: 1
        )
        #expect(!mprBridge.contains(a1.service.myPeerID))
        #expect(!a1.service.isPeerConnected(b1.service.myPeerID))

        let a1AnnouncesBeforeIndirect = countOutboundAnnounces(mesh, nodeIndex: 1)
        let b1Announce = makeSignedAnnounce(
            from: b1.service,
            nickname: "b1",
            directNeighbors: [mesh.nodes[3].service.myPeerID, mesh.nodes[5].service.myPeerID],
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000) + 1_000,
            ttl: TransportConfig.messageTTLDefault - 1
        )
        let bridgeLinkOnA1 = BLEIngressLinkID.central(mesh.linkUUID(from: 3, at: 1))
        a1.service._test_ingestFrame(b1Announce, link: bridgeLinkOnA1)
        mesh.pump()
        mesh.advanceTime(by: 2)
        #expect(countOutboundAnnounces(mesh, nodeIndex: 1) - a1AnnouncesBeforeIndirect == 0)

        // Part 2: Age origin's topology entry on a1 past bleMprEdgeMaxAgeSeconds
        // without removing it from the tracker (simulating stale-but-unpruned entry).
        let staleDate = Date().addingTimeInterval(-(TransportConfig.bleMprEdgeMaxAgeSeconds + 30))
        a1.service._test_topologyTracker.updateNeighbors(
            for: origin.service.myPeerID.routingData,
            neighbors: [
                a1.service.myPeerID.routingData,
                mesh.nodes[2].service.myPeerID.routingData,
                mesh.nodes[3].service.myPeerID.routingData
            ].compactMap { $0 },
            announceTimestamp: nil,
            at: staleDate
        )
        #expect(!a1.service._test_topologyTracker.isFreshAnnouncement(for: origin.service.myPeerID))

        // Origin sends an unchanged verified ANNOUNCE with a newer timestamp.
        // Because origin was stale before this update, a1 MUST conservatively relay it
        // (and NOT suppress via MPR).
        let a1AnnouncesBeforeStale = countOutboundAnnounces(mesh, nodeIndex: 1)
        let originAnnounce = makeSignedAnnounce(
            from: origin.service,
            nickname: "origin",
            directNeighbors: [a1.service.myPeerID, mesh.nodes[2].service.myPeerID, mesh.nodes[3].service.myPeerID],
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000) + 2_000,
            ttl: TransportConfig.messageTTLDefault
        )
        let originLinkOnA1 = BLEIngressLinkID.central(mesh.linkUUID(from: 0, at: 1))
        a1.service._test_ingestFrame(originAnnounce, link: originLinkOnA1)
        mesh.pump()
        mesh.advanceTime(by: 2)
        #expect(countOutboundAnnounces(mesh, nodeIndex: 1) - a1AnnouncesBeforeStale == 1)
    }

    @Test
    func disconnectPrunesDirectEdgeAndSchedulesTopologyChangeAnnounce() {
        let mesh = SimulatedMesh(usePlannedLinkDelivery: true)
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

    /// Regression for R1-SPEC-03: bulk role teardown (`allPeripheralLinksEnded`
    /// and `allCentralLinksEnded`) must mark peers that lost their last link as
    /// disconnected BEFORE calling `refreshLocalTopology()`, drop their direct
    /// edge, keep peers that survive on the other role, and schedule the ~0.5s
    /// topology-change ANNOUNCE with only the surviving neighbors.
    @Test
    func bulkRoleTeardownMarksLostPeersDisconnectedAndSchedulesTopologyChangeAnnounce() throws {
        let mesh = SimulatedMesh(usePlannedLinkDelivery: true)
        let a = mesh.addNode(nickname: "alice")
        let b = mesh.addNode(nickname: "bob")
        let c = mesh.addNode(nickname: "carol")
        mesh.connect(0, 1)
        mesh.connect(0, 2)
        settleDiscovery(mesh)

        // Move Bob to a peripheral-only link on Alice while Carol stays on a central link.
        let bobCentralUUID = mesh.linkUUID(from: 1, at: 0)
        let bobPeripheralUUID = "SIM-PERIPH-BOB"
        a.service._test_bindPeripheral(bobPeripheralUUID, to: b.service.myPeerID)
        a.service.emitLinkEvent(.centralLinkEnded(centralUUID: bobCentralUUID))
        a.service._test_fenceEngine()
        #expect(a.service.isPeerConnected(b.service.myPeerID))
        #expect(a.service.isPeerConnected(c.service.myPeerID))

        let announcesBefore = countOutboundAnnounces(mesh, nodeIndex: 0)
        a.service._test_resetAnnounceThrottle()

        // Bulk peripheral teardown drops Bob's only remaining link while Carol survives on central.
        a.service.emitLinkEvent(.allPeripheralLinksEnded(
            peripheralIDs: [bobPeripheralUUID],
            retireProofsAndNotify: true
        ))
        a.service._test_fenceEngine()

        #expect(!a.service.isPeerConnected(b.service.myPeerID))
        #expect(a.service.isPeerConnected(c.service.myPeerID))
        #expect(!a.service._test_topologyTracker.isFreshConfirmedNeighbor(a.service.myPeerID, b.service.myPeerID))
        #expect(a.service._test_topologyTracker.isFreshConfirmedNeighbor(a.service.myPeerID, c.service.myPeerID))

        // Before the 0.5s delay, no topology-change announce has fired yet.
        mesh.advanceTime(by: TransportConfig.bleTopologyChangeAnnounceDelaySeconds - 0.1)
        #expect(countOutboundAnnounces(mesh, nodeIndex: 0) == announcesBefore)

        // Past the 0.5s delay, the announce fires and advertises Carol without Bob.
        mesh.advanceTime(by: 0.2)
        let newAnnounces = mesh.emittedPackets(from: 0).filter {
            $0.type == MessageType.announce.rawValue
        }
        #expect(newAnnounces.count > announcesBefore)
        let latest = try #require(newAnnounces.last)
        let decoded = try #require(AnnouncementPacket.decode(from: latest.payload))
        let advertisedNeighbors = Set(decoded.directNeighbors ?? [])
        #expect(advertisedNeighbors.contains(try #require(c.service.myPeerID.routingData)))
        #expect(!advertisedNeighbors.contains(try #require(b.service.myPeerID.routingData)))

        // Symmetric check for `.allCentralLinksEnded(..., retireProofsAndNotify: false)`:
        // give Bob a surviving peripheral link and drop all centrals (Carol loses its only link).
        let d = mesh.addNode(nickname: "dave")
        mesh.connect(0, 3)
        a.service._test_bindPeripheral("SIM-PERIPH-DAVE", to: d.service.myPeerID)
        a.service._test_seedConnectedPeer(d.service.myPeerID, nickname: "dave")
        a.service._test_topologyTracker.updateNeighbors(
            for: d.service.myPeerID.routingData,
            neighbors: [a.service.myPeerID.routingData].compactMap { $0 }
        )
        let announcesBeforeCentralTear = countOutboundAnnounces(mesh, nodeIndex: 0)
        a.service._test_resetAnnounceThrottle()

        a.service.emitLinkEvent(.allCentralLinksEnded(centralUUIDs: [], retireProofsAndNotify: false))
        a.service._test_fenceEngine()

        #expect(!a.service.isPeerConnected(c.service.myPeerID))
        #expect(a.service.isPeerConnected(d.service.myPeerID))
        #expect(!a.service._test_topologyTracker.isFreshConfirmedNeighbor(a.service.myPeerID, c.service.myPeerID))

        mesh.advanceTime(by: TransportConfig.bleTopologyChangeAnnounceDelaySeconds + 0.1)
        #expect(countOutboundAnnounces(mesh, nodeIndex: 0) > announcesBeforeCentralTear)
    }

    /// Regression for R1-STD-06: when physical teardown occurs on `bleQueue`
    /// before the queued binding-retirement event runs on the engine queue,
    /// both `scheduleRelayIfNeeded` and `sendOnAllLinks` join `linkBindings`
    /// against physical liveness (`readLinkState`) — failing safe by relaying
    /// (not suppressing) and disabling neighbor pruning so live targets are
    /// never dropped.
    @Test
    func physicalTeardownBeforeBindingRetirementDisablesSuppressionAndNeighborPruning() {
        let mesh = SimulatedMesh(usePlannedLinkDelivery: true)
        // Cluster A clique {0 (origin), 1 (a1), 2 (a2), 3 (bridge)} + Cluster B {3, 4 (b1)}
        let origin = mesh.addNode(nickname: "origin")
        let a1 = mesh.addNode(nickname: "a1")
        _ = mesh.addNode(nickname: "a2")
        let bridge = mesh.addNode(nickname: "bridge")
        _ = mesh.addNode(nickname: "b1")

        for a in 0..<4 {
            for b in (a + 1)..<4 {
                mesh.connect(a, b)
            }
        }
        mesh.connect(3, 4)
        settleDiscovery(mesh)

        // Confirm a1 would normally suppress origin's broadcast, and bridge would
        // normally prune a1/a2 when relaying origin's broadcast.
        let originLinkOnA1 = BLEIngressLinkID.central(mesh.linkUUID(from: 0, at: 1))
        let originLinkOnBridge = BLEIngressLinkID.central(mesh.linkUUID(from: 0, at: 3))
        #expect(a1.service._test_linkBinding(originLinkOnA1) == origin.service.myPeerID)
        #expect(bridge.service._test_linkBinding(originLinkOnBridge) == origin.service.myPeerID)

        // Simulate physical link gone while binding still exists in linkBindings!
        a1.service._test_isPhysicalLinkLive = { $0 != originLinkOnA1 }
        bridge.service._test_isPhysicalLinkLive = { $0 != originLinkOnBridge }

        let signedPacket = origin.service.signPacketForBroadcast(BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: origin.service.myPeerID.routingData ?? Data(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: Data("liveness-race".utf8),
            signature: nil,
            ttl: TransportConfig.messageTTLDefault
        ))

        // 1. Relay evaluation path (`scheduleRelayIfNeeded`): a1 must NOT suppress
        //    because physical liveness says originLinkOnA1 is dead (previousHop -> nil).
        let a1RelaysBefore = countOutboundPublicMessages(mesh, nodeIndex: 1)
        a1.service._test_ingestFrame(signedPacket, link: originLinkOnA1)
        mesh.pump()
        mesh.advanceTime(by: 2)
        #expect(countOutboundPublicMessages(mesh, nodeIndex: 1) - a1RelaysBefore == 1)

        // 2. Egress-only teardown between scheduleRelayIfNeeded and sendOnAllLinks:
        //    originLinkOnBridge IS live during scheduleRelayIfNeeded (so relayContext
        //    is created with skipNeighborPruning == false), and ONLY goes physically
        //    dead before the jittered sendOnAllLinks fires. sendOnAllLinks must
        //    independently revalidate physical liveness and disable neighbor pruning,
        //    so a2 (a fresh confirmed neighbor of origin) IS included alongside b1!
        bridge.service._test_isPhysicalLinkLive = { _ in true }
        let bridgePlannedBefore = mesh.plannedTransmissions(from: 3).count
        let signedPacket2 = origin.service.signPacketForBroadcast(BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: origin.service.myPeerID.routingData ?? Data(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000) + 10,
            payload: Data("liveness-egress".utf8),
            signature: nil,
            ttl: TransportConfig.messageTTLDefault
        ))
        bridge.service._test_ingestFrame(signedPacket2, link: originLinkOnBridge)
        mesh.pump()
        // Now tear down originLinkOnBridge physically BEFORE the jittered relay fires
        // (while linkBindings still retains the binding).
        bridge.service._test_isPhysicalLinkLive = { $0 != originLinkOnBridge }
        mesh.advanceTime(by: 2)

        let bridgeTargets = Set(
            mesh.plannedTransmissions(from: 3)
                .dropFirst(bridgePlannedBefore)
                .filter { $0.packet.type == MessageType.message.rawValue }
                .map(\.to)
        )
        #expect(bridgeTargets.contains(4)) // b1
        #expect(bridgeTargets.contains(2)) // a2 NOT pruned when previous hop link dies before egress
    }

    /// Regression for R1-SPEC-04 & R2-SPEC-04: `sendEncrypted` must forward
    /// `relayContext` into `sendFragmentedPacket` on BOTH direct-recipient MTU
    /// paths (peripheral write limit and central notify limit). Even when
    /// `origin != prevHop` and BOTH the recipient AND `prevHop`'s original
    /// ingress link disconnect mid-fragment-train (while `prevHop` retains a
    /// surviving alternate link), later chunks must NEVER echo back onto
    /// `prevHop`'s surviving link while still reaching `other`.
    @Test
    func encryptedRelayFragmentationPreservesRelayContextAcrossDisconnectForBothRoles() {
        for role in ["peripheral", "central"] {
            let mesh = SimulatedMesh(usePlannedLinkDelivery: true)
            _ = mesh.addNode(nickname: "prev")
            let relay = mesh.addNode(nickname: "relay")
            let recipient = mesh.addNode(nickname: "dest")
            _ = mesh.addNode(nickname: "other")
            let origin = mesh.addNode(nickname: "origin")

            mesh.connectDuplicateLinks(0, 1) // prev - relay has TWO links (primary + duplicate)
            mesh.connect(1, 2)               // relay - dest
            mesh.connect(1, 3)               // relay - other
            mesh.connect(4, 0)               // origin - prev (origin != prevHop!)
            settleDiscovery(mesh)

            let recipientID = recipient.service.myPeerID
            if role == "peripheral" {
                relay.service._test_directLinkMTU = { peerID in
                    peerID == recipientID ? (peripheralMaxLen: 90, centralMaxLen: nil) : (nil, nil)
                }
            } else {
                relay.service._test_directLinkMTU = { peerID in
                    peerID == recipientID ? (peripheralMaxLen: nil, centralMaxLen: 90) : (nil, nil)
                }
            }

            // Large encrypted packet (> 90 bytes) originated by `origin` (NOT `prevHop`),
            // addressed to `dest`, arriving at `relay` over `prevHop`'s primary link.
            let largeEncrypted = BitchatPacket(
                type: MessageType.noiseEncrypted.rawValue,
                senderID: origin.service.myPeerID.routingData ?? Data(),
                recipientID: recipientID.routingData,
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: Data(repeating: 0x5A, count: 260),
                signature: nil,
                ttl: TransportConfig.messageTTLDefault - 1
            )

            let plannedBefore = mesh.plannedTransmissions(from: 1).count
            let ingressLinkUUID = mesh.linkUUID(from: 0, at: 1)
            let ingressLink = BLEIngressLinkID.central(ingressLinkUUID)
            relay.service._test_ingestFrame(largeEncrypted, link: ingressLink)
            mesh.pump()
            // Noise packets hop onto messageQueue a second time in handleReceivedPacket;
            // fence once more so scheduleRelayIfNeeded has registered on engineScheduler.
            relay.service._test_fenceEngine()

            // Advance just past the relay jitter (20..60ms) so sendEncrypted starts
            // the 8-chunk fragment train (25ms spacing, 175ms total), then step
            // 10ms so chunk 0 (0ms offset) delivers directly to dest while later
            // chunks remain pending.
            mesh.advanceTime(by: 0.07)
            mesh.advanceTime(by: 0.01)

            // Disconnect recipient AND drop prevHop's original ingress link while
            // prevHop's surviving duplicate link stays connected!
            let destLinkOnRelay = mesh.linkUUID(from: 2, at: 1)
            mesh.silence(1, 2)
            mesh.dropPrimaryDuplicateLink(0, 1)
            relay.service._test_directLinkMTU = nil
            relay.service.emitLinkEvent(.centralLinkEnded(centralUUID: destLinkOnRelay))
            relay.service.emitLinkEvent(.centralLinkEnded(centralUUID: ingressLinkUUID))
            relay.service._test_fenceEngine()

            // Flush all remaining fragment chunks.
            mesh.advanceTime(by: 2.0)

            let fragmentTransmissions = mesh.plannedTransmissions(from: 1)
                .dropFirst(plannedBefore)
                .filter { $0.packet.type == MessageType.fragment.rawValue }
            // Early chunk(s) reached dest directly before disconnect; later chunks
            // fell back to flooding non-excluded links (`other`) and NEVER echoed
            // back onto `prevHop`'s surviving link (node 0).
            #expect(fragmentTransmissions.contains { $0.to == 2 })
            #expect(fragmentTransmissions.contains { $0.to == 3 })
            #expect(!fragmentTransmissions.contains { $0.to == 0 })
        }
    }

    /// Regression for R2-SPEC-01: an off-route receiver receiving a source-routed
    /// packet whose `route[0]` is its own ingress peer must not drop the packet
    /// after egress excludes that peer — it must fall back to conservative
    /// broadcast/flood and deliver over an alternate path.
    @Test
    func offRouteSourceRoutedPacketFallsBackToConservativeFloodWhenRouteFirstHopIsIngress() async {
        let mesh = SimulatedMesh(usePlannedLinkDelivery: true)
        let origin = mesh.addNode(nickname: "origin")       // 0
        let firstHop = mesh.addNode(nickname: "firstHop")   // 1 (route[0])
        let offRoute = mesh.addNode(nickname: "offRoute")   // 2 (receives from firstHop)
        let dest = mesh.addNode(nickname: "dest")           // 3 (alternate path from offRoute)

        mesh.connect(0, 1)
        mesh.connect(1, 2)
        mesh.connect(2, 3)
        settleDiscovery(mesh)

        let captureDest = MPRPublicMessageCapture()
        dest.service.eventDelegate = captureDest

        // Source-routed packet with route = [firstHop], arriving at `offRoute` from `firstHop`.
        // `offRoute` is not in `route`, and `route[0]` IS its own ingress peer (`firstHop`).
        let routedPacket = origin.service.signPacketForBroadcast(BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: origin.service.myPeerID.routingData ?? Data(),
            recipientID: dest.service.myPeerID.routingData,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: Data("route-fallback".utf8),
            signature: nil,
            ttl: TransportConfig.messageTTLDefault - 1,
            version: 2,
            route: [firstHop.service.myPeerID.routingData].compactMap { $0 }
        ))

        let ingressLink = BLEIngressLinkID.central(mesh.linkUUID(from: 1, at: 2))
        offRoute.service._test_ingestFrame(routedPacket, link: ingressLink)
        mesh.pump()
        mesh.advanceTime(by: 2)

        // Conservative flood fallback delivered the packet to `dest` via alternate link.
        let plannedFromOffRoute = mesh.plannedTransmissions(from: 2)
            .filter { $0.packet.type == MessageType.message.rawValue }
            .map(\.to)
        #expect(plannedFromOffRoute.contains(3))
        #expect(!plannedFromOffRoute.contains(1))
    }

    /// Regression for R2-SPEC-02 & R2-SPEC-03: a provisional raw `ANNOUNCE`
    /// binding (before signature verification) must neither impersonate a
    /// verified previous hop to suppress/prune traffic nor hide an unidentified
    /// live link from MPR fail-safes.
    @Test
    func provisionalRawAnnounceBindingNeitherImpersonatesPreviousHopNorHidesUnidentifiedLink() {
        let mesh = SimulatedMesh(usePlannedLinkDelivery: true)
        // Cluster A clique {0 (origin), 1 (a1), 2 (a2), 3 (bridge)} + Cluster B {3, 4 (b1)}
        let origin = mesh.addNode(nickname: "origin")
        let a1 = mesh.addNode(nickname: "a1")
        _ = mesh.addNode(nickname: "a2")
        _ = mesh.addNode(nickname: "bridge")
        _ = mesh.addNode(nickname: "b1")
        let newcomer = mesh.addNode(nickname: "newcomer") // 5

        for a in 0..<4 {
            for b in (a + 1)..<4 {
                mesh.connect(a, b)
            }
        }
        mesh.connect(3, 4)
        settleDiscovery(mesh)

        // Connect newcomer to a1 WITHOUT verifying its announce, then send an
        // UNSIGNED (unverified) raw direct announce so linkBindings holds a
        // provisional binding to newcomer while peerRegistry has no connected row.
        mesh.connect(1, 5)
        let newcomerLinkOnA1 = BLEIngressLinkID.central(mesh.linkUUID(from: 5, at: 1))
        let unverifiedAnnounce = BitchatPacket(
            type: MessageType.announce.rawValue,
            senderID: newcomer.service.myPeerID.routingData ?? Data(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000) + 500,
            payload: AnnouncementPacket(
                nickname: "newcomer",
                noisePublicKey: newcomer.service.noiseStaticPublicKeyData(),
                signingPublicKey: newcomer.service.noiseSigningPublicKeyData(),
                directNeighbors: []
            ).encode() ?? Data(),
            signature: nil,
            ttl: TransportConfig.messageTTLDefault
        )
        a1.service._test_ingestFrame(unverifiedAnnounce, link: newcomerLinkOnA1)
        mesh.pump()
        mesh.advanceTime(by: 2)

        // Confirm provisional binding exists, yet newcomer is NOT connected in peerRegistry.
        #expect(a1.service._test_linkBinding(newcomerLinkOnA1) == newcomer.service.myPeerID)
        #expect(!a1.service.isPeerConnected(newcomer.service.myPeerID))

        // Seed a fresh confirmed edge between `origin` and `newcomer` in a1's
        // topology (simulating a peer that moved from origin onto a provisional
        // link on a1). Egress pruning MUST NOT trust the unverified provisional
        // binding to prune newcomer's only current egress link (R3-SPEC-02).
        a1.service._test_topologyTracker.updateNeighbors(
            for: origin.service.myPeerID.routingData,
            neighbors: [
                a1.service.myPeerID.routingData,
                mesh.nodes[2].service.myPeerID.routingData,
                mesh.nodes[3].service.myPeerID.routingData,
                newcomer.service.myPeerID.routingData
            ].compactMap { $0 }
        )
        a1.service._test_topologyTracker.updateNeighbors(
            for: newcomer.service.myPeerID.routingData,
            neighbors: [origin.service.myPeerID.routingData].compactMap { $0 }
        )
        #expect(a1.service._test_topologyTracker.isFreshConfirmedNeighbor(
            origin.service.myPeerID,
            newcomer.service.myPeerID
        ))

        // 1. R2-SPEC-03 & R3-SPEC-02: Normally a1 suppresses origin's broadcast
        //    and prunes origin's confirmed neighbors, but because newcomer's link
        //    is only provisionally bound (unverified), a1 MUST fail safe, relay,
        //    AND deliver to newcomer on its planned egress link!
        let a1RelaysBefore = countOutboundPublicMessages(mesh, nodeIndex: 1)
        let a1PlannedBefore = mesh.plannedTransmissions(from: 1).count
        let originMsg = origin.service.signPacketForBroadcast(BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: origin.service.myPeerID.routingData ?? Data(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000) + 1_000,
            payload: Data("dont-strand-newcomer".utf8),
            signature: nil,
            ttl: TransportConfig.messageTTLDefault
        ))
        let originLinkOnA1 = BLEIngressLinkID.central(mesh.linkUUID(from: 0, at: 1))
        a1.service._test_ingestFrame(originMsg, link: originLinkOnA1)
        mesh.pump()
        mesh.advanceTime(by: 2)
        #expect(countOutboundPublicMessages(mesh, nodeIndex: 1) - a1RelaysBefore == 1)
        let a1PlannedTargets = Set(
            mesh.plannedTransmissions(from: 1)
                .dropFirst(a1PlannedBefore)
                .filter { $0.packet.type == MessageType.message.rawValue }
                .map(\.to)
        )
        #expect(a1PlannedTargets.contains(5))

        // 2. R2-SPEC-02: An unverified provisional link claiming an existing fresh
        //    peer (`origin`) must NOT act as a verified previous hop to suppress.
        let spoofedLink = BLEIngressLinkID.central("SIM-SPOOF-ORIGIN")
        a1.service._test_bindCentral("SIM-SPOOF-ORIGIN", to: origin.service.myPeerID, verified: false)
        // Drop newcomer link so the ONLY thing preventing suppression is the unverified ingress.
        mesh.silence(1, 5)
        a1.service.emitLinkEvent(.centralLinkEnded(centralUUID: mesh.linkUUID(from: 5, at: 1)))
        a1.service._test_fenceEngine()

        let a1RelaysBeforeSpoof = countOutboundPublicMessages(mesh, nodeIndex: 1)
        let spoofHopMsg = origin.service.signPacketForBroadcast(BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: origin.service.myPeerID.routingData ?? Data(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000) + 2_000,
            payload: Data("provisional-hop-must-not-suppress".utf8),
            signature: nil,
            ttl: TransportConfig.messageTTLDefault
        ))
        a1.service._test_ingestFrame(spoofHopMsg, link: spoofedLink)
        mesh.pump()
        mesh.advanceTime(by: 2)
        #expect(countOutboundPublicMessages(mesh, nodeIndex: 1) - a1RelaysBeforeSpoof == 1)
    }

    /// Regression for R2-SPEC-05: a duplicate arriving on an unbound/unknown-hop
    /// link must NOT prematurely reopen or claim terminal `.relayed` for a
    /// suppressed authenticated packet, so a subsequent arrival from the
    /// electing hop still relays once.
    @Test
    func unknownHopDuplicateDoesNotPrematurelyClaimSuppressedRelay() async {
        let (mesh, indices) = makeDualHopLifecycleMesh()
        let p2 = mesh.nodes[indices.p2]
        let m = mesh.nodes[indices.m]
        let leaf = mesh.nodes[indices.leaf]

        let captureLeaf = MPRPublicMessageCapture()
        leaf.service.eventDelegate = captureLeaf

        let signedPacket = p2.service.signPacketForBroadcast(BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: p2.service.myPeerID.routingData ?? Data(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: Data("unknown-hop-dup".utf8),
            signature: nil,
            ttl: TransportConfig.messageTTLDefault
        ))

        let mRelaysBefore = countOutboundPublicMessages(mesh, nodeIndex: indices.m)
        let linkFromP1 = BLEIngressLinkID.central(mesh.linkUUID(from: indices.p1, at: indices.m))
        let linkFromP2 = BLEIngressLinkID.central(mesh.linkUUID(from: indices.p2, at: indices.m))
        let unboundLink = BLEIngressLinkID.central("SIM-UNBOUND-LINK")

        // 1. First arrival from non-electing P1 -> suppressed.
        var fromP1Copy = signedPacket
        fromP1Copy.ttl = TransportConfig.messageTTLDefault - 1
        m.service._test_ingestFrame(fromP1Copy, link: linkFromP1)
        mesh.pump()
        mesh.advanceTime(by: 2)
        #expect(countOutboundPublicMessages(mesh, nodeIndex: indices.m) - mRelaysBefore == 0)

        // 2. Duplicate on unbound link (unknown previous hop) -> must NOT relay or
        //    claim terminal `.relayed`.
        m.service._test_ingestFrame(fromP1Copy, link: unboundLink)
        mesh.pump()
        mesh.advanceTime(by: 2)
        #expect(countOutboundPublicMessages(mesh, nodeIndex: indices.m) - mRelaysBefore == 0)

        // 3. Subsequent arrival from electing hop P2 STILL reopens and relays once!
        m.service._test_ingestFrame(signedPacket, link: linkFromP2)
        mesh.pump()
        mesh.advanceTime(by: 2)
        #expect(countOutboundPublicMessages(mesh, nodeIndex: indices.m) - mRelaysBefore == 1)
        #expect(await captureLeaf.drainedCount(content: "unknown-hop-dup", on: leaf.service) == 1)
    }

    /// Regression for R2-BUG-01: solicited gossip replay (RSR, TTL 0) must
    /// still deliver a peer's own cached public message back to that peer over
    /// planned links (even though `targetPeerID == originPeerID`), after the
    /// ingress record has expired.
    @Test
    func solicitedGossipReplayRestoresSelfAuthoredPublicMessageOverPlannedLinks() async {
        let mesh = SimulatedMesh(usePlannedLinkDelivery: true)
        let alice = mesh.addNode(nickname: "alice") // 0
        let bob = mesh.addNode(nickname: "bob")     // 1

        var clock = Date()
        alice.service._test_now = { clock }
        bob.service._test_now = { clock }

        mesh.connect(0, 1)
        settleDiscovery(mesh)

        let captureAlice = MPRPublicMessageCapture()
        alice.service.eventDelegate = captureAlice

        // Alice broadcasts a public message; Bob caches it.
        let originalPacket = alice.service.signPacketForBroadcast(BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: alice.service.myPeerID.routingData ?? Data(),
            recipientID: nil,
            timestamp: UInt64(clock.timeIntervalSince1970 * 1000),
            payload: Data("restore-my-history".utf8),
            signature: nil,
            ttl: TransportConfig.messageTTLDefault
        ))
        let aliceLinkOnBob = BLEIngressLinkID.central(mesh.linkUUID(from: 0, at: 1))
        bob.service._test_ingestFrame(originalPacket, link: aliceLinkOnBob)
        mesh.pump()
        mesh.advanceTime(by: 2)

        // Expire the ingress record on Bob via controlled clock.
        clock = clock.addingTimeInterval(TransportConfig.bleIngressRecordLifetimeSeconds + 2.0)

        // Alice registers an outgoing sync request to Bob, and Bob answers with
        // a solicited gossip sync replay (TTL 0, isRSR = true) of Alice's own
        // message via `sendPacket(to:packet:)`.
        alice.service._test_registerOutgoingSyncRequest(to: bob.service.myPeerID)
        var rsrReplay = originalPacket
        rsrReplay.ttl = 0
        rsrReplay.isRSR = true

        let bobPlannedBefore = mesh.plannedTransmissions(from: 1).count
        bob.service.sendPacket(to: alice.service.myPeerID, packet: rsrReplay)
        mesh.pump()
        mesh.advanceTime(by: 1)

        // Bob's planned links MUST include Alice (node 0), and Alice MUST
        // receive her own restored public message.
        let bobReplayTargets = mesh.plannedTransmissions(from: 1)
            .dropFirst(bobPlannedBefore)
            .filter { $0.packet.type == MessageType.message.rawValue && $0.packet.isRSR }
            .map(\.to)
        #expect(bobReplayTargets == [0])
        #expect(await captureAlice.drainedCount(content: "restore-my-history", on: alice.service) == 1)
    }

    /// Regression for R3-STD-02: if a routed packet's next hop physically tears
    /// down before its binding/registry entry retires while another unrelated
    /// link is available, `forwardAlongRouteIfNeeded` must NOT credit the
    /// unrelated link as routed unicast success — it must trigger the explicit
    /// conservative broadcast fallback (`skipNeighborPruning = true`).
    @Test
    func routedNextHopPhysicallyGoneFallsBackToConservativeFloodEvenWithOtherLinks() {
        let mesh = SimulatedMesh(usePlannedLinkDelivery: true)
        let origin = mesh.addNode(nickname: "origin")     // 0
        let relay = mesh.addNode(nickname: "relay")       // 1
        let deadNext = mesh.addNode(nickname: "deadNext") // 2 (physically gone, registry still connected)
        let altHop = mesh.addNode(nickname: "altHop")     // 3 (also a confirmed neighbor of origin!)
        let dest = mesh.addNode(nickname: "dest")         // 4

        mesh.connect(0, 1) // origin - relay
        mesh.connect(0, 3) // origin - altHop (so non-conservative pruning would drop altHop!)
        mesh.connect(1, 2) // relay - deadNext
        mesh.connect(1, 3) // relay - altHop
        mesh.connect(3, 4) // altHop - dest
        settleDiscovery(mesh)

        // deadNext is physically dead before its binding/registry entry retires.
        let deadNextLinkOnRelay = BLEIngressLinkID.central(mesh.linkUUID(from: 2, at: 1))
        #expect(relay.service.isPeerConnected(deadNext.service.myPeerID))
        relay.service._test_isPhysicalLinkLive = { $0 != deadNextLinkOnRelay }

        let routedPacket = origin.service.signPacketForBroadcast(BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: origin.service.myPeerID.routingData ?? Data(),
            recipientID: dest.service.myPeerID.routingData,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: Data("dead-next-hop-fallback".utf8),
            signature: nil,
            ttl: TransportConfig.messageTTLDefault,
            version: 2,
            route: [relay.service.myPeerID.routingData, deadNext.service.myPeerID.routingData].compactMap { $0 }
        ))

        let plannedBefore = mesh.plannedTransmissions(from: 1).count
        let originLinkOnRelay = BLEIngressLinkID.central(mesh.linkUUID(from: 0, at: 1))
        relay.service._test_ingestFrame(routedPacket, link: originLinkOnRelay)
        mesh.pump()
        mesh.advanceTime(by: 2)

        // Conservative flood fallback ran (did NOT prune altHop despite origin-altHop edge)
        // and transmitted to altHop (node 3), reaching dest!
        let relayTargets = Set(
            mesh.plannedTransmissions(from: 1)
                .dropFirst(plannedBefore)
                .filter { $0.packet.type == MessageType.message.rawValue }
                .map(\.to)
        )
        #expect(relayTargets.contains(3))
        #expect(!relayTargets.contains(0))
    }

    /// Regression for R3-SPEC-03: verifies previous-hop echo handling across
    /// both link transitions with `origin != prevHop` and a surviving sibling link:
    /// 1. Physical teardown BEFORE scheduling: generated fragments must still
    ///    suppress echo onto `prevHop`'s surviving sibling link.
    /// 2. Ingress rebind BEFORE unfragmented send: old owner's sibling link
    ///    must NOT remain excluded once ingress belongs to a different peer.
    @Test
    func previousHopEchoSuppressionHandlesTeardownBeforeSchedulingAndIngressRebind() {
        // Part 1: Physical teardown BEFORE scheduling on fragmented encrypted relay.
        do {
            let mesh = SimulatedMesh(usePlannedLinkDelivery: true)
            _ = mesh.addNode(nickname: "prev")     // 0
            let relay = mesh.addNode(nickname: "relay")      // 1
            let recipient = mesh.addNode(nickname: "dest")   // 2
            let other = mesh.addNode(nickname: "other")      // 3
            let origin = mesh.addNode(nickname: "origin")    // 4 (distinct from prevHop!)

            mesh.connectDuplicateLinks(0, 1) // primary + sibling link between prevHop and relay
            mesh.connect(1, 2)
            mesh.connect(1, 3)
            mesh.connect(4, 0)
            settleDiscovery(mesh)

            let primaryLinkUUID = mesh.linkUUID(from: 0, at: 1)
            let primaryLink = BLEIngressLinkID.central(primaryLinkUUID)
            let recipientID = recipient.service.myPeerID

            // Force physical teardown of `primaryLink` BEFORE scheduling runs, while
            // keeping its binding and sibling link intact.
            relay.service._test_isPhysicalLinkLive = { $0 != primaryLink }
            relay.service._test_directLinkMTU = { peerID in
                peerID == recipientID ? (peripheralMaxLen: 90, centralMaxLen: nil) : (nil, nil)
            }

            let largeEncrypted = BitchatPacket(
                type: MessageType.noiseEncrypted.rawValue,
                senderID: origin.service.myPeerID.routingData ?? Data(),
                recipientID: recipientID.routingData,
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: Data(repeating: 0x6B, count: 260),
                signature: nil,
                ttl: TransportConfig.messageTTLDefault - 1
            )

            let plannedBefore = mesh.plannedTransmissions(from: 1).count
            relay.service._test_ingestFrame(largeEncrypted, link: primaryLink)
            mesh.pump()
            relay.service._test_fenceEngine()

            // Start fragment train, then disconnect recipient so remaining chunks flood.
            mesh.advanceTime(by: 0.07)
            mesh.advanceTime(by: 0.01)
            mesh.silence(1, 2)
            relay.service._test_directLinkMTU = nil
            relay.service.emitLinkEvent(.centralLinkEnded(centralUUID: mesh.linkUUID(from: 2, at: 1)))
            relay.service._test_fenceEngine()
            mesh.advanceTime(by: 2.0)

            let fragTargets = mesh.plannedTransmissions(from: 1)
                .dropFirst(plannedBefore)
                .filter { $0.packet.type == MessageType.fragment.rawValue }
                .map(\.to)
            #expect(fragTargets.contains(3))
            #expect(!fragTargets.contains(0)) // sibling link of prevHop must NOT receive echoes
        }

        // Part 2: Ingress rebind to a different peer BEFORE unfragmented relay fires.
        do {
            let mesh = SimulatedMesh(usePlannedLinkDelivery: true)
            let oldOwner = mesh.addNode(nickname: "oldOwner") // 0
            let relay = mesh.addNode(nickname: "relay")       // 1
            let newOwner = mesh.addNode(nickname: "newOwner") // 2
            let origin = mesh.addNode(nickname: "origin")     // 3 (distinct from oldOwner!)

            mesh.connectDuplicateLinks(0, 1) // oldOwner has primary + sibling link to relay
            mesh.connect(3, 0)
            settleDiscovery(mesh)

            let primaryLinkUUID = mesh.linkUUID(from: 0, at: 1)
            let primaryLink = BLEIngressLinkID.central(primaryLinkUUID)

            let msg = origin.service.signPacketForBroadcast(BitchatPacket(
                type: MessageType.message.rawValue,
                senderID: origin.service.myPeerID.routingData ?? Data(),
                recipientID: nil,
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000) + 100,
                payload: Data("rebind-sibling-check".utf8),
                signature: nil,
                ttl: TransportConfig.messageTTLDefault - 1
            ))

            let plannedBefore = mesh.plannedTransmissions(from: 1).count
            relay.service._test_ingestFrame(msg, link: primaryLink)
            mesh.pump()

            // Rebind `primaryLink` to `newOwner` BEFORE the jittered relay fires!
            // `oldOwner`'s sibling link remains live and must no longer be excluded.
            relay.service._test_bindCentral(primaryLinkUUID, to: newOwner.service.myPeerID, verified: true)
            mesh.advanceTime(by: 2.0)

            let msgTargets = Set(
                mesh.plannedTransmissions(from: 1)
                    .dropFirst(plannedBefore)
                    .filter { $0.packet.type == MessageType.message.rawValue }
                    .map(\.to)
            )
            #expect(msgTargets.contains(0)) // oldOwner's sibling link is eligible after ingress rebind
        }
    }

    /// Regression for R3-SPEC-04: a source-routed packet over a 4-node path
    /// (`A -> B -> C -> D`) where the middle link (`B -> C`) has a smaller MTU
    /// forcing re-fragmentation at `B` must preserve `D` as the fragment
    /// `recipientID`, forward every fragment through `C` to `D`, and reassemble
    /// at `D`.
    @Test
    func sourceRoutedPacketSurvivesMiddleLinkSmallMTURefragmentation() async {
        let mesh = SimulatedMesh(usePlannedLinkDelivery: true)
        let a = mesh.addNode(nickname: "a") // 0
        let b = mesh.addNode(nickname: "b") // 1
        let c = mesh.addNode(nickname: "c") // 2
        let d = mesh.addNode(nickname: "d") // 3

        mesh.connect(0, 1)
        mesh.connect(1, 2)
        mesh.connect(2, 3)
        settleDiscovery(mesh)

        // Middle link B -> C has a smaller MTU (110 bytes) forcing re-fragmentation at B.
        let cLinkOnB = mesh.linkUUID(from: 2, at: 1)
        b.service._test_virtualCentralMTU = { uuid in
            uuid == cLinkOnB ? 110 : nil
        }

        let captureD = MPRPublicMessageCapture()
        d.service.eventDelegate = captureD

        let longBody = String(repeating: "R", count: 160)
        let routedPacket = a.service.signPacketForBroadcast(BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: a.service.myPeerID.routingData ?? Data(),
            recipientID: d.service.myPeerID.routingData,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: Data(longBody.utf8),
            signature: nil,
            ttl: TransportConfig.messageTTLDefault,
            version: 2,
            route: [b.service.myPeerID.routingData, c.service.myPeerID.routingData].compactMap { $0 }
        ))

        let aLinkOnB = BLEIngressLinkID.central(mesh.linkUUID(from: 0, at: 1))
        let bPlannedBefore = mesh.plannedTransmissions(from: 1).count
        let cPlannedBefore = mesh.plannedTransmissions(from: 2).count

        b.service._test_ingestFrame(routedPacket, link: aLinkOnB)
        mesh.pump()
        mesh.advanceTime(by: 2)
        mesh.advanceTime(by: 2)

        // B re-fragmented into >1 fragments addressed to D (NOT C), and C forwarded them to D.
        let bFragsToC = mesh.plannedTransmissions(from: 1)
            .dropFirst(bPlannedBefore)
            .filter { $0.to == 2 && $0.packet.type == MessageType.fragment.rawValue }
        let cFragsToD = mesh.plannedTransmissions(from: 2)
            .dropFirst(cPlannedBefore)
            .filter { $0.to == 3 && $0.packet.type == MessageType.fragment.rawValue }
        #expect(bFragsToC.count > 1)
        #expect(bFragsToC.allSatisfy { $0.packet.recipientID == d.service.myPeerID.routingData })
        #expect(bFragsToC.allSatisfy { ($0.packet.toBinaryData(padding: false)?.count ?? Int.max) <= 110 })
        #expect(cFragsToD.count == bFragsToC.count)
        #expect(await captureD.drainedCount(content: longBody, on: d.service) == 1)
    }

    /// Regression for R4-SPEC-02: when the routed next hop's MTU is too small
    /// to carry even a 1-byte v2 routed fragment (`50 < 62` bytes for a 2-hop
    /// route), strict routed delivery must fail cleanly and fall back to
    /// conservative broadcast/flood over an alternate path instead of silently
    /// dropping oversized frames.
    @Test
    func routedNextHopMTUTooSmallForRoutedFragmentFallsBackToConservativeFlood() async {
        let mesh = SimulatedMesh(usePlannedLinkDelivery: true)
        let a = mesh.addNode(nickname: "a") // 0
        let b = mesh.addNode(nickname: "b") // 1
        let c = mesh.addNode(nickname: "c") // 2 (routed next hop, tiny MTU)
        let e = mesh.addNode(nickname: "e") // 3 (alternate relay)
        let d = mesh.addNode(nickname: "d") // 4 (final destination)

        mesh.connect(0, 1)
        mesh.connect(1, 2)
        mesh.connect(2, 4)
        mesh.connect(1, 3)
        mesh.connect(3, 4)
        settleDiscovery(mesh)

        // B -> C MTU (50 bytes) is smaller than the 62-byte 2-hop v2 routed
        // fragment overhead, so routed fragmentation cannot fit on B -> C.
        let cLinkOnB = mesh.linkUUID(from: 2, at: 1)
        b.service._test_virtualCentralMTU = { uuid in
            uuid == cLinkOnB ? 50 : nil
        }

        let captureD = MPRPublicMessageCapture()
        d.service.eventDelegate = captureD

        let body = String(repeating: "F", count: 140)
        let routedPacket = a.service.signPacketForBroadcast(BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: a.service.myPeerID.routingData ?? Data(),
            recipientID: d.service.myPeerID.routingData,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: Data(body.utf8),
            signature: nil,
            ttl: TransportConfig.messageTTLDefault,
            version: 2,
            route: [b.service.myPeerID.routingData, c.service.myPeerID.routingData].compactMap { $0 }
        ))

        let aLinkOnB = BLEIngressLinkID.central(mesh.linkUUID(from: 0, at: 1))
        let bPlannedBefore = mesh.plannedTransmissions(from: 1).count

        b.service._test_ingestFrame(routedPacket, link: aLinkOnB)
        mesh.pump()
        mesh.advanceTime(by: 2)
        mesh.advanceTime(by: 2)

        // B must not emit oversized routed frames onto C; it must fall back to
        // conservative flooding via E so D still receives the message.
        let bSent = mesh.plannedTransmissions(from: 1).dropFirst(bPlannedBefore)
        #expect(bSent.allSatisfy { $0.to != 2 })
        #expect(bSent.contains { $0.to == 3 })
        #expect(await captureD.drainedCount(content: body, on: d.service) == 1)
        _ = e
    }

    /// Regression for R4-STD-02: conservative-flood classes (such as an urgent
    /// `BOARD_POST`) must always relay and must not have their pending
    /// scheduled relay cancelled at `degree > 2` if a duplicate copy reassembles
    /// with `ttl == 0` before the relay timer fires.
    @Test
    func conservativeUrgentBoardPostSurvivesReassembledTTLZeroDuplicateBeforeRelayFires() throws {
        let mesh = SimulatedMesh(usePlannedLinkDelivery: true)
        let sender = mesh.addNode(nickname: "sender")         // 0
        let relay = mesh.addNode(nickname: "relay")           // 1 (degree = 3 > 2)
        let downstream = mesh.addNode(nickname: "downstream") // 2
        let other = mesh.addNode(nickname: "other")           // 3

        mesh.connect(0, 1)
        mesh.connect(1, 2)
        mesh.connect(1, 3)
        settleDiscovery(mesh)

        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let author = Curve25519.Signing.PrivateKey()
        let postID = Data(repeating: 0x55, count: 16)
        let content = String(repeating: "URGENT ", count: 30)
        let signingBytes = BoardPostPacket.signingBytes(
            postID: postID,
            geohash: "9q8yy",
            content: content,
            authorSigningKey: author.publicKey.rawRepresentation,
            authorNickname: "sender",
            createdAt: nowMs,
            expiresAt: nowMs + 60_000,
            flags: BoardPostPacket.urgentFlag
        )
        let post = BoardPostPacket(
            postID: postID,
            geohash: "9q8yy",
            content: content,
            authorSigningKey: author.publicKey.rawRepresentation,
            authorNickname: "sender",
            createdAt: nowMs,
            expiresAt: nowMs + 60_000,
            flags: BoardPostPacket.urgentFlag,
            signature: try author.signature(for: signingBytes)
        )
        let urgentPacket = BitchatPacket(
            type: MessageType.boardPost.rawValue,
            senderID: sender.service.myPeerID.routingData ?? Data(),
            recipientID: nil,
            timestamp: nowMs,
            payload: BoardWire.post(post).encode(),
            signature: nil,
            ttl: TransportConfig.messageTTLDefault
        )

        let senderLinkOnRelay = BLEIngressLinkID.central(mesh.linkUUID(from: 0, at: 1))
        let otherLinkOnRelay = BLEIngressLinkID.central(mesh.linkUUID(from: 3, at: 1))
        let relayPlannedBefore = mesh.plannedTransmissions(from: 1).count

        // 1. First arrival schedules a conservative relay on `relay` (timer not yet fired).
        relay.service._test_ingestFrame(urgentPacket, link: senderLinkOnRelay)
        relay.service._test_fenceEngine()

        // 2. Before advancing time, complete a duplicate fragment train of the
        //    exact same urgent post on `otherLinkOnRelay`; reassembly sets
        //    `ttl = 0` and enters `dropDuplicatePacketIfNeeded` at degree 3.
        let fragPlan = try #require(BLEOutboundFragmentPlanner.makePlan(
            for: BLEOutboundFragmentTransferRequest(
                packet: urgentPacket,
                pad: false,
                maxChunk: 120,
                directedPeer: nil,
                transferId: nil
            ),
            defaultChunkSize: 256,
            bleMaxMTU: 512,
            fragmentID: Data(repeating: 0x77, count: 8)
        ))
        #expect(fragPlan.fragmentPackets.count > 1)
        for frag in fragPlan.fragmentPackets {
            relay.service._test_ingestFrame(frag, link: otherLinkOnRelay)
        }
        relay.service._test_fenceEngine()

        // 3. Advance time so the scheduled conservative relay fires; it must
        //    still transmit the urgent BOARD_POST to `downstream`.
        mesh.advanceTime(by: 2)

        let relayedToDownstream = mesh.plannedTransmissions(from: 1)
            .dropFirst(relayPlannedBefore)
            .filter { $0.to == 2 && $0.packet.type == MessageType.boardPost.rawValue }
        #expect(relayedToDownstream.count == 1)
        _ = downstream
        _ = other
    }

    /// Regression for R4-BUG-01: maintenance cleanup (`performCleanup`) must
    /// prune `relayLifecycle` and `ingressLinks` against the monotonic topology
    /// clock rather than wall-clock `Date()`, so a forward wall-clock jump does
    /// not wipe active suppression state before its monotonic TTL expires.
    @Test
    func maintenanceCleanupUsesMonotonicClockAndPreservesSuppressedRelayState() async {
        let (mesh, idx) = makeDualHopLifecycleMesh()
        let p1 = mesh.nodes[idx.p1]
        let p2 = mesh.nodes[idx.p2]
        let m = mesh.nodes[idx.m]
        let leaf = mesh.nodes[idx.leaf]

        // Pin M's monotonic clock 10 hours behind wall-clock `Date()` so a
        // wall-clock maintenance prune would wipe both `relayLifecycle` (60s)
        // and `ingressLinks` (3s).
        let monotonicBase = Date().addingTimeInterval(-36_000)
        m.service._test_now = { monotonicBase }
        settleDiscovery(mesh)

        let captureLeaf = MPRPublicMessageCapture()
        leaf.service.eventDelegate = captureLeaf

        let content = "r4-monotonic-cleanup-check"
        // Author the packet at P2 (not connected to `leaf`) so M's reopened
        // relay from electing hop P2 is NOT pruned by origin-neighbor exclusion.
        let signedPacket = p2.service.signPacketForBroadcast(BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: p2.service.myPeerID.routingData ?? Data(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: Data(content.utf8),
            signature: nil,
            ttl: TransportConfig.messageTTLDefault
        ))

        let p1LinkOnM = BLEIngressLinkID.central(mesh.linkUUID(from: idx.p1, at: idx.m))
        let p2LinkOnM = BLEIngressLinkID.central(mesh.linkUUID(from: idx.p2, at: idx.m))
        let mBefore = countOutboundPublicMessages(mesh, nodeIndex: idx.m)

        // 1. P1 -> M suppresses the broadcast at `monotonicBase` (M not in MPR(P1)).
        var fromP1 = signedPacket
        fromP1.ttl = signedPacket.ttl - 1
        m.service._test_ingestFrame(fromP1, link: p1LinkOnM)
        mesh.pump()
        mesh.advanceTime(by: 2)
        #expect(countOutboundPublicMessages(mesh, nodeIndex: idx.m) == mBefore)

        // 2. Run maintenance cleanup while wall-clock `Date()` is 10 hours
        //    ahead of `monotonicBase`: suppressed state must survive.
        m.service._test_performCleanup()

        // 3. Matching duplicate from electing hop P2 must still reopen and
        //    relay once to `leaf`.
        m.service._test_ingestFrame(signedPacket, link: p2LinkOnM)
        mesh.pump()
        mesh.advanceTime(by: 2)

        #expect(countOutboundPublicMessages(mesh, nodeIndex: idx.m) == mBefore + 1)
        #expect(await captureLeaf.drainedCount(content: content, on: leaf.service) == 1)
        _ = p1
    }

    /// Regression for R5-SPEC-02: routed `NOISE_ENCRYPTED` (direct fallback via
    /// `sendEncrypted`) and routed `FILE_TRANSFER` (`broadcastPacket` path) must
    /// both use route-aware MTU chunking, keeping every emitted fragment within
    /// the 110-byte link MTU while preserving final `recipientID`.
    @Test
    func routedNoiseAndFileTransferFallbackRespectSmallLinkMTU() {
        let mesh = SimulatedMesh(usePlannedLinkDelivery: true)
        let a = mesh.addNode(nickname: "a") // 0
        let b = mesh.addNode(nickname: "b") // 1 (relay)
        let c = mesh.addNode(nickname: "c") // 2 (unreachable next hop)
        let d = mesh.addNode(nickname: "d") // 3 (final destination, 110-byte link from B)

        mesh.connect(0, 1)
        mesh.connect(1, 2)
        mesh.connect(1, 3)
        mesh.connect(2, 3)
        settleDiscovery(mesh)

        // Break B -> C so B falls back to conservative broadcast/direct send to D.
        mesh.silence(1, 2)
        let dLinkOnB = mesh.linkUUID(from: 3, at: 1)
        b.service._test_virtualCentralMTU = { uuid in
            uuid == dLinkOnB ? 110 : nil
        }
        // Also configure `_test_directLinkMTU` so `sendEncrypted` exercises its
        // direct-link fragmentation branch directly.
        b.service._test_directLinkMTU = { peerID in
            guard peerID == d.service.myPeerID else { return (nil, nil) }
            return (peripheralMaxLen: nil, centralMaxLen: 110)
        }

        let aLinkOnB = BLEIngressLinkID.central(mesh.linkUUID(from: 0, at: 1))
        let route = [b.service.myPeerID.routingData, c.service.myPeerID.routingData].compactMap { $0 }

        // 1. Routed NOISE_ENCRYPTED fallback via `sendEncrypted`.
        let bPlannedBeforeNoise = mesh.plannedTransmissions(from: 1).count
        let routedNoise = BitchatPacket(
            type: MessageType.noiseEncrypted.rawValue,
            senderID: a.service.myPeerID.routingData ?? Data(),
            recipientID: d.service.myPeerID.routingData,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: Data(repeating: 0xAB, count: 160),
            signature: nil,
            ttl: TransportConfig.messageTTLDefault,
            version: 2,
            route: route
        )
        b.service._test_ingestFrame(routedNoise, link: aLinkOnB)
        b.service._test_fenceEngine()
        mesh.pump()
        mesh.advanceTime(by: 2)
        mesh.advanceTime(by: 2)

        let noiseFragsToD = mesh.plannedTransmissions(from: 1)
            .dropFirst(bPlannedBeforeNoise)
            .filter { $0.to == 3 && $0.packet.type == MessageType.fragment.rawValue }
        #expect(noiseFragsToD.count > 1)
        #expect(noiseFragsToD.allSatisfy { $0.packet.recipientID == d.service.myPeerID.routingData })
        #expect(noiseFragsToD.allSatisfy { ($0.packet.toBinaryData(padding: false)?.count ?? Int.max) <= 110 })

        // 2. Routed FILE_TRANSFER fallback via `broadcastPacket`.
        let bPlannedBeforeFile = mesh.plannedTransmissions(from: 1).count
        let filePayload = BitchatFilePacket(
            fileName: "sample.bin",
            fileSize: 160,
            mimeType: "application/octet-stream",
            content: Data(repeating: 0xCD, count: 160)
        ).encode() ?? Data(repeating: 0xCD, count: 160)
        let routedFile = a.service.signPacketForBroadcast(BitchatPacket(
            type: MessageType.fileTransfer.rawValue,
            senderID: a.service.myPeerID.routingData ?? Data(),
            recipientID: d.service.myPeerID.routingData,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000) + 1,
            payload: filePayload,
            signature: nil,
            ttl: TransportConfig.messageTTLDefault,
            version: 2,
            route: route
        ))
        b.service._test_ingestFrame(routedFile, link: aLinkOnB)
        mesh.pump()
        mesh.advanceTime(by: 2)
        mesh.advanceTime(by: 2)

        let fileFragsToD = mesh.plannedTransmissions(from: 1)
            .dropFirst(bPlannedBeforeFile)
            .filter { $0.to == 3 && $0.packet.type == MessageType.fragment.rawValue }
        #expect(fileFragsToD.count > 1)
        #expect(fileFragsToD.allSatisfy { $0.packet.recipientID == d.service.myPeerID.routingData })
        #expect(fileFragsToD.allSatisfy { ($0.packet.toBinaryData(padding: false)?.count ?? Int.max) <= 110 })
    }

    /// Regression for R5-SPEC-03: when a middle hop breaks (`B - C`) and
    /// conservative flood reaches an off-route relay `E` via `F` (so `E`'s
    /// ingress is `F`, not `B`) where `E` has live links to BOTH `route[0] == B`
    /// and destination `D`, `E` must deliver to `D` instead of bouncing the
    /// packet back to `B` (where deduplication drops it).
    @Test
    func offRouteFallbackRelayReachesDestinationInsteadOfLoopingBackToFirstHop() async {
        let mesh = SimulatedMesh(usePlannedLinkDelivery: true)
        let a = mesh.addNode(nickname: "a") // 0 (origin)
        let b = mesh.addNode(nickname: "b") // 1 (route[0])
        let c = mesh.addNode(nickname: "c") // 2 (route[1], unreachable from B)
        let f = mesh.addNode(nickname: "f") // 3 (intermediate off-route relay)
        let e = mesh.addNode(nickname: "e") // 4 (off-route relay linked to both B and D)
        let d = mesh.addNode(nickname: "d") // 5 (final destination)

        mesh.connect(0, 1) // A - B
        mesh.connect(1, 2) // B - C
        mesh.connect(2, 5) // C - D
        mesh.connect(1, 3) // B - F
        mesh.connect(3, 4) // F - E
        mesh.connect(4, 1) // E - B (first hop)
        mesh.connect(4, 5) // E - D (destination)
        settleDiscovery(mesh)

        // Break middle hop B - C so B falls back to conservative flood.
        mesh.silence(1, 2)

        let captureD = MPRPublicMessageCapture()
        d.service.eventDelegate = captureD

        let body = "r5-off-route-fallback-delivery"
        let routedPacket = a.service.signPacketForBroadcast(BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: a.service.myPeerID.routingData ?? Data(),
            recipientID: d.service.myPeerID.routingData,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: Data(body.utf8),
            signature: nil,
            ttl: TransportConfig.messageTTLDefault,
            version: 2,
            route: [b.service.myPeerID.routingData, c.service.myPeerID.routingData].compactMap { $0 }
        ))

        let aLinkOnB = BLEIngressLinkID.central(mesh.linkUUID(from: 0, at: 1))
        let ePlannedBefore = mesh.plannedTransmissions(from: 4).count

        b.service._test_ingestFrame(routedPacket, link: aLinkOnB)
        mesh.pump()
        mesh.advanceTime(by: 2)
        mesh.advanceTime(by: 2)
        mesh.advanceTime(by: 2)

        // E must deliver to D rather than looping the packet back to B.
        let eMsgTargets = Set(
            mesh.plannedTransmissions(from: 4)
                .dropFirst(ePlannedBefore)
                .filter { $0.packet.type == MessageType.message.rawValue }
                .map(\.to)
        )
        #expect(eMsgTargets.contains(5))
        #expect(!eMsgTargets.contains(1))
        #expect(await captureD.drainedCount(content: body, on: d.service) == 1)
        _ = f
        _ = e
    }

    /// Regression for R5-STD-01: when bulk role teardown clears all peripheral
    /// links while a peer's opposite-role central binding is still present in
    /// `linkBindings` but already physically dead (staggered teardown before
    /// binding retirement), `handleBulkRoleLinksEnded` must join against
    /// physical liveness, immediately prune the direct edge, and schedule a
    /// topology-change announce.
    @Test
    func bulkRoleTeardownWithStaggeredOppositeRolePhysicalDropPrunesEdgeAndAnnounces() {
        let mesh = SimulatedMesh(usePlannedLinkDelivery: true)
        let hub = mesh.addNode(nickname: "hub")       // 0
        let leaving = mesh.addNode(nickname: "leave") // 1
        let survivor = mesh.addNode(nickname: "stay") // 2

        mesh.connect(0, 1)
        mesh.connect(0, 2)
        settleDiscovery(mesh)

        // Give `leaving` an extra peripheral binding on `hub` (dual-role), then
        // physically drop its central link BEFORE its central binding retires.
        let periphID = "SIM-PERIPH-LEAVING"
        let survivorCentralID = mesh.linkUUID(from: 2, at: 0)
        hub.service._test_bindPeripheral(periphID, to: leaving.service.myPeerID)

        // Mark `leaving`'s central link physically dead while keeping its
        // binding queued, and keep `survivor`'s central link physically live.
        hub.service._test_isPhysicalLinkLive = { link in
            switch link {
            case .central(let uuid):
                return uuid == survivorCentralID
            case .peripheral:
                return false
            }
        }

        let announcesBefore = countOutboundAnnounces(mesh, nodeIndex: 0)
        hub.service._test_resetAnnounceThrottle()
        hub.service.emitLinkEvent(.allPeripheralLinksEnded(
            peripheralIDs: [periphID],
            retireProofsAndNotify: true
        ))
        mesh.pump()
        mesh.advanceTime(by: 1.0)

        let directNeighbors = hub.service._test_topologyTracker.freshConfirmedNeighbors(
            of: hub.service.myPeerID
        )
        #expect(!directNeighbors.contains(leaving.service.myPeerID))
        #expect(!hub.service.isPeerConnected(leaving.service.myPeerID))
        #expect(countOutboundAnnounces(mesh, nodeIndex: 0) > announcesBefore)
        _ = survivor
    }

    /// Regression for R6-STD-01, R6-SPEC-03, R7-STD-02, and R7-SPEC-02:
    /// legacy directed `FILE_TRANSFER` preflight and encrypted private media
    /// must evaluate the live link-MTU budget, visibly emit `.rejected` before
    /// scheduler admission (never `.started`, 0 fragments emitted) when the
    /// actual plan exceeds 256 fragments, leaves 0 usable payload bytes, or
    /// exceeds the shared 10,000-fragment receiver ceiling.
    @Test
    func legacyPrivateMediaPreflightRejectsLinkAwarePlansExceedingAndroid256FragmentLimit() {
        func makeIncompressibleData(count: Int, seed: UInt64) -> Data {
            var state = seed
            return Data((0..<count).map { _ in
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return UInt8(truncatingIfNeeded: state >> 32)
            })
        }

        let progressLock = NSLock()
        var rejectedReasons: [String: String] = [:]
        var startedIDs = Set<String>()
        let cancellable = TransferProgressManager.shared.publisher.sink { event in
            progressLock.lock()
            defer { progressLock.unlock() }
            switch event {
            case let .rejected(id, reason):
                rejectedReasons[id] = reason
            case let .started(id, _):
                startedIDs.insert(id)
            default:
                break
            }
        }
        defer { cancellable.cancel() }

        func assertRejectedBeforeStart(_ id: String, expectingLegacyCap: Bool) {
            // `snapshot(id:)` syncs on TransferProgressManager's internal queue,
            // deterministically fencing the barrier publish from `rejectBeforeStart`.
            _ = TransferProgressManager.shared.snapshot(id: id)
            progressLock.lock()
            let reason = rejectedReasons[id]
            let wasStarted = startedIDs.contains(id)
            progressLock.unlock()
            #expect(reason != nil)
            #expect(!wasStarted)
            if expectingLegacyCap {
                #expect(reason?.contains("256") == true)
            } else {
                #expect(reason?.contains("256") == false)
                #expect(reason == String(localized: "content.delivery.reason.send_error", defaultValue: "send error"))
            }
        }

        // Case 1 (R6-STD-01): unrouted 40 KiB directed file on an MTU-185 link
        // fits in 88 default chunks, but requires >256 chunks at MTU 185.
        do {
            let mesh = SimulatedMesh(usePlannedLinkDelivery: true)
            let sender = mesh.addNode(nickname: "sender")
            let receiver = mesh.addNode(nickname: "receiver")
            mesh.connect(0, 1)
            settleDiscovery(mesh)

            let receiverLink = mesh.linkUUID(from: 1, at: 0)
            sender.service._test_virtualCentralMTU = { uuid in
                uuid == receiverLink ? 185 : nil
            }

            let transferId = "r6-std-01-unrouted-\(UUID().uuidString)"
            let fragsBefore = countOutboundFragments(mesh, nodeIndex: 0)
            let packet = BitchatPacket(
                type: MessageType.fileTransfer.rawValue,
                senderID: sender.service.myPeerID.routingData ?? Data(),
                recipientID: receiver.service.myPeerID.routingData,
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: makeIncompressibleData(count: 40_000, seed: 0x1111),
                signature: nil,
                ttl: TransportConfig.messageTTLDefault,
                version: 1,
                route: nil
            )
            sender.service._test_broadcastPacket(packet, transferId: transferId)
            mesh.pump()
            mesh.advanceTime(by: 5)

            assertRejectedBeforeStart(transferId, expectingLegacyCap: true)
            #expect(countOutboundFragments(mesh, nodeIndex: 0) == fragsBefore)
        }

        // Case 2 (R6-SPEC-03): 1-hop routed 20 KiB directed file on an MTU-110
        // link fits in ~46 default chunks, but requires >256 chunks at MTU 110.
        do {
            let mesh = SimulatedMesh(usePlannedLinkDelivery: true)
            let sender = mesh.addNode(nickname: "sender")
            let hop = mesh.addNode(nickname: "hop")
            let dest = mesh.addNode(nickname: "dest")
            mesh.connect(0, 1)
            mesh.connect(1, 2)
            settleDiscovery(mesh)

            let hopLink = mesh.linkUUID(from: 1, at: 0)
            sender.service._test_virtualCentralMTU = { uuid in
                uuid == hopLink ? 110 : nil
            }

            let transferId = "r6-spec-03-routed-\(UUID().uuidString)"
            let fragsBefore = countOutboundFragments(mesh, nodeIndex: 0)
            let packet = BitchatPacket(
                type: MessageType.fileTransfer.rawValue,
                senderID: sender.service.myPeerID.routingData ?? Data(),
                recipientID: dest.service.myPeerID.routingData,
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: makeIncompressibleData(count: 20_000, seed: 0x2222),
                signature: nil,
                ttl: TransportConfig.messageTTLDefault,
                version: 2,
                route: [hop.service.myPeerID.routingData].compactMap { $0 }
            )
            sender.service._test_broadcastPacket(packet, transferId: transferId)
            mesh.pump()
            mesh.advanceTime(by: 5)

            assertRejectedBeforeStart(transferId, expectingLegacyCap: true)
            #expect(countOutboundFragments(mesh, nodeIndex: 0) == fragsBefore)
        }

        // Case 3 (R7-STD-02 & R8-BUG-01): 1-hop routed legacy file on a sole
        // 54-byte link leaves 0 usable payload bytes (`54 - 54 = 0`); must
        // reject visibly with an MTU reason rather than the 256-fragment reason.
        do {
            let mesh = SimulatedMesh(usePlannedLinkDelivery: true)
            let sender = mesh.addNode(nickname: "sender")
            let hop = mesh.addNode(nickname: "hop")
            let dest = mesh.addNode(nickname: "dest")
            mesh.connect(0, 1)
            mesh.connect(1, 2)
            settleDiscovery(mesh)

            let hopLink = mesh.linkUUID(from: 1, at: 0)
            sender.service._test_virtualCentralMTU = { uuid in
                uuid == hopLink ? 54 : nil
            }

            let transferId = "r7-std-02-zero-budget-\(UUID().uuidString)"
            let fragsBefore = countOutboundFragments(mesh, nodeIndex: 0)
            let packet = BitchatPacket(
                type: MessageType.fileTransfer.rawValue,
                senderID: sender.service.myPeerID.routingData ?? Data(),
                recipientID: dest.service.myPeerID.routingData,
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: makeIncompressibleData(count: 4_000, seed: 0x3333),
                signature: nil,
                ttl: TransportConfig.messageTTLDefault,
                version: 2,
                route: [hop.service.myPeerID.routingData].compactMap { $0 }
            )
            sender.service._test_broadcastPacket(packet, transferId: transferId)
            mesh.pump()
            mesh.advanceTime(by: 5)

            assertRejectedBeforeStart(transferId, expectingLegacyCap: false)
            #expect(countOutboundFragments(mesh, nodeIndex: 0) == fragsBefore)
        }

        // Case 4 (R7-SPEC-02 & R8-BUG-01): 65 KiB unrouted v1 legacy file on a
        // sole 49-byte link (`49 - 43 = 6` B/chunk -> >10,800 fragments > 10,000
        // ceiling) must reject visibly with the non-256 send failure reason.
        do {
            let mesh = SimulatedMesh(usePlannedLinkDelivery: true)
            let sender = mesh.addNode(nickname: "sender")
            let receiver = mesh.addNode(nickname: "receiver")
            mesh.connect(0, 1)
            settleDiscovery(mesh)

            let receiverLink = mesh.linkUUID(from: 1, at: 0)
            sender.service._test_virtualCentralMTU = { uuid in
                uuid == receiverLink ? 49 : nil
            }

            let transferId = "r7-spec-02-over10k-file-\(UUID().uuidString)"
            let fragsBefore = countOutboundFragments(mesh, nodeIndex: 0)
            let packet = BitchatPacket(
                type: MessageType.fileTransfer.rawValue,
                senderID: sender.service.myPeerID.routingData ?? Data(),
                recipientID: receiver.service.myPeerID.routingData,
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: makeIncompressibleData(count: 65_000, seed: 0x4444),
                signature: nil,
                ttl: TransportConfig.messageTTLDefault,
                version: 1,
                route: nil
            )
            sender.service._test_broadcastPacket(packet, transferId: transferId)
            mesh.pump()
            mesh.advanceTime(by: 5)

            assertRejectedBeforeStart(transferId, expectingLegacyCap: false)
            #expect(countOutboundFragments(mesh, nodeIndex: 0) == fragsBefore)
        }

        // Case 5 (R7-SPEC-02 & R8-BUG-01 encrypted): 80 KiB routed encrypted
        // private media on a sole 60-byte 1-hop link (`60 - 54 = 6` B/chunk ->
        // >13,000 frags) must reject visibly with an MTU reason before admission.
        do {
            let mesh = SimulatedMesh(usePlannedLinkDelivery: true)
            let sender = mesh.addNode(nickname: "sender")
            let hop = mesh.addNode(nickname: "hop")
            let dest = mesh.addNode(nickname: "dest")
            mesh.connect(0, 1)
            mesh.connect(1, 2)
            settleDiscovery(mesh)

            let hopLink = mesh.linkUUID(from: 1, at: 0)
            sender.service._test_virtualCentralMTU = { uuid in
                uuid == hopLink ? 60 : nil
            }

            let transferId = "r7-spec-02-over10k-noise-\(UUID().uuidString)"
            let fragsBefore = countOutboundFragments(mesh, nodeIndex: 0)
            let packet = BitchatPacket(
                type: MessageType.noiseEncrypted.rawValue,
                senderID: sender.service.myPeerID.routingData ?? Data(),
                recipientID: dest.service.myPeerID.routingData,
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: makeIncompressibleData(count: 80_000, seed: 0x5555),
                signature: nil,
                ttl: TransportConfig.messageTTLDefault,
                version: 2,
                route: [hop.service.myPeerID.routingData].compactMap { $0 }
            )
            sender.service._test_broadcastPacket(packet, transferId: transferId)
            mesh.pump()
            mesh.advanceTime(by: 5)

            assertRejectedBeforeStart(transferId, expectingLegacyCap: false)
            #expect(countOutboundFragments(mesh, nodeIndex: 0) == fragsBefore)
        }
    }

    /// Regression for R7-SPEC-01: direct (unrouted) app-originated encrypted
    /// private media (`noiseEncrypted` with a `transferId`) must size fragments
    /// to the negotiated direct-recipient MTU (185 bytes) instead of using the
    /// default 469-byte chunk budget.
    @Test
    func appOriginatedDirectEncryptedPrivateMediaRespectsLinkMTU() {
        let mesh = SimulatedMesh(usePlannedLinkDelivery: true)
        let a = mesh.addNode(nickname: "a")
        let b = mesh.addNode(nickname: "b")
        mesh.connect(0, 1)
        settleDiscovery(mesh)

        let bLinkOnA = mesh.linkUUID(from: 1, at: 0)
        a.service._test_virtualCentralMTU = { uuid in
            uuid == bLinkOnA ? 185 : nil
        }

        let aPlannedBefore = mesh.plannedTransmissions(from: 0).count
        var state: UInt64 = 0xCAFE_BABE
        let incompressiblePayload = Data((0..<400).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: state >> 32)
        })
        let directPrivateMedia = BitchatPacket(
            type: MessageType.noiseEncrypted.rawValue,
            senderID: a.service.myPeerID.routingData ?? Data(),
            recipientID: b.service.myPeerID.routingData,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: incompressiblePayload,
            signature: nil,
            ttl: TransportConfig.messageTTLDefault,
            version: 1,
            route: nil
        )

        a.service._test_broadcastPacket(directPrivateMedia, transferId: "r7-spec-01-direct-\(UUID().uuidString)")
        mesh.pump()
        mesh.advanceTime(by: 2)
        mesh.advanceTime(by: 2)

        let aFragsToB = mesh.plannedTransmissions(from: 0)
            .dropFirst(aPlannedBefore)
            .filter { $0.to == 1 && $0.packet.type == MessageType.fragment.rawValue }
        #expect(aFragsToB.count > 1)
        #expect(aFragsToB.allSatisfy { $0.packet.recipientID == b.service.myPeerID.routingData })
        #expect(aFragsToB.allSatisfy { ($0.packet.toBinaryData(padding: false)?.count ?? Int.max) <= 185 })
    }

    /// Regression for R7-SPEC-03: when a routed `FILE_TRANSFER` arrives at an
    /// intermediate relay `C` over its 512-byte link to `route[0] == B` and
    /// `C`'s next hop `X` is unreachable, conservative flood fallback must
    /// exclude the ingress link (`B`) when sizing fragments so it respects the
    /// 110-byte onward alternate link `C -> E` instead of sizing against `B`.
    @Test
    func routedFileFallbackExcludesIngressMTUAndDeliversOverSmallAlternateLink() {
        let mesh = SimulatedMesh(usePlannedLinkDelivery: true)
        let a = mesh.addNode(nickname: "a") // 0 (origin)
        let b = mesh.addNode(nickname: "b") // 1 (route[0], 512-byte ingress link into C)
        let c = mesh.addNode(nickname: "c") // 2 (route[1], relay performing fallback)
        let x = mesh.addNode(nickname: "x") // 3 (route[2], unreachable from C)
        let e = mesh.addNode(nickname: "e") // 4 (onward alternate link from C, 110-byte MTU)
        let d = mesh.addNode(nickname: "d") // 5 (final destination)

        mesh.connect(0, 1) // A - B
        mesh.connect(1, 2) // B - C (512-byte link)
        mesh.connect(2, 3) // C - X
        mesh.connect(3, 5) // X - D
        mesh.connect(2, 4) // C - E (110-byte onward link)
        mesh.connect(4, 5) // E - D
        settleDiscovery(mesh)

        // Break C - X so C falls back to conservative flood toward E.
        mesh.silence(2, 3)
        let eLinkOnC = mesh.linkUUID(from: 4, at: 2)
        c.service._test_virtualCentralMTU = { uuid in
            uuid == eLinkOnC ? 110 : nil
        }

        let route = [
            b.service.myPeerID.routingData,
            c.service.myPeerID.routingData,
            x.service.myPeerID.routingData
        ].compactMap { $0 }
        let filePayload = BitchatFilePacket(
            fileName: "fallback.bin",
            fileSize: 160,
            mimeType: "application/octet-stream",
            content: Data(repeating: 0xEF, count: 160)
        ).encode() ?? Data(repeating: 0xEF, count: 160)
        let routedFile = a.service.signPacketForBroadcast(BitchatPacket(
            type: MessageType.fileTransfer.rawValue,
            senderID: a.service.myPeerID.routingData ?? Data(),
            recipientID: d.service.myPeerID.routingData,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: filePayload,
            signature: nil,
            ttl: TransportConfig.messageTTLDefault,
            version: 2,
            route: route
        ))

        let bLinkOnC = BLEIngressLinkID.central(mesh.linkUUID(from: 1, at: 2))
        let cPlannedBefore = mesh.plannedTransmissions(from: 2).count

        c.service._test_ingestFrame(routedFile, link: bLinkOnC)
        mesh.pump()
        mesh.advanceTime(by: 2)
        mesh.advanceTime(by: 2)

        let cFragsToE = mesh.plannedTransmissions(from: 2)
            .dropFirst(cPlannedBefore)
            .filter { $0.to == 4 && $0.packet.type == MessageType.fragment.rawValue }
        #expect(cFragsToE.count > 1)
        #expect(cFragsToE.allSatisfy { $0.packet.recipientID == d.service.myPeerID.routingData })
        #expect(cFragsToE.allSatisfy { ($0.packet.toBinaryData(padding: false)?.count ?? Int.max) <= 110 })
        _ = e
    }

    /// Regression for R7-STD-01: when a peer holds three peripheral bindings
    /// (`p1`, preferred `p2`, and live `p3`) and `p1` + `p2` physically drop
    /// before `p1` retires, retiring `p1` must inspect ALL surviving peripheral
    /// links via `isPhysicalLinkLive` and keep the peer connected via `p3`.
    @Test
    func staggeredMultiPeripheralTeardownKeepsPeerConnectedWhenThirdPeripheralRemainsLive() {
        let mesh = SimulatedMesh(usePlannedLinkDelivery: true)
        let hub = mesh.addNode(nickname: "hub")
        let peer = mesh.addNode(nickname: "peer")
        mesh.connect(0, 1)
        settleDiscovery(mesh)

        // Bind three peripheral links (`p2` last so it becomes preferred) and
        // drop the central link so only the peripheral links remain.
        let centralID = mesh.linkUUID(from: 1, at: 0)
        hub.service._test_bindPeripheral("SIM-P3-LIVE", to: peer.service.myPeerID)
        hub.service._test_bindPeripheral("SIM-P1-DEAD", to: peer.service.myPeerID)
        hub.service._test_bindPeripheral("SIM-P2-PREF-DEAD", to: peer.service.myPeerID)
        hub.service.emitLinkEvent(.centralLinkEnded(centralUUID: centralID))
        hub.service._test_fenceEngine()

        // Both p1 and preferred p2 are physically dead; p3 is still live.
        hub.service._test_isPhysicalLinkLive = { link in
            link == .peripheral("SIM-P3-LIVE")
        }

        // Retiring p1 first (while preferred still points at dead p2) must keep
        // the peer connected and retain its direct edge because p3 is live.
        hub.service.emitLinkEvent(.peripheralLinkEnded(
            peripheralID: "SIM-P1-DEAD",
            runPeerBookkeeping: true
        ))
        hub.service._test_fenceEngine()

        #expect(hub.service.isPeerConnected(peer.service.myPeerID))
        #expect(hub.service._test_topologyTracker.isFreshConfirmedNeighbor(
            hub.service.myPeerID,
            peer.service.myPeerID
        ))
    }

    /// Regression for R7-BUG-01: bulk role teardown with `retireProofsAndNotify: true`
    /// must NOT emit `.peerDisconnected` for a peer that remains connected over
    /// a live opposite-role link.
    @Test
    func bulkRoleTeardownDoesNotEmitDisconnectEventForPeerWithLiveOppositeRoleLink() async {
        final class DisconnectCapture: TransportEventDelegate, @unchecked Sendable {
            private let lock = NSLock()
            private var disconnected: [PeerID] = []
            func didReceiveTransportEvent(_ event: TransportEvent) {
                guard case let .peerDisconnected(peerID) = event else { return }
                lock.lock()
                disconnected.append(peerID)
                lock.unlock()
            }
            func events() -> [PeerID] {
                lock.lock()
                defer { lock.unlock() }
                return disconnected
            }
        }

        let mesh = SimulatedMesh(usePlannedLinkDelivery: true)
        let hub = mesh.addNode(nickname: "hub")
        let dualPeer = mesh.addNode(nickname: "dual")
        mesh.connect(0, 1)
        settleDiscovery(mesh)

        let capture = DisconnectCapture()
        hub.service.eventDelegate = capture

        let periphID = "SIM-PERIPH-DUAL"
        hub.service._test_bindPeripheral(periphID, to: dualPeer.service.myPeerID)

        hub.service.emitLinkEvent(.allPeripheralLinksEnded(
            peripheralIDs: [periphID],
            retireProofsAndNotify: true
        ))
        await hub.service._test_drainUI()

        #expect(hub.service.isPeerConnected(dualPeer.service.myPeerID))
        #expect(!capture.events().contains(dualPeer.service.myPeerID))
    }

    /// Regression for R8-SPEC-01: locally originated routed media must unicast
    /// ONLY to a healthy first hop (not flood unrelated alternates), and when
    /// the first hop's MTU cannot carry the routed train (54 B for a 1-hop
    /// route), it must fall back to a viable alternate link (110 B) instead of
    /// rejecting the transfer.
    @Test
    func routedMediaUnicastsHealthyFirstHopAndFallsBackWhenFirstHopMTUTooSmall() {
        // Case A: Healthy first hop (`B`) must NOT flood unrelated alternate (`Alt`).
        do {
            let mesh = SimulatedMesh(usePlannedLinkDelivery: true)
            let a = mesh.addNode(nickname: "a")   // 0 (origin)
            let b = mesh.addNode(nickname: "b")   // 1 (healthy first hop)
            let alt = mesh.addNode(nickname: "alt") // 2 (unrelated alternate neighbor)
            let d = mesh.addNode(nickname: "d")   // 3 (final destination)

            mesh.connect(0, 1)
            mesh.connect(1, 3)
            mesh.connect(0, 2)
            mesh.connect(2, 3)
            settleDiscovery(mesh)

            let aPlannedBefore = mesh.plannedTransmissions(from: 0).count
            let bPlannedBefore = mesh.plannedTransmissions(from: 1).count
            var state: UInt64 = 0x1020_3040
            let payload = Data((0..<700).map { _ in
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return UInt8(truncatingIfNeeded: state >> 32)
            })
            let routedMedia = BitchatPacket(
                type: MessageType.noiseEncrypted.rawValue,
                senderID: a.service.myPeerID.routingData ?? Data(),
                recipientID: d.service.myPeerID.routingData,
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: payload,
                signature: nil,
                ttl: TransportConfig.messageTTLDefault,
                version: 2,
                route: [b.service.myPeerID.routingData].compactMap { $0 }
            )
            a.service._test_broadcastPacket(routedMedia, transferId: "r8-spec-01-healthy-\(UUID().uuidString)")
            mesh.pump()
            mesh.advanceTime(by: 2)
            mesh.advanceTime(by: 2)

            let aFrags = mesh.plannedTransmissions(from: 0)
                .dropFirst(aPlannedBefore)
                .filter { $0.packet.type == MessageType.fragment.rawValue }
            let bFragsToD = mesh.plannedTransmissions(from: 1)
                .dropFirst(bPlannedBefore)
                .filter { $0.to == 3 && $0.packet.type == MessageType.fragment.rawValue }

            #expect(aFrags.count > 1)
            #expect(aFrags.allSatisfy { $0.to == 1 }) // unicast to B only; zero flooded to Alt
            #expect(bFragsToD.count == aFrags.count)
            _ = alt
        }

        // Case B: 54-byte first hop (`B`) leaves 0 usable bytes, while `Alt`
        // has 110-byte MTU; must fall back to `Alt` and deliver to `D`.
        do {
            let mesh = SimulatedMesh(usePlannedLinkDelivery: true)
            let a = mesh.addNode(nickname: "a")   // 0
            let b = mesh.addNode(nickname: "b")   // 1 (54-byte first hop)
            let alt = mesh.addNode(nickname: "alt") // 2 (110-byte viable alternate)
            let d = mesh.addNode(nickname: "d")   // 3 (final destination)

            mesh.connect(0, 1)
            mesh.connect(1, 3)
            mesh.connect(0, 2)
            mesh.connect(2, 3)
            settleDiscovery(mesh)

            let bLinkOnA = mesh.linkUUID(from: 1, at: 0)
            let altLinkOnA = mesh.linkUUID(from: 2, at: 0)
            a.service._test_virtualCentralMTU = { uuid in
                if uuid == bLinkOnA { return 54 }
                if uuid == altLinkOnA { return 110 }
                return nil
            }

            let aPlannedBefore = mesh.plannedTransmissions(from: 0).count
            let altPlannedBefore = mesh.plannedTransmissions(from: 2).count
            var state: UInt64 = 0xCAFE_BABE_1234_5678
            let incompressiblePayload = Data((0..<200).map { _ in
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return UInt8(truncatingIfNeeded: state >> 32)
            })
            let routedFile = BitchatPacket(
                type: MessageType.fileTransfer.rawValue,
                senderID: a.service.myPeerID.routingData ?? Data(),
                recipientID: d.service.myPeerID.routingData,
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: incompressiblePayload,
                signature: nil,
                ttl: TransportConfig.messageTTLDefault,
                version: 2,
                route: [b.service.myPeerID.routingData].compactMap { $0 }
            )
            a.service._test_broadcastPacket(routedFile, transferId: "r8-spec-01-fallback-\(UUID().uuidString)")
            mesh.pump()
            mesh.advanceTime(by: 2)
            mesh.advanceTime(by: 2)

            let aFragsToAlt = mesh.plannedTransmissions(from: 0)
                .dropFirst(aPlannedBefore)
                .filter { $0.to == 2 && $0.packet.type == MessageType.fragment.rawValue }
            let altFragsToD = mesh.plannedTransmissions(from: 2)
                .dropFirst(altPlannedBefore)
                .filter { $0.to == 3 && $0.packet.type == MessageType.fragment.rawValue }

            #expect(aFragsToAlt.count > 1)
            #expect(aFragsToAlt.allSatisfy { ($0.packet.toBinaryData(padding: false)?.count ?? Int.max) <= 110 })
            #expect(altFragsToD.count == aFragsToAlt.count)
            _ = alt
        }
    }

    /// Regression for R8-SPEC-02: routed fallback must exclude BOTH the exact
    /// ingress link AND surviving sibling links of the ingress peer when sizing
    /// fragments, so a 71-byte excluded ingress sibling cannot force 1-byte
    /// chunks over a 512-byte onward alternate link; verifies end-to-end
    /// delivery to the final recipient.
    @Test
    func routedFallbackExcludesIngressSiblingMTUAndDeliversToFinalRecipient() {
        let mesh = SimulatedMesh(usePlannedLinkDelivery: true)
        let a = mesh.addNode(nickname: "a") // 0
        let b = mesh.addNode(nickname: "b") // 1 (route[0], dual-linked to C)
        let c = mesh.addNode(nickname: "c") // 2 (route[1], relay)
        let x = mesh.addNode(nickname: "x") // 3 (route[2], unreachable from C)
        let e = mesh.addNode(nickname: "e") // 4 (onward 512-byte alternate)
        let d = mesh.addNode(nickname: "d") // 5 (final destination)

        mesh.connect(0, 1)
        mesh.connectDuplicateLinks(1, 2) // B - C has primary (512 B) + excluded sibling (71 B)
        mesh.connect(2, 3)
        mesh.connect(3, 5)
        mesh.connect(2, 4)
        mesh.connect(4, 5)
        settleDiscovery(mesh)

        mesh.silence(2, 3)
        let bDupLinkOnC = mesh.duplicateLinkUUID(from: 1, at: 2)
        c.service._test_virtualCentralMTU = { uuid in
            uuid == bDupLinkOnC ? 71 : nil
        }

        let route = [
            b.service.myPeerID.routingData,
            c.service.myPeerID.routingData,
            x.service.myPeerID.routingData
        ].compactMap { $0 }
        var state: UInt64 = 0x5566_7788
        let fileBody = Data((0..<800).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: state >> 32)
        })
        let routedFile = a.service.signPacketForBroadcast(BitchatPacket(
            type: MessageType.fileTransfer.rawValue,
            senderID: a.service.myPeerID.routingData ?? Data(),
            recipientID: d.service.myPeerID.routingData,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: fileBody,
            signature: nil,
            ttl: TransportConfig.messageTTLDefault,
            version: 2,
            route: route
        ))

        let bPrimaryOnC = BLEIngressLinkID.central(mesh.linkUUID(from: 1, at: 2))
        let cPlannedBefore = mesh.plannedTransmissions(from: 2).count
        let ePlannedBefore = mesh.plannedTransmissions(from: 4).count

        c.service._test_ingestFrame(routedFile, link: bPrimaryOnC)
        mesh.pump()
        mesh.advanceTime(by: 2)
        mesh.advanceTime(by: 2)

        let cFragsToE = mesh.plannedTransmissions(from: 2)
            .dropFirst(cPlannedBefore)
            .filter { $0.to == 4 && $0.packet.type == MessageType.fragment.rawValue }
        let eFragsToD = mesh.plannedTransmissions(from: 4)
            .dropFirst(ePlannedBefore)
            .filter { $0.to == 5 && $0.packet.type == MessageType.fragment.rawValue }

        // With 71-byte excluded sibling ignored, 800 bytes fits in 2-3 fragments
        // on the 512-byte link (NOT ~900 1-byte fragments).
        #expect(cFragsToE.count >= 2 && cFragsToE.count <= 4)
        #expect(eFragsToD.count == cFragsToE.count)
        _ = e
    }

    /// Regression for R8-SPEC-03: legacy 256-fragment preflight must select a
    /// peer's viable 512-byte sibling link instead of letting an undersized
    /// 50-byte sibling link cause a false preflight rejection.
    @Test
    func legacyPreflightAcceptsMixedMTUSiblingWhenLargerSiblingFits256FragmentCap() {
        let mesh = SimulatedMesh(usePlannedLinkDelivery: true)
        let sender = mesh.addNode(nickname: "sender")
        let receiver = mesh.addNode(nickname: "receiver")
        mesh.connectDuplicateLinks(0, 1)
        settleDiscovery(mesh)

        let tinyLink = mesh.linkUUID(from: 1, at: 0)
        sender.service._test_virtualCentralMTU = { uuid in
            uuid == tinyLink ? 50 : nil
        }

        var state: UInt64 = 0x99AA_BBCC
        let payload = Data((0..<20_000).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: state >> 32)
        })
        let plannedBefore = mesh.plannedTransmissions(from: 0).count
        let packet = BitchatPacket(
            type: MessageType.fileTransfer.rawValue,
            senderID: sender.service.myPeerID.routingData ?? Data(),
            recipientID: receiver.service.myPeerID.routingData,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil,
            ttl: TransportConfig.messageTTLDefault,
            version: 1,
            route: nil
        )
        sender.service._test_broadcastPacket(packet, transferId: "r8-spec-03-sibling-\(UUID().uuidString)")
        mesh.pump()
        mesh.advanceTime(by: 5)

        let fragsToReceiver = mesh.plannedTransmissions(from: 0)
            .dropFirst(plannedBefore)
            .filter { $0.to == 1 && $0.packet.type == MessageType.fragment.rawValue }
        #expect(fragsToReceiver.count > 1 && fragsToReceiver.count <= BLEOutboundFragmentPlanner.privateMediaV1MaxFragments)
    }

    /// Regression for R8-SPEC-04: public broadcast `FILE_TRANSFER` (`recipientID
    /// == nil`) on a sole 50-byte link must size chunks to the 35-byte v1
    /// broadcast overhead (`50 - 35 = 15` B/chunk) instead of clamping up to 64
    /// bytes and emitting oversized 99-byte frames.
    @Test
    func publicMediaFitsTight50ByteLinkWithoutOversizedBroadcastFragments() {
        let mesh = SimulatedMesh(usePlannedLinkDelivery: true)
        let sender = mesh.addNode(nickname: "sender")
        let receiver = mesh.addNode(nickname: "receiver")
        mesh.connect(0, 1)
        settleDiscovery(mesh)

        let linkOnSender = mesh.linkUUID(from: 1, at: 0)
        sender.service._test_virtualCentralMTU = { uuid in
            uuid == linkOnSender ? 50 : nil
        }

        var state: UInt64 = 0x1234_5678
        let payload = Data((0..<120).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: state >> 32)
        })
        let plannedBefore = mesh.plannedTransmissions(from: 0).count
        let publicFile = sender.service.signPacketForBroadcast(BitchatPacket(
            type: MessageType.fileTransfer.rawValue,
            senderID: sender.service.myPeerID.routingData ?? Data(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil,
            ttl: TransportConfig.messageTTLDefault,
            version: 1,
            route: nil
        ))
        sender.service._test_broadcastPacket(publicFile, transferId: "r8-spec-04-public-\(UUID().uuidString)")
        mesh.pump()
        mesh.advanceTime(by: 5)

        let fragsToReceiver = mesh.plannedTransmissions(from: 0)
            .dropFirst(plannedBefore)
            .filter { $0.to == 1 && $0.packet.type == MessageType.fragment.rawValue }
        #expect(fragsToReceiver.count > 1)
        #expect(fragsToReceiver.allSatisfy { ($0.packet.toBinaryData(padding: false)?.count ?? Int.max) <= 50 })
        _ = receiver
    }

    /// Regression for R6-SPEC-02: app-originated encrypted private media
    /// (`noiseEncrypted` with a `transferId` and a source route) must size its
    /// fragments to the routed first-hop MTU (110 bytes) rather than the global
    /// 512-byte MTU so every fragment traverses `A -> B -> C` within the wire
    /// MTU limit.
    @Test
    func appOriginatedEncryptedPrivateMediaUsesRoutedLinkMTU() {
        let mesh = SimulatedMesh(usePlannedLinkDelivery: true)
        let a = mesh.addNode(nickname: "a") // 0 (origin)
        let b = mesh.addNode(nickname: "b") // 1 (first hop, 110-byte link from A)
        let c = mesh.addNode(nickname: "c") // 2 (final destination)

        mesh.connect(0, 1)
        mesh.connect(1, 2)
        settleDiscovery(mesh)

        let bLinkOnA = mesh.linkUUID(from: 1, at: 0)
        a.service._test_virtualCentralMTU = { uuid in
            uuid == bLinkOnA ? 110 : nil
        }

        let aPlannedBefore = mesh.plannedTransmissions(from: 0).count
        let bPlannedBefore = mesh.plannedTransmissions(from: 1).count

        let routedPrivateMedia = BitchatPacket(
            type: MessageType.noiseEncrypted.rawValue,
            senderID: a.service.myPeerID.routingData ?? Data(),
            recipientID: c.service.myPeerID.routingData,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: Data(repeating: 0x9E, count: 160),
            signature: nil,
            ttl: TransportConfig.messageTTLDefault,
            version: 2,
            route: [b.service.myPeerID.routingData].compactMap { $0 }
        )

        a.service._test_broadcastPacket(routedPrivateMedia, transferId: "r6-spec-02-media")
        mesh.pump()
        mesh.advanceTime(by: 2)
        mesh.advanceTime(by: 2)

        let aFragsToB = mesh.plannedTransmissions(from: 0)
            .dropFirst(aPlannedBefore)
            .filter { $0.to == 1 && $0.packet.type == MessageType.fragment.rawValue }
        let bFragsToC = mesh.plannedTransmissions(from: 1)
            .dropFirst(bPlannedBefore)
            .filter { $0.to == 2 && $0.packet.type == MessageType.fragment.rawValue }

        #expect(aFragsToB.count > 1)
        #expect(aFragsToB.allSatisfy { $0.packet.recipientID == c.service.myPeerID.routingData })
        #expect(aFragsToB.allSatisfy { ($0.packet.toBinaryData(padding: false)?.count ?? Int.max) <= 110 })
        #expect(bFragsToC.count == aFragsToB.count)
    }

    /// Regression for R6-STD-02: single-peripheral teardown (`peripheralLinkEnded`)
    /// must join surviving central bindings against physical liveness inside
    /// `directLinkState`, so when a peer's central link has already physically
    /// dropped (retirement held), retiring its peripheral link immediately
    /// marks it disconnected, removes its direct edge, and schedules a prompt
    /// topology-change announce.
    @Test
    func singlePeripheralTeardownWithStaggeredDeadCentralPrunesEdgeAndAnnounces() {
        let mesh = SimulatedMesh(usePlannedLinkDelivery: true)
        let hub = mesh.addNode(nickname: "hub")       // 0
        let leaving = mesh.addNode(nickname: "leave") // 1
        let survivor = mesh.addNode(nickname: "stay") // 2

        mesh.connect(0, 1)
        mesh.connect(0, 2)
        settleDiscovery(mesh)

        let periphID = "SIM-PERIPH-SINGLE-DROP"
        let survivorCentralID = mesh.linkUUID(from: 2, at: 0)
        hub.service._test_bindPeripheral(periphID, to: leaving.service.myPeerID)

        // Hold `leaving`'s central retirement while marking its central link
        // physically dead; `survivor` stays physically live.
        hub.service._test_isPhysicalLinkLive = { link in
            switch link {
            case .central(let uuid):
                return uuid == survivorCentralID
            case .peripheral:
                return false
            }
        }

        let announcesBefore = countOutboundAnnounces(mesh, nodeIndex: 0)
        hub.service._test_resetAnnounceThrottle()
        hub.service.emitLinkEvent(.peripheralLinkEnded(
            peripheralID: periphID,
            runPeerBookkeeping: true
        ))
        mesh.pump()
        mesh.advanceTime(by: 1.0)

        let directNeighbors = hub.service._test_topologyTracker.freshConfirmedNeighbors(
            of: hub.service.myPeerID
        )
        #expect(!directNeighbors.contains(leaving.service.myPeerID))
        #expect(!hub.service.isPeerConnected(leaving.service.myPeerID))
        #expect(countOutboundAnnounces(mesh, nodeIndex: 0) > announcesBefore)
        _ = survivor
    }

    // MARK: - Helpers

    private struct DualHopIndices {
        let p1 = 0
        let p2 = 1
        let m = 2
        let c1 = 3
        let c2 = 4
        let leaf = 5
        let y1 = 6
        let y2 = 7
    }

    /// Builds a deterministic 8-node graph where:
    /// - `MPR_1(P1) == MPR_2(P1) == {C1, C2}` (strictly excludes M regardless of peer IDs)
    /// - `M in MPR_1(P2)` AND `M in MPR_2(P2)` (M is sole cover of `leaf`)
    private func makeDualHopLifecycleMesh() -> (SimulatedMesh, DualHopIndices) {
        let mesh = SimulatedMesh(usePlannedLinkDelivery: true)
        let idx = DualHopIndices()
        _ = mesh.addNode(nickname: "p1")   // 0
        _ = mesh.addNode(nickname: "p2")   // 1
        _ = mesh.addNode(nickname: "m")    // 2
        _ = mesh.addNode(nickname: "c1")   // 3
        _ = mesh.addNode(nickname: "c2")   // 4
        _ = mesh.addNode(nickname: "leaf") // 5
        _ = mesh.addNode(nickname: "y1")   // 6
        _ = mesh.addNode(nickname: "y2")   // 7

        let edges = [
            (idx.p1, idx.m), (idx.p1, idx.c1), (idx.p1, idx.c2), (idx.p1, idx.leaf),
            (idx.p2, idx.m), (idx.p2, idx.c1), (idx.p2, idx.c2),
            (idx.m, idx.c1), (idx.m, idx.c2), (idx.m, idx.leaf),
            (idx.c1, idx.c2),
            (idx.c1, idx.y1),
            (idx.c2, idx.y2)
        ]
        for (a, b) in edges {
            mesh.connect(a, b)
        }
        settleDiscovery(mesh)
        return (mesh, idx)
    }

    private func makeSignedAnnounce(
        from service: BLEService,
        nickname: String,
        directNeighbors: [PeerID],
        timestamp: UInt64,
        ttl: UInt8
    ) -> BitchatPacket {
        let announcement = AnnouncementPacket(
            nickname: nickname,
            noisePublicKey: service.noiseStaticPublicKeyData(),
            signingPublicKey: service.noiseSigningPublicKeyData(),
            directNeighbors: directNeighbors.compactMap(\.routingData)
        )
        let packet = BitchatPacket(
            type: MessageType.announce.rawValue,
            senderID: service.myPeerID.routingData ?? Data(),
            recipientID: nil,
            timestamp: timestamp,
            payload: announcement.encode() ?? Data(),
            signature: nil,
            ttl: ttl
        )
        return service.signPacketForBroadcast(packet)
    }

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

    private func countOutboundFragments(_ mesh: SimulatedMesh, nodeIndex: Int) -> Int {
        mesh.emittedPackets(from: nodeIndex).filter {
            $0.type == MessageType.fragment.rawValue
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

    func drainedCount(
        content: String,
        on service: BLEService
    ) async -> Int {
        // Deterministically await every engine-enqueued `notifyUI` /
        // `emitTransportEvent` MainActor delivery task on `service` rather
        // than relying on a fixed number of actor yields.
        await service._test_drainUI()
        return count(content: content)
    }
}
