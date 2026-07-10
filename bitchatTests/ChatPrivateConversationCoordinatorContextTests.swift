//
// ChatPrivateConversationCoordinatorContextTests.swift
// bitchatTests
//
// Exercises `ChatPrivateConversationCoordinator` against a mock
// `ChatPrivateConversationContext` — proving the coordinator works without a
// `ChatViewModel`, following the `ChatDeliveryCoordinatorContextTests` exemplar.
//

import Testing
import Foundation
import BitFoundation
@testable import bitchat

// MARK: - Mock Context

/// Lightweight stand-in for `ChatPrivateConversationContext` proving that
/// `ChatPrivateConversationCoordinator` is testable without a `ChatViewModel`.
@MainActor
private final class MockChatPrivateConversationContext: ChatPrivateConversationContext {
    // Conversation state
    var privateChats: [PeerID: [BitchatMessage]] = [:]
    var sentReadReceipts: Set<String> = []
    var sentGeoDeliveryAcks: Set<String> = []
    var unreadPrivateMessages: Set<PeerID> = []
    var selectedPrivateChatPeer: PeerID?
    var nickname = "me"
    var activeChannel: ChannelID = .mesh
    var nostrKeyMapping: [PeerID: String] = [:]
    private(set) var notifyUIChangedCount = 0

    @discardableResult
    func markReadReceiptSent(_ messageID: String) -> Bool {
        sentReadReceipts.insert(messageID).inserted
    }

    @discardableResult
    func markGeoDeliveryAckSent(_ messageID: String) -> Bool {
        sentGeoDeliveryAcks.insert(messageID).inserted
    }

    func handOffSelectedPrivateChat(from oldPeerIDs: [PeerID], to newPeerID: PeerID) {
        guard oldPeerIDs.contains(where: { selectedPrivateChatPeer == $0 }) else { return }
        selectedPrivateChatPeer = newPeerID
    }

    func notifyUIChanged() {
        notifyUIChangedCount += 1
    }

    // Conversation store intents (mirror `ConversationStore` semantics:
    // ordered insert, dedup by ID, no-downgrade status, unread carry on
    // migrate) while recording calls for assertions.
    private(set) var upsertedMessages: [(messageID: String, peerID: PeerID)] = []
    private(set) var migratedChats: [(from: PeerID, to: PeerID)] = []

    @discardableResult
    func appendPrivateMessage(_ message: BitchatMessage, to peerID: PeerID) -> Bool {
        var chat = privateChats[peerID] ?? []
        guard !chat.contains(where: { $0.id == message.id }) else {
            privateChats[peerID] = chat
            return false
        }
        let index = chat.firstIndex(where: { $0.timestamp > message.timestamp }) ?? chat.count
        chat.insert(message, at: index)
        privateChats[peerID] = chat
        return true
    }

    func upsertPrivateMessage(_ message: BitchatMessage, in peerID: PeerID) {
        upsertedMessages.append((message.id, peerID))
        if var chat = privateChats[peerID],
           let index = chat.firstIndex(where: { $0.id == message.id }) {
            chat[index] = message
            privateChats[peerID] = chat
        } else {
            appendPrivateMessage(message, to: peerID)
        }
    }

    @discardableResult
    func setPrivateDeliveryStatus(_ status: DeliveryStatus, forMessageID messageID: String, peerID: PeerID) -> Bool {
        guard let chat = privateChats[peerID],
              let index = chat.firstIndex(where: { $0.id == messageID }) else {
            return false
        }
        if Conversation.shouldSkipStatusUpdate(current: chat[index].deliveryStatus, new: status) {
            return false
        }
        chat[index].deliveryStatus = status
        privateChats[peerID] = chat
        return true
    }

    func markPrivateChatUnread(_ peerID: PeerID) {
        unreadPrivateMessages.insert(peerID)
    }

    func markPrivateChatRead(_ peerID: PeerID) {
        unreadPrivateMessages.remove(peerID)
    }

    func migratePrivateChat(from oldPeerID: PeerID, to newPeerID: PeerID) {
        migratedChats.append((oldPeerID, newPeerID))
        guard oldPeerID != newPeerID, let source = privateChats[oldPeerID] else { return }
        for message in source {
            appendPrivateMessage(message, to: newPeerID)
        }
        if privateChats[newPeerID] == nil {
            privateChats[newPeerID] = []
        }
        let wasUnread = unreadPrivateMessages.contains(oldPeerID)
        privateChats.removeValue(forKey: oldPeerID)
        unreadPrivateMessages.remove(oldPeerID)
        if wasUnread {
            unreadPrivateMessages.insert(newPeerID)
        }
    }

    func privateChatsContainMessage(withID messageID: String) -> Bool {
        privateChats.values.contains { chat in
            chat.contains { $0.id == messageID }
        }
    }

    func privateChat(_ peerID: PeerID, containsMessageWithID messageID: String) -> Bool {
        privateChats[peerID]?.contains { $0.id == messageID } == true
    }

    // Peers & identity
    var myPeerID = PeerID(str: "0011223344556677")
    var nicknamesByPeerID: [PeerID: String] = [:]
    var connectedPeers: Set<PeerID> = []
    var reachablePeers: Set<PeerID> = []
    var blockedPeers: Set<PeerID> = []
    var noiseKeysByPeerID: [PeerID: Data] = [:]
    var ephemeralPeerIDsByNoiseKey: [Data: PeerID] = [:]
    var peerIDsByNickname: [String: PeerID] = [:]
    var fingerprintsByPeerID: [PeerID: String] = [:]
    private(set) var clearedFingerprints: [PeerID] = []

    func peerNickname(for peerID: PeerID) -> String? { nicknamesByPeerID[peerID] }
    func isPeerConnected(_ peerID: PeerID) -> Bool { connectedPeers.contains(peerID) }
    func isPeerReachable(_ peerID: PeerID) -> Bool { reachablePeers.contains(peerID) }
    func isPeerBlocked(_ peerID: PeerID) -> Bool { blockedPeers.contains(peerID) }
    func noisePublicKey(for peerID: PeerID) -> Data? { noiseKeysByPeerID[peerID] }
    func ephemeralPeerID(forNoiseKey noiseKey: Data) -> PeerID? { ephemeralPeerIDsByNoiseKey[noiseKey] }
    func getPeerIDForNickname(_ nickname: String) -> PeerID? { peerIDsByNickname[nickname] }
    func getFingerprint(for peerID: PeerID) -> String? { fingerprintsByPeerID[peerID] }
    func storedFingerprint(for peerID: PeerID) -> String? { fingerprintsByPeerID[peerID] }

    func clearStoredFingerprint(for peerID: PeerID) {
        fingerprintsByPeerID.removeValue(forKey: peerID)
        clearedFingerprints.append(peerID)
    }

    // Nostr identity
    var blockedNostrPubkeys: Set<String> = []
    var displayNamesByPubkey: [String: String] = [:]

    func isNostrBlocked(pubkeyHexLowercased: String) -> Bool {
        blockedNostrPubkeys.contains(pubkeyHexLowercased)
    }

    func displayNameForNostrPubkey(_ pubkeyHex: String) -> String {
        displayNamesByPubkey[pubkeyHex] ?? "anon"
    }

    func deriveNostrIdentity(forGeohash geohash: String) throws -> NostrIdentity { Self.dummyIdentity }
    func currentNostrIdentity() -> NostrIdentity? { Self.dummyIdentity }

    // Routing & acknowledgements
    private(set) var routedPrivateMessages: [(content: String, peerID: PeerID, messageID: String)] = []
    private(set) var routedReadReceipts: [(messageID: String, peerID: PeerID)] = []
    private(set) var meshReadReceipts: [(messageID: String, peerID: PeerID)] = []
    private(set) var geoPrivateMessages: [(content: String, recipientHex: String, messageID: String)] = []
    private(set) var geoDeliveryAcks: [(messageID: String, recipientHex: String)] = []
    private(set) var geoReadReceipts: [(messageID: String, recipientHex: String)] = []

    func routePrivateMessage(_ content: String, to peerID: PeerID, recipientNickname: String, messageID: String) {
        routedPrivateMessages.append((content, peerID, messageID))
    }

    var routeReadReceiptResult = true
    func routeReadReceipt(_ receipt: ReadReceipt, to peerID: PeerID) -> Bool {
        routedReadReceipts.append((receipt.originalMessageID, peerID))
        return routeReadReceiptResult
    }

    func sendMeshReadReceipt(_ receipt: ReadReceipt, to peerID: PeerID) {
        meshReadReceipts.append((receipt.originalMessageID, peerID))
    }

    func sendGeohashPrivateMessage(_ content: String, toRecipientHex recipientHex: String, from identity: NostrIdentity, messageID: String) {
        geoPrivateMessages.append((content, recipientHex, messageID))
    }

    func sendGeohashDeliveryAck(for messageID: String, toRecipientHex recipientHex: String, from identity: NostrIdentity) {
        geoDeliveryAcks.append((messageID, recipientHex))
    }

    func sendGeohashReadReceipt(_ messageID: String, toRecipientHex recipientHex: String, from identity: NostrIdentity) {
        geoReadReceipts.append((messageID, recipientHex))
    }

    // Favorites & notifications
    var favoriteRelationshipsByNoiseKey: [Data: FavoritesPersistenceService.FavoriteRelationship] = [:]
    private(set) var peerFavoritedUsUpdates: [(noiseKey: Data, favorited: Bool, nickname: String, nostrPublicKey: String?)] = []
    private(set) var privateMessageNotifications: [(senderName: String, message: String, peerID: PeerID)] = []

    func favoriteRelationship(forNoiseKey noiseKey: Data) -> FavoritesPersistenceService.FavoriteRelationship? {
        favoriteRelationshipsByNoiseKey[noiseKey]
    }

    func favoriteRelationship(forPeerID peerID: PeerID) -> FavoritesPersistenceService.FavoriteRelationship? {
        favoriteRelationshipsByNoiseKey.first(where: { PeerID(publicKey: $0.key) == peerID })?.value
    }

    func updatePeerFavoritedUs(noiseKey: Data, favorited: Bool, nickname: String, nostrPublicKey: String?) {
        peerFavoritedUsUpdates.append((noiseKey, favorited, nickname, nostrPublicKey))
    }

    func notifyPrivateMessage(from senderName: String, message: String, peerID: PeerID) {
        privateMessageNotifications.append((senderName, message, peerID))
    }

    // System messages
    private(set) var meshOnlySystemMessages: [String] = []

    func addMeshOnlySystemMessage(_ content: String) {
        meshOnlySystemMessages.append(content)
    }

    private(set) var privateSystemMessages: [(content: String, peerID: PeerID)] = []

    func addLocalPrivateSystemMessage(_ content: String, to peerID: PeerID) {
        privateSystemMessages.append((content, peerID))
    }

    static let dummyIdentity = NostrIdentity(
        privateKey: Data(repeating: 0x11, count: 32),
        publicKey: Data(repeating: 0x22, count: 32),
        npub: "npub1mock",
        createdAt: Date(timeIntervalSince1970: 0)
    )
}

// MARK: - Helpers

@MainActor
private func makeIncomingMessage(
    id: String,
    sender: String = "alice",
    content: String = "hello",
    timestamp: Date = Date(),
    senderPeerID: PeerID? = nil,
    recipientNickname: String? = "me"
) -> BitchatMessage {
    BitchatMessage(
        id: id,
        sender: sender,
        content: content,
        timestamp: timestamp,
        isRelay: false,
        isPrivate: true,
        recipientNickname: recipientNickname,
        senderPeerID: senderPeerID,
        deliveryStatus: .delivered(to: "me", at: timestamp)
    )
}

private func isDelivered(_ status: DeliveryStatus?, to expected: String) -> Bool {
    if case .delivered(let to, _) = status { return to == expected }
    return false
}

private func isRead(_ status: DeliveryStatus?, by expected: String) -> Bool {
    if case .read(let by, _) = status { return by == expected }
    return false
}

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

// MARK: - Coordinator Tests Against Mock Context

/// Exercises `ChatPrivateConversationCoordinator` against
/// `MockChatPrivateConversationContext` with no `ChatViewModel`. Scoped to the
/// pure-state and ack flows plus — now that notifications and favorites are
/// injected through the context (`notifyPrivateMessage`,
/// `favoriteRelationship(forNoiseKey:)`, `updatePeerFavoritedUs`) — the
/// notification and favorite-transition flows that previously required the
/// live singletons.
struct ChatPrivateConversationCoordinatorContextTests {

    @Test @MainActor
    func addMessageToPrivateChats_upsertsByIdAndSanitizes() async {
        let context = MockChatPrivateConversationContext()
        let coordinator = ChatPrivateConversationCoordinator(context: context)
        let peerID = PeerID(str: "0102030405060708")

        let original = makeIncomingMessage(id: "m1", content: "first")
        coordinator.addMessageToPrivateChatsIfNeeded(original, targetPeerID: peerID)
        #expect(context.privateChats[peerID]?.map(\.id) == ["m1"])

        // Same id again must replace in place, not append a duplicate.
        let updated = makeIncomingMessage(id: "m1", content: "edited")
        coordinator.addMessageToPrivateChatsIfNeeded(updated, targetPeerID: peerID)
        #expect(context.privateChats[peerID]?.count == 1)
        #expect(context.privateChats[peerID]?.first?.content == "edited")

        // A different id appends.
        coordinator.addMessageToPrivateChatsIfNeeded(makeIncomingMessage(id: "m2"), targetPeerID: peerID)
        #expect(context.privateChats[peerID]?.map(\.id) == ["m1", "m2"])
        // Every add went through the store's upsert intent.
        #expect(context.upsertedMessages.map(\.peerID) == [peerID, peerID, peerID])
        #expect(context.upsertedMessages.map(\.messageID) == ["m1", "m1", "m2"])

        #expect(coordinator.isDuplicateMessage("m1", targetPeerID: peerID))
        #expect(!coordinator.isDuplicateMessage("m3", targetPeerID: peerID))
    }

    @Test @MainActor
    func geoDeliveredAndReadAcks_updateStatusAndNotify() async {
        let context = MockChatPrivateConversationContext()
        let coordinator = ChatPrivateConversationCoordinator(context: context)
        let convKey = PeerID(str: "nostr_abcdef12")
        let senderPubkey = "feedface00112233"
        context.displayNamesByPubkey[senderPubkey] = "alice#1234"
        context.privateChats[convKey] = [
            makeIncomingMessage(id: "mine-1", sender: "me"),
            makeIncomingMessage(id: "mine-2", sender: "me")
        ]

        coordinator.handleDelivered(
            NoisePayload(type: .delivered, data: Data("mine-1".utf8)),
            senderPubkey: senderPubkey,
            convKey: convKey
        )
        #expect(isDelivered(context.privateChats[convKey]?.first?.deliveryStatus, to: "alice#1234"))
        #expect(context.notifyUIChangedCount == 1)

        coordinator.handleReadReceipt(
            NoisePayload(type: .readReceipt, data: Data("mine-2".utf8)),
            senderPubkey: senderPubkey,
            convKey: convKey
        )
        #expect(isRead(context.privateChats[convKey]?.last?.deliveryStatus, by: "alice#1234"))
        #expect(context.notifyUIChangedCount == 2)

        // Unknown message id: no state change, no UI notification.
        coordinator.handleDelivered(
            NoisePayload(type: .delivered, data: Data("missing".utf8)),
            senderPubkey: senderPubkey,
            convKey: convKey
        )
        #expect(context.notifyUIChangedCount == 2)
    }

    @Test @MainActor
    func geoPrivateMessage_sendsDeliveryAckOnceAndDeduplicates() async {
        let context = MockChatPrivateConversationContext()
        let coordinator = ChatPrivateConversationCoordinator(context: context)
        let convKey = PeerID(str: "nostr_abcdef12")
        let senderPubkey = "feedface00112233"
        context.displayNamesByPubkey[senderPubkey] = "bob#5678"
        let payloadData = PrivateMessagePacket(messageID: "geo-1", content: "hi there").encode()!
        let payload = NoisePayload(type: .privateMessage, data: payloadData)
        // Old timestamp: not "recent", so no unread marking (and no notification).
        let oldTimestamp = Date().addingTimeInterval(-120)

        coordinator.handlePrivateMessage(
            payload,
            senderPubkey: senderPubkey,
            convKey: convKey,
            id: MockChatPrivateConversationContext.dummyIdentity,
            messageTimestamp: oldTimestamp
        )

        #expect(context.geoDeliveryAcks.map(\.messageID) == ["geo-1"])
        #expect(context.geoDeliveryAcks.first?.recipientHex == senderPubkey)
        #expect(context.sentGeoDeliveryAcks == ["geo-1"])
        #expect(context.privateChats[convKey]?.map(\.id) == ["geo-1"])
        #expect(context.privateChats[convKey]?.first?.sender == "bob#5678")
        #expect(context.unreadPrivateMessages.isEmpty)
        #expect(context.notifyUIChangedCount == 1)

        // Redelivery: ack is deduplicated and the message is not appended twice.
        coordinator.handlePrivateMessage(
            payload,
            senderPubkey: senderPubkey,
            convKey: convKey,
            id: MockChatPrivateConversationContext.dummyIdentity,
            messageTimestamp: oldTimestamp
        )
        #expect(context.geoDeliveryAcks.count == 1)
        #expect(context.privateChats[convKey]?.count == 1)
    }

    @Test @MainActor
    func handleViewingThisChat_clearsUnreadAndSendsRoutedReadReceiptOnce() async {
        let context = MockChatPrivateConversationContext()
        let coordinator = ChatPrivateConversationCoordinator(context: context)
        let noiseKey = Data(repeating: 0xAB, count: 32)
        let stablePeerID = PeerID(hexData: noiseKey)
        let ephemeralPeerID = PeerID(str: "0102030405060708")
        context.ephemeralPeerIDsByNoiseKey[noiseKey] = ephemeralPeerID
        context.unreadPrivateMessages = [stablePeerID, ephemeralPeerID]
        let message = makeIncomingMessage(id: "read-1", senderPeerID: stablePeerID)

        coordinator.handleViewingThisChat(
            message,
            targetPeerID: stablePeerID,
            key: noiseKey,
            senderPubkey: "feedface00112233"
        )

        #expect(context.unreadPrivateMessages.isEmpty)
        #expect(context.routedReadReceipts.map(\.messageID) == ["read-1"])
        #expect(context.routedReadReceipts.first?.peerID == stablePeerID)
        #expect(context.sentReadReceipts == ["read-1"])

        // Already-acked message must not produce a second receipt.
        coordinator.handleViewingThisChat(
            message,
            targetPeerID: stablePeerID,
            key: noiseKey,
            senderPubkey: "feedface00112233"
        )
        #expect(context.routedReadReceipts.count == 1)

        // Without a Noise key, the receipt goes out via the geohash transport.
        context.sentReadReceipts = []
        coordinator.handleViewingThisChat(
            message,
            targetPeerID: stablePeerID,
            key: nil,
            senderPubkey: "feedface00112233"
        )
        #expect(context.geoReadReceipts.map(\.messageID) == ["read-1"])
        #expect(context.sentReadReceipts == ["read-1"])
    }

    @Test @MainActor
    func markAsUnread_tracksTargetAndEphemeralWithoutNotificationWhenStale() async {
        let context = MockChatPrivateConversationContext()
        let coordinator = ChatPrivateConversationCoordinator(context: context)
        let noiseKey = Data(repeating: 0xCD, count: 32)
        let stablePeerID = PeerID(hexData: noiseKey)
        let ephemeralPeerID = PeerID(str: "1112131415161718")
        context.ephemeralPeerIDsByNoiseKey[noiseKey] = ephemeralPeerID

        // isRecentMessage false keeps the flow off the NotificationService singleton.
        coordinator.markAsUnreadIfNeeded(
            shouldMarkAsUnread: true,
            targetPeerID: stablePeerID,
            key: noiseKey,
            isRecentMessage: false,
            senderNickname: "alice",
            messageContent: "hello"
        )
        #expect(context.unreadPrivateMessages == [stablePeerID, ephemeralPeerID])

        context.unreadPrivateMessages = []
        coordinator.markAsUnreadIfNeeded(
            shouldMarkAsUnread: false,
            targetPeerID: stablePeerID,
            key: noiseKey,
            isRecentMessage: false,
            senderNickname: "alice",
            messageContent: "hello"
        )
        #expect(context.unreadPrivateMessages.isEmpty)
    }

    @Test @MainActor
    func migratePrivateChats_movesMessagesOnFingerprintMatchAndClearsOldPeer() async {
        let context = MockChatPrivateConversationContext()
        let coordinator = ChatPrivateConversationCoordinator(context: context)
        let oldPeerID = PeerID(str: "aaaaaaaaaaaaaaaa")
        let newPeerID = PeerID(str: "bbbbbbbbbbbbbbbb")
        context.fingerprintsByPeerID[oldPeerID] = "fp-1"
        context.fingerprintsByPeerID[newPeerID] = "fp-1"
        let older = makeIncomingMessage(id: "old-1", timestamp: Date().addingTimeInterval(-60))
        let newer = makeIncomingMessage(id: "old-2", timestamp: Date().addingTimeInterval(-30))
        context.privateChats[oldPeerID] = [newer, older]
        context.unreadPrivateMessages = [oldPeerID]
        context.selectedPrivateChatPeer = oldPeerID

        coordinator.migratePrivateChatsIfNeeded(for: newPeerID, senderNickname: "alice")

        #expect(context.privateChats[oldPeerID] == nil)
        #expect(context.privateChats[newPeerID]?.map(\.id) == ["old-1", "old-2"])
        #expect(context.unreadPrivateMessages.isEmpty)
        #expect(context.clearedFingerprints == [oldPeerID])
        #expect(context.selectedPrivateChatPeer == newPeerID)
        // The wholesale move went through the store's migrate intent.
        #expect(context.migratedChats.map(\.from) == [oldPeerID])
        #expect(context.migratedChats.map(\.to) == [newPeerID])
        #expect(context.notifyUIChangedCount == 1)
    }

    @Test @MainActor
    func handlePrivateMessage_postsNotificationOnlyWhenNotViewingChat() async {
        let context = MockChatPrivateConversationContext()
        let coordinator = ChatPrivateConversationCoordinator(context: context)
        let peerID = PeerID(str: "0102030405060708")

        // Not viewing: marked unread and a local notification is posted.
        coordinator.handlePrivateMessage(
            makeIncomingMessage(id: "pm-1", content: "hi there", senderPeerID: peerID)
        )
        #expect(context.unreadPrivateMessages == [peerID])
        #expect(context.privateMessageNotifications.count == 1)
        #expect(context.privateMessageNotifications.first?.senderName == "alice")
        #expect(context.privateMessageNotifications.first?.message == "hi there")
        #expect(context.privateMessageNotifications.first?.peerID == peerID)
        #expect(context.meshReadReceipts.isEmpty)

        // Viewing the chat: a READ ack is sent instead and no notification fires.
        context.selectedPrivateChatPeer = peerID
        coordinator.handlePrivateMessage(makeIncomingMessage(id: "pm-2", senderPeerID: peerID))
        #expect(context.meshReadReceipts.map(\.messageID) == ["pm-2"])
        #expect(context.sentReadReceipts.contains("pm-2"))
        #expect(context.privateMessageNotifications.count == 1)
    }

    @Test @MainActor
    func handleFavoriteNotification_persistsAndAnnouncesTransitionsOnly() async {
        let context = MockChatPrivateConversationContext()
        let coordinator = ChatPrivateConversationCoordinator(context: context)
        let noiseKey = Data(repeating: 0xAB, count: 32)
        let peerID = PeerID(hexData: noiseKey)

        // First [FAVORITED] flips theyFavoritedUs: store write + announcement.
        coordinator.handleFavoriteNotification("[FAVORITED]:npub1alice", from: peerID, senderNickname: "alice")
        #expect(context.peerFavoritedUsUpdates.count == 1)
        #expect(context.peerFavoritedUsUpdates.first?.noiseKey == noiseKey)
        #expect(context.peerFavoritedUsUpdates.first?.favorited == true)
        #expect(context.peerFavoritedUsUpdates.first?.nostrPublicKey == "npub1alice")
        #expect(context.meshOnlySystemMessages == ["alice favorited you"])

        // Same state again: store write still happens, but no repeat announcement.
        context.favoriteRelationshipsByNoiseKey[noiseKey] = makeFavoriteRelationship(
            noiseKey: noiseKey,
            theyFavoritedUs: true
        )
        coordinator.handleFavoriteNotification("[FAVORITED]:npub1alice", from: peerID, senderNickname: "alice")
        #expect(context.peerFavoritedUsUpdates.count == 2)
        #expect(context.meshOnlySystemMessages == ["alice favorited you"])

        // [UNFAVORITED] transition announces again.
        coordinator.handleFavoriteNotification("[UNFAVORITED]", from: peerID, senderNickname: "alice")
        #expect(context.peerFavoritedUsUpdates.last?.favorited == false)
        #expect(context.meshOnlySystemMessages == ["alice favorited you", "alice unfavorited you"])
    }

    /// A Nostr DM whose sender resolved to a known noise key must be labeled
    /// with the favorite's nickname, not the geohash-scoped anon fallback.
    @Test @MainActor
    func nostrPrivateMessage_noiseKeyedConversationUsesFavoriteNickname() async {
        let context = MockChatPrivateConversationContext()
        let coordinator = ChatPrivateConversationCoordinator(context: context)
        let noiseKey = Data(repeating: 0xDA, count: 32)
        let convKey = PeerID(hexData: noiseKey)
        let senderPubkey = "0badc0de00112233"
        // No displayNamesByPubkey entry: the geo fallback would be "anon".
        context.favoriteRelationshipsByNoiseKey[noiseKey] = makeFavoriteRelationship(
            noiseKey: noiseKey,
            nostrPublicKey: "npub1bob",
            nickname: "bob",
            isFavorite: true,
            theyFavoritedUs: true
        )

        let payloadData = PrivateMessagePacket(messageID: "nostr-dm-1", content: "hello from afar").encode()!
        let payload = NoisePayload(type: .privateMessage, data: payloadData)

        coordinator.handlePrivateMessage(
            payload,
            senderPubkey: senderPubkey,
            convKey: convKey,
            id: MockChatPrivateConversationContext.dummyIdentity,
            messageTimestamp: Date()
        )

        #expect(context.privateChats[convKey]?.first?.sender == "bob")
    }

    /// Over Nostr, [FAVORITED] markers arrive as embedded PMs on the convKey
    /// path; they must update the relationship, not render as chat text.
    @Test @MainActor
    func nostrPrivateMessage_favoritedMarkerUpdatesRelationshipInsteadOfAppending() async {
        let context = MockChatPrivateConversationContext()
        let coordinator = ChatPrivateConversationCoordinator(context: context)
        let noiseKey = Data(repeating: 0xEE, count: 32)
        // The inbound pipeline resolves known favorites to their noise-key ID.
        let convKey = PeerID(hexData: noiseKey)
        let senderPubkey = "feedface99887766"
        context.displayNamesByPubkey[senderPubkey] = "alice#1234"

        let payloadData = PrivateMessagePacket(messageID: "fav-1", content: "[FAVORITED]:npub1alice").encode()!
        let payload = NoisePayload(type: .privateMessage, data: payloadData)

        coordinator.handlePrivateMessage(
            payload,
            senderPubkey: senderPubkey,
            convKey: convKey,
            id: MockChatPrivateConversationContext.dummyIdentity,
            messageTimestamp: Date()
        )

        #expect(context.peerFavoritedUsUpdates.count == 1)
        #expect(context.peerFavoritedUsUpdates.first?.noiseKey == noiseKey)
        #expect(context.peerFavoritedUsUpdates.first?.favorited == true)
        #expect(context.peerFavoritedUsUpdates.first?.nostrPublicKey == "npub1alice")
        #expect(context.privateChats[convKey, default: []].isEmpty)
        #expect(context.meshOnlySystemMessages == ["alice#1234 favorited you"])
    }

    @Test @MainActor
    func sendPrivateMessage_routesViaMutualFavoriteNostrWhenPeerOffline() async {
        let context = MockChatPrivateConversationContext()
        let coordinator = ChatPrivateConversationCoordinator(context: context)
        let noiseKey = Data(repeating: 0xCD, count: 32)
        let peerID = PeerID(hexData: noiseKey)
        context.favoriteRelationshipsByNoiseKey[noiseKey] = makeFavoriteRelationship(
            noiseKey: noiseKey,
            nostrPublicKey: "npub1bob",
            nickname: "bob",
            isFavorite: true,
            theyFavoritedUs: true
        )

        coordinator.sendPrivateMessage("hello bob", to: peerID)

        // Offline but mutual favorite with a Nostr key: routed, marked sent,
        // and the nickname falls back to the favorite relationship.
        #expect(context.routedPrivateMessages.map(\.content) == ["hello bob"])
        #expect(context.privateChats[peerID]?.first?.deliveryStatus == .sent)
        #expect(context.privateChats[peerID]?.first?.recipientNickname == "bob")
    }

    /// Same as above, but the conversation is keyed by the SHORT mesh ID —
    /// the DM window was opened while the peer was on mesh, then they went
    /// out of range. The favorite must resolve via the derived short ID and
    /// route over Nostr instead of failing "peer not reachable".
    @Test @MainActor
    func sendPrivateMessage_routesViaNostrWhenMeshKeyedPeerGoesOffline() async {
        let context = MockChatPrivateConversationContext()
        let coordinator = ChatPrivateConversationCoordinator(context: context)
        let noiseKey = Data(repeating: 0xCE, count: 32)
        let shortID = PeerID(publicKey: noiseKey)
        context.favoriteRelationshipsByNoiseKey[noiseKey] = makeFavoriteRelationship(
            noiseKey: noiseKey,
            nostrPublicKey: "npub1bob",
            nickname: "bob",
            isFavorite: true,
            theyFavoritedUs: true
        )

        coordinator.sendPrivateMessage("hello again", to: shortID)

        #expect(context.routedPrivateMessages.map(\.content) == ["hello again"])
        #expect(context.privateChats[shortID]?.first?.deliveryStatus == .sent)
        #expect(context.privateChats[shortID]?.first?.recipientNickname == "bob")
    }

    /// Field-found: pre-judging reachability here marked the message failed
    /// without ever routing it, so the router's retained outbox, courier
    /// deposits, and bridge drops never got a chance. A fully unreachable
    /// non-favorite must still be routed and stay "sending" (the router's
    /// callbacks later move it to carried/delivered or expire it as failed).
    @Test @MainActor
    func sendPrivateMessage_routesAndStaysSendingWhenOfflineWithoutMutualFavorite() async {
        let context = MockChatPrivateConversationContext()
        let coordinator = ChatPrivateConversationCoordinator(context: context)
        let peerID = PeerID(hexData: Data(repeating: 0xCD, count: 32))

        coordinator.sendPrivateMessage("hello?", to: peerID)

        #expect(context.routedPrivateMessages.map(\.content) == ["hello?"])
        #expect(context.privateChats[peerID]?.first?.deliveryStatus == .sending)
    }
}
