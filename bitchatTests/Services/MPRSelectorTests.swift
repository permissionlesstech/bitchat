//
// MPRSelectorTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation
import Testing
@testable import bitchat

struct MPRSelectorTests {
    private func peer(_ byte: UInt8) -> PeerID {
        PeerID(str: String(format: "%02x00000000000000", byte))
    }

    /// Populates bidirectional confirmed edges in `tracker` at `now`.
    private func addConfirmedGraph(
        _ tracker: MeshTopologyTracker,
        edges: [(PeerID, PeerID)],
        at now: Date
    ) {
        var adjacency: [PeerID: Set<PeerID>] = [:]
        for (a, b) in edges {
            adjacency[a, default: []].insert(b)
            adjacency[b, default: []].insert(a)
        }
        for (node, neighbors) in adjacency {
            tracker.updateNeighbors(
                for: node.routingData,
                neighbors: neighbors.compactMap(\.routingData),
                at: now
            )
        }
    }

    @Test
    func linearChainElectsEveryIntermediateNode() {
        let tracker = MeshTopologyTracker()
        let now = Date(timeIntervalSince1970: 1_000)
        let a = peer(0x01)
        let b = peer(0x02)
        let c = peer(0x03)
        let d = peer(0x04)

        addConfirmedGraph(tracker, edges: [(a, b), (b, c), (c, d)], at: now)

        #expect(MPRSelector.selectMPRs(previousHopPeerID: a, topology: tracker, now: now) == [b])
        #expect(MPRSelector.selectMPRs(previousHopPeerID: b, topology: tracker, now: now) == [c])
        #expect(MPRSelector.selectMPRs(previousHopPeerID: c, topology: tracker, now: now) == [b])
        #expect(MPRSelector.selectMPRs(previousHopPeerID: d, topology: tracker, now: now) == [c])
    }

    @Test
    func fullCliqueSelectsNoMPRs() {
        let tracker = MeshTopologyTracker()
        let now = Date(timeIntervalSince1970: 1_000)
        let nodes = (UInt8(1)...UInt8(5)).map(peer)

        var edges: [(PeerID, PeerID)] = []
        for i in 0..<nodes.count {
            for j in (i + 1)..<nodes.count {
                edges.append((nodes[i], nodes[j]))
            }
        }
        addConfirmedGraph(tracker, edges: edges, at: now)

        for p in nodes {
            #expect(MPRSelector.selectMPRs(previousHopPeerID: p, topology: tracker, now: now).isEmpty)
            for other in nodes where other != p {
                let decision = MPRSelector.evaluateRelay(
                    myPeerID: other,
                    previousHopPeerID: p,
                    originPeerID: p,
                    topology: tracker,
                    directConnectedNeighbors: Set(nodes.filter { $0 != other }),
                    now: now
                )
                #expect(!decision.shouldRelay)
                #expect(decision.reason == .suppressedNonMPR)
            }
        }
    }

    @Test
    func twoDenseClustersWithSingleBridgeAlwaysElectBridge() {
        let tracker = MeshTopologyTracker()
        let now = Date(timeIntervalSince1970: 1_000)
        // Cluster 1: p, u1, u2, bridge (full clique)
        // Cluster 2: bridge, w1, w2, w3 (full clique)
        let p = peer(0x01)
        let u1 = peer(0x02)
        let u2 = peer(0x03)
        let bridge = peer(0xFF) // lexicographically largest to verify sole-cover wins over ID
        let w1 = peer(0x10)
        let w2 = peer(0x11)
        let w3 = peer(0x12)

        let edges: [(PeerID, PeerID)] = [
            (p, u1), (p, u2), (p, bridge),
            (u1, u2), (u1, bridge), (u2, bridge),
            (bridge, w1), (bridge, w2), (bridge, w3),
            (w1, w2), (w1, w3), (w2, w3)
        ]
        addConfirmedGraph(tracker, edges: edges, at: now)

        let selected = MPRSelector.selectMPRs(previousHopPeerID: p, topology: tracker, now: now)
        #expect(selected == [bridge])

        let bridgeDecision = MPRSelector.evaluateRelay(
            myPeerID: bridge,
            previousHopPeerID: p,
            originPeerID: p,
            topology: tracker,
            directConnectedNeighbors: [p, u1, u2, w1, w2, w3],
            now: now
        )
        #expect(bridgeDecision.shouldRelay)
        #expect(bridgeDecision.reason == .selectedMPR)

        for nonBridge in [u1, u2] {
            let decision = MPRSelector.evaluateRelay(
                myPeerID: nonBridge,
                previousHopPeerID: p,
                originPeerID: p,
                topology: tracker,
                directConnectedNeighbors: Set([p, u1, u2, bridge].filter { $0 != nonBridge }),
                now: now
            )
            #expect(!decision.shouldRelay)
            #expect(decision.reason == .suppressedNonMPR)
        }
    }

    @Test
    func dualBridgeGraphSupports1CoveredAnd2CoveredSelection() {
        let tracker = MeshTopologyTracker()
        let now = Date(timeIntervalSince1970: 1_000)
        let p = peer(0x01)
        let b1 = peer(0x02)
        let b2 = peer(0x03)
        let leaf = peer(0x04)
        let w1 = peer(0x10)
        let w2 = peer(0x11)

        let edges: [(PeerID, PeerID)] = [
            (p, b1), (p, b2), (p, leaf),
            (b1, w1), (b1, w2),
            (b2, w1), (b2, w2)
        ]
        addConfirmedGraph(tracker, edges: edges, at: now)

        // k = 1: b1 and b2 tie on reach (2) and degree (3); smallest peerID (b1) wins.
        #expect(MPRSelector.selectMPRs(previousHopPeerID: p, topology: tracker, coverageK: 1, now: now) == [b1])
        // k = 2: both b1 and b2 are needed to 2-cover w1 and w2.
        #expect(MPRSelector.selectMPRs(previousHopPeerID: p, topology: tracker, coverageK: 2, now: now) == [b1, b2])
    }

    @Test
    func tieBreakingPrefersReachThenDegreeThenSmallestPeerID() {
        let p = peer(0x01)
        let uHighReach = peer(0x50)
        let uHighDegree = peer(0x40)
        let uSmallID = peer(0x10)
        let uLargeID = peer(0x20)
        let uOther = peer(0x30)
        let extraN1 = peer(0x60)
        let w1 = peer(0xA1)
        let w2 = peer(0xA2)

        // 1. Reach beats degree and smaller peerID in Step 2 greedy selection
        //    (each w has 2 covers so Step 1 sole-cover does not fire).
        let reachWinner = MPRSelector.selectMPRs(
            previousHopPeerID: p,
            n1: [uHighReach, uSmallID, uOther, extraN1],
            neighborsByN1: [
                uHighReach: [p, w1, w2],
                uSmallID: [p, uHighReach, extraN1, uOther, w1],
                uOther: [p, uSmallID, w2],
                extraN1: [p, uSmallID]
            ],
            coverageK: 1
        )
        #expect(reachWinner == [uHighReach])

        // 2. Equal reach -> higher confirmed degree beats smaller peerID.
        let degreeWinner = MPRSelector.selectMPRs(
            previousHopPeerID: p,
            n1: [uHighDegree, uSmallID, extraN1],
            neighborsByN1: [
                uHighDegree: [p, extraN1, uSmallID, w1],
                uSmallID: [p, w1],
                extraN1: [p, uHighDegree]
            ],
            coverageK: 1
        )
        #expect(degreeWinner == [uHighDegree])

        // 3. Equal reach & degree -> lexicographically smallest peerID wins.
        let idWinner = MPRSelector.selectMPRs(
            previousHopPeerID: p,
            n1: [uLargeID, uSmallID],
            neighborsByN1: [
                uLargeID: [p, w1],
                uSmallID: [p, w1]
            ],
            coverageK: 1
        )
        #expect(idWinner == [uSmallID])
    }

    @Test
    func failSafeRelaysWhenGraphStaleOrMissing() {
        let tracker = MeshTopologyTracker()
        let now = Date(timeIntervalSince1970: 1_000)
        let p = peer(0x01)
        let m = peer(0x02)

        // Missing graph for P -> relay.
        let missing = MPRSelector.evaluateRelay(
            myPeerID: m,
            previousHopPeerID: p,
            topology: tracker,
            now: now
        )
        #expect(missing.shouldRelay)
        #expect(missing.reason == .staleOrMissingGraph)

        // Stale graph for P -> relay.
        let staleTime = now.addingTimeInterval(-(TransportConfig.bleMprEdgeMaxAgeSeconds + 5))
        addConfirmedGraph(tracker, edges: [(p, m)], at: staleTime)
        let stale = MPRSelector.evaluateRelay(
            myPeerID: m,
            previousHopPeerID: p,
            topology: tracker,
            now: now
        )
        #expect(stale.shouldRelay)
        #expect(stale.reason == .staleOrMissingGraph)
    }

    @Test
    func failSafeRelaysForUnidentifiedAndUnconfirmedDirectNeighbors() {
        let tracker = MeshTopologyTracker()
        let now = Date(timeIntervalSince1970: 1_000)
        let p = peer(0x01)
        let m = peer(0x02)
        let other = peer(0x03)
        let legacyPeer = peer(0x99)

        addConfirmedGraph(tracker, edges: [(p, m), (p, other), (m, other)], at: now)

        // Unidentified direct link forces relay even in a clique.
        let unidentified = MPRSelector.evaluateRelay(
            myPeerID: m,
            previousHopPeerID: p,
            originPeerID: p,
            topology: tracker,
            directConnectedNeighbors: [p, other],
            hasUnidentifiedDirectLink: true,
            now: now
        )
        #expect(unidentified.shouldRelay)
        #expect(unidentified.reason == .unidentifiedDirectNeighbor)

        // Legacy/newly-joined neighbor connected to M but absent from N1(P) and N2(P) forces relay.
        let legacy = MPRSelector.evaluateRelay(
            myPeerID: m,
            previousHopPeerID: p,
            originPeerID: p,
            topology: tracker,
            directConnectedNeighbors: [p, other, legacyPeer],
            hasUnidentifiedDirectLink: false,
            now: now
        )
        #expect(legacy.shouldRelay)
        #expect(legacy.reason == .unconfirmedDirectNeighbor)
    }

    @Test
    func confirmedN2NeighborAlreadyCoveredBySelectedMPRDoesNotTriggerFailSafe() {
        let tracker = MeshTopologyTracker()
        let now = Date(timeIntervalSince1970: 1_000)
        // P connects to b1 (smaller ID) and m (larger ID).
        // Both b1 and m connect to w1 in N2(P).
        let p = peer(0x01)
        let b1 = peer(0x02)
        let m = peer(0x03)
        let w1 = peer(0x10)

        addConfirmedGraph(tracker, edges: [(p, b1), (p, m), (b1, w1), (m, w1)], at: now)

        // For k = 1, b1 is elected and covers w1 (coverage = 1 >= 1).
        // M sees w1 as a direct neighbor, but w1 is already 1-covered by b1 -> suppress M.
        let k1Decision = MPRSelector.evaluateRelay(
            myPeerID: m,
            previousHopPeerID: p,
            originPeerID: p,
            topology: tracker,
            directConnectedNeighbors: [p, w1],
            coverageK: 1,
            now: now
        )
        #expect(!k1Decision.shouldRelay)
        #expect(k1Decision.reason == .suppressedNonMPR)
        #expect(k1Decision.selectedMPRs == [b1])

        // For k = 2, both b1 and m are elected to 2-cover w1.
        let k2Decision = MPRSelector.evaluateRelay(
            myPeerID: m,
            previousHopPeerID: p,
            originPeerID: p,
            topology: tracker,
            directConnectedNeighbors: [p, w1],
            coverageK: 2,
            now: now
        )
        #expect(k2Decision.shouldRelay)
        #expect(k2Decision.reason == .selectedMPR)
        #expect(k2Decision.selectedMPRs == [b1, m])
    }
}
