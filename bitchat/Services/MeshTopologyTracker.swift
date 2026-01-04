import Foundation

/// Tracks observed mesh topology and computes hop-by-hop routes.
final class MeshTopologyTracker {
    private typealias RoutingID = Data

    private let queue = DispatchQueue(label: "mesh.topology", attributes: .concurrent)
    private let hopSize = 8
    private var adjacency: [RoutingID: Set<RoutingID>] = [:]

    func reset() {
        queue.sync(flags: .barrier) {
            self.adjacency.removeAll()
        }
    }

    func recordDirectLink(between a: Data?, and b: Data?) {
        guard let left = sanitize(a), let right = sanitize(b), left != right else { return }
        queue.sync(flags: .barrier) {
            var setA = self.adjacency[left] ?? []
            setA.insert(right)
            self.adjacency[left] = setA

            var setB = self.adjacency[right] ?? []
            setB.insert(left)
            self.adjacency[right] = setB
        }
    }

    func removeDirectLink(between a: Data?, and b: Data?) {
        guard let left = sanitize(a), let right = sanitize(b), left != right else { return }
        queue.sync(flags: .barrier) {
            if var setA = self.adjacency[left] {
                setA.remove(right)
                self.adjacency[left] = setA.isEmpty ? nil : setA
            }
            if var setB = self.adjacency[right] {
                setB.remove(left)
                self.adjacency[right] = setB.isEmpty ? nil : setB
            }
        }
    }

    func removePeer(_ data: Data?) {
        guard let peer = sanitize(data) else { return }
        queue.sync(flags: .barrier) {
            guard let neighbors = self.adjacency.removeValue(forKey: peer) else { return }
            for neighbor in neighbors {
                if var set = self.adjacency[neighbor] {
                    set.remove(peer)
                    self.adjacency[neighbor] = set.isEmpty ? nil : set
                }
            }
        }
    }

    func recordRoute(_ hops: [Data]) {
        let sanitized = hops.compactMap { sanitize($0) }
        guard sanitized.count >= 2 else { return }
        queue.sync(flags: .barrier) {
            for idx in 0..<(sanitized.count - 1) {
                let left = sanitized[idx]
                let right = sanitized[idx + 1]
                guard left != right else { continue }

                var setA = self.adjacency[left] ?? []
                setA.insert(right)
                self.adjacency[left] = setA

                var setB = self.adjacency[right] ?? []
                setB.insert(left)
                self.adjacency[right] = setB
            }
        }
    }

    func computeRoute(from start: Data?, to goal: Data?, maxHops: Int = 255) -> [Data]? {
        guard let source = sanitize(start), let target = sanitize(goal) else { return nil }
        if source == target { return [source] }

        let graph = queue.sync { adjacency }
        guard graph[source] != nil, graph[target] != nil else { return nil }

        var visited: Set<RoutingID> = [source]
        var queuePaths: [[RoutingID]] = [[source]]
        var index = 0

        while index < queuePaths.count {
            let path = queuePaths[index]
            index += 1
            guard path.count <= maxHops else { continue }
            guard let last = path.last, let neighbors = graph[last] else { continue }

            for neighbor in neighbors {
                if visited.contains(neighbor) { continue }
                var nextPath = path
                nextPath.append(neighbor)
                if neighbor == target { return nextPath }
                if nextPath.count <= maxHops {
                    queuePaths.append(nextPath)
                }
                visited.insert(neighbor)
            }
        }

        return nil
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
