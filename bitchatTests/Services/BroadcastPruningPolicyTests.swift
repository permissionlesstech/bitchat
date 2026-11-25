//
// BroadcastPruningPolicyTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation
import Testing
@testable import bitchat

struct BroadcastPruningPolicyTests {
    private func peer(_ byte: UInt8) -> PeerID {
        PeerID(str: String(format: "%02x00000000000000", byte))
    }

    private func makePacket(
        type: MessageType = .message,
        sender: PeerID,
        recipient: PeerID? = nil
    ) -> BitchatPacket {
        BitchatPacket(
            type: type.rawValue,
            senderID: sender.routingData ?? Data(),
            recipientID: recipient?.routingData,
            timestamp: 1_000,
            payload: Data("hello".utf8),
            signature: Data(repeating: 0xAA, count: 64),
            ttl: 6
        )
    }

    private func addConfirmedEdge(_ tracker: MeshTopologyTracker, _ a: PeerID, _ b: PeerID, at now: Date) {
        let existingA = tracker.adjacencySnapshot()[a.routingData ?? Data()] ?? []
        let existingB = tracker.adjacencySnapshot()[b.routingData ?? Data()] ?? []
        tracker.updateNeighbors(for: a.routingData, neighbors: Array(existingA) + [b.routingData!], at: now)
        tracker.updateNeighbors(for: b.routingData, neighbors: Array(existingB) + [a.routingData!], at: now)
    }

    @Test
    func alwaysSkipsIngressLinkOriginAndPreviousHop() {
        let tracker = MeshTopologyTracker()
        let now = Date(timeIntervalSince1970: 1_000)
        let origin = peer(0x01)
        let prevHop = peer(0x02)
        let local = peer(0x03)
        let packet = makePacket(type: .leave, sender: origin)

        // Exact ingress link skipped even for conservative packet with no topology.
        #expect(BroadcastPruningPolicy.shouldSkipTarget(
            packet: packet,
            localPeerID: local,
            targetPeerID: nil,
            targetLink: .central("c-in"),
            ingressLink: .central("c-in"),
            previousHopPeerID: prevHop,
            skipNeighborPruning: true,
            topology: tracker,
            now: now
        ))

        // Origin skipped even on another link.
        #expect(BroadcastPruningPolicy.shouldSkipTarget(
            packet: packet,
            localPeerID: local,
            targetPeerID: origin,
            targetLink: .peripheral("p-origin"),
            ingressLink: .central("c-in"),
            previousHopPeerID: prevHop,
            skipNeighborPruning: true,
            topology: tracker,
            now: now
        ))

        // Previous hop skipped even on an alternate dual-role link.
        #expect(BroadcastPruningPolicy.shouldSkipTarget(
            packet: packet,
            localPeerID: local,
            targetPeerID: prevHop,
            targetLink: .peripheral("p-prev"),
            ingressLink: .central("c-in"),
            previousHopPeerID: prevHop,
            skipNeighborPruning: true,
            topology: tracker,
            now: now
        ))
    }

    @Test
    func prunesFreshConfirmedNeighborsOfOriginAndPreviousHopOnly() {
        let tracker = MeshTopologyTracker()
        let now = Date(timeIntervalSince1970: 1_000)
        let origin = peer(0x01)
        let prevHop = peer(0x02)
        let local = peer(0x03)
        let originNeighbor = peer(0x04)
        let prevHopNeighbor = peer(0x05)
        let downstream = peer(0x06)
        let oneWayNeighbor = peer(0x07)

        addConfirmedEdge(tracker, origin, prevHop, at: now)
        addConfirmedEdge(tracker, origin, originNeighbor, at: now)
        addConfirmedEdge(tracker, prevHop, prevHopNeighbor, at: now)
        addConfirmedEdge(tracker, local, downstream, at: now)
        // One-way claim: prevHop claims oneWayNeighbor, but oneWayNeighbor has not confirmed.
        let prevExisting = tracker.adjacencySnapshot()[prevHop.routingData!] ?? []
        tracker.updateNeighbors(for: prevHop.routingData, neighbors: Array(prevExisting) + [oneWayNeighbor.routingData!], at: now)

        let packet = makePacket(type: .message, sender: origin)

        // Fresh confirmed neighbors of origin and previousHop are pruned.
        #expect(BroadcastPruningPolicy.shouldSkipTarget(
            packet: packet,
            localPeerID: local,
            targetPeerID: originNeighbor,
            previousHopPeerID: prevHop,
            topology: tracker,
            now: now
        ))
        #expect(BroadcastPruningPolicy.shouldSkipTarget(
            packet: packet,
            localPeerID: local,
            targetPeerID: prevHopNeighbor,
            previousHopPeerID: prevHop,
            topology: tracker,
            now: now
        ))

        // Downstream, unconfirmed one-way, and unidentified targets are NOT pruned.
        #expect(!BroadcastPruningPolicy.shouldSkipTarget(
            packet: packet,
            localPeerID: local,
            targetPeerID: downstream,
            previousHopPeerID: prevHop,
            topology: tracker,
            now: now
        ))
        #expect(!BroadcastPruningPolicy.shouldSkipTarget(
            packet: packet,
            localPeerID: local,
            targetPeerID: oneWayNeighbor,
            previousHopPeerID: prevHop,
            topology: tracker,
            now: now
        ))
        #expect(!BroadcastPruningPolicy.shouldSkipTarget(
            packet: packet,
            localPeerID: local,
            targetPeerID: nil,
            previousHopPeerID: prevHop,
            topology: tracker,
            now: now
        ))
    }

    @Test
    func unknownOrStalePreviousHopDisablesAllNeighborPruning() {
        let tracker = MeshTopologyTracker()
        let now = Date(timeIntervalSince1970: 1_000)
        let staleTime = now.addingTimeInterval(-(TransportConfig.bleMprEdgeMaxAgeSeconds + 10))
        let origin = peer(0x01)
        let prevHop = peer(0x02)
        let local = peer(0x03)
        let originNeighbor = peer(0x04)

        addConfirmedEdge(tracker, origin, originNeighbor, at: now)
        addConfirmedEdge(tracker, prevHop, originNeighbor, at: staleTime)
        // Refresh origin + originNeighbor so origin's edge is fresh while prevHop is stale.
        addConfirmedEdge(tracker, origin, originNeighbor, at: now)

        let packet = makePacket(type: .message, sender: origin)

        // Unknown previous hop disables even origin-neighbor pruning.
        #expect(!BroadcastPruningPolicy.shouldSkipTarget(
            packet: packet,
            localPeerID: local,
            targetPeerID: originNeighbor,
            previousHopPeerID: nil,
            topology: tracker,
            now: now
        ))

        // Stale previous hop disables even origin-neighbor pruning.
        #expect(!BroadcastPruningPolicy.shouldSkipTarget(
            packet: packet,
            localPeerID: local,
            targetPeerID: originNeighbor,
            previousHopPeerID: prevHop,
            topology: tracker,
            now: now
        ))
    }

    @Test
    func locallyOriginatedAndConservativePacketsNeverPruneNeighbors() {
        let tracker = MeshTopologyTracker()
        let now = Date(timeIntervalSince1970: 1_000)
        let origin = peer(0x01)
        let prevHop = peer(0x02)
        let local = peer(0x03)
        let sharedNeighbor = peer(0x04)

        addConfirmedEdge(tracker, origin, sharedNeighbor, at: now)
        addConfirmedEdge(tracker, prevHop, sharedNeighbor, at: now)
        addConfirmedEdge(tracker, local, sharedNeighbor, at: now)

        // Locally originated broadcast fans out to all direct neighbors.
        let localPacket = makePacket(type: .message, sender: local)
        #expect(!BroadcastPruningPolicy.shouldSkipTarget(
            packet: localPacket,
            localPeerID: local,
            targetPeerID: sharedNeighbor,
            previousHopPeerID: prevHop,
            topology: tracker,
            now: now
        ))

        // Conservative packet types skip neighbor pruning.
        for conservativeType: MessageType in [.leave, .noiseHandshake, .noiseEncrypted] {
            let packet = makePacket(type: conservativeType, sender: origin)
            #expect(!BroadcastPruningPolicy.shouldSkipTarget(
                packet: packet,
                localPeerID: local,
                targetPeerID: sharedNeighbor,
                previousHopPeerID: prevHop,
                topology: tracker,
                now: now
            ))
        }

        // Explicit skipNeighborPruning flag skips neighbor pruning.
        let announce = makePacket(type: .announce, sender: origin)
        #expect(!BroadcastPruningPolicy.shouldSkipTarget(
            packet: announce,
            localPeerID: local,
            targetPeerID: sharedNeighbor,
            previousHopPeerID: prevHop,
            skipNeighborPruning: true,
            topology: tracker,
            now: now
        ))
    }

    @Test
    func prunedLinksFiltersPeripheralsAndCentralsWhilePreservingUnboundLinks() {
        let tracker = MeshTopologyTracker()
        let now = Date(timeIntervalSince1970: 1_000)
        let origin = peer(0x01)
        let prevHop = peer(0x02)
        let local = peer(0x03)
        let shared = peer(0x04)
        let downstream = peer(0x05)

        addConfirmedEdge(tracker, prevHop, shared, at: now)
        addConfirmedEdge(tracker, local, downstream, at: now)

        let packet = makePacket(type: .message, sender: origin)
        let excluded = BroadcastPruningPolicy.prunedLinks(
            packet: packet,
            localPeerID: local,
            peripheralIDs: ["p-prev", "p-shared", "p-downstream", "p-unbound"],
            centralIDs: ["c-in", "c-origin", "c-unbound"],
            peripheralPeerBindings: [
                "p-prev": prevHop,
                "p-shared": shared,
                "p-downstream": downstream
            ],
            centralPeerBindings: [
                "c-in": prevHop,
                "c-origin": origin
            ],
            ingressLink: .central("c-in"),
            previousHopPeerID: prevHop,
            skipNeighborPruning: false,
            topology: tracker,
            now: now
        )

        #expect(excluded == [
            .peripheral("p-prev"),
            .peripheral("p-shared"),
            .central("c-in"),
            .central("c-origin")
        ])
    }
}
