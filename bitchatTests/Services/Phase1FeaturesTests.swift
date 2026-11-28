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

    func test_migrateLegacyInstall_preservesImplicitTorOnAndRamOnlyHistory() {
        let defaults = makeDefaults()
        // Simulate a 1.x user who relied on the old Tor-on default (never
        // toggled userTorEnabled, so key is absent) and has 1.x install state.
        defaults.set("alice", forKey: "bitchat.nickname")
        defaults.set(true, forKey: "keychain.installLifecycleMarker.present")

        let migrated = PrivacyModeSettings.migrateLegacyInstallIfNeeded(in: defaults)

        XCTAssertTrue(migrated)
        XCTAssertTrue(NetworkActivationService.persistedTorPreference(in: defaults))
        XCTAssertEqual(PrivacyModeSettings.currentMode(in: defaults), .stealth)
        XCTAssertFalse(PrivacyModeSettings.shouldPersistPrivateHistory(in: defaults))
        XCTAssertTrue(PrivacyModeSettings.isTripleTapPanicEnabled(in: defaults))

        // Idempotent on subsequent launches; user choice to Everyday is respected.
        XCTAssertFalse(PrivacyModeSettings.migrateLegacyInstallIfNeeded(in: defaults))
        PrivacyModeSettings.setMode(.everyday, in: defaults)
        defaults.set(false, forKey: NetworkActivationService.torPreferenceKey)
        XCTAssertFalse(PrivacyModeSettings.migrateLegacyInstallIfNeeded(in: defaults))
        XCTAssertEqual(PrivacyModeSettings.currentMode(in: defaults), .everyday)
        XCTAssertFalse(NetworkActivationService.persistedTorPreference(in: defaults))
    }

    func test_migrateLegacyInstall_preservesExplicitTorOffAndRamOnlyHistory() {
        let defaults = makeDefaults()
        // Simulate a 1.x user who explicitly disabled Tor before upgrading.
        defaults.set("bob", forKey: "bitchat.nickname")
        defaults.set(false, forKey: NetworkActivationService.torPreferenceKey)

        let migrated = PrivacyModeSettings.migrateLegacyInstallIfNeeded(in: defaults)

        XCTAssertTrue(migrated)
        XCTAssertFalse(NetworkActivationService.persistedTorPreference(in: defaults))
        XCTAssertEqual(PrivacyModeSettings.currentMode(in: defaults), .everyday)
        // Still preserves 1.x RAM-only history until the user explicitly opts in.
        XCTAssertFalse(PrivacyModeSettings.shouldPersistPrivateHistory(in: defaults))
    }

    func test_migrateLegacyInstall_leavesFresh20InstallInEverydayMode() {
        let defaults = makeDefaults()

        let migrated = PrivacyModeSettings.migrateLegacyInstallIfNeeded(in: defaults)

        XCTAssertFalse(migrated)
        XCTAssertEqual(PrivacyModeSettings.currentMode(in: defaults), .everyday)
        XCTAssertFalse(NetworkActivationService.persistedTorPreference(in: defaults))
        XCTAssertTrue(PrivacyModeSettings.shouldPersistPrivateHistory(in: defaults))
        XCTAssertFalse(PrivacyModeSettings.isTripleTapPanicEnabled(in: defaults))

        // Writing 2.0 keys afterwards never retro-triggers 1.x migration.
        defaults.set("charlie", forKey: "bitchat.nickname")
        XCTAssertFalse(PrivacyModeSettings.migrateLegacyInstallIfNeeded(in: defaults))
        XCTAssertFalse(NetworkActivationService.persistedTorPreference(in: defaults))
    }

    func test_resetForPanic_preservesStealthTorPostureAndTripleTap() {
        let defaults = makeDefaults()
        PrivacyModeSettings.setMode(.stealth, in: defaults)
        defaults.set(true, forKey: NetworkActivationService.torPreferenceKey)

        PrivacyModeSettings.resetForPanic(in: defaults)

        XCTAssertEqual(PrivacyModeSettings.currentMode(in: defaults), .stealth)
        XCTAssertTrue(NetworkActivationService.persistedTorPreference(in: defaults))
        XCTAssertFalse(PrivacyModeSettings.shouldPersistPrivateHistory(in: defaults))
        XCTAssertTrue(PrivacyModeSettings.isTripleTapPanicEnabled(in: defaults))
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
        AppSupportFileStore.drainPendingWrites()

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
        AppSupportFileStore.drainPendingWrites()
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        store.wipe()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(store.timer(for: peer), .off)
        XCTAssertNil(store.load())
    }

    func test_synchronousSaveLandsOnDiskBeforeReturning() {
        let keychain = MockKeychain()
        let fileURL = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let store = EncryptedHistoryStore(
            keychain: keychain,
            persistsToDisk: true,
            fileURL: fileURL,
            persistenceEnabledProvider: { true }
        )
        let peer = PeerID(str: "dddddddddddddddd")
        let conversations = ConversationStore()
        conversations.append(
            BitchatMessage(id: "sync-1", sender: "d", content: "flush me now", timestamp: Date(), isRelay: false, isPrivate: true),
            to: .directPeer(peer)
        )

        // Do NOT call drainPendingWrites(): synchronous save must land before return.
        store.save(from: conversations, nostrKeyMapping: [:], synchronous: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func test_migrateTimerPreservesStricterRetentionAcrossAliases() {
        let store = EncryptedHistoryStore(
            keychain: MockKeychain(),
            persistsToDisk: false,
            persistenceEnabledProvider: { true }
        )
        let stableNostrID = PeerID(hexData: Data(repeating: 0xAA, count: 32))
        let shortMeshID = PeerID(str: "1122334455667788")

        // Ephemeral Nostr chat migrating to default (.off) short mesh ID stays ephemeral.
        store.setTimer(.ephemeral, for: stableNostrID)
        store.migrateTimer(from: stableNostrID, to: shortMeshID)
        XCTAssertEqual(store.timer(for: stableNostrID), .off)
        XCTAssertEqual(store.timer(for: shortMeshID), .ephemeral)

        // Reconciling two aliases keeps the stricter (shorter) retention window.
        let aliasA = PeerID(str: "aaaaaaaaaaaaaaaa")
        let aliasB = PeerID(str: "bbbbbbbbbbbbbbbb")
        store.setTimer(.days7, for: aliasA)
        store.setTimer(.hours24, for: aliasB)
        store.migrateTimer(from: aliasA, to: aliasB)
        XCTAssertEqual(store.timer(for: aliasA), .off)
        XCTAssertEqual(store.timer(for: aliasB), .hours24)
    }
}

final class FriendInviteTests: XCTestCase {
    private func sampleInvite(
        nickname: String = "alice",
        noiseByte: UInt8 = 0x11,
        signingByte: UInt8 = 0x22
    ) throws -> (invite: FriendInvite, identity: NostrIdentity) {
        let noiseKey = Data(repeating: noiseByte, count: 32)
        let signingKey = Data(repeating: signingByte, count: 32)
        let identity = try NostrIdentity.generate()
        let invite = try XCTUnwrap(
            FriendInvite.makeSigned(
                nickname: nickname,
                noisePublicKey: noiseKey,
                signingPublicKey: signingKey,
                nostrIdentity: identity
            )
        )
        return (invite, identity)
    }

    func test_universalAndDeepLinkRoundTrip() throws {
        let (invite, _) = try sampleInvite(nickname: "alice")
        let universal = try XCTUnwrap(invite.universalURL)
        let deep = try XCTUnwrap(invite.deepLinkURL)

        XCTAssertEqual(universal.scheme, "https")
        XCTAssertEqual(universal.host, "bitchat.free")
        XCTAssertEqual(deep.scheme, "bitchat")
        XCTAssertEqual(FriendInvite.parse(url: universal), invite)
        XCTAssertEqual(FriendInvite.parse(url: deep), invite)
    }

    func test_parseExtractsInviteFromFullShareMessageUsingDirectDeepLink() throws {
        let (invite, _) = try sampleInvite(nickname: "bob")
        XCTAssertTrue(invite.sharePayloadText.contains("bitchat://invite?"))
        let parsed = FriendInvite.parse(from: invite.sharePayloadText)
        XCTAssertEqual(parsed, invite)
    }

    func test_parseRejectsRecombinedVictimNpubAndUnsignedInvites() throws {
        let (attacker, _) = try sampleInvite(nickname: "mallory", noiseByte: 0xAA, signingByte: 0xBB)
        let victimIdentity = try NostrIdentity.generate()

        // Swapping `p` to a victim's npub while keeping attacker's k/s/b must be rejected.
        var components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(attacker.deepLinkURL), resolvingAgainstBaseURL: false))
        components.queryItems = components.queryItems?.map { item in
            item.name == "p" ? URLQueryItem(name: "p", value: victimIdentity.npub) : item
        }
        let forgedURL = try XCTUnwrap(components.url)
        XCTAssertNil(FriendInvite.parse(url: forgedURL))

        // Removing the binding signature `b` must also be rejected.
        components.queryItems = components.queryItems?.filter { $0.name != "b" }
        let unsignedURL = try XCTUnwrap(components.url)
        XCTAssertNil(FriendInvite.parse(url: unsignedURL))
    }

    func test_favoriteAcceptancePayloadVerifiesSenderBinding() throws {
        let (bob, bobIdentity) = try sampleInvite(nickname: "bob")
        let otherIdentity = try NostrIdentity.generate()
        let payload = bob.favoriteAcceptancePayload()

        // Legacy 1.x parser sees [FAVORITED] in parts[0] and npub in parts[1].
        let parts = payload.split(separator: ":")
        XCTAssertEqual(parts[0], "[FAVORITED]")
        XCTAssertEqual(String(parts[1]), bobIdentity.npub)

        // Valid when NIP-17 sender pubkey matches the embedded npub.
        let parsed = FriendInvite.parseFavoriteAcceptancePayload(
            payload,
            expectedSenderPubkeyHex: bobIdentity.publicKeyHex,
            nickname: "bob"
        )
        XCTAssertEqual(parsed, bob)

        // Rejected when a different NIP-17 sender relays Bob's payload.
        XCTAssertNil(
            FriendInvite.parseFavoriteAcceptancePayload(
                payload,
                expectedSenderPubkeyHex: otherIdentity.publicKeyHex,
                nickname: "bob"
            )
        )
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
        var myFingerprint = Data(repeating: 0xAA, count: 32).sha256Fingerprint()

        var identitiesByPeer: [PeerID: (fingerprint: String, signingKey: Data)] = [:]
        var nicknamesByPeer: [PeerID: String] = [:]
        var connectedPeers = Set<PeerID>()
        var nostrPeerByFingerprint: [String: PeerID] = [:]

        var bleInvites: [(Data, PeerID)] = []
        var nostrInvites: [(Data, PeerID)] = []
        var bleGroupBroadcasts: [Data] = []
        var nostrGroupMessages: [(Data, PeerID)] = []
        var nostrDirectPubkeyGroupMessages: [(Data, String)] = []
        var nostrPubkeyByFingerprint: [String: String] = [:]
        var ownNostrPubkeyHex: String?
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
        func myNostrPubkeyHex() -> String? { ownNostrPubkeyHex }
        func nostrPubkeyHex(forFingerprint fingerprint: String) -> String? {
            nostrPubkeyByFingerprint[fingerprint]
        }
        func isFingerprintBlocked(_ fingerprint: String) -> Bool { false }
        func sendGroupInvitePayload(_ payload: Data, to peerID: PeerID) { bleInvites.append((payload, peerID)) }
        func sendGroupKeyUpdatePayload(_ payload: Data, to peerID: PeerID) {}
        func broadcastGroupMessagePayload(_ payload: Data) { bleGroupBroadcasts.append(payload) }
        func sendGroupInviteViaNostr(_ payload: Data, to peerID: PeerID) { nostrInvites.append((payload, peerID)) }
        func sendGroupKeyUpdateViaNostr(_ payload: Data, to peerID: PeerID) {}
        func sendGroupMessageViaNostr(_ payload: Data, to peerID: PeerID) { nostrGroupMessages.append((payload, peerID)) }
        func sendGroupMessageViaNostr(_ payload: Data, toPubkeyHex pubkeyHex: String) {
            nostrDirectPubkeyGroupMessages.append((payload, pubkeyHex))
        }

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

    func test_groupStateDistributesMemberNostrRoutingAndDeliversWithoutDirectFavorites() throws {
        let keychain = MockKeychain()
        let groupStore = GroupStore(keychain: keychain, persistsToDisk: false)
        let context = MockHybridGroupContext(groupStore: groupStore)
        let coordinator = ChatGroupCoordinator(context: context)

        let alicePubkeyHex = Data(repeating: 0xA1, count: 32).hexEncodedString()
        let bobPubkeyHex = Data(repeating: 0xB2, count: 32).hexEncodedString()
        let creatorPubkeyHex = Data(repeating: 0xC3, count: 32).hexEncodedString()
        context.ownNostrPubkeyHex = creatorPubkeyHex

        let aliceNoiseKey = Data(repeating: 0x51, count: 32)
        let alicePeerID = PeerID(hexData: aliceNoiseKey)
        let aliceFp = aliceNoiseKey.sha256Fingerprint()
        let aliceSigningKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        context.identitiesByPeer[alicePeerID] = (aliceFp, aliceSigningKey)
        context.nicknamesByPeer[alicePeerID] = "alice"
        context.nostrPeerByFingerprint[aliceFp] = alicePeerID
        context.nostrPubkeyByFingerprint[aliceFp] = alicePubkeyHex

        let bobNoiseKey = Data(repeating: 0x52, count: 32)
        let bobPeerID = PeerID(hexData: bobNoiseKey)
        let bobFp = bobNoiseKey.sha256Fingerprint()
        let bobSigningKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        context.identitiesByPeer[bobPeerID] = (bobFp, bobSigningKey)
        context.nicknamesByPeer[bobPeerID] = "bob"
        context.nostrPeerByFingerprint[bobFp] = bobPeerID
        context.nostrPubkeyByFingerprint[bobFp] = bobPubkeyHex

        _ = coordinator.createGroup(named: "Trio", initialMemberPeerIDs: [alicePeerID, bobPeerID])
        let lastInviteBytes = try XCTUnwrap(context.nostrInvites.last?.0)
        let decodedState = try XCTUnwrap(GroupStatePayload.decode(lastInviteBytes))
        XCTAssertTrue(decodedState.verifyCreatorSignature())
        XCTAssertEqual(decodedState.members.first(where: { $0.fingerprint == aliceFp })?.nostrPubkeyHex, alicePubkeyHex)
        XCTAssertEqual(decodedState.members.first(where: { $0.fingerprint == bobFp })?.nostrPubkeyHex, bobPubkeyHex)
        XCTAssertEqual(decodedState.members.first(where: { $0.fingerprint == context.myFingerprint })?.nostrPubkeyHex, creatorPubkeyHex)

        // Simulate Alice's device: Alice has NO local favorite for Bob, only the
        // creator-distributed group state. Sending a group message must still
        // fan out to Bob and the creator via their roster nostrPubkeyHex, while
        // skipping Alice herself.
        let aliceStore = GroupStore(keychain: MockKeychain(), persistsToDisk: false)
        XCTAssertTrue(aliceStore.upsert(decodedState.asGroup, key: decodedState.key))
        let aliceContext = MockHybridGroupContext(groupStore: aliceStore)
        aliceContext.myFingerprint = aliceFp
        let aliceCoordinator = ChatGroupCoordinator(context: aliceContext)
        aliceCoordinator.sendGroupMessage("Hey Bob!", to: decodedState.asGroup.peerID)

        let deliveredHexes = Set(aliceContext.nostrDirectPubkeyGroupMessages.map(\.1))
        XCTAssertEqual(deliveredHexes, Set([bobPubkeyHex, creatorPubkeyHex]))
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

final class PlaceTitleResolutionTests: XCTestCase {
    func test_popularRegionUsesExplicitTitleInsteadOfLocalGPSRegionName() {
        let localUS = GeohashChannel(level: .region, geohash: "dr")
        let italy = GeohashChannel(level: .region, geohash: "sr")

        let title = LocationChannelsModel.resolveDisplayTitle(
            for: italy,
            availableChannels: [localUS],
            locationNames: [.region: "United States"],
            bookmarkNames: [:],
            explicitTitle: "Italy"
        )

        XCTAssertEqual(title, "Italy")
    }

    func test_remoteChannelWithoutExplicitTitleNeverLeaksLocalGPSRegionName() {
        let localUS = GeohashChannel(level: .region, geohash: "dr")
        let italy = GeohashChannel(level: .region, geohash: "sr")

        let fallbackTitle = LocationChannelsModel.resolveDisplayTitle(
            for: italy,
            availableChannels: [localUS],
            locationNames: [.region: "United States"],
            bookmarkNames: [:],
            explicitTitle: nil
        )
        XCTAssertEqual(fallbackTitle, "#sr")

        let bookmarkedTitle = LocationChannelsModel.resolveDisplayTitle(
            for: italy,
            availableChannels: [localUS],
            locationNames: [.region: "United States"],
            bookmarkNames: ["sr": "Italy"],
            explicitTitle: nil
        )
        XCTAssertEqual(bookmarkedTitle, "Italy")
    }

    func test_localChannelUsesLocalGPSLocationName() {
        let localUS = GeohashChannel(level: .region, geohash: "dr")

        let title = LocationChannelsModel.resolveDisplayTitle(
            for: localUS,
            availableChannels: [localUS],
            locationNames: [.region: "United States"],
            bookmarkNames: [:],
            explicitTitle: nil
        )
        XCTAssertEqual(title, "United States")
    }
}

final class AppRootTabPersistenceTests: XCTestCase {
    func test_persistsAndRestoresLastSelectedTab() {
        let suiteName = "AppRootTabPersistenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(AppRootTab.persisted(in: defaults), .chats)

        AppRootTab.persist(.places, in: defaults)
        XCTAssertEqual(AppRootTab.persisted(in: defaults), .places)

        AppRootTab.persist(.nearby, in: defaults)
        XCTAssertEqual(AppRootTab.persisted(in: defaults), .nearby)

        AppRootTab.persist(.settings, in: defaults)
        XCTAssertEqual(AppRootTab.persisted(in: defaults), .settings)
    }
}

final class InboxPinnedChatsTests: XCTestCase {
    func test_toggleUnpinAndClearPersistAcrossReads() {
        let suiteName = "InboxPinnedChatsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(InboxPinnedChats.isPinned("chat-a", in: defaults))
        XCTAssertTrue(InboxPinnedChats.toggle("chat-a", in: defaults))
        XCTAssertTrue(InboxPinnedChats.isPinned("chat-a", in: defaults))

        XCTAssertTrue(InboxPinnedChats.toggle("chat-b", in: defaults))
        XCTAssertEqual(InboxPinnedChats.pinnedKeys(in: defaults), Set(["chat-a", "chat-b"]))

        XCTAssertFalse(InboxPinnedChats.toggle("chat-a", in: defaults))
        XCTAssertFalse(InboxPinnedChats.isPinned("chat-a", in: defaults))

        InboxPinnedChats.unpin("chat-b", in: defaults)
        XCTAssertTrue(InboxPinnedChats.pinnedKeys(in: defaults).isEmpty)

        InboxPinnedChats.toggle("chat-c", in: defaults)
        InboxPinnedChats.clear(in: defaults)
        XCTAssertTrue(InboxPinnedChats.pinnedKeys(in: defaults).isEmpty)
    }

    func test_mutedChatsToggleUnmuteAndClear() {
        let suiteName = "InboxMutedChatsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(InboxMutedChats.isMuted("chat-a", in: defaults))
        XCTAssertTrue(InboxMutedChats.toggle("chat-a", in: defaults))
        XCTAssertTrue(InboxMutedChats.isMuted("chat-a", in: defaults))

        XCTAssertFalse(InboxMutedChats.toggle("chat-a", in: defaults))
        XCTAssertFalse(InboxMutedChats.isMuted("chat-a", in: defaults))

        InboxMutedChats.toggle("chat-b", in: defaults)
        InboxMutedChats.unmute("chat-b", in: defaults)
        XCTAssertTrue(InboxMutedChats.mutedKeys(in: defaults).isEmpty)

        InboxMutedChats.toggle("chat-c", in: defaults)
        InboxMutedChats.clear(in: defaults)
        XCTAssertTrue(InboxMutedChats.mutedKeys(in: defaults).isEmpty)
    }

    func test_onboardingStatePersistsCompletionAndSuppressesInTests() {
        let suiteName = "OnboardingStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(OnboardingState.shouldPresent(in: defaults, isRunningTests: true))
        XCTAssertTrue(OnboardingState.shouldPresent(in: defaults, isRunningTests: false))

        OnboardingState.markCompleted(in: defaults)
        XCTAssertFalse(OnboardingState.shouldPresent(in: defaults, isRunningTests: false))

        OnboardingState.reset(in: defaults)
        XCTAssertTrue(OnboardingState.shouldPresent(in: defaults, isRunningTests: false))
    }

    func test_stealthModeEnforcesHiddenNotificationPreviews() {
        let suiteName = "StealthNotificationPrivacyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        NotificationPrivacySettings.setHideMessagePreviews(false, in: defaults)
        XCTAssertFalse(NotificationPrivacySettings.hideMessagePreviews(in: defaults))

        PrivacyModeSettings.setMode(.stealth, in: defaults)
        XCTAssertTrue(NotificationPrivacySettings.hideMessagePreviews(in: defaults))

        PrivacyModeSettings.setMode(.everyday, in: defaults)
        XCTAssertFalse(NotificationPrivacySettings.hideMessagePreviews(in: defaults))
    }

    func test_quotedReplyRoundTripAndNestedSnippetStripping() {
        let original = MessageReplyTarget(
            messageID: "msg-12345678",
            sender: "alice",
            content: "Meet at the north gate at 5pm\nBring jackets"
        )
        let encoded = MessageInteractionCodec.encodeReply(to: original, body: "On my way!")
        XCTAssertEqual(encoded, "> @alice: Meet at the north gate at 5pm Bring jackets\nOn my way!")

        let parsed = MessageInteractionCodec.parseReply(from: encoded)
        XCTAssertEqual(parsed?.quotedSender, "alice")
        XCTAssertEqual(parsed?.quotedSnippet, "Meet at the north gate at 5pm Bring jackets")
        XCTAssertEqual(parsed?.body, "On my way!")

        // Replying to a reply quotes only the inner body, not nested `>` lines.
        let nested = MessageReplyTarget(messageID: "msg-2", sender: "bob", content: encoded)
        XCTAssertEqual(nested.snippet, "On my way!")
    }

    func test_reactionAggregationToggleAndOrphanSuppression() {
        let alice = PeerID(str: "1111111111111111")
        let bob = PeerID(str: "2222222222222222")
        let target = BitchatMessage(
            id: "abcd1234-full-id",
            sender: "alice",
            content: "Dinner at 7?",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            senderPeerID: alice
        )
        let bobThumbs = BitchatMessage(
            id: "r1",
            sender: "bob",
            content: MessageInteractionCodec.encodeReaction(emoji: "👍", toMessageID: target.id),
            timestamp: Date().addingTimeInterval(1),
            isRelay: false,
            isPrivate: true,
            senderPeerID: bob
        )
        let myThumbs = BitchatMessage(
            id: "r2",
            sender: "me",
            content: MessageInteractionCodec.encodeReaction(emoji: "👍", toMessageID: target.id),
            timestamp: Date().addingTimeInterval(2),
            isRelay: false,
            isPrivate: true,
            senderPeerID: alice
        )
        let myHeartAdd = BitchatMessage(
            id: "r3",
            sender: "me",
            content: MessageInteractionCodec.encodeReaction(emoji: "❤️", toMessageID: target.id),
            timestamp: Date().addingTimeInterval(3),
            isRelay: false,
            isPrivate: true,
            senderPeerID: alice
        )
        let myHeartRemove = BitchatMessage(
            id: "r4",
            sender: "me",
            content: MessageInteractionCodec.encodeReaction(emoji: "❤️", toMessageID: target.id),
            timestamp: Date().addingTimeInterval(4),
            isRelay: false,
            isPrivate: true,
            senderPeerID: alice
        )
        let orphan = BitchatMessage(
            id: "r5",
            sender: "bob",
            content: "[react:deadbeef:🔥]",
            timestamp: Date().addingTimeInterval(5),
            isRelay: false,
            isPrivate: true,
            senderPeerID: bob
        )

        let summary = MessageInteractionCodec.aggregateReactions(
            in: [target, bobThumbs, myThumbs, myHeartAdd, myHeartRemove, orphan],
            isCurrentUser: { $0.sender == "me" }
        )

        XCTAssertEqual(summary.consumedControlMessageIDs, Set(["r1", "r2", "r3", "r4", "r5"]))
        XCTAssertEqual(summary.reactionsByMessageID[target.id], [
            AggregatedReaction(emoji: "👍", count: 2, includesCurrentUser: true)
        ])
    }

    func test_inChatSearchSkipsSystemAndReactionControlMessages() {
        let m1 = BitchatMessage(id: "m1", sender: "alice", content: "Coffee at Blue Bottle", timestamp: Date(), isRelay: false, isPrivate: true)
        let sys = BitchatMessage(id: "sys", sender: "system", content: "Coffee system line", timestamp: Date(), isRelay: false, isPrivate: false)
        let react = BitchatMessage(id: "r1", sender: "bob", content: "[react:m1:☕️]", timestamp: Date(), isRelay: false, isPrivate: true)
        let m2 = BitchatMessage(
            id: "m2",
            sender: "bob",
            content: "> @alice: Coffee at Blue Bottle\nSounds great!",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true
        )

        XCTAssertEqual(MessageInteractionCodec.matchingMessageIDs(in: [m1, sys, react, m2], query: "coffee"), ["m1"])
        XCTAssertEqual(MessageInteractionCodec.matchingMessageIDs(in: [m1, sys, react, m2], query: "sounds"), ["m2"])
        XCTAssertEqual(MessageInteractionCodec.matchingMessageIDs(in: [m1, sys, react, m2], query: "alice"), ["m1"])
    }

    @MainActor
    func test_publicChatModelTracksUnreadMeshMessagesAndClearsOnViewing() {
        let store = ConversationStore()
        let myID = PeerID(str: "0000111122223333")
        let aliceID = PeerID(str: "aaaabbbbccccdddd")
        let model = PublicChatModel(conversations: store, myPeerIDProvider: { myID })
        model.setViewingNearbyMesh(false)

        // System lines, own messages, and reactions do not bump unread count.
        store.append(
            BitchatMessage(id: "sys1", sender: "system", content: "joined", timestamp: Date(), isRelay: false, isPrivate: false),
            to: .mesh
        )
        store.append(
            BitchatMessage(id: "mine1", sender: "me", content: "hello", timestamp: Date(), isRelay: false, isPrivate: false, senderPeerID: myID),
            to: .mesh
        )
        store.append(
            BitchatMessage(id: "react1", sender: "alice", content: "[react:mine1:👍]", timestamp: Date(), isRelay: false, isPrivate: false, senderPeerID: aliceID),
            to: .mesh
        )
        XCTAssertEqual(model.unreadMeshMessageCount, 0)
        XCTAssertNil(model.latestUnreadMeshPreview)

        // Incoming peer message bumps unread count & captures preview.
        store.append(
            BitchatMessage(id: "peer1", sender: "alice", content: "Anyone around?", timestamp: Date(), isRelay: false, isPrivate: false, senderPeerID: aliceID),
            to: .mesh
        )
        XCTAssertEqual(model.unreadMeshMessageCount, 1)
        XCTAssertEqual(model.latestUnreadMeshPreview, PublicChatModel.UnreadMeshPreview(sender: "alice", text: "Anyone around?"))

        // Opening Nearby clears unread state and suppresses new increments while viewing.
        model.setViewingNearbyMesh(true)
        XCTAssertEqual(model.unreadMeshMessageCount, 0)
        XCTAssertNil(model.latestUnreadMeshPreview)

        store.append(
            BitchatMessage(id: "peer2", sender: "alice", content: "Still here", timestamp: Date(), isRelay: false, isPrivate: false, senderPeerID: aliceID),
            to: .mesh
        )
        XCTAssertEqual(model.unreadMeshMessageCount, 0)
    }

    func test_replyCodecSanitizesColonSpaceAndLeadingQuoteInSenderNickname() {
        let target = MessageReplyTarget(
            messageID: "m-colon",
            sender: "> alice: admin",
            content: "Original body: with colon"
        )
        let encoded = MessageInteractionCodec.encodeReply(to: target, body: "Got it!")
        let parsed = MessageInteractionCodec.parseReply(from: encoded)
        XCTAssertEqual(parsed?.quotedSender, "alice admin")
        XCTAssertEqual(parsed?.quotedSnippet, "Original body: with colon")
        XCTAssertEqual(parsed?.body, "Got it!")
    }
}
