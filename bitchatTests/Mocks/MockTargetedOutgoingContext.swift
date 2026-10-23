//
// MockTargetedOutgoingContext.swift
// bitchatTests
//
// A `ChatOutgoingContext` that records where every send, command, line and
// identity lookup was aimed, so target tests can prove the coordinator
// never falls back to the selection.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import BitFoundation
@testable import bitchat

@MainActor
final class MockTargetedOutgoingContext: ChatOutgoingContext {
    // Identity & channel state
    var nickname = "me"
    var myPeerID = PeerID(str: "0011223344556677")
    var activeChannel: ChannelID = .mesh
    var selectedPrivateChatPeer: PeerID?
    /// Geohashes `isTeleported(geohash:)` reports as teleported.
    var teleportedGeohashes: Set<String> = []
    private(set) var teleportQueries: [String] = []

    func isTeleported(geohash: String) -> Bool {
        teleportQueries.append(geohash)
        return teleportedGeohashes.contains(geohash)
    }

    // Commands & private messages
    /// What the open DM re-resolves to; nil leaves the selection alone.
    var selectedPeerAfterUpdate: PeerID?
    /// Unordered pairs of peer IDs that are one conversation (a handoff).
    var sameConversationPairs: [Set<PeerID>] = []
    private(set) var handledCommands: [(command: String, origin: ConversationTarget)] = []
    private(set) var updatePrivateChatPeerIfNeededCount = 0
    private(set) var sentPrivateMessages: [(content: String, peerID: PeerID, scope: ChannelID)] = []

    func handleCommand(_ command: String, from origin: ConversationTarget) {
        handledCommands.append((command, origin))
    }

    func updatePrivateChatPeerIfNeeded() {
        updatePrivateChatPeerIfNeededCount += 1
        if let selectedPeerAfterUpdate {
            selectedPrivateChatPeer = selectedPeerAfterUpdate
        }
    }

    func isSameDirectConversation(_ lhs: PeerID, _ rhs: PeerID) -> Bool {
        lhs == rhs || sameConversationPairs.contains([lhs, rhs])
    }

    func sendPrivateMessage(_ content: String, to peerID: PeerID, scope: ChannelID) {
        sentPrivateMessages.append((content, peerID, scope))
    }

    // Public timeline (local echo)
    private(set) var appendedPublicMessages: [(message: BitchatMessage, conversationID: ConversationID)] = []
    private(set) var systemMessages: [(content: String, target: ConversationTarget)] = []

    func parseMentions(from content: String) -> [String] { [] }

    @discardableResult
    func appendPublicMessage(_ message: BitchatMessage, to conversationID: ConversationID) -> Bool {
        appendedPublicMessages.append((message, conversationID))
        return true
    }

    func addSystemMessage(_ content: String, to target: ConversationTarget) {
        systemMessages.append((content, target))
    }

    // Content dedup
    func normalizedContentKey(_ content: String) -> String { "key:\(content)" }
    func recordContentKey(_ key: String, timestamp: Date) {}

    // Outbound routing
    private(set) var recordedActivityKeys: [String] = []
    private(set) var sentMeshMessages: [String] = []
    private(set) var sentGeohashContexts: [ChatViewModel.GeoOutgoingContext] = []
    private(set) var bridgedMessages: [String] = []

    func recordPublicActivity(forChannelKey key: String) { recordedActivityKeys.append(key) }

    func sendMeshMessage(_ content: String, mentions: [String], messageID: String, timestamp: Date) {
        sentMeshMessages.append(content)
    }

    func sendGeohash(context: ChatViewModel.GeoOutgoingContext) {
        sentGeohashContexts.append(context)
    }

    func bridgeOutgoingPublicMessage(_ content: String, senderPeerID: PeerID, timestamp: Date) {
        bridgedMessages.append(content)
    }

    // Geohash identity
    struct IdentityUnavailable: Error {}
    var deriveNostrIdentityError: Error?
    /// Hands out an identity whose key can't sign (zero is no secp256k1
    /// key), so a geohash send fails later, in its mining task.
    var identityCannotSign = false
    private(set) var derivedIdentityGeohashes: [String] = []

    func deriveNostrIdentity(forGeohash geohash: String) throws -> NostrIdentity {
        derivedIdentityGeohashes.append(geohash)
        if let deriveNostrIdentityError { throw deriveNostrIdentityError }
        return NostrIdentity(
            privateKey: Data(repeating: identityCannotSign ? 0x00 : 0x11, count: 32),
            publicKey: Data(repeating: 0x22, count: 32),
            npub: "npub1mock",
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }
}
