import BitFoundation
import Foundation

/// Shared local identity and channel state read by multiple ViewModel coordinators.
@MainActor
protocol ChatIdentityContext: AnyObject {
    var nickname: String { get }
    var myPeerID: PeerID { get }
    var activeChannel: ChannelID { get }
}

/// Shared single-writer direct-conversation store intents.
@MainActor
protocol ChatDirectMessageStoreContext: AnyObject {
    func privateMessages(for peerID: PeerID) -> [BitchatMessage]
    @discardableResult
    func appendPrivateMessage(_ message: BitchatMessage, to peerID: PeerID) -> Bool
    func markPrivateChatRead(_ peerID: PeerID)
}

/// Shared geohash/Nostr identity lookup and blocking surface.
@MainActor
protocol ChatGeohashIdentityContext: AnyObject {
    var geoNicknames: [String: String] { get }
    func deriveNostrIdentity(forGeohash geohash: String) throws -> NostrIdentity
    func isNostrBlocked(pubkeyHexLowercased: String) -> Bool
}
