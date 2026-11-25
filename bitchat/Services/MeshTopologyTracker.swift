//
// MeshTopologyTracker.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation

/// Tracks observed mesh topology and computes hop-by-hop routes and
/// freshness-bounded 2-hop neighborhoods for deterministic MPR relaying.
final class MeshTopologyTracker {
    private typealias RoutingID = Data

    /// Atomic snapshot of the fresh confirmed 2-hop neighborhood around `centerPeerID`.
    ///
    /// - `centerIsFresh`: Whether `centerPeerID` itself has an unexpired announcement.
    /// - `n1`: All fresh confirmed 1-hop neighbors of `centerPeerID`.
    /// - `neighborsByN1`: Maps each `u` in `n1` to all of `u`'s fresh confirmed 1-hop neighbors.
    struct TwoHopNeighborhood: Equatable {
        let centerPeerID: PeerID
        let centerIsFresh: Bool
        let n1: Set<PeerID>
        let neighborsByN1: [PeerID: Set<PeerID>]
    }

    private let queue = DispatchQueue(label: "mesh.topology", attributes: .concurrent)
    private let hopSize = 8
    private static let maxReportedNeighbors = 10

    // Directed claims: Key claims to see Value (neighbors). Local disconnect
    // pruning removes lost links here immediately.
    private var claims: [RoutingID: Set<RoutingID>] = [:]
    // Latest wire-reported neighbor set per peer, untouched by local disconnect
    // pruning so a subsequent ANNOUNCE reflecting a lost neighbor is still
    // classified as topologyChanged = true.
    private var reportedClaims: [RoutingID: Set<RoutingID>] = [:]
    // Latest accepted ANNOUNCE packet timestamp (ms) per peer for out-of-order
    // duplicate rejection.
    private var lastAnnounceTimestamp: [RoutingID: UInt64] = [:]
    // Last local receipt time we accepted a topology update for a node.
    private var lastSeen: [RoutingID: Date] = [:]
    // Highest protocol version observed from each node's decoded packets.
    // Nodes absent from this map are assumed v1-only and are never used as
    // hops (or targets) for version-gated routes.
    private var observedVersions: [RoutingID: (version: UInt8, seenAt: Date)] = [:]

    // Maximum age for topology claims to be considered fresh for source routing.
    // Routes computed using stale topology can fail when the network has changed.
    private static let routeFreshnessThreshold: TimeInterval = 60 // 60 seconds

    func reset() {
        queue.sync(flags: .barrier) {
            self.claims.removeAll()
            self.reportedClaims.removeAll()
            self.lastAnnounceTimestamp.removeAll()
            self.lastSeen.removeAll()
            self.observedVersions.removeAll()
        }
    }

    /// Update the topology with a node's self-reported neighbor list.
    ///
    /// - Parameters:
    ///   - sourceData: 8-byte routing ID of the announcing node.
    ///   - neighbors: Direct neighbor routing IDs (capped at 10 distinct non-self entries).
    ///   - announceTimestamp: Optional wire packet timestamp (ms) for verified
    ///     ANNOUNCE updates. When provided, older or equal timestamps are ignored
    ///     and `false` is returned.
    ///   - now: Local receipt timestamp.
    /// - Returns: `true` if the update was accepted and either introduced `sourceData`
    ///   or changed its wire-reported neighbor set; `false` otherwise.
    @discardableResult
    func updateNeighbors(
        for sourceData: Data?,
        neighbors: [Data],
        announceTimestamp: UInt64? = nil,
        at now: Date = Date()
    ) -> Bool {
        guard let source = sanitize(sourceData) else { return false }

        // Preserve first-seen distinct order up to the protocol cap of 10, excluding self-loops.
        var validNeighbors = Set<RoutingID>()
        validNeighbors.reserveCapacity(min(neighbors.count, Self.maxReportedNeighbors))
        for rawNeighbor in neighbors {
            guard validNeighbors.count < Self.maxReportedNeighbors else { break }
            guard let sanitized = sanitize(rawNeighbor), sanitized != source else { continue }
            validNeighbors.insert(sanitized)
        }

        return queue.sync(flags: .barrier) {
            if let announceTimestamp {
                if let prevTs = self.lastAnnounceTimestamp[source], prevTs >= announceTimestamp {
                    return false
                }
                self.lastAnnounceTimestamp[source] = announceTimestamp
            }

            let prevReported = self.reportedClaims[source]
            let topologyChanged = prevReported == nil || prevReported != validNeighbors
            self.reportedClaims[source] = validNeighbors
            self.claims[source] = validNeighbors
            self.lastSeen[source] = now
            return topologyChanged
        }
    }

    /// Record the protocol version observed on a decoded packet from a node.
    /// Only versions above the v1 baseline are stored; the highest wins.
    func recordObservedVersion(_ version: UInt8, for peerData: Data?, at now: Date = Date()) {
        guard version > 1, let peer = sanitize(peerData) else { return }
        queue.sync(flags: .barrier) {
            let current = self.observedVersions[peer]?.version ?? 1
            self.observedVersions[peer] = (version: max(version, current), seenAt: now)
        }
    }

    /// Raw directed neighbor claims, for diagnostics (topology map, /trace).
    /// Callers treat the claims as advisory: announces cap `directNeighbors`
    /// at 10, so an edge may be claimed by only one of its endpoints.
    func adjacencySnapshot() -> [Data: Set<Data>] {
        queue.sync { claims }
    }

    /// Promptly prune a direct edge between `peerA` and `peerB` (e.g., on link
    /// disconnect) without erasing unrelated edges or the peers' last
    /// wire-reported neighbor sets.
    func removeDirectEdge(between peerA: Data?, and peerB: Data?) {
        guard let a = sanitize(peerA), let b = sanitize(peerB), a != b else { return }
        queue.sync(flags: .barrier) {
            self.claims[a]?.remove(b)
            self.claims[b]?.remove(a)
        }
    }

    func removePeer(_ data: Data?) {
        guard let peer = sanitize(data) else { return }
        queue.sync(flags: .barrier) {
            self.claims.removeValue(forKey: peer)
            self.reportedClaims.removeValue(forKey: peer)
            self.lastAnnounceTimestamp.removeValue(forKey: peer)
            self.lastSeen.removeValue(forKey: peer)
            self.observedVersions.removeValue(forKey: peer)
            for origin in self.claims.keys {
                self.claims[origin]?.remove(peer)
            }
        }
    }

    /// Prune nodes that haven't updated their topology in `age` seconds.
    func prune(olderThan age: TimeInterval, now: Date = Date()) {
        let deadline = now.addingTimeInterval(-age)
        queue.sync(flags: .barrier) {
            let stalePeers = Set(self.lastSeen.filter { $0.value < deadline }.map(\.key))
            for peer in stalePeers {
                self.claims.removeValue(forKey: peer)
                self.reportedClaims.removeValue(forKey: peer)
                self.lastAnnounceTimestamp.removeValue(forKey: peer)
                self.lastSeen.removeValue(forKey: peer)
            }
            if !stalePeers.isEmpty {
                for origin in self.claims.keys {
                    self.claims[origin]?.subtract(stalePeers)
                }
            }
            self.observedVersions = self.observedVersions.filter { $0.value.seenAt >= deadline }
        }
    }

    // MARK: - Freshness-Bounded Topology Queries (MPR & Neighbor Pruning)

    /// Returns `true` if `peerID` has an accepted topology update received within `maxAge`.
    func isFreshAnnouncement(
        for peerID: PeerID,
        maxAge: TimeInterval = TransportConfig.bleMprEdgeMaxAgeSeconds,
        now: Date = Date()
    ) -> Bool {
        guard maxAge >= 0, let peer = sanitize(peerID.routingData) else { return false }
        return queue.sync {
            isFreshLocked(peer, now: now, maxAge: maxAge)
        }
    }

    /// Returns `true` if `a` and `b` mutually confirm each other AND both peers'
    /// announcements were received locally within `maxAge`.
    func isFreshConfirmedNeighbor(
        _ a: PeerID,
        _ b: PeerID,
        maxAge: TimeInterval = TransportConfig.bleMprEdgeMaxAgeSeconds,
        now: Date = Date()
    ) -> Bool {
        guard maxAge >= 0,
              let aData = sanitize(a.routingData),
              let bData = sanitize(b.routingData),
              aData != bData else {
            return false
        }
        return queue.sync {
            isFreshConfirmedEdgeLocked(aData, bData, now: now, maxAge: maxAge)
        }
    }

    /// Returns all peers that have a fresh, mutually confirmed edge with `peerID`.
    func freshConfirmedNeighbors(
        of peerID: PeerID,
        maxAge: TimeInterval = TransportConfig.bleMprEdgeMaxAgeSeconds,
        now: Date = Date()
    ) -> Set<PeerID> {
        guard maxAge >= 0, let center = sanitize(peerID.routingData) else { return [] }
        return queue.sync {
            let neighbors = freshConfirmedNeighborsLocked(of: center, now: now, maxAge: maxAge)
            return Set(neighbors.compactMap { PeerID(routingData: $0) })
        }
    }

    /// Captures a consistent 2-hop fresh confirmed neighborhood snapshot around
    /// `centerPeerID` under a single read lock so MPR selection cannot observe
    /// torn updates.
    func freshTwoHopNeighborhood(
        around centerPeerID: PeerID,
        maxAge: TimeInterval = TransportConfig.bleMprEdgeMaxAgeSeconds,
        now: Date = Date()
    ) -> TwoHopNeighborhood {
        guard maxAge >= 0, let center = sanitize(centerPeerID.routingData) else {
            return TwoHopNeighborhood(
                centerPeerID: centerPeerID,
                centerIsFresh: false,
                n1: [],
                neighborsByN1: [:]
            )
        }

        return queue.sync {
            guard isFreshLocked(center, now: now, maxAge: maxAge) else {
                return TwoHopNeighborhood(
                    centerPeerID: centerPeerID,
                    centerIsFresh: false,
                    n1: [],
                    neighborsByN1: [:]
                )
            }

            let rawN1 = freshConfirmedNeighborsLocked(of: center, now: now, maxAge: maxAge)
            var n1 = Set<PeerID>()
            n1.reserveCapacity(rawN1.count)
            var neighborsByN1: [PeerID: Set<PeerID>] = [:]
            neighborsByN1.reserveCapacity(rawN1.count)

            for rawU in rawN1 {
                guard let u = PeerID(routingData: rawU) else { continue }
                n1.insert(u)
                let rawUNeighbors = freshConfirmedNeighborsLocked(of: rawU, now: now, maxAge: maxAge)
                neighborsByN1[u] = Set(rawUNeighbors.compactMap { PeerID(routingData: $0) })
            }

            return TwoHopNeighborhood(
                centerPeerID: centerPeerID,
                centerIsFresh: true,
                n1: n1,
                neighborsByN1: neighborsByN1
            )
        }
    }

    // MARK: - Source Route Computation

    /// BFS over confirmed, fresh edges. When `requiringVersion` is set, every
    /// node on the path except the source (i.e. all intermediate hops and the
    /// target) must have been observed speaking at least that protocol
    /// version — a v1-only hop cannot decode a v2 routed packet.
    func computeRoute(from start: Data?, to goal: Data?, maxHops: Int = 10, requiringVersion: UInt8? = nil, now: Date = Date()) -> [Data]? {
        guard let source = sanitize(start), let target = sanitize(goal) else { return nil }
        if source == target { return [] } // Direct connection, no intermediate hops

        return queue.sync {
            let freshnessDeadline = now.addingTimeInterval(-Self.routeFreshnessThreshold)
            func meetsRequiredVersion(_ peer: RoutingID) -> Bool {
                guard let requiringVersion else { return true }
                return (observedVersions[peer]?.version ?? 1) >= requiringVersion
            }

            // BFS
            var visited: Set<RoutingID> = [source]
            // Queue stores paths: [Start, Hop1, Hop2, ..., Current]
            var queuePaths: [[RoutingID]] = [[source]]

            while !queuePaths.isEmpty {
                let path = queuePaths.removeFirst()
                // Limit path length (path contains source + maxHops + target) -> maxHops intermediate
                // If maxHops = 10, max edges = 11, max nodes = 12.
                if path.count > maxHops + 1 { continue }

                guard let last = path.last else { continue }

                // Get neighbors that 'last' claims to see
                guard let neighbors = claims[last] else { continue }

                // Check if 'last' node's topology info is fresh
                guard let lastSeenTime = lastSeen[last], lastSeenTime > freshnessDeadline else {
                    continue // Skip stale nodes
                }

                for neighbor in neighbors {
                    if visited.contains(neighbor) { continue }

                    // Version gate: skip nodes not known to speak the
                    // required protocol version.
                    guard meetsRequiredVersion(neighbor) else { continue }

                    // CONFIRMED EDGE CHECK:
                    // 'last' claims 'neighbor' (checked above)
                    // Does 'neighbor' claim 'last'?
                    guard let neighborClaims = claims[neighbor],
                          neighborClaims.contains(last) else {
                        continue
                    }

                    // Check if 'neighbor' node's topology info is fresh
                    guard let neighborSeenTime = lastSeen[neighbor], neighborSeenTime > freshnessDeadline else {
                        continue // Skip edges to stale nodes
                    }

                    var nextPath = path
                    nextPath.append(neighbor)

                    if neighbor == target {
                        // Return only intermediate hops
                        // Path: [Source, I1, I2, Target] -> [I1, I2]
                        return Array(nextPath.dropFirst().dropLast())
                    }

                    visited.insert(neighbor)
                    queuePaths.append(nextPath)
                }
            }
            return nil
        }
    }

    // MARK: - Helpers

    private func isFreshLocked(_ peer: RoutingID, now: Date, maxAge: TimeInterval) -> Bool {
        guard let receivedAt = lastSeen[peer] else { return false }
        let age = now.timeIntervalSince(receivedAt)
        return age >= 0 && age <= maxAge
    }

    private func isFreshConfirmedEdgeLocked(
        _ a: RoutingID,
        _ b: RoutingID,
        now: Date,
        maxAge: TimeInterval
    ) -> Bool {
        guard a != b,
              isFreshLocked(a, now: now, maxAge: maxAge),
              isFreshLocked(b, now: now, maxAge: maxAge) else {
            return false
        }
        return claims[a]?.contains(b) == true && claims[b]?.contains(a) == true
    }

    private func freshConfirmedNeighborsLocked(
        of peer: RoutingID,
        now: Date,
        maxAge: TimeInterval
    ) -> Set<RoutingID> {
        guard isFreshLocked(peer, now: now, maxAge: maxAge),
              let declared = claims[peer],
              !declared.isEmpty else {
            return []
        }

        var confirmed = Set<RoutingID>()
        confirmed.reserveCapacity(declared.count)
        for neighbor in declared where neighbor != peer {
            if isFreshLocked(neighbor, now: now, maxAge: maxAge),
               claims[neighbor]?.contains(peer) == true {
                confirmed.insert(neighbor)
            }
        }
        return confirmed
    }

    private func sanitize(_ data: Data?) -> Data? {
        guard var value = data, !value.isEmpty else { return nil }
        if value.count > hopSize {
            value = Data(value.prefix(hopSize))
        } else if value.count < hopSize {
            value.append(Data(repeating: 0, count: hopSize - value.count))
        }
        return value
    }
}
