//
// MPRSelector.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation

/// Pure, deterministic OLSR-style 2-hop Multipoint Relay (MPR) hub selector.
///
/// Given a previous-hop node `P`, computes `N1(P)` (fresh confirmed 1-hop
/// neighbors of `P`) and `N2(P)` (fresh confirmed 2-hop neighbors reachable
/// through `N1(P)` that are neither `P` nor in `N1(P)`), then selects a
/// deterministic subset of `N1(P)` that covers every node in `N2(P)` at least
/// `min(coverageK, availableCovers)` times.
///
/// Tie-breaking is strictly deterministic (highest uncovered 2-hop reach ->
/// highest confirmed 1-hop degree -> lexicographically smallest peerID) so
/// Android, Wear OS, and iOS neighbors with the same 2-hop graph view
/// independently agree on the same MPR set without extra wire bytes.
enum MPRSelector {
    enum RelayDecisionReason: Equatable {
        case selectedMPR
        case staleOrMissingGraph
        case unidentifiedDirectNeighbor
        case unconfirmedDirectNeighbor
        case suppressedNonMPR
    }

    struct RelayDecision: Equatable {
        let shouldRelay: Bool
        let reason: RelayDecisionReason
        let selectedMPRs: Set<PeerID>

        init(
            shouldRelay: Bool,
            reason: RelayDecisionReason,
            selectedMPRs: Set<PeerID> = []
        ) {
            self.shouldRelay = shouldRelay
            self.reason = reason
            self.selectedMPRs = selectedMPRs
        }
    }

    /// Select `k`-covered MPRs for `previousHopPeerID` using the fresh
    /// confirmed 2-hop graph in `topology`.
    static func selectMPRs(
        previousHopPeerID: PeerID,
        topology: MeshTopologyTracker,
        coverageK: Int = 1,
        maxAge: TimeInterval = TransportConfig.bleMprEdgeMaxAgeSeconds,
        now: Date = Date()
    ) -> Set<PeerID> {
        let neighborhood = topology.freshTwoHopNeighborhood(
            around: previousHopPeerID,
            maxAge: maxAge,
            now: now
        )
        return selectMPRs(neighborhood: neighborhood, coverageK: coverageK)
    }

    /// Pure selection over an explicit `MeshTopologyTracker.TwoHopNeighborhood` snapshot.
    static func selectMPRs(
        neighborhood: MeshTopologyTracker.TwoHopNeighborhood,
        coverageK: Int = 1
    ) -> Set<PeerID> {
        precondition(coverageK >= 1, "coverageK must be >= 1, was \(coverageK)")
        guard neighborhood.centerIsFresh, !neighborhood.n1.isEmpty else {
            return []
        }
        return selectMPRsFromAdjacency(
            previousHopPeerID: neighborhood.centerPeerID,
            n1: neighborhood.n1,
            neighborsByN1: neighborhood.neighborsByN1,
            coverageK: coverageK
        ).selectedMPRs
    }

    /// Pure selection over explicit 1-hop and 2-hop neighbor maps.
    static func selectMPRs(
        previousHopPeerID: PeerID,
        n1: Set<PeerID>,
        neighborsByN1: [PeerID: Set<PeerID>],
        coverageK: Int = 1
    ) -> Set<PeerID> {
        precondition(coverageK >= 1, "coverageK must be >= 1, was \(coverageK)")
        let cleanN1 = n1.filter { $0 != previousHopPeerID }
        guard !cleanN1.isEmpty else { return [] }
        return selectMPRsFromAdjacency(
            previousHopPeerID: previousHopPeerID,
            n1: cleanN1,
            neighborsByN1: neighborsByN1,
            coverageK: coverageK
        ).selectedMPRs
    }

    /// Evaluate whether `myPeerID` should relay a packet received from
    /// `previousHopPeerID` under `k`-covered MPR selection with the
    /// mixed/moving-mesh fail-safe rule.
    ///
    /// Fail-safe rule:
    /// - If the local graph does not have a fresh announcement for `previousHopPeerID`, relay.
    /// - If `myPeerID` is in `P`'s selected MPR set, relay.
    /// - Even if `myPeerID` is NOT in `P`'s selected MPR set, relay if `myPeerID` has any
    ///   unidentified direct link OR any currently connected direct neighbor (other than self,
    ///   `previousHopPeerID`, or `originPeerID`) that is neither a fresh confirmed neighbor of
    ///   `previousHopPeerID` nor already covered at least `coverageK` times by the selected MPRs
    ///   (e.g., a legacy client omitting TLV `0x04`, a newly joined peer, or a peer whose link
    ///   to `P` is stale/unconfirmed).
    static func evaluateRelay(
        myPeerID: PeerID,
        previousHopPeerID: PeerID,
        originPeerID: PeerID? = nil,
        topology: MeshTopologyTracker,
        directConnectedNeighbors: Set<PeerID> = [],
        hasUnidentifiedDirectLink: Bool = false,
        coverageK: Int = 1,
        maxAge: TimeInterval = TransportConfig.bleMprEdgeMaxAgeSeconds,
        now: Date = Date()
    ) -> RelayDecision {
        let neighborhood = topology.freshTwoHopNeighborhood(
            around: previousHopPeerID,
            maxAge: maxAge,
            now: now
        )
        return evaluateRelay(
            myPeerID: myPeerID,
            neighborhood: neighborhood,
            originPeerID: originPeerID,
            directConnectedNeighbors: directConnectedNeighbors,
            hasUnidentifiedDirectLink: hasUnidentifiedDirectLink,
            coverageK: coverageK
        )
    }

    /// Pure relay evaluation over an explicit `MeshTopologyTracker.TwoHopNeighborhood` snapshot.
    static func evaluateRelay(
        myPeerID: PeerID,
        neighborhood: MeshTopologyTracker.TwoHopNeighborhood,
        originPeerID: PeerID? = nil,
        directConnectedNeighbors: Set<PeerID> = [],
        hasUnidentifiedDirectLink: Bool = false,
        coverageK: Int = 1
    ) -> RelayDecision {
        precondition(coverageK >= 1, "coverageK must be >= 1, was \(coverageK)")

        guard neighborhood.centerIsFresh else {
            return RelayDecision(
                shouldRelay: true,
                reason: .staleOrMissingGraph
            )
        }

        let previousHopPeerID = neighborhood.centerPeerID
        let selection = selectMPRsFromAdjacency(
            previousHopPeerID: previousHopPeerID,
            n1: neighborhood.n1,
            neighborsByN1: neighborhood.neighborsByN1,
            coverageK: coverageK
        )

        if selection.selectedMPRs.contains(myPeerID) {
            return RelayDecision(
                shouldRelay: true,
                reason: .selectedMPR,
                selectedMPRs: selection.selectedMPRs
            )
        }

        if hasUnidentifiedDirectLink {
            return RelayDecision(
                shouldRelay: true,
                reason: .unidentifiedDirectNeighbor,
                selectedMPRs: selection.selectedMPRs
            )
        }

        let hasUncoveredDirectNeighbor = directConnectedNeighbors.contains { neighbor in
            neighbor != myPeerID &&
                neighbor != previousHopPeerID &&
                neighbor != originPeerID &&
                !neighborhood.n1.contains(neighbor) &&
                (selection.coverageCountByN2[neighbor] ?? 0) < coverageK
        }
        if hasUncoveredDirectNeighbor {
            return RelayDecision(
                shouldRelay: true,
                reason: .unconfirmedDirectNeighbor,
                selectedMPRs: selection.selectedMPRs
            )
        }

        return RelayDecision(
            shouldRelay: false,
            reason: .suppressedNonMPR,
            selectedMPRs: selection.selectedMPRs
        )
    }

    // MARK: - Selection Core

    private struct SelectionResult {
        let selectedMPRs: Set<PeerID>
        let coverageCountByN2: [PeerID: Int]
    }

    private static func selectMPRsFromAdjacency(
        previousHopPeerID: PeerID,
        n1: Set<PeerID>,
        neighborsByN1: [PeerID: Set<PeerID>],
        coverageK: Int
    ) -> SelectionResult {
        var strictN2ByU: [PeerID: Set<PeerID>] = [:]
        strictN2ByU.reserveCapacity(n1.count)
        var degreeByU: [PeerID: Int] = [:]
        degreeByU.reserveCapacity(n1.count)
        var coversByW: [PeerID: [PeerID]] = [:]

        // Sort N1 deterministically so iteration order is independent of set hashing.
        let sortedN1 = n1.sorted()
        for u in sortedN1 {
            let uNeighbors = neighborsByN1[u] ?? []
            degreeByU[u] = uNeighbors.count
            var strictN2 = Set<PeerID>()
            for v in uNeighbors where v != previousHopPeerID && !n1.contains(v) && v != u {
                strictN2.insert(v)
                coversByW[v, default: []].append(u)
            }
            strictN2ByU[u] = strictN2
        }

        guard !coversByW.isEmpty else {
            return SelectionResult(selectedMPRs: [], coverageCountByN2: [:])
        }

        var selectedMPRs = Set<PeerID>()
        var requiredCoverageByW: [PeerID: Int] = [:]
        requiredCoverageByW.reserveCapacity(coversByW.count)
        var coverageCountByW: [PeerID: Int] = [:]
        coverageCountByW.reserveCapacity(coversByW.count)

        // Step 1: Include any u in N1(P) that is the sole cover (or among the
        // only <= k covers) for some 2-hop node w in N2(P).
        for (w, covers) in coversByW {
            requiredCoverageByW[w] = min(coverageK, covers.count)
            coverageCountByW[w] = 0
            if covers.count <= coverageK {
                selectedMPRs.formUnion(covers)
            }
        }

        for u in selectedMPRs {
            for w in strictN2ByU[u] ?? [] {
                coverageCountByW[w, default: 0] += 1
            }
        }

        // Step 2: Greedily select the remaining u in N1(P) covering the most
        // still-uncovered nodes in N2(P), with strict tie-breaking:
        //   1. highest uncovered 2-hop reach
        //   2. highest confirmed 1-hop degree
        //   3. lexicographically smallest peerID
        var uncoveredN2 = Set<PeerID>()
        uncoveredN2.reserveCapacity(requiredCoverageByW.count)
        for (w, required) in requiredCoverageByW where (coverageCountByW[w] ?? 0) < required {
            uncoveredN2.insert(w)
        }

        var remainingCandidates = sortedN1.filter { !selectedMPRs.contains($0) }
        while !uncoveredN2.isEmpty && !remainingCandidates.isEmpty {
            var bestCandidate: PeerID?
            var bestReach = 0
            var bestDegree = -1

            for u in remainingCandidates {
                var reach = 0
                for w in strictN2ByU[u] ?? [] where uncoveredN2.contains(w) {
                    reach += 1
                }
                guard reach > 0 else { continue }

                let degree = degreeByU[u] ?? 0
                let isBetter: Bool
                if let currentBest = bestCandidate {
                    if reach != bestReach {
                        isBetter = reach > bestReach
                    } else if degree != bestDegree {
                        isBetter = degree > bestDegree
                    } else {
                        isBetter = u < currentBest
                    }
                } else {
                    isBetter = true
                }

                if isBetter {
                    bestCandidate = u
                    bestReach = reach
                    bestDegree = degree
                }
            }

            guard let chosen = bestCandidate else { break }
            selectedMPRs.insert(chosen)
            remainingCandidates.removeAll { $0 == chosen }

            for w in strictN2ByU[chosen] ?? [] {
                let updated = (coverageCountByW[w] ?? 0) + 1
                coverageCountByW[w] = updated
                if let required = requiredCoverageByW[w], updated >= required {
                    uncoveredN2.remove(w)
                }
            }
        }

        return SelectionResult(
            selectedMPRs: selectedMPRs,
            coverageCountByN2: coverageCountByW
        )
    }
}
