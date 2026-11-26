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
            let prevHop = mesh.addNode(nickname: "prev")
            let relay = mesh.addNode(nickname: "relay")
            let recipient = mesh.addNode(nickname: "dest")
            let other = mesh.addNode(nickname: "other")
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
            let prevHop = mesh.addNode(nickname: "prev")     // 0
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
        #expect(cFragsToD.count == bFragsToC.count)
        #expect(await captureD.drainedCount(content: longBody, on: d.service) == 1)
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
