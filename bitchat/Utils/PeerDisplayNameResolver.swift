import Foundation

/// Resolves a stable display name for peers, adding a short suffix when collisions exist.
struct PeerDisplayNameResolver {
    /// Computes display names with a `#xxxx` suffix for connected peers when nickname collisions occur.
    /// - Parameters:
    ///   - peers: Array of tuples (id, nickname, isConnected).
    ///   - selfNickname: The local user's current nickname, included in collision counts to suffix remotes matching it.
    /// - Returns: Map of peerID -> displayName.
    static func resolve(_ peers: [(id: String, nickname: String, isConnected: Bool)], selfNickname: String) -> [String: String] {
        // Count collisions among connected peers and include our own nickname
        var counts: [String: Int] = [:]
        for p in peers where p.isConnected {
            counts[p.nickname, default: 0] += 1
        }
        counts[selfNickname, default: 0] += 1

        var result: [String: String] = [:]
        for p in peers {
            var name = p.nickname
            if p.isConnected, (counts[p.nickname] ?? 0) > 1 {
                name += "#" + String(p.id.prefix(4))
            }
            result[p.id] = name
        }
        return result
    }
}

