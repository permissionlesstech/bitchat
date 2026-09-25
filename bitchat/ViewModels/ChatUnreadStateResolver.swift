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

    /// Peer IDs in `unreadPrivateMessages` that resolve to the same
    /// conversation badge as `hasUnreadMessages(for:)`.
    static func matchingUnreadPeerIDs(
        for context: ChatUnreadPeerContext,
        unreadPrivateMessages: Set<PeerID>,
        privateChats: [PeerID: [BitchatMessage]]
    ) -> Set<PeerID> {
        var matching = Set<PeerID>()

        if unreadPrivateMessages.contains(context.peerID) {
            matching.insert(context.peerID)
        }

        if let noiseKeyPeerID = context.noiseKeyPeerID,
           unreadPrivateMessages.contains(noiseKeyPeerID) {
            matching.insert(noiseKeyPeerID)
        }

        if let nostrPeerID = context.nostrPeerID,
           unreadPrivateMessages.contains(nostrPeerID) {
            matching.insert(nostrPeerID)
        }

        if let peerNickname = context.nickname?.lowercased(), !peerNickname.isEmpty {
            for unreadPeerID in unreadPrivateMessages where unreadPeerID.isGeoDM {
                guard let firstMessage = privateChats[unreadPeerID]?.first else { continue }
                if firstMessage.sender.lowercased() == peerNickname {
                    matching.insert(unreadPeerID)
                }
            }
        }

        return matching
    }
}
