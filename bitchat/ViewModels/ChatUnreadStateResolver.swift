import BitFoundation
import Foundation

struct ChatUnreadPeerContext {
    let peerID: PeerID
    let noiseKeyPeerID: PeerID?
    let nostrPeerID: PeerID?
}

enum ChatUnreadStateResolver {
    static func hasUnreadMessages(
        for context: ChatUnreadPeerContext,
        unreadPrivateMessages: Set<PeerID>
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

        return false

    }
}
