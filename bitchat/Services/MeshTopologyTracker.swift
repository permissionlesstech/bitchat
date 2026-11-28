import Foundation

/// Tracks observed mesh topology and computes hop-by-hop routes.
final class MeshTopologyTracker {
    /// Fixed 8-byte routing identifier packed big-endian into a UInt64 to avoid
    /// per-node `Data` allocations and byte-loop hashing during BFS routing.
    private typealias RoutingID = UInt64

    private let queue = DispatchQueue(label: "mesh.topology", attributes: .concurrent)
    private let hopSize = 8
    // Directed claims: Key claims to see Value (neighbors)
    private var claims: [RoutingID: Set<RoutingID>] = [:]
    // Last time we received an update from a node
    private var lastSeen: [RoutingID: Date] = [:]
    // Highest protocol version observed from each node's decoded packets.
    // Nodes absent from this map are assumed v1-only and are never used as
    // hops (or targets) for version-gated routes.
    private var observedVersions: [RoutingID: (version: UInt8, seenAt: Date)] = [:]

    // Maximum age for topology claims to be considered fresh for routing
    // Routes computed using stale topology can fail when the network has changed
    private static let routeFreshnessThreshold: TimeInterval = 60 // 60 seconds

    func hasRemoteNodes(excluding localData: Data?) -> Bool {
        let local = sanitize(localData)
        return queue.sync {
            if let local {
                return claims.keys.contains { $0 != local }
                    || lastSeen.keys.contains { $0 != local }
                    || observedVersions.keys.contains { $0 != local }
            }
            return !claims.isEmpty || !lastSeen.isEmpty || !observedVersions.isEmpty
        }
    }

    func reset() {
        queue.sync(flags: .barrier) {
            self.claims.removeAll()
            self.lastSeen.removeAll()
            self.observedVersions.removeAll()
        }
    }

    /// Update the topology with a node's self-reported neighbor list
    func updateNeighbors(for sourceData: Data?, neighbors: [Data], at now: Date = Date()) {
        guard let source = sanitize(sourceData) else { return }
        // Sanitize neighbors and exclude self-loops
        let validNeighbors = Set(neighbors.compactMap { sanitize($0) }).subtracting([source])

        queue.sync(flags: .barrier) {
            self.claims[source] = validNeighbors
            self.lastSeen[source] = now
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
        queue.sync {
            var snapshot: [Data: Set<Data>] = [:]
            snapshot.reserveCapacity(claims.count)
            for (node, neighbors) in claims {
                var unpacked = Set<Data>(minimumCapacity: neighbors.count)
                for neighbor in neighbors {
                    unpacked.insert(unpack(neighbor))
                }
                snapshot[unpack(node)] = unpacked
            }
            return snapshot
        }
    }

    #if DEBUG
    func removePeer(_ data: Data?) {
        guard let peer = sanitize(data) else { return }
        queue.sync(flags: .barrier) {
            self.claims.removeValue(forKey: peer)
            self.lastSeen.removeValue(forKey: peer)
            self.observedVersions.removeValue(forKey: peer)
        }
    }
    #endif

    /// Prune nodes that haven't updated their topology in `age` seconds
    func prune(olderThan age: TimeInterval, now: Date = Date()) {
        let deadline = now.addingTimeInterval(-age)
        queue.sync(flags: .barrier) {
            let stale = self.lastSeen.filter { $0.value < deadline }
            for (peer, _) in stale {
                self.claims.removeValue(forKey: peer)
                self.lastSeen.removeValue(forKey: peer)
            }
            self.observedVersions = self.observedVersions.filter { $0.value.seenAt >= deadline }
        }
    }

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

            // BFS with flat (node, depth) queue and parent map to avoid
            // copying full paths on every edge and O(n) Array.removeFirst().
            var visited: Set<RoutingID> = [source]
            var parent: [RoutingID: RoutingID] = [:]
            var queueNodes: [(node: RoutingID, depth: Int)] = [(source, 0)]
            var head = 0

            while head < queueNodes.count {
                let (last, depth) = queueNodes[head]
                head += 1

                // Limit path length (source + maxHops intermediate + target)
                // depth == 0 is source; depth == maxHops means next hop is maxHops + 1 edges (maxHops intermediates).
                if depth > maxHops { continue }

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

                    if neighbor == target {
                        // Reconstruct only intermediate hops: [I1, I2, ...]
                        var hops: [Data] = []
                        hops.reserveCapacity(depth)
                        var current = last
                        while current != source {
                            hops.append(unpack(current))
                            guard let prev = parent[current] else { break }
                            current = prev
                        }
                        hops.reverse()
                        return hops
                    }

                    visited.insert(neighbor)
                    if depth < maxHops {
                        parent[neighbor] = last
                        queueNodes.append((neighbor, depth + 1))
                    }
                }
            }
            return nil
        }
    }

    // MARK: - Helpers

    private func sanitize(_ data: Data?) -> RoutingID? {
        guard let value = data, !value.isEmpty else { return nil }
        var packed: UInt64 = 0
        let count = min(value.count, hopSize)
        value.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for i in 0..<count {
                packed |= UInt64(bytes[i]) << UInt64((hopSize - 1 - i) * 8)
            }
        }
        return packed
    }

    private func unpack(_ id: RoutingID) -> Data {
        var bigEndian = id.bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }
}
