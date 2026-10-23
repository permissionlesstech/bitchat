import Foundation
import BitFoundation

/// Resolves a stable display name for peers, adding a short suffix when collisions exist.
struct PeerDisplayNameResolver {
    /// The form two nicknames are judged to collide in. Never displayed.
    static func collisionKey(_ nickname: String) -> String {
        nickname.precomposedStringWithCompatibilityMapping.lowercased()
    }

    /// Computes display names with a `#xxxx` suffix for connected peers when nickname collisions occur.
    /// - Parameters:
    ///   - peers: Array of tuples (peerID, nickname, isConnected).
    ///   - selfNickname: The local user's current nickname, included in collision counts to suffix remotes matching it.
    /// - Returns: Map of peerID -> displayName.
    static func resolve(_ peers: [(peerID: PeerID, nickname: String, isConnected: Bool)], selfNickname: String) -> [PeerID: String] {
        // Count collisions on a FOLDED key, not the displayed name. The point
        // of the suffix is to make namesakes distinguishable, so anything that
        // renders alike has to count as a collision.
        //
        // Compatibility mapping plus case folding covers more than it looks:
        // fullwidth Ｍedic, mathematical 𝐌edic, script ℳedic and roman-numeral
        // Ⅿedic all fold to "medic", and NFKC subsumes the canonical folding
        // that Swift's String keys were already giving us for free.
        //
        // What it does NOT cover is cross-script homoglyphs — Cyrillic М and
        // Greek Ο have their own compatibility forms — which needs a UTS #39
        // confusables table. Suffixing the displayed name is unchanged; only
        // the collision key folds.
        var counts: [String: Int] = [:]
        for p in peers where p.isConnected {
            counts[Self.collisionKey(p.nickname), default: 0] += 1
        }
        counts[Self.collisionKey(selfNickname), default: 0] += 1

        var result: [PeerID: String] = [:]
        for p in peers {
            var name = p.nickname
            if p.isConnected, (counts[Self.collisionKey(p.nickname)] ?? 0) > 1 {
                name += "#" + String(p.peerID.id.prefix(4))
            }
            result[p.peerID] = name
        }
        return result
    }
}
