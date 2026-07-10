import BitFoundation
import Foundation

struct ChatUnreadPeerContext {
    let peerID: PeerID
    let noiseKeyPeerID: PeerID?
    let nostrPeerID: PeerID?
    let nickname: String?
}

enum ChatUnreadStateResolver {
    static func hasUnreadMessages(
        for context: ChatUnreadPeerContext,
        unreadPrivateMessages: Set<PeerID>,
        privateChats: [PeerID: [BitchatMessage]]
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
                  let firstMessage = privateChats[unreadPeerID]?.first else {
                return false
            }
            return firstMessage.sender.lowercased() == peerNickname
        }
    }
}
