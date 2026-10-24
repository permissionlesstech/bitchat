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
            nostrPeerID: nil,
            nickname: nil
        )

        #expect(ChatUnreadStateResolver.hasUnreadMessages(
            for: context,
            unreadPrivateMessages: [peerID],
            firstMessage: { _ in nil }
        ))
    }

    @Test
    func stableNoiseKeyUnreadReturnsTrue() {
        let peerID = PeerID(str: "ephemeral")
        let stableID = PeerID(str: "stable")
        let context = ChatUnreadPeerContext(
            peerID: peerID,
            noiseKeyPeerID: stableID,
            nostrPeerID: nil,
            nickname: nil
        )

        #expect(ChatUnreadStateResolver.hasUnreadMessages(
            for: context,
            unreadPrivateMessages: [stableID],
            firstMessage: { _ in nil }
        ))
    }

    @Test
    func nostrConversationUnreadReturnsTrue() {
        let peerID = PeerID(str: "ephemeral")
        let nostrID = PeerID(nostr_: "abcdef")
        let context = ChatUnreadPeerContext(
            peerID: peerID,
            noiseKeyPeerID: nil,
            nostrPeerID: nostrID,
            nickname: nil
        )

        #expect(ChatUnreadStateResolver.hasUnreadMessages(
            for: context,
            unreadPrivateMessages: [nostrID],
            firstMessage: { _ in nil }
        ))
    }

    @Test
    func temporaryGeoDMWithMatchingNicknameReturnsTrue() {
        let peerID = PeerID(str: "mesh-peer")
        let geoDM = PeerID(nostr_: "0123456789abcdef")
        let context = ChatUnreadPeerContext(
            peerID: peerID,
            noiseKeyPeerID: nil,
            nostrPeerID: nil,
            nickname: "Alice"
        )
        let message = BitchatMessage(
            sender: "alice",
            content: "hi",
            timestamp: Date(timeIntervalSince1970: 1),
            isRelay: false,
            originalSender: nil,
            isPrivate: true,
            recipientNickname: "me",
            senderPeerID: geoDM
        )

        #expect(ChatUnreadStateResolver.hasUnreadMessages(
            for: context,
            unreadPrivateMessages: [geoDM],
            firstMessage: { $0 == geoDM ? message : nil }
        ))
    }

    @Test
    func unmatchedUnreadStateReturnsFalse() {
        let peerID = PeerID(str: "mesh-peer")
        let geoDM = PeerID(nostr_: "0123456789abcdef")
        let context = ChatUnreadPeerContext(
            peerID: peerID,
            noiseKeyPeerID: nil,
            nostrPeerID: nil,
            nickname: "Alice"
        )
        let message = BitchatMessage(
            sender: "bob",
            content: "hi",
            timestamp: Date(timeIntervalSince1970: 1),
            isRelay: false,
            originalSender: nil,
            isPrivate: true,
            recipientNickname: "me",
            senderPeerID: geoDM
        )

        #expect(!ChatUnreadStateResolver.hasUnreadMessages(
            for: context,
            unreadPrivateMessages: [geoDM],
            firstMessage: { $0 == geoDM ? message : nil }
        ))
    }

    /// The first-message lookup feeds only the geoDM-nickname fallback, so
    /// a direct hit never builds or reads any conversation.
    @Test
    func firstMessageIsReadOnlyForTheGeoDMNicknameFallback() {
        let peerID = PeerID(str: "mesh-peer")
        let geoDM = PeerID(nostr_: "0123456789abcdef")
        let context = ChatUnreadPeerContext(
            peerID: peerID,
            noiseKeyPeerID: nil,
            nostrPeerID: nil,
            nickname: "Alice"
        )
        var lookups: [PeerID] = []

        let direct = ChatUnreadStateResolver.hasUnreadMessages(
            for: context,
            unreadPrivateMessages: [peerID, geoDM],
            firstMessage: { lookups.append($0); return nil }
        )
        #expect(direct)
        #expect(lookups.isEmpty)

        let fallback = ChatUnreadStateResolver.hasUnreadMessages(
            for: context,
            unreadPrivateMessages: [geoDM, PeerID(str: "other-peer")],
            firstMessage: { lookups.append($0); return nil }
        )
        #expect(!fallback)
        #expect(lookups == [geoDM])
    }
}
