import Foundation

/// Resolve a typed nickname to a peer ID string.
///
/// An unsuffixed name is accepted only when it identifies exactly one peer.
/// Colliding nicknames must be disambiguated with the people-list `#xxxx`
/// suffix (first four hex characters of the peer ID).
enum NicknameLookup {
    static func uniquePeerIDString(
        for query: String,
        peers: [(id: String, nickname: String, displayName: String)]
    ) -> String? {
        let target = query.normalizedNickname
        var matches: [String] = []
        for peer in peers {
            let nick = peer.nickname.normalizedNickname
            let display = peer.displayName.normalizedNickname
            let prefix = String(peer.id.prefix(4))
            let suffixedNick = (nick + "#" + prefix).normalizedNickname
            let suffixedDisplay = (display + "#" + prefix).normalizedNickname
            if display == target || nick == target || suffixedNick == target || suffixedDisplay == target {
                if !matches.contains(peer.id) {
                    matches.append(peer.id)
                }
            }
        }
        return matches.count == 1 ? matches.first : nil
    }
}
