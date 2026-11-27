//
// Phase1FeaturesTests.swift
// bitchatTests
//
// Focused unit tests for Phase 1 everyday-utility features:
// - PrivacyModeSettings (Everyday vs Stealth)
// - EncryptedHistoryStore + DisappearingTimer
// - FriendInvite URL/QR parsing & acceptance
// - Hybrid BLE + Nostr group encoding and delivery
//

import BitFoundation
import CryptoKit
import Foundation
import XCTest
@testable import bitchat

final class PrivacyModeSettingsTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "bitchat.tests.privacyMode.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func test_defaultsToEverydayMode() {
        let defaults = makeDefaults()
        XCTAssertEqual(PrivacyModeSettings.currentMode(in: defaults), .everyday)
        XCTAssertTrue(PrivacyModeSettings.shouldPersistPrivateHistory(in: defaults))
        XCTAssertFalse(PrivacyModeSettings.isTripleTapPanicEnabled(in: defaults))
    }

    func test_stealthModeDisablesPersistenceAndArmsTripleTapPanic() {
        let defaults = makeDefaults()
        PrivacyModeSettings.setMode(.stealth, in: defaults)

        XCTAssertEqual(PrivacyModeSettings.currentMode(in: defaults), .stealth)
        XCTAssertFalse(PrivacyModeSettings.shouldPersistPrivateHistory(in: defaults))
        XCTAssertTrue(PrivacyModeSettings.isTripleTapPanicEnabled(in: defaults))
    }

    func test_resetRestoresEverydayDefault() {
        let defaults = makeDefaults()
        PrivacyModeSettings.setMode(.stealth, in: defaults)
        PrivacyModeSettings.reset(in: defaults)

        XCTAssertEqual(PrivacyModeSettings.currentMode(in: defaults), .everyday)
        XCTAssertTrue(PrivacyModeSettings.shouldPersistPrivateHistory(in: defaults))
    }
}

@MainActor
final class EncryptedHistoryStoreTests: XCTestCase {
    private func makeTempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("bitchat-history-\(UUID().uuidString)")
            .appendingPathComponent("private-chats.sealed")
    }

    func test_saveAndLoad_roundTripsPrivateConversationsOnly() {
        let keychain = MockKeychain()
        let fileURL = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let store = EncryptedHistoryStore(
            keychain: keychain,
            persistsToDisk: true,
            fileURL: fileURL,
            persistenceEnabledProvider: { true }
        )

        let conversations = ConversationStore()
        let alice = PeerID(str: "0123456789abcdef")
        let dmMessage = BitchatMessage(
            id: "msg-dm-1",
            sender: "alice",
            content: "Meet at Blue Bottle at 3pm",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "me",
            senderPeerID: alice
        )
        let publicMessage = BitchatMessage(
            id: "msg-pub-1",
            sender: "stranger",
            content: "Public mesh chatter",
            timestamp: Date(),
            isRelay: false,
            isPrivate: false
        )
        conversations.append(dmMessage, to: .directPeer(alice))
        conversations.markUnread(.directPeer(alice))
        conversations.append(publicMessage, to: .mesh)
        store.setTimer(.days7, for: alice)

        store.save(from: conversations, nostrKeyMapping: [alice: "abcd1234"])

        // File must exist and must NOT contain plaintext message
        let rawBytes = try? Data(contentsOf: fileURL)
        XCTAssertNotNil(rawBytes)
        XCTAssertFalse(String(data: rawBytes ?? Data(), encoding: .utf8)?.contains("Blue Bottle") == true)

        // Fresh store instance with the same keychain decrypts the DM & timer, excluding public mesh
        let reloaded = EncryptedHistoryStore(
            keychain: keychain,
            persistsToDisk: true,
            fileURL: fileURL,
            persistenceEnabledProvider: { true }
        )
        let snapshot = reloaded.load()
        XCTAssertEqual(snapshot?.messagesByPeerID.count, 1)
        XCTAssertEqual(snapshot?.messagesByPeerID[alice.id]?.first?.content, "Meet at Blue Bottle at 3pm")
        XCTAssertEqual(snapshot?.unreadPeerIDs, [alice.id])
        XCTAssertEqual(snapshot?.nostrKeyMapping[alice.id], "abcd1234")
        XCTAssertEqual(reloaded.timer(for: alice), .days7)
    }

    func test_disappearingTimerPrunesExpiredMessagesAndSkipsEphemeral() {
        let keychain = MockKeychain()
        let fileURL = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let now = Date()
        let alice = PeerID(str: "aaaaaaaaaaaaaaaa")
        let bob = PeerID(str: "bbbbbbbbbbbbbbbb")

        let oldMsg = BitchatMessage(
            id: "old",
            sender: "alice",
            content: "Expired yesterday",
            timestamp: now.addingTimeInterval(-30 * 60 * 60),
            isRelay: false,
            isPrivate: true,
            senderPeerID: alice
        )
        let freshMsg = BitchatMessage(
            id: "fresh",
            sender: "alice",
            content: "Still fresh",
            timestamp: now.addingTimeInterval(-2 * 60 * 60),
            isRelay: false,
            isPrivate: true,
            senderPeerID: alice
        )
        let ephemeralMsg = BitchatMessage(
            id: "eph",
            sender: "bob",
            content: "Never write to disk",
            timestamp: now,
            isRelay: false,
            isPrivate: true,
            senderPeerID: bob
        )

        let conversations = ConversationStore()
        conversations.append(oldMsg, to: .directPeer(alice))
        conversations.append(freshMsg, to: .directPeer(alice))
        conversations.append(ephemeralMsg, to: .directPeer(bob))

        let store = EncryptedHistoryStore(
            keychain: keychain,
            persistsToDisk: true,
            fileURL: fileURL,
            persistenceEnabledProvider: { true }
        )
        store.setTimer(.hours24, for: alice)
        store.setTimer(.ephemeral, for: bob)
        store.save(from: conversations, nostrKeyMapping: [:], now: now)

        let reloaded = EncryptedHistoryStore(
            keychain: keychain,
            persistsToDisk: true,
            fileURL: fileURL,
            persistenceEnabledProvider: { true }
        )
        let snapshot = reloaded.load(now: now)
        XCTAssertEqual(snapshot?.messagesByPeerID[alice.id]?.map(\.id), ["fresh"])
        XCTAssertNil(snapshot?.messagesByPeerID[bob.id])
        XCTAssertEqual(reloaded.timer(for: bob), .ephemeral)
    }

    func test_wipeRemovesFileKeyAndTimers() {
        let keychain = MockKeychain()
        let fileURL = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let store = EncryptedHistoryStore(
            keychain: keychain,
            persistsToDisk: true,
            fileURL: fileURL,
            persistenceEnabledProvider: { true }
        )
        let peer = PeerID(str: "cccccccccccccccc")
        let conversations = ConversationStore()
        conversations.append(
            BitchatMessage(id: "m1", sender: "c", content: "secret", timestamp: Date(), isRelay: false, isPrivate: true),
            to: .directPeer(peer)
        )
        store.setTimer(.hours24, for: peer)
        store.save(from: conversations, nostrKeyMapping: [:])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        store.wipe()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(store.timer(for: peer), .off)
        XCTAssertNil(store.load())
    }
}

final class FriendInviteTests: XCTestCase {
    private func sampleInvite(nickname: String = "alice") throws -> FriendInvite {
        let noiseKey = Data(repeating: 0x11, count: 32)
        let signingKey = Data(repeating: 0x22, count: 32)
        let nostrPubKey = Data(repeating: 0x33, count: 32)
        let npub = try Bech32.encode(hrp: "npub", data: nostrPubKey)
        return FriendInvite(
            nickname: nickname,
            noisePublicKey: noiseKey,
            signingPublicKey: signingKey,
            nostrNpub: npub
        )
    }

    func test_universalAndDeepLinkRoundTrip() throws {
        let invite = try sampleInvite(nickname: "alice")
        let universal = try XCTUnwrap(invite.universalURL)
        let deep = try XCTUnwrap(invite.deepLinkURL)

        XCTAssertEqual(universal.scheme, "https")
        XCTAssertEqual(universal.host, "bitchat.free")
        XCTAssertEqual(FriendInvite.parse(url: universal), invite)
        XCTAssertEqual(FriendInvite.parse(url: deep), invite)
    }

    func test_parseExtractsInviteFromFullShareMessage() throws {
        let invite = try sampleInvite(nickname: "bob")
        let parsed = FriendInvite.parse(from: invite.sharePayloadText)
        XCTAssertEqual(parsed, invite)
    }

    func test_parseRejectsMalformedKeysAndWrongHost() {
        XCTAssertNil(FriendInvite.parse(from: "https://example.com/invite?v=1&k=abc&s=def&p=npub1invalid"))
        XCTAssertNil(FriendInvite.parse(from: "https://bitchat.free/invite?v=99&k=abc&s=def&p=npub1invalid"))
        XCTAssertNil(FriendInvite.parse(from: "not a link at all"))
    }
}

@MainActor
final class HybridGroupDeliveryTests: XCTestCase {
    private final class MockHybridGroupContext: ChatGroupContext {
        var nickname = "creator"
        var myPeerID = PeerID(str: "1111111111111111")
        var selectedPrivateChatPeer: PeerID?
        let groupStore: GroupStore

        let mySigningPrivateKey = Curve25519.Signing.PrivateKey()
        let myFingerprint = Data(repeating: 0xAA, count: 32).sha256Fingerprint()

        var identitiesByPeer: [PeerID: (fingerprint: String, signingKey: Data)] = [:]
        var nicknamesByPeer: [PeerID: String] = [:]
        var connectedPeers = Set<PeerID>()
        var nostrPeerByFingerprint: [String: PeerID] = [:]

        var bleInvites: [(Data, PeerID)] = []
        var nostrInvites: [(Data, PeerID)] = []
        var bleGroupBroadcasts: [Data] = []
        var nostrGroupMessages: [(Data, PeerID)] = []
        var conversations = ConversationStore()

        init(groupStore: GroupStore) {
            self.groupStore = groupStore
        }

        func myNoiseFingerprint() -> String { myFingerprint }
        func mySigningPublicKey() -> Data { mySigningPrivateKey.publicKey.rawRepresentation }
        func signWithNoiseKey(_ data: Data) -> Data? { try? mySigningPrivateKey.signature(for: data) }
        func getPeerIDForNickname(_ nickname: String) -> PeerID? {
            nicknamesByPeer.first(where: { $0.value == nickname })?.key
        }
        func isPeerConnected(_ peerID: PeerID) -> Bool { connectedPeers.contains(peerID) }
        func peerNickname(for peerID: PeerID) -> String? { nicknamesByPeer[peerID] }
        func meshFingerprint(for peerID: PeerID) -> String? { identitiesByPeer[peerID]?.fingerprint }
        func cryptoIdentity(for peerID: PeerID) -> (fingerprint: String, signingKey: Data)? { identitiesByPeer[peerID] }
        func connectedPeerID(forFingerprint fingerprint: String) -> PeerID? {
            identitiesByPeer.first(where: { $0.value.fingerprint == fingerprint && connectedPeers.contains($0.key) })?.key
        }
        func nostrReachablePeerID(forFingerprint fingerprint: String) -> PeerID? {
            nostrPeerByFingerprint[fingerprint]
        }
        func isFingerprintBlocked(_ fingerprint: String) -> Bool { false }
        func sendGroupInvitePayload(_ payload: Data, to peerID: PeerID) { bleInvites.append((payload, peerID)) }
        func sendGroupKeyUpdatePayload(_ payload: Data, to peerID: PeerID) {}
        func broadcastGroupMessagePayload(_ payload: Data) { bleGroupBroadcasts.append(payload) }
        func sendGroupInviteViaNostr(_ payload: Data, to peerID: PeerID) { nostrInvites.append((payload, peerID)) }
        func sendGroupKeyUpdateViaNostr(_ payload: Data, to peerID: PeerID) {}
        func sendGroupMessageViaNostr(_ payload: Data, to peerID: PeerID) { nostrGroupMessages.append((payload, peerID)) }

        @discardableResult
        func appendPrivateMessage(_ message: BitchatMessage, to peerID: PeerID) -> Bool {
            conversations.append(message, to: .directPeer(peerID))
        }
        func markPrivateChatUnread(_ peerID: PeerID) { conversations.markUnread(.directPeer(peerID)) }
        func removePrivateChat(_ peerID: PeerID) { conversations.removeConversation(.directPeer(peerID)) }
        func startPrivateChat(with peerID: PeerID) { selectedPrivateChatPeer = peerID }
        func endPrivateChat() { selectedPrivateChatPeer = nil }
        func addSystemMessage(_ content: String) {}
        func addLocalPrivateSystemMessage(_ content: String, to peerID: PeerID) {}
        func notifyPrivateMessage(from senderName: String, message: String, peerID: PeerID) {}
    }

    func test_inviteAndSendGroupMessageViaNostrForRemoteFriend() {
        let keychain = MockKeychain()
        let groupStore = GroupStore(keychain: keychain, persistsToDisk: false)
        let context = MockHybridGroupContext(groupStore: groupStore)
        let coordinator = ChatGroupCoordinator(context: context)

        let remoteNoiseKey = Data(repeating: 0x55, count: 32)
        let remotePeerID = PeerID(hexData: remoteNoiseKey)
        let remoteFingerprint = remoteNoiseKey.sha256Fingerprint()
        let remoteSigningKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation

        // Remote friend is NOT connected over BLE — only reachable via Nostr
        context.identitiesByPeer[remotePeerID] = (remoteFingerprint, remoteSigningKey)
        context.nicknamesByPeer[remotePeerID] = "remote_bob"
        context.nostrPeerByFingerprint[remoteFingerprint] = remotePeerID

        let result = coordinator.createGroup(named: "Weekend Crew", initialMemberPeerIDs: [remotePeerID])
        if case .error(let msg) = result {
            XCTFail("Expected group creation to succeed, got error: \(msg)")
        }

        XCTAssertEqual(context.bleInvites.count, 0)
        XCTAssertEqual(context.nostrInvites.count, 1)
        XCTAssertEqual(context.nostrInvites.first?.1, remotePeerID)

        let group = try! XCTUnwrap(groupStore.groups.first)
        XCTAssertEqual(group.members.count, 2)

        coordinator.sendGroupMessage("See everyone at 6!", to: group.peerID)
        XCTAssertEqual(context.bleGroupBroadcasts.count, 1)
        XCTAssertEqual(context.nostrGroupMessages.count, 1)
        XCTAssertEqual(context.nostrGroupMessages.first?.1, remotePeerID)
    }

    func test_nostrEmbeddedGroupStateAndMessagePacketsDecodeCleanly() throws {
        let recipient = PeerID(hexData: Data(repeating: 0x44, count: 32))
        let sender = PeerID(str: "0102030405060708")
        let samplePayload = Data([0xDE, 0xAD, 0xBE, 0xEF])

        let encodedState = try XCTUnwrap(
            NostrEmbeddedBitChat.encodeGroupStateForNostr(
                type: .groupInvite,
                payload: samplePayload,
                recipientPeerID: recipient,
                senderPeerID: sender
            )
        )
        XCTAssertTrue(encodedState.hasPrefix("bitchat1:"))
        let stateBytes = try XCTUnwrap(Base64URLCoding.decode(String(encodedState.dropFirst("bitchat1:".count))))
        let statePacket = try XCTUnwrap(BitchatPacket.from(stateBytes))
        XCTAssertEqual(statePacket.type, MessageType.noiseEncrypted.rawValue)
        let decodedNoise = try XCTUnwrap(NoisePayload.decode(statePacket.payload))
        XCTAssertEqual(decodedNoise.type, .groupInvite)
        XCTAssertEqual(decodedNoise.data, samplePayload)

        let encodedMsg = try XCTUnwrap(
            NostrEmbeddedBitChat.encodeGroupMessageForNostr(
                payload: samplePayload,
                recipientPeerID: recipient,
                senderPeerID: sender
            )
        )
        XCTAssertTrue(encodedMsg.hasPrefix("bitchat1:"))
        let msgBytes = try XCTUnwrap(Base64URLCoding.decode(String(encodedMsg.dropFirst("bitchat1:".count))))
        let msgPacket = try XCTUnwrap(BitchatPacket.from(msgBytes))
        XCTAssertEqual(msgPacket.type, MessageType.groupMessage.rawValue)
        XCTAssertEqual(msgPacket.payload, samplePayload)
    }
}
