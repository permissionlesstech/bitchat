import Foundation

/// Tracks observed mesh topology and computes hop-by-hop routes.
final class MeshTopologyTracker {
    private typealias RoutingID = Data

    private let queue = DispatchQueue(label: "mesh.topology", attributes: .concurrent)
    private let hopSize = 8
    // Directed claims: Key claims to see Value (neighbors)
    private var claims: [RoutingID: Set<RoutingID>] = [:]
    // Last time we received an update from a node
    private var lastSeen: [RoutingID: Date] = [:]

    // Maximum age for topology claims to be considered fresh for routing
    // Routes computed using stale topology can fail when the network has changed
    private static let routeFreshnessThreshold: TimeInterval = 60 // 60 seconds

    func reset() {
        queue.sync(flags: .barrier) {
            self.claims.removeAll()
            self.lastSeen.removeAll()
        }
    }

    /// Update the topology with a node's self-reported neighbor list
    func updateNeighbors(for sourceData: Data?, neighbors: [Data]) {
        guard let source = sanitize(sourceData) else { return }
        // Sanitize neighbors and exclude self-loops
        let validNeighbors = Set(neighbors.compactMap { sanitize($0) }).subtracting([source])
        
        queue.sync(flags: .barrier) {
            self.claims[source] = validNeighbors
            self.lastSeen[source] = Date()
        }
    }

    func removePeer(_ data: Data?) {
        guard let peer = sanitize(data) else { return }
        queue.sync(flags: .barrier) {
            self.claims.removeValue(forKey: peer)
            self.lastSeen.removeValue(forKey: peer)
        }
    }
    
    /// Prune nodes that haven't updated their topology in `age` seconds
    func prune(olderThan age: TimeInterval) {
        let deadline = Date().addingTimeInterval(-age)
        queue.sync(flags: .barrier) {
            let stale = self.lastSeen.filter { $0.value < deadline }
            for (peer, _) in stale {
                self.claims.removeValue(forKey: peer)
                self.lastSeen.removeValue(forKey: peer)
            }
        }
    }

    func computeRoute(from start: Data?, to goal: Data?, maxHops: Int = 10) -> [Data]? {
        guard let source = sanitize(start), let target = sanitize(goal) else { return nil }
        if source == target { return [] } // Direct connection, no intermediate hops

        return queue.sync {
            let now = Date()
            let freshnessDeadline = now.addingTimeInterval(-Self.routeFreshnessThreshold)

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
