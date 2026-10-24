import BitFoundation
import Foundation

struct ChatUnreadPeerContext {
    let peerID: PeerID
    let noiseKeyPeerID: PeerID?
    let nostrPeerID: PeerID?
    let nickname: String?
}

enum ChatUnreadStateResolver {
    /// `firstMessage` returns a direct conversation's first message; it is
    /// consulted only for the geoDM-nickname fallback, so callers pass a
    /// lookup instead of building every conversation up front.
    static func hasUnreadMessages(
        for context: ChatUnreadPeerContext,
        unreadPrivateMessages: Set<PeerID>,
        firstMessage: (PeerID) -> BitchatMessage?
    ) -> Bool {
        if unreadPrivateMessages.contains(context.peerID) {
            return true
        }

        if let noiseKeyPeerID = context.noiseKeyPeerID,
           unreadPrivateMessages.contains(noiseKeyPeerID) {
            return true
        }

        if let nostrPeerID = context.nostrPeerID,
           unreadPrivateMessages.contains(nostrPeerID) {
            return true
        }

        guard let peerNickname = context.nickname?.lowercased(), !peerNickname.isEmpty else {
            return false
        }

        return unreadPrivateMessages.contains { unreadPeerID in
            guard unreadPeerID.isGeoDM,
                  let message = firstMessage(unreadPeerID) else {
                return false
            }
            return message.sender.lowercased() == peerNickname
        }
    }
}
