import BitFoundation
import Foundation
import Testing
@testable import bitchat

struct ChatUnreadStateResolverTests {
    @Test
    func directUnreadPeerReturnsTrue() {
        let peerID = PeerID(str: "peer-a")
        let context = ChatUnreadPeerContext(
            peerID: peerID,
            noiseKeyPeerID: nil,
            nostrPeerID: nil
        )

        #expect(ChatUnreadStateResolver.hasUnreadMessages(
            for: context,
            unreadPrivateMessages: [peerID]
        ))
    }

    @Test
    func stableNoiseKeyUnreadReturnsTrue() {
        let peerID = PeerID(str: "ephemeral")
        let stableID = PeerID(str: "stable")
        let context = ChatUnreadPeerContext(
            peerID: peerID,
            noiseKeyPeerID: stableID,
            nostrPeerID: nil
        )

        #expect(ChatUnreadStateResolver.hasUnreadMessages(
            for: context,
            unreadPrivateMessages: [stableID]
        ))
    }

    @Test
    func nostrConversationUnreadReturnsTrue() {
        let peerID = PeerID(str: "ephemeral")
        let nostrID = PeerID(nostr_: "abcdef")
        let context = ChatUnreadPeerContext(
            peerID: peerID,
            noiseKeyPeerID: nil,
            nostrPeerID: nostrID
        )

        #expect(ChatUnreadStateResolver.hasUnreadMessages(
            for: context,
            unreadPrivateMessages: [nostrID]
        ))
    }

    @Test
    func unrelatedUnreadConversationReturnsFalse() {
        let peerID = PeerID(str: "mesh-peer")
        let geoDM = PeerID(nostr_: "0123456789abcdef")
        let context = ChatUnreadPeerContext(
            peerID: peerID,
            noiseKeyPeerID: nil,
            nostrPeerID: nil
        )

        #expect(!ChatUnreadStateResolver.hasUnreadMessages(
            for: context,
            unreadPrivateMessages: [geoDM]
        ))
    }
}
