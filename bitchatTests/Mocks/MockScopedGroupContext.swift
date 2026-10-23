//
// MockScopedGroupContext.swift
// bitchatTests
//
// A `ChatGroupContext` for the scoped /group commands: an in-memory group
// store, a selection the commands must not act on, and a record of where
// names were looked up and which chats were closed or removed.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import BitFoundation
@testable import bitchat

@MainActor
final class MockScopedGroupContext: ChatGroupContext {
    let nickname = "me"
    let myPeerID = PeerID(str: "0e0e0e0e0e0e0e0e")
    var selectedPrivateChatPeer: PeerID?
    let groupStore = GroupStore(keychain: MockKeychain(), persistsToDisk: false)

    /// Our Noise identity: a 32-byte fingerprint and signing key, so groups
    /// we create name us as their creator.
    let myFingerprint = String(repeating: "0e", count: 32)
    let mySigningKey = Data(repeating: 0x0E, count: 32)

    func myNoiseFingerprint() -> String { myFingerprint }
    func mySigningPublicKey() -> Data { mySigningKey }
    func signWithNoiseKey(_ data: Data) -> Data? { nil }

    // Peers
    var peersByChannel: [ChannelID: [String: PeerID]] = [:]
    private(set) var lookups: [(name: String, scope: ChannelID)] = []

    func getPeerIDForNickname(_ nickname: String, in scope: ChannelID) -> PeerID? {
        lookups.append((nickname, scope))
        return peersByChannel[scope]?[nickname]
    }

    func isPeerConnected(_ peerID: PeerID) -> Bool { false }
    func peerNickname(for peerID: PeerID) -> String? { nil }
    func meshFingerprint(for peerID: PeerID) -> String? { nil }
    func cryptoIdentity(for peerID: PeerID) -> (fingerprint: String, signingKey: Data)? { nil }
    func connectedPeerID(forFingerprint fingerprint: String) -> PeerID? { nil }
    func isFingerprintBlocked(_ fingerprint: String) -> Bool { false }

    // Transport
    func sendGroupInvitePayload(_ payload: Data, to peerID: PeerID) {}
    func sendGroupKeyUpdatePayload(_ payload: Data, to peerID: PeerID) {}
    func broadcastGroupMessagePayload(_ payload: Data) {}

    // Conversation intents
    private(set) var removedPrivateChats: [PeerID] = []
    private(set) var endPrivateChatCount = 0
    private(set) var startedPrivateChats: [PeerID] = []

    @discardableResult
    func appendPrivateMessage(_ message: BitchatMessage, to peerID: PeerID) -> Bool { true }
    func markPrivateChatUnread(_ peerID: PeerID) {}
    func removePrivateChat(_ peerID: PeerID) { removedPrivateChats.append(peerID) }

    func startPrivateChat(with peerID: PeerID) {
        startedPrivateChats.append(peerID)
        selectedPrivateChatPeer = peerID
    }

    func endPrivateChat() {
        endPrivateChatCount += 1
        selectedPrivateChatPeer = nil
    }

    func addSystemMessage(_ content: String) {}
    func addLocalPrivateSystemMessage(_ content: String, to peerID: PeerID) {}
    func notifyUIChanged() {}
    func notifyPrivateMessage(from senderName: String, message: String, peerID: PeerID) {}
}
