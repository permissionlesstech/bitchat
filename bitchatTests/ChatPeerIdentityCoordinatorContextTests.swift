//
// ChatPeerIdentityCoordinatorContextTests.swift
// bitchatTests
//
// Exercises `ChatPeerIdentityCoordinator` against a mock
// `ChatPeerIdentityContext` — proving the coordinator works without a
// `ChatViewModel`, following the `ChatDeliveryCoordinatorContextTests` /
// `ChatPrivateConversationCoordinatorContextTests` exemplars.
//
// Scope note: favorites are injected through the context
// (`favoriteRelationship(forNoiseKey:)` / `addFavorite` / `removeFavorite`),
// so the favorite toggle and lookup flows are covered here alongside the
// session, migration, encryption-status, and nickname resolution flows.
//

import Testing
import Foundation
import BitFoundation
@testable import bitchat

// MARK: - Mock Context

/// Lightweight stand-in for `ChatPeerIdentityContext` proving that
/// `ChatPeerIdentityCoordinator` is testable without a `ChatViewModel`.
@MainActor
private final class MockChatPeerIdentityContext: ChatPeerIdentityContext {
    // Conversation state
    var privateChats: [PeerID: [BitchatMessage]] = [:]
    var unreadPrivateMessages: Set<PeerID> = []
    var selectedPrivateChatPeer: PeerID?
    var selectedPrivateChatFingerprint: String?
    var myPeerID = PeerID(str: "0011223344556677")
    var activeChannel: ChannelID = .mesh
    private(set) var notifyUIChangedCount = 0
    private(set) var systemMessages: [String] = []

    func notifyUIChanged() { notifyUIChangedCount += 1 }
    func addSystemMessage(_ content: String) { systemMessages.append(content) }

    // Conversation store intents (mirror `ConversationStore` migrate
    // semantics: dedup by ID, timestamp order, unread carried, old chat
    // removed) while recording calls for assertions.
    private(set) var migratedChats: [(from: PeerID, to: PeerID)] = []

    func markPrivateChatRead(_ peerID: PeerID) {
        unreadPrivateMessages.remove(peerID)
    }

    func markPrivateChatUnread(_ peerID: PeerID) {
        unreadPrivateMessages.insert(peerID)
    }

    @discardableResult
    func appendPrivateMessage(_ message: BitchatMessage, to peerID: PeerID) -> Bool {
        var chat = privateChats[peerID] ?? []
        guard !chat.contains(where: { $0.id == message.id }) else { return false }
        let index = chat.firstIndex(where: { $0.timestamp > message.timestamp }) ?? chat.count
        chat.insert(message, at: index)
        privateChats[peerID] = chat
        return true
    }

    func migratePrivateChat(from oldPeerID: PeerID, to newPeerID: PeerID) {
        migratedChats.append((oldPeerID, newPeerID))
        guard oldPeerID != newPeerID, let source = privateChats[oldPeerID] else { return }
        var destination = privateChats[newPeerID] ?? []
        for message in source where !destination.contains(where: { $0.id == message.id }) {
            let index = destination.firstIndex(where: { $0.timestamp > message.timestamp }) ?? destination.count
            destination.insert(message, at: index)
        }
        privateChats[newPeerID] = destination
        privateChats.removeValue(forKey: oldPeerID)
        if unreadPrivateMessages.remove(oldPeerID) != nil {
            unreadPrivateMessages.insert(newPeerID)
        }
    }

    // Private chat session lifecycle
    private(set) var consolidatedPeers: [(peerID: PeerID, peerNickname: String)] = []
    private(set) var syncedReadReceiptPeers: [PeerID] = []
    private(set) var begunChatSessions: [PeerID] = []
    private(set) var markedReadPeers: [PeerID] = []

    @discardableResult
    func consolidatePrivateMessages(for peerID: PeerID, peerNickname: String) -> Bool {
        consolidatedPeers.append((peerID, peerNickname))
        return false
    }

    func syncReadReceiptsForSentMessages(for peerID: PeerID) {
        syncedReadReceiptPeers.append(peerID)
    }

    func beginPrivateChatSession(with peerID: PeerID) {
        begunChatSessions.append(peerID)
    }

    func markPrivateMessagesAsRead(from peerID: PeerID) { markedReadPeers.append(peerID) }

    // Unified peer service
    var connectedPeers: Set<PeerID> = []
    var peersByID: [PeerID: BitchatPeer] = [:]
    var blockedPeers: Set<PeerID> = []
    var fingerprintsByPeerID: [PeerID: String] = [:]
    var peerIDsByNickname: [String: PeerID] = [:]
    var ephemeralPeerIDsByNoiseKey: [Data: PeerID] = [:]
    private(set) var toggledFavoritePeers: [PeerID] = []

    func unifiedPeer(for peerID: PeerID) -> BitchatPeer? { peersByID[peerID] }
    func unifiedIsBlocked(_ peerID: PeerID) -> Bool { blockedPeers.contains(peerID) }
    func unifiedToggleFavorite(_ peerID: PeerID) { toggledFavoritePeers.append(peerID) }
    func unifiedFingerprint(for peerID: PeerID) -> String? { fingerprintsByPeerID[peerID] }
    func unifiedPeerID(forNickname nickname: String) -> PeerID? { peerIDsByNickname[nickname] }
    func ephemeralPeerID(forNoiseKey noiseKey: Data) -> PeerID? { ephemeralPeerIDsByNoiseKey[noiseKey] }

    // Mesh & Noise sessions
    var nicknamesByPeerID: [PeerID: String] = [:]
    var noiseSessionStates: [PeerID: LazyHandshakeState] = [:]
    var establishedNoiseSessions: Set<PeerID> = []
    var activeNoiseSessions: Set<PeerID> = []
    var myNoiseFingerprint = "my-fingerprint"
    private(set) var triggeredHandshakes: [PeerID] = []

    func peerNickname(for peerID: PeerID) -> String? { nicknamesByPeerID[peerID] }
    func meshPeerNicknames() -> [PeerID: String] { nicknamesByPeerID }
    func noiseSessionState(for peerID: PeerID) -> LazyHandshakeState {
        noiseSessionStates[peerID] ?? .none
    }
    func triggerHandshake(with peerID: PeerID) { triggeredHandshakes.append(peerID) }
    func hasEstablishedNoiseSession(with peerID: PeerID) -> Bool {
        establishedNoiseSessions.contains(peerID)
    }
    func hasNoiseSession(with peerID: PeerID) -> Bool { activeNoiseSessions.contains(peerID) }
    func noiseIdentityFingerprint() -> String { myNoiseFingerprint }

    // Identity store (fingerprints & encryption status)
    var verifiedFingerprintSet: Set<String> = []
    var socialIdentitiesByFingerprint: [String: SocialIdentity] = [:]
    private(set) var storedFingerprints: [(fingerprint: String, peerID: PeerID)] = []
    private(set) var encryptionStatuses: [PeerID: EncryptionStatus?] = [:]
    private(set) var cachedEncryptionStatuses: [PeerID: EncryptionStatus] = [:]
    private(set) var invalidatedEncryptionCachePeers: [PeerID?] = []

    func setStoredFingerprint(_ fingerprint: String, for peerID: PeerID) {
        storedFingerprints.append((fingerprint, peerID))
        fingerprintsByPeerID[peerID] = fingerprint
    }

    func migrateFingerprintMapping(from oldPeerID: PeerID, to newPeerID: PeerID, fallback: String?) -> String? {
        let fingerprint = fingerprintsByPeerID.removeValue(forKey: oldPeerID) ?? fallback
        if let fingerprint {
            fingerprintsByPeerID[newPeerID] = fingerprint
        }
        return fingerprint
    }

    func isVerifiedFingerprint(_ fingerprint: String) -> Bool {
        verifiedFingerprintSet.contains(fingerprint)
    }

    func setEncryptionStatus(_ status: EncryptionStatus?, for peerID: PeerID) {
        encryptionStatuses[peerID] = status
    }

    func cachedEncryptionStatus(for peerID: PeerID) -> EncryptionStatus? {
        cachedEncryptionStatuses[peerID]
    }

    func setCachedEncryptionStatus(_ status: EncryptionStatus, for peerID: PeerID) {
        cachedEncryptionStatuses[peerID] = status
    }

    func invalidateStoredEncryptionCache(for peerID: PeerID?) {
        invalidatedEncryptionCachePeers.append(peerID)
        if let peerID {
            cachedEncryptionStatuses.removeValue(forKey: peerID)
        } else {
            cachedEncryptionStatuses.removeAll()
        }
    }

    func socialIdentity(forFingerprint fingerprint: String) -> SocialIdentity? {
        socialIdentitiesByFingerprint[fingerprint]
    }

    // Geohash & Nostr
    var geoNicknames: [String: String] = [:]
    var geohashPeople: [GeoPerson] = []
    private(set) var registeredNostrKeyMappings: [(pubkey: String, peerID: PeerID)] = []
    private(set) var nostrFavoriteNotifications: [(noisePublicKey: Data, isFavorite: Bool)] = []
    var bridgedNostrKeysByNoiseKey: [Data: String] = [:]

    func visibleGeohashPeople() -> [GeoPerson] { geohashPeople }

    func registerNostrKeyMapping(_ pubkey: String, for peerID: PeerID) {
        registeredNostrKeyMappings.append((pubkey, peerID))
    }

    func bridgedNostrPublicKey(for noiseKey: Data) -> String? {
        bridgedNostrKeysByNoiseKey[noiseKey]
    }

    func sendFavoriteNotificationViaNostr(noisePublicKey: Data, isFavorite: Bool) {
        nostrFavoriteNotifications.append((noisePublicKey, isFavorite))
    }

    // Favorites
    var favoriteRelationshipsByNoiseKey: [Data: FavoritesPersistenceService.FavoriteRelationship] = [:]
    var favoriteRelationshipsByPeerID: [PeerID: FavoritesPersistenceService.FavoriteRelationship] = [:]
    private(set) var addedFavorites: [(noiseKey: Data, nostrPublicKey: String?, nickname: String)] = []
    private(set) var removedFavorites: [Data] = []

    func favoriteRelationship(forNoiseKey noiseKey: Data) -> FavoritesPersistenceService.FavoriteRelationship? {
        favoriteRelationshipsByNoiseKey[noiseKey]
    }

    func favoriteRelationship(forPeerID peerID: PeerID) -> FavoritesPersistenceService.FavoriteRelationship? {
        favoriteRelationshipsByPeerID[peerID]
    }

    func addFavorite(noiseKey: Data, nostrPublicKey: String?, nickname: String) {
        addedFavorites.append((noiseKey, nostrPublicKey, nickname))
    }

    func removeFavorite(noiseKey: Data) {
        removedFavorites.append(noiseKey)
    }
}

// MARK: - Helpers

private func makeFavoriteRelationship(
    noiseKey: Data,
    nostrPublicKey: String? = nil,
    nickname: String = "alice",
    isFavorite: Bool = false,
    theyFavoritedUs: Bool = false
) -> FavoritesPersistenceService.FavoriteRelationship {
    FavoritesPersistenceService.FavoriteRelationship(
        peerNoisePublicKey: noiseKey,
        peerNostrPublicKey: nostrPublicKey,
        peerNickname: nickname,
        isFavorite: isFavorite,
        theyFavoritedUs: theyFavoritedUs,
        favoritedAt: Date(timeIntervalSince1970: 0),
        lastUpdated: Date(timeIntervalSince1970: 0)
    )
}

@MainActor
private func makePrivateMessage(
    id: String,
    sender: String = "alice",
    timestamp: Date = Date(),
    senderPeerID: PeerID? = nil
) -> BitchatMessage {
    BitchatMessage(
        id: id,
        sender: sender,
        content: "hello",
        timestamp: timestamp,
        isRelay: false,
        isPrivate: true,
        recipientNickname: "me",
        senderPeerID: senderPeerID
    )
}

// MARK: - Coordinator Tests Against Mock Context

/// Exercises `ChatPeerIdentityCoordinator` against
/// `MockChatPeerIdentityContext` with no `ChatViewModel`.
struct ChatPeerIdentityCoordinatorContextTests {

    @Test @MainActor
    func startPrivateChat_runsFullSessionSetupSequence() async {
        let context = MockChatPeerIdentityContext()
        let coordinator = ChatPeerIdentityCoordinator(context: context)
        let peerID = PeerID(str: "1122334455667788")
        context.nicknamesByPeerID[peerID] = "alice"
        context.fingerprintsByPeerID[peerID] = "fp-alice"

        // Chatting with ourselves is a no-op.
        coordinator.startPrivateChat(with: context.myPeerID)
        #expect(context.begunChatSessions.isEmpty)

        coordinator.startPrivateChat(with: peerID)

        #expect(context.consolidatedPeers.map(\.peerID) == [peerID])
        #expect(context.consolidatedPeers.first?.peerNickname == "alice")
        // No Noise session yet -> handshake triggered.
        #expect(context.triggeredHandshakes == [peerID])
        #expect(context.syncedReadReceiptPeers == [peerID])
        #expect(context.storedFingerprints.map(\.fingerprint) == ["fp-alice"])
        #expect(context.selectedPrivateChatFingerprint == "fp-alice")
        #expect(context.begunChatSessions == [peerID])
        #expect(context.markedReadPeers == [peerID])

        // Established session: no second handshake.
        context.noiseSessionStates[peerID] = .established
        coordinator.startPrivateChat(with: peerID)
        #expect(context.triggeredHandshakes == [peerID])
    }

    @Test @MainActor
    func startPrivateChat_blockedPeerOnlyGetsSystemMessage() async {
        let context = MockChatPeerIdentityContext()
        let coordinator = ChatPeerIdentityCoordinator(context: context)
        let peerID = PeerID(str: "1122334455667788")
        context.blockedPeers = [peerID]

        coordinator.startPrivateChat(with: peerID)

        #expect(context.systemMessages.count == 1)
        #expect(context.begunChatSessions.isEmpty)
        #expect(context.consolidatedPeers.isEmpty)
        #expect(context.markedReadPeers.isEmpty)
    }

    @Test @MainActor
    func updatePrivateChatPeerIfNeeded_migratesChatStateByFingerprint() async {
        let context = MockChatPeerIdentityContext()
        let coordinator = ChatPeerIdentityCoordinator(context: context)
        let oldPeerID = PeerID(str: "1111111111111111")
        let newPeerID = PeerID(str: "2222222222222222")

        context.selectedPrivateChatFingerprint = "fp"
        context.selectedPrivateChatPeer = oldPeerID
        context.connectedPeers = [newPeerID]
        context.fingerprintsByPeerID[newPeerID] = "fp"
        let earlier = makePrivateMessage(id: "m1", timestamp: Date(timeIntervalSince1970: 1))
        let later = makePrivateMessage(id: "m2", timestamp: Date(timeIntervalSince1970: 2))
        context.privateChats[oldPeerID] = [later]
        context.privateChats[newPeerID] = [earlier, later] // duplicate id "m2"
        context.unreadPrivateMessages = [oldPeerID]

        coordinator.updatePrivateChatPeerIfNeeded()

        // Old chat is merged into the new peer's chat, deduplicated by id and
        // sorted by timestamp; old keys are dropped.
        #expect(context.privateChats[oldPeerID] == nil)
        #expect(context.privateChats[newPeerID]?.map(\.id) == ["m1", "m2"])
        #expect(context.selectedPrivateChatPeer == newPeerID)
        // Unread moved to the new peer, then cleared for the now-open chat.
        #expect(context.unreadPrivateMessages.isEmpty)
    }

    @Test @MainActor
    func getEncryptionStatus_computesVerifiedStatusAndCachesIt() async {
        let context = MockChatPeerIdentityContext()
        let coordinator = ChatPeerIdentityCoordinator(context: context)
        let peerID = PeerID(str: "1122334455667788")

        // Unknown peer with no fingerprint or session: no handshake yet.
        #expect(coordinator.getEncryptionStatus(for: peerID) == .noHandshake)
        #expect(context.cachedEncryptionStatuses[peerID] == .noHandshake)

        // Cache hit short-circuits recomputation.
        context.noiseSessionStates[peerID] = .established
        #expect(coordinator.getEncryptionStatus(for: peerID) == .noHandshake)

        // After invalidation, an established session with a verified
        // fingerprint resolves (and re-caches) as verified.
        coordinator.invalidateEncryptionCache(for: peerID)
        context.fingerprintsByPeerID[peerID] = "fp"
        context.verifiedFingerprintSet = ["fp"]
        #expect(coordinator.getEncryptionStatus(for: peerID) == .noiseVerified)
        #expect(context.cachedEncryptionStatuses[peerID] == .noiseVerified)

        // updateEncryptionStatus publishes to the store and invalidates the cache.
        context.establishedNoiseSessions = [peerID]
        coordinator.updateEncryptionStatus(for: peerID)
        #expect(context.encryptionStatuses[peerID] == .noiseVerified)
        #expect(context.cachedEncryptionStatuses[peerID] == nil)
    }

    @Test @MainActor
    func getEncryptionStatus_reflectsLiveSessionNotHistory() async {
        let context = MockChatPeerIdentityContext()
        let coordinator = ChatPeerIdentityCoordinator(context: context)
        let peerID = PeerID(str: "8877665544332211")

        // A remembered (even verified) fingerprint must not conjure a lock on
        // its own: the DM header and "end-to-end encrypted" caption follow
        // this status, and claiming secured with no live session is the false
        // security signal this mapping used to produce.
        context.fingerprintsByPeerID[peerID] = "fp"
        context.verifiedFingerprintSet = ["fp"]

        #expect(coordinator.getEncryptionStatus(for: peerID) == .noHandshake)

        coordinator.invalidateEncryptionCache(for: peerID)
        context.noiseSessionStates[peerID] = .handshaking
        #expect(coordinator.getEncryptionStatus(for: peerID) == .noiseHandshaking)

        // A FAILED handshake is a red lock.slash, not yesterday's seal.
        struct HandshakeError: Error {}
        coordinator.invalidateEncryptionCache(for: peerID)
        context.noiseSessionStates[peerID] = .failed(HandshakeError())
        #expect(coordinator.getEncryptionStatus(for: peerID) == .none)

        // Only a live established session upgrades to the verified seal.
        coordinator.invalidateEncryptionCache(for: peerID)
        context.noiseSessionStates[peerID] = .established
        #expect(coordinator.getEncryptionStatus(for: peerID) == .noiseVerified)
    }

    @Test @MainActor
    func resolveNickname_walksMeshIdentityAndAnonFallbacks() async {
        let context = MockChatPeerIdentityContext()
        let coordinator = ChatPeerIdentityCoordinator(context: context)
        let meshPeer = PeerID(str: "aabbccddeeff0011")
        let identityPeer = PeerID(str: "1234567890abcdef")
        let unknownPeer = PeerID(str: "feedfacefeedface")

        context.nicknamesByPeerID[meshPeer] = "alice"
        #expect(coordinator.resolveNickname(for: meshPeer) == "alice")

        context.fingerprintsByPeerID[identityPeer] = "fp"
        context.socialIdentitiesByFingerprint["fp"] = SocialIdentity(
            fingerprint: "fp",
            localPetname: "bob!",
            claimedNickname: "bob",
            trustLevel: .casual,
            isFavorite: false,
            isBlocked: false,
            notes: nil
        )
        #expect(coordinator.resolveNickname(for: identityPeer) == "bob!")

        // Local alias outranks a live mesh announce for the same peer.
        context.nicknamesByPeerID[identityPeer] = "bob"
        #expect(coordinator.resolveNickname(for: identityPeer) == "bob!")

        #expect(coordinator.resolveNickname(for: unknownPeer) == "anonfeed")
        #expect(coordinator.getMyFingerprint() == "my-fingerprint")
    }

    @Test @MainActor
    func getPeerIDForNickname_inGeohashChannel_registersNostrMapping() async {
        let context = MockChatPeerIdentityContext()
        let coordinator = ChatPeerIdentityCoordinator(context: context)
        let pubkey = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789".lowercased()
        context.activeChannel = .location(GeohashChannel(level: .city, geohash: "u4pruy"))
        context.geohashPeople = [GeoPerson(id: pubkey, displayName: "alice#6789", lastSeen: Date())]
        context.geoNicknames[pubkey] = "alice"

        // Suffixed display-name match.
        let bySuffix = coordinator.getPeerIDForNickname("alice#6789")
        #expect(bySuffix == PeerID(nostr_: pubkey))
        // Base-nickname match via geoNicknames.
        let byBase = coordinator.getPeerIDForNickname("ALICE")
        #expect(byBase == PeerID(nostr_: pubkey))
        #expect(context.registeredNostrKeyMappings.count == 2)
        #expect(context.registeredNostrKeyMappings.allSatisfy { $0.pubkey == pubkey })

        // Mesh channel falls through to the unified peer service.
        context.activeChannel = .mesh
        let meshPeer = PeerID(str: "1122334455667788")
        context.peerIDsByNickname["carol"] = meshPeer
        #expect(coordinator.getPeerIDForNickname("carol") == meshPeer)
    }

    @Test @MainActor
    func getPeerIDForNickname_inGeohashChannel_refusesAmbiguousBaseName() async {
        let context = MockChatPeerIdentityContext()
        let coordinator = ChatPeerIdentityCoordinator(context: context)
        let aliceA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let aliceB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        context.activeChannel = .location(GeohashChannel(level: .city, geohash: "u4pruy"))
        context.geohashPeople = [
            GeoPerson(id: aliceA, displayName: "alice#aaaa", lastSeen: Date()),
            GeoPerson(id: aliceB, displayName: "alice#bbbb", lastSeen: Date())
        ]
        context.geoNicknames[aliceA] = "alice"
        context.geoNicknames[aliceB] = "alice"
        context.peerIDsByNickname["alice"] = PeerID(str: "1122334455667788")

        #expect(coordinator.getPeerIDForNickname("alice") == nil)
        #expect(coordinator.getPeerIDForNickname("alice#aaaa") == PeerID(nostr_: aliceA))
        #expect(coordinator.getPeerIDForNickname("alice#bbbb") == PeerID(nostr_: aliceB))
    }

    @Test @MainActor
    func toggleFavorite_forNoiseKeyPeer_usesInjectedFavoritesStore() async {
        let context = MockChatPeerIdentityContext()
        let coordinator = ChatPeerIdentityCoordinator(context: context)
        let noiseKey = Data(repeating: 0xAB, count: 32)
        let peerID = PeerID(hexData: noiseKey)

        // No prior relationship: adds a favorite, no Nostr notification yet.
        coordinator.toggleFavorite(peerID: peerID)
        #expect(context.addedFavorites.count == 1)
        #expect(context.addedFavorites.first?.noiseKey == noiseKey)
        #expect(context.addedFavorites.first?.nickname == "Unknown")
        #expect(context.nostrFavoriteNotifications.isEmpty)
        #expect(coordinator.isFavorite(peerID: peerID) == false)

        // They already favorite us: adding sends the mutual notification.
        context.favoriteRelationshipsByNoiseKey[noiseKey] = makeFavoriteRelationship(
            noiseKey: noiseKey,
            theyFavoritedUs: true
        )
        coordinator.toggleFavorite(peerID: peerID)
        #expect(context.addedFavorites.count == 2)
        #expect(context.addedFavorites.last?.nickname == "alice")
        #expect(context.nostrFavoriteNotifications.map(\.isFavorite) == [true])

        // Existing favorite: toggling removes it and notifies the unfavorite.
        context.favoriteRelationshipsByNoiseKey[noiseKey] = makeFavoriteRelationship(
            noiseKey: noiseKey,
            isFavorite: true
        )
        #expect(coordinator.isFavorite(peerID: peerID) == true)
        coordinator.toggleFavorite(peerID: peerID)
        #expect(context.removedFavorites == [noiseKey])
        #expect(context.nostrFavoriteNotifications.map(\.isFavorite) == [true, false])
    }

}

// MARK: - Refused Signing Keys

/// The notice for an announce that claimed a contact's identity with a
/// different signing key and was refused.
struct ChatPeerIdentityCoordinatorRefusedSigningKeyTests {
    private let noiseKey = Data(repeating: 0x9B, count: 32)
    private var peerID: PeerID { PeerID(publicKey: noiseKey) }

    @MainActor
    private func refuse(
        _ coordinator: ChatPeerIdentityCoordinator,
        key: UInt8,
        reason: SigningKeyRefusalReason = .pinnedKey
    ) {
        coordinator.warnOfRefusedSigningKey(
            for: peerID,
            noisePublicKey: noiseKey,
            signingPublicKey: Data(repeating: key, count: 32),
            reason: reason
        )
    }

    @MainActor
    private func notices(in chat: [BitchatMessage]) -> [BitchatMessage] {
        chat.filter { $0.id.hasPrefix(ChatPeerIdentityCoordinator.refusedSigningKeyNoticeIDPrefix) }
    }

    @Test @MainActor
    func warnsInTheExistingChatUnderTheNameAlreadyKnown() throws {
        let context = MockChatPeerIdentityContext()
        let coordinator = ChatPeerIdentityCoordinator(context: context)
        context.nicknamesByPeerID[peerID] = "alice"
        context.privateChats[peerID] = [makePrivateMessage(id: "m1", timestamp: Date(timeIntervalSince1970: 1))]

        refuse(coordinator, key: 0x99)

        let chat = context.privateChats[peerID] ?? []
        #expect(chat.count == 2)
        let notice = try #require(chat.last)
        #expect(notice.sender == "system")
        #expect(notice.isPrivate)
        #expect(notice.content.contains("alice"))
        #expect(context.unreadPrivateMessages.contains(peerID))
        #expect(context.notifyUIChangedCount == 1)
    }

    @Test @MainActor
    func theSameRefusedKeyWarnsOnce() {
        let context = MockChatPeerIdentityContext()
        let coordinator = ChatPeerIdentityCoordinator(context: context)
        context.privateChats[peerID] = [makePrivateMessage(id: "m1", timestamp: Date(timeIntervalSince1970: 1))]

        refuse(coordinator, key: 0x99)
        // A real message in between, so only the per-key de-dup can hold it.
        _ = context.appendPrivateMessage(makePrivateMessage(id: "m2"), to: peerID)
        refuse(coordinator, key: 0x99)

        #expect(notices(in: context.privateChats[peerID] ?? []).count == 1)
    }

    /// Signing keys cost nothing to generate, so de-duplicating per key alone
    /// would let a stream of fresh keys fill the chat with notices.
    @Test @MainActor
    func freshKeysCannotFloodTheChat() {
        let context = MockChatPeerIdentityContext()
        let coordinator = ChatPeerIdentityCoordinator(context: context)
        context.privateChats[peerID] = [makePrivateMessage(id: "m1", timestamp: Date(timeIntervalSince1970: 1))]

        refuse(coordinator, key: 0xA1)
        refuse(coordinator, key: 0xA2)
        refuse(coordinator, key: 0xA3, reason: .authenticatedKey)
        #expect(notices(in: context.privateChats[peerID] ?? []).count == 1)

        _ = context.appendPrivateMessage(makePrivateMessage(id: "m2"), to: peerID)
        refuse(coordinator, key: 0xA4)
        #expect(notices(in: context.privateChats[peerID] ?? []).count == 2)
    }

    @Test @MainActor
    func withNoChatNothingIsCreated() {
        let context = MockChatPeerIdentityContext()
        let coordinator = ChatPeerIdentityCoordinator(context: context)

        refuse(coordinator, key: 0x99)

        #expect(context.privateChats.isEmpty)
        #expect(context.unreadPrivateMessages.isEmpty)
        #expect(context.notifyUIChangedCount == 0)
    }

    @Test @MainActor
    func theOpenChatIsWarnedWithoutMarkingItUnread() {
        let context = MockChatPeerIdentityContext()
        let coordinator = ChatPeerIdentityCoordinator(context: context)
        context.selectedPrivateChatPeer = peerID

        refuse(coordinator, key: 0x99)

        #expect(notices(in: context.privateChats[peerID] ?? []).count == 1)
        #expect(!context.unreadPrivateMessages.contains(peerID))
    }

    @Test @MainActor
    func warnsInTheChatHeldUnderTheFullNoiseKey() {
        let context = MockChatPeerIdentityContext()
        let coordinator = ChatPeerIdentityCoordinator(context: context)
        let stableID = PeerID(hexData: noiseKey)
        context.privateChats[stableID] = [makePrivateMessage(id: "m1", timestamp: Date(timeIntervalSince1970: 1))]

        refuse(coordinator, key: 0x99)

        #expect(notices(in: context.privateChats[stableID] ?? []).count == 1)
        #expect(context.privateChats[peerID] == nil)
    }

    @Test @MainActor
    func warnsInTheChatHeldUnderTheBridgedNostrKey() {
        let context = MockChatPeerIdentityContext()
        let coordinator = ChatPeerIdentityCoordinator(context: context)
        let nostrPublicKey = String(repeating: "ab", count: 32)
        context.bridgedNostrKeysByNoiseKey[noiseKey] = nostrPublicKey
        let nostrID = PeerID(nostr_: nostrPublicKey)
        context.privateChats[nostrID] = [makePrivateMessage(id: "m1", timestamp: Date(timeIntervalSince1970: 1))]

        refuse(coordinator, key: 0x99)

        #expect(notices(in: context.privateChats[nostrID] ?? []).count == 1)
        #expect(context.privateChats[peerID] == nil)
    }
}
