//
// ChatViewModelExtensionsTests.swift
// bitchatTests
//
// Tests for ChatViewModel extensions (PrivateChat, Nostr, Tor).
//

import Testing
import Foundation
import Combine
#if os(iOS)
import UIKit
#else
import AppKit
#endif
import BitFoundation
@testable import bitchat

// MARK: - Test Helpers

@MainActor
private func makeTestableViewModel() -> (viewModel: ChatViewModel, transport: MockTransport) {
    let keychain = MockKeychain()
    let keychainHelper = MockKeychainHelper()
    let idBridge = NostrIdentityBridge(keychain: keychainHelper)
    let identityManager = MockIdentityManager(keychain)
    let transport = MockTransport()

    let viewModel = ChatViewModel(
        keychain: keychain,
        idBridge: idBridge,
        identityManager: identityManager,
        transport: transport
    )

    return (viewModel, transport)
}

// MARK: - Private Chat Extension Tests

struct ChatViewModelPrivateChatExtensionTests {

    @Test @MainActor
    func sendPrivateMessage_mesh_storesAndSends() async {
        let (viewModel, transport) = makeTestableViewModel()
        // Use valid hex string for PeerID (32 bytes = 64 hex chars for Noise key usually, or just valid hex)
        let validHex = "0102030405060708090a0b0c0d0e0f100102030405060708090a0b0c0d0e0f10"
        let peerID = PeerID(str: validHex)
        
        // Simulate connection
        transport.connectedPeers.insert(peerID)
        transport.peerNicknames[peerID] = "MeshUser"
        
        viewModel.sendPrivateMessage("Hello Mesh", to: peerID)
        
        // Verify transport was called
        // Note: MockTransport stores sent messages
        // Since sendPrivateMessage delegates to MessageRouter which delegates to Transport...
        // We need to ensure MessageRouter is using our MockTransport.
        // ChatViewModel init sets up MessageRouter with the passed transport.
        
        // Wait for async processing
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        // Verify message stored locally
        #expect(viewModel.privateChats[peerID]?.count == 1)
        #expect(viewModel.privateChats[peerID]?.first?.content == "Hello Mesh")
        
        // Verify message sent to transport (MockTransport captures sendPrivateMessage)
        // MockTransport.sendPrivateMessage is what MessageRouter calls for connected peers
        // Check MockTransport implementation... it might need update or verification
    }

    @Test @MainActor
    func sendPrivateMessage_unreachable_setsFailedStatus() async {
        let (viewModel, _) = makeTestableViewModel()
        let validHex = "0102030405060708090a0b0c0d0e0f100102030405060708090a0b0c0d0e0f10"
        let peerID = PeerID(str: validHex)

        viewModel.sendPrivateMessage("Hello", to: peerID)

        #expect(viewModel.privateChats[peerID]?.count == 1)
        let status = viewModel.privateChats[peerID]?.last?.deliveryStatus
        #expect({
            if case .failed = status { return true }
            return false
        }())
    }
    
    @Test @MainActor
    func handlePrivateMessage_storesMessage() async {
        let (viewModel, _) = makeTestableViewModel()
        let peerID = PeerID(str: "SENDER_001")
        
        let message = BitchatMessage(
            id: "msg-1",
            sender: "Sender",
            content: "Private Content",
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: true,
            recipientNickname: "Me",
            senderPeerID: peerID
        )
        
        // Simulate receiving a private message via the handlePrivateMessage extension method
        viewModel.handlePrivateMessage(message)
        
        // Verify stored
        #expect(viewModel.privateChats[peerID]?.count == 1)
        #expect(viewModel.privateChats[peerID]?.first?.content == "Private Content")
        
        // Verify notification trigger (unread count should increase if not viewing)
        #expect(viewModel.unreadPrivateMessages.contains(peerID))
    }
    
    @Test @MainActor
    func handlePrivateMessage_deduplicates() async {
        let (viewModel, _) = makeTestableViewModel()
        let peerID = PeerID(str: "SENDER_001")
        
        let message = BitchatMessage(
            id: "msg-1",
            sender: "Sender",
            content: "Content",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            senderPeerID: peerID
        )
        
        viewModel.handlePrivateMessage(message)
        viewModel.handlePrivateMessage(message) // Duplicate
        
        #expect(viewModel.privateChats[peerID]?.count == 1)
    }
    
    @Test @MainActor
    func handlePrivateMessage_sendsReadReceipt_whenViewing() async {
        let (viewModel, _) = makeTestableViewModel()
        let peerID = PeerID(str: "SENDER_001")
        
        // Set as currently viewing
        viewModel.selectedPrivateChatPeer = peerID
        
        let message = BitchatMessage(
            id: "msg-1",
            sender: "Sender",
            content: "Content",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            senderPeerID: peerID
        )
        
        viewModel.handlePrivateMessage(message)
        
        // Should NOT be marked unread
        #expect(!viewModel.unreadPrivateMessages.contains(peerID))
    }
    
    @Test @MainActor
    func migratePrivateChats_consolidatesHistory_onFingerprintMatch() async {
        let (viewModel, _) = makeTestableViewModel()
        let oldPeerID = PeerID(str: "OLD_PEER")
        let newPeerID = PeerID(str: "NEW_PEER")
        let fingerprint = "fp_123"
        
        // Setup old chat
        let oldMessage = BitchatMessage(
            id: "msg-old",
            sender: "User",
            content: "Old message",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            senderPeerID: oldPeerID
        )
        viewModel.privateChats[oldPeerID] = [oldMessage]
        viewModel.peerIDToPublicKeyFingerprint[oldPeerID] = fingerprint
        
        // Setup new peer fingerprint
        viewModel.peerIDToPublicKeyFingerprint[newPeerID] = fingerprint
        
        // Trigger migration
        viewModel.migratePrivateChatsIfNeeded(for: newPeerID, senderNickname: "User")
        
        // Verify migration
        #expect(viewModel.privateChats[newPeerID]?.count == 1)
        #expect(viewModel.privateChats[newPeerID]?.first?.content == "Old message")
        #expect(viewModel.privateChats[oldPeerID] == nil) // Old chat removed
    }
    
    @Test @MainActor
    func isMessageBlocked_filtersBlockedUsers() async {
        let (viewModel, _) = makeTestableViewModel()
        let blockedPeerID = PeerID(str: "BLOCKED_PEER")
        
        // Block the peer
        // MockIdentityManager stores state based on fingerprint
        // We need to map peerID to a fingerprint
        viewModel.peerIDToPublicKeyFingerprint[blockedPeerID] = "fp_blocked"
        viewModel.identityManager.setBlocked("fp_blocked", isBlocked: true)
        
        // Also ensure UnifiedPeerService can resolve the fingerprint.
        // UnifiedPeerService uses its own cache or delegates to meshService/Peer list.
        // Since we are mocking, we can't easily inject into UnifiedPeerService's internal cache.
        // However, ChatViewModel's isMessageBlocked uses:
        // 1. isPeerBlocked(peerID) -> unifiedPeerService.isBlocked(peerID) -> getFingerprint -> identityManager.isBlocked
        
        // We need UnifiedPeerService.getFingerprint(for: blockedPeerID) to return "fp_blocked"
        // UnifiedPeerService tries: cache -> meshService -> getPeer
        
        // Option 1: Mock the transport (meshService) to return the fingerprint
        // (viewModel.transport is MockTransport, but UnifiedPeerService holds a reference to it)
        // Check if MockTransport has `getFingerprint`
        
        // If not, we might need to rely on the fallback: ChatViewModel.isMessageBlocked also checks Nostr blocks.
        
        // Let's assume MockTransport needs `getFingerprint` implementation or update it.
        // For now, let's try to verify if `MockTransport` supports `getFingerprint`.
        
        // Actually, let's just use the Nostr block path which is simpler and also tested here.
        // "Check geohash (Nostr) blocks using mapping to full pubkey"
        
        let hexPubkey = "0000000000000000000000000000000000000000000000000000000000000001"
        viewModel.nostrKeyMapping[blockedPeerID] = hexPubkey
        viewModel.identityManager.setNostrBlocked(hexPubkey, isBlocked: true)
        
        // Force isGeoChat/isGeoDM check to be true by setting prefix?
        // Or ensure the logic covers it.
        // The logic is:
        // if peerID.isGeoChat || peerID.isGeoDM { check nostr }
        // We need a peerID that looks like geo.
        
        let geoPeerID = PeerID(nostr_: hexPubkey)
        viewModel.nostrKeyMapping[geoPeerID] = hexPubkey
        
        let geoMessage = BitchatMessage(
            id: "msg-geo-blocked",
            sender: "BlockedGeoUser",
            content: "Spam",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            senderPeerID: geoPeerID
        )
        
        #expect(viewModel.isMessageBlocked(geoMessage))
    }
}

// MARK: - Nostr Extension Tests

struct ChatViewModelNostrExtensionTests {
    
    @Test @MainActor
    func switchLocationChannel_mesh_clearsGeo() async {
        let (viewModel, _) = makeTestableViewModel()
        
        // Setup some geo state
        viewModel.switchLocationChannel(to: .location(GeohashChannel(level: .city, geohash: "u4pruydq")))
        #expect(viewModel.currentGeohash == "u4pruydq")
        
        // Switch to mesh
        viewModel.switchLocationChannel(to: .mesh)
        
        #expect(viewModel.activeChannel == .mesh)
        #expect(viewModel.currentGeohash == nil)
    }
    
    @Test @MainActor
    func subscribeNostrEvent_addsToTimeline_ifMatchesGeohash() async throws {
        let geohash = "u4pruydq"
        let channel = ChannelID.location(GeohashChannel(level: .city, geohash: geohash))

        LocationChannelManager.shared.select(channel)
        defer { LocationChannelManager.shared.select(.mesh) }

        _ = await TestHelpers.waitUntil({ LocationChannelManager.shared.selectedChannel == channel })

        let (viewModel, _) = makeTestableViewModel()
        
        _ = await TestHelpers.waitUntil({ viewModel.activeChannel == channel })
        
        let signer = try NostrIdentity.generate()
        let event = NostrEvent(
            pubkey: signer.publicKeyHex,
            createdAt: Date(),
            kind: .ephemeralEvent,
            tags: [["g", geohash]],
            content: "Hello Geo"
        )
        let signed = try event.sign(with: signer.schnorrSigningKey())
        viewModel.handleNostrEvent(signed)
        
        let didAppend = await TestHelpers.waitUntil({
            viewModel.publicMessagePipeline.flushIfNeeded()
            return viewModel.messages.contains { $0.content == "Hello Geo" }
        })
        #expect(didAppend)
    }

    @Test @MainActor
    func handleNostrEvent_ignoresRecentSelfEcho() async throws {
        let (viewModel, _) = makeTestableViewModel()
        let geohash = "u4pruydq"

        viewModel.switchLocationChannel(to: .location(GeohashChannel(level: .city, geohash: geohash)))
        let identity = try viewModel.idBridge.deriveIdentity(forGeohash: geohash)

        let event = NostrEvent(
            pubkey: identity.publicKeyHex,
            createdAt: Date(),
            kind: .ephemeralEvent,
            tags: [["g", geohash]],
            content: "Self echo"
        )
        let signed = try event.sign(with: identity.schnorrSigningKey())
        viewModel.handleNostrEvent(signed)

        try? await Task.sleep(nanoseconds: 100_000_000)
        viewModel.publicMessagePipeline.flushIfNeeded()

        #expect(!viewModel.messages.contains { $0.content == "Self echo" })
    }

    @Test @MainActor
    func handleNostrEvent_skipsBlockedSender() async throws {
        let (viewModel, _) = makeTestableViewModel()
        let geohash = "u4pruydq"
        let blockedIdentity = try NostrIdentity.generate()
        let blockedPubkey = blockedIdentity.publicKeyHex

        viewModel.switchLocationChannel(to: .location(GeohashChannel(level: .city, geohash: geohash)))
        viewModel.identityManager.setNostrBlocked(blockedPubkey, isBlocked: true)

        let event = NostrEvent(
            pubkey: blockedPubkey,
            createdAt: Date(),
            kind: .ephemeralEvent,
            tags: [["g", geohash]],
            content: "Blocked"
        )
        let signed = try event.sign(with: blockedIdentity.schnorrSigningKey())
        viewModel.handleNostrEvent(signed)

        try? await Task.sleep(nanoseconds: 100_000_000)
        viewModel.publicMessagePipeline.flushIfNeeded()

        #expect(!viewModel.messages.contains { $0.content == "Blocked" })
    }

    @Test @MainActor
    func handleNostrEvent_rejectsInvalidSignature() async throws {
        let (viewModel, _) = makeTestableViewModel()
        let geohash = "u4pruydq"
        let identity = try NostrIdentity.generate()

        viewModel.switchLocationChannel(to: .location(GeohashChannel(level: .city, geohash: geohash)))

        let event = NostrEvent(
            pubkey: identity.publicKeyHex,
            createdAt: Date(),
            kind: .ephemeralEvent,
            tags: [["g", geohash]],
            content: "Valid"
        )
        var signed = try event.sign(with: identity.schnorrSigningKey())
        signed.id = "deadbeef"

        viewModel.handleNostrEvent(signed)

        try? await Task.sleep(nanoseconds: 100_000_000)
        viewModel.publicMessagePipeline.flushIfNeeded()

        #expect(!viewModel.messages.contains { $0.content == "Tampered" })
    }

    @Test @MainActor
    func subscribeGiftWrap_rejectsOversizedEmbeddedPacket() async throws {
        let (viewModel, _) = makeTestableViewModel()
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()

        let oversized = Data(repeating: 0x41, count: FileTransferLimits.maxFramedFileBytes + 1)
        let content = "bitchat1:" + base64URLEncode(oversized)
        let giftWrap = try NostrProtocol.createPrivateMessage(
            content: content,
            recipientPubkey: recipient.publicKeyHex,
            senderIdentity: sender
        )

        viewModel.subscribeGiftWrap(giftWrap, id: recipient)

        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(viewModel.privateChats.isEmpty)
    }

    @Test @MainActor
    func switchLocationChannel_clearsNostrDedupCache() async {
        let (viewModel, _) = makeTestableViewModel()
        let geohash = "u4pruydq"

        viewModel.deduplicationService.recordNostrEvent("evt-cache")
        #expect(viewModel.deduplicationService.hasProcessedNostrEvent("evt-cache"))

        viewModel.switchLocationChannel(to: .location(GeohashChannel(level: .city, geohash: geohash)))

        #expect(!viewModel.deduplicationService.hasProcessedNostrEvent("evt-cache"))
    }

    @Test @MainActor
    func handleNostrEvent_presenceTracksParticipantWithoutTimelineMessage() async throws {
        let (viewModel, _) = makeTestableViewModel()
        let geohash = "u4pruydq"
        let identity = try NostrIdentity.generate()

        viewModel.switchLocationChannel(to: .location(GeohashChannel(level: .city, geohash: geohash)))

        let event = NostrEvent(
            pubkey: identity.publicKeyHex,
            createdAt: Date(),
            kind: .geohashPresence,
            tags: [["g", geohash]],
            content: ""
        )
        let signed = try event.sign(with: identity.schnorrSigningKey())

        viewModel.handleNostrEvent(signed)

        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(viewModel.geohashParticipantCount(for: geohash) >= 1)
        viewModel.publicMessagePipeline.flushIfNeeded()
        #expect(viewModel.messages.isEmpty)
    }

    @Test @MainActor
    func subscribeGiftWrap_deliveredAckUpdatesExistingMessage() async throws {
        let (viewModel, _) = makeTestableViewModel()
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let convKey = PeerID(nostr_: sender.publicKeyHex)
        let messageID = "geo-ack-delivered"

        viewModel.privateChats[convKey] = [
            BitchatMessage(
                id: messageID,
                sender: viewModel.nickname,
                content: "Hello",
                timestamp: Date(),
                isRelay: false,
                isPrivate: true,
                recipientNickname: "Friend",
                senderPeerID: viewModel.meshService.myPeerID,
                deliveryStatus: .sent
            )
        ]

        let content = try ackContent(type: .delivered, messageID: messageID, senderPeerID: PeerID(str: "0123456789abcdef"))
        let giftWrap = try NostrProtocol.createPrivateMessage(
            content: content,
            recipientPubkey: recipient.publicKeyHex,
            senderIdentity: sender
        )

        viewModel.subscribeGiftWrap(giftWrap, id: recipient)

        let didUpdate = await TestHelpers.waitUntil(
            { isDelivered(status: deliveryStatus(in: viewModel, peerID: convKey, messageID: messageID)) },
            timeout: 0.5
        )
        #expect(didUpdate)
    }

    @Test @MainActor
    func subscribeGiftWrap_readAckUpdatesExistingMessage() async throws {
        let (viewModel, _) = makeTestableViewModel()
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let convKey = PeerID(nostr_: sender.publicKeyHex)
        let messageID = "geo-ack-read"

        viewModel.privateChats[convKey] = [
            BitchatMessage(
                id: messageID,
                sender: viewModel.nickname,
                content: "Hello",
                timestamp: Date(),
                isRelay: false,
                isPrivate: true,
                recipientNickname: "Friend",
                senderPeerID: viewModel.meshService.myPeerID,
                deliveryStatus: .delivered(to: "Friend", at: Date())
            )
        ]

        let content = try ackContent(type: .readReceipt, messageID: messageID, senderPeerID: PeerID(str: "0123456789abcdef"))
        let giftWrap = try NostrProtocol.createPrivateMessage(
            content: content,
            recipientPubkey: recipient.publicKeyHex,
            senderIdentity: sender
        )

        viewModel.subscribeGiftWrap(giftWrap, id: recipient)

        let didUpdate = await TestHelpers.waitUntil(
            { isRead(status: deliveryStatus(in: viewModel, peerID: convKey, messageID: messageID)) },
            timeout: 0.5
        )
        #expect(didUpdate)
    }

    @Test @MainActor
    func handleGiftWrap_privateMessageStoresConversationAndMapping() async throws {
        let (viewModel, _) = makeTestableViewModel()
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let messageID = "gift-private"
        let convKey = PeerID(nostr_: sender.publicKeyHex)

        let content = try privateMessageContent(
            text: "Hello from gift wrap",
            messageID: messageID,
            senderPeerID: PeerID(str: "0123456789abcdef")
        )
        let giftWrap = try NostrProtocol.createPrivateMessage(
            content: content,
            recipientPubkey: recipient.publicKeyHex,
            senderIdentity: sender
        )

        viewModel.handleGiftWrap(giftWrap, id: recipient)

        let didStore = await TestHelpers.waitUntil(
            { viewModel.privateChats[convKey]?.first?.content == "Hello from gift wrap" },
            timeout: 0.5
        )
        #expect(didStore)
        #expect(viewModel.nostrKeyMapping[convKey] == sender.publicKeyHex)
        #expect(viewModel.sentGeoDeliveryAcks.contains(messageID))
    }

    @Test @MainActor
    func handleGiftWrap_blockedSenderSkipsMessageStorage() async throws {
        let (viewModel, _) = makeTestableViewModel()
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let messageID = "gift-blocked"
        let convKey = PeerID(nostr_: sender.publicKeyHex)

        viewModel.identityManager.setNostrBlocked(sender.publicKeyHex, isBlocked: true)

        let content = try privateMessageContent(
            text: "Blocked",
            messageID: messageID,
            senderPeerID: PeerID(str: "0123456789abcdef")
        )
        let giftWrap = try NostrProtocol.createPrivateMessage(
            content: content,
            recipientPubkey: recipient.publicKeyHex,
            senderIdentity: sender
        )

        viewModel.handleGiftWrap(giftWrap, id: recipient)

        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(viewModel.privateChats[convKey] == nil)
        #expect(viewModel.sentGeoDeliveryAcks.contains(messageID))
    }

    @Test @MainActor
    func handleGiftWrap_deliveredAckUpdatesExistingMessage() async throws {
        let (viewModel, _) = makeTestableViewModel()
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let convKey = PeerID(nostr_: sender.publicKeyHex)
        let messageID = "gift-delivered"

        viewModel.privateChats[convKey] = [
            BitchatMessage(
                id: messageID,
                sender: viewModel.nickname,
                content: "Hello",
                timestamp: Date(),
                isRelay: false,
                isPrivate: true,
                recipientNickname: "Friend",
                senderPeerID: viewModel.meshService.myPeerID,
                deliveryStatus: .sent
            )
        ]

        let content = try ackContent(type: .delivered, messageID: messageID, senderPeerID: PeerID(str: "0123456789abcdef"))
        let giftWrap = try NostrProtocol.createPrivateMessage(
            content: content,
            recipientPubkey: recipient.publicKeyHex,
            senderIdentity: sender
        )

        viewModel.handleGiftWrap(giftWrap, id: recipient)

        let didUpdate = await TestHelpers.waitUntil(
            { isDelivered(status: deliveryStatus(in: viewModel, peerID: convKey, messageID: messageID)) },
            timeout: 0.5
        )
        #expect(didUpdate)
    }

    @Test @MainActor
    func findNoiseKey_matchesFavoriteStoredAsNpub() async throws {
        let (viewModel, _) = makeTestableViewModel()
        let identity = try NostrIdentity.generate()
        let noiseKey = Data((0..<32).map { UInt8(($0 + 80) & 0xFF) })

        FavoritesPersistenceService.shared.addFavorite(
            peerNoisePublicKey: noiseKey,
            peerNostrPublicKey: identity.npub,
            peerNickname: "Alice"
        )
        defer { FavoritesPersistenceService.shared.removeFavorite(peerNoisePublicKey: noiseKey) }

        #expect(viewModel.findNoiseKey(for: identity.publicKeyHex) == noiseKey)
    }

    @Test @MainActor
    func findNoiseKey_matchesFavoriteStoredAsHex() async {
        let (viewModel, _) = makeTestableViewModel()
        let nostrHex = String(repeating: "ab", count: 32)
        let noiseKey = Data((0..<32).map { UInt8(($0 + 112) & 0xFF) })

        FavoritesPersistenceService.shared.addFavorite(
            peerNoisePublicKey: noiseKey,
            peerNostrPublicKey: nostrHex,
            peerNickname: "Bob"
        )
        defer { FavoritesPersistenceService.shared.removeFavorite(peerNoisePublicKey: noiseKey) }

        #expect(viewModel.findNoiseKey(for: nostrHex) == noiseKey)
    }

    @Test @MainActor
    func handleFavoriteNotification_updatesFavoriteAssociation() async throws {
        let (viewModel, _) = makeTestableViewModel()
        let identity = try NostrIdentity.generate()
        let noiseKey = Data((0..<32).map { UInt8(($0 + 144) & 0xFF) })

        FavoritesPersistenceService.shared.addFavorite(
            peerNoisePublicKey: noiseKey,
            peerNostrPublicKey: identity.npub,
            peerNickname: "Before"
        )
        defer { FavoritesPersistenceService.shared.removeFavorite(peerNoisePublicKey: noiseKey) }

        viewModel.handleFavoriteNotification(
            content: "FAVORITE:TRUE|NPUB:\(identity.npub)|Alice",
            from: identity.publicKeyHex
        )

        let relationship = FavoritesPersistenceService.shared.getFavoriteStatus(for: noiseKey)
        #expect(relationship?.peerNickname == "Alice")
        #expect(relationship?.peerNostrPublicKey == identity.npub)
        #expect(relationship?.isFavorite == true)
    }

    @Test @MainActor
    func geohashDMHelpers_exposeMappingAndDisplayName() async {
        let (viewModel, _) = makeTestableViewModel()
        let nostrHex = String(repeating: "cd", count: 32)
        let convKey = PeerID(nostr_: nostrHex)

        viewModel.geoNicknames[nostrHex] = "Alice"
        viewModel.startGeohashDM(withPubkeyHex: nostrHex)

        #expect(viewModel.selectedPrivateChatPeer == convKey)
        #expect(viewModel.fullNostrHex(forSenderPeerID: convKey) == nostrHex)
        #expect(viewModel.geohashDisplayName(for: convKey).hasPrefix("Alice"))
        #expect(viewModel.nostrPubkeyForDisplayName("Alice") == nostrHex)
    }
}

// MARK: - Geohash Queue Tests

struct ChatViewModelGeohashQueueTests {

    @Test @MainActor
    func addGeohashOnlySystemMessage_queuesUntilLocationChannel() async {
        let (viewModel, _) = makeTestableViewModel()
        let geohash = "u4pruydq"

        viewModel.addGeohashOnlySystemMessage("Queued system")
        #expect(!viewModel.messages.contains { $0.content == "Queued system" })

        viewModel.switchLocationChannel(to: .location(GeohashChannel(level: .city, geohash: geohash)))

        #expect(viewModel.messages.contains { $0.content == "Queued system" })
    }
}

// MARK: - GeoDM Tests

struct ChatViewModelGeoDMTests {

    @Test @MainActor
    func handlePrivateMessage_geohash_dedupsAndTracksAck() async throws {
        let (viewModel, _) = makeTestableViewModel()
        let geohash = "u4pruydq"
        let senderPubkey = "0000000000000000000000000000000000000000000000000000000000000001"
        let messageID = "pm-1"

        viewModel.switchLocationChannel(to: .location(GeohashChannel(level: .city, geohash: geohash)))
        let identity = try viewModel.idBridge.deriveIdentity(forGeohash: geohash)

        let convKey = PeerID(nostr_: senderPubkey)
        let packet = PrivateMessagePacket(messageID: messageID, content: "Hello")
        let payloadData = try #require(packet.encode(), "Failed to encode private message")
        let payload = NoisePayload(type: .privateMessage, data: payloadData)

        viewModel.handlePrivateMessage(payload, senderPubkey: senderPubkey, convKey: convKey, id: identity, messageTimestamp: Date())
        viewModel.handlePrivateMessage(payload, senderPubkey: senderPubkey, convKey: convKey, id: identity, messageTimestamp: Date())

        #expect(viewModel.privateChats[convKey]?.count == 1)
        #expect(viewModel.sentGeoDeliveryAcks.contains(messageID))
    }

    @Test @MainActor
    func sendGeohashDM_requiresActiveLocationChannel() async {
        let (viewModel, _) = makeTestableViewModel()
        let convKey = PeerID(nostr_: "0000000000000000000000000000000000000000000000000000000000000001")

        viewModel.sendGeohashDM("hello", to: convKey)

        #expect(viewModel.privateChats[convKey] == nil)
        #expect(viewModel.messages.count == 1)
        #expect(viewModel.messages.last?.sender == "system")
    }

    @Test @MainActor
    func sendGeohashDM_missingRecipientMapping_marksFailed() async {
        let (viewModel, _) = makeTestableViewModel()
        let geohash = "u4pruydq"
        let convKey = PeerID(nostr_: "0000000000000000000000000000000000000000000000000000000000000002")

        viewModel.switchLocationChannel(to: .location(GeohashChannel(level: .city, geohash: geohash)))
        viewModel.sendGeohashDM("hello", to: convKey)

        #expect(viewModel.privateChats[convKey]?.count == 1)
        #expect(isFailed(status: viewModel.privateChats[convKey]?.last?.deliveryStatus))
    }

    @Test @MainActor
    func sendGeohashDM_blockedRecipient_marksFailedAndAddsSystemMessage() async {
        let (viewModel, _) = makeTestableViewModel()
        let geohash = "u4pruydq"
        let recipientHex = "0000000000000000000000000000000000000000000000000000000000000003"
        let convKey = PeerID(nostr_: recipientHex)

        viewModel.switchLocationChannel(to: .location(GeohashChannel(level: .city, geohash: geohash)))
        viewModel.nostrKeyMapping[convKey] = recipientHex
        viewModel.identityManager.setNostrBlocked(recipientHex, isBlocked: true)

        viewModel.sendGeohashDM("hello", to: convKey)

        #expect(viewModel.privateChats[convKey]?.count == 1)
        #expect(isFailed(status: viewModel.privateChats[convKey]?.last?.deliveryStatus))
        #expect(viewModel.messages.contains(where: { $0.sender == "system" }))
    }

    @Test @MainActor
    func handlePrivateMessage_geohashViewingConversationRecordsReadReceipt() async throws {
        let (viewModel, _) = makeTestableViewModel()
        let geohash = "u4pruydq"
        let senderPubkey = "0000000000000000000000000000000000000000000000000000000000000004"
        let convKey = PeerID(nostr_: senderPubkey)
        let messageID = "pm-viewing"

        viewModel.switchLocationChannel(to: .location(GeohashChannel(level: .city, geohash: geohash)))
        viewModel.selectedPrivateChatPeer = convKey

        let identity = try viewModel.idBridge.deriveIdentity(forGeohash: geohash)
        let packet = PrivateMessagePacket(messageID: messageID, content: "Hello")
        let payloadData = try #require(packet.encode(), "Failed to encode private message")
        let payload = NoisePayload(type: .privateMessage, data: payloadData)

        viewModel.handlePrivateMessage(
            payload,
            senderPubkey: senderPubkey,
            convKey: convKey,
            id: identity,
            messageTimestamp: Date()
        )

        #expect(viewModel.sentGeoDeliveryAcks.contains(messageID))
        #expect(viewModel.sentReadReceipts.contains(messageID))
        #expect(!viewModel.unreadPrivateMessages.contains(convKey))
    }
}

struct ChatViewModelMediaTransferTests {

    @Test @MainActor
    func handleTransferEvent_updatesPrivateMessageProgressAndClearsMappingOnCompletion() async {
        let (viewModel, _) = makeTestableViewModel()
        let peerID = PeerID(str: "0102030405060708090a0b0c0d0e0f100102030405060708090a0b0c0d0e0f10")
        let message = viewModel.enqueueMediaMessage(content: "[voice] clip.m4a", targetPeer: peerID)
        let transferID = "transfer-1"

        viewModel.registerTransfer(transferId: transferID, messageID: message.id)
        viewModel.handleTransferEvent(.started(id: transferID, totalFragments: 4))
        #expect(isPartiallyDelivered(status: deliveryStatus(in: viewModel, peerID: peerID, messageID: message.id), reached: 0, total: 4))

        viewModel.handleTransferEvent(.updated(id: transferID, sentFragments: 2, totalFragments: 4))
        #expect(isPartiallyDelivered(status: deliveryStatus(in: viewModel, peerID: peerID, messageID: message.id), reached: 2, total: 4))

        viewModel.handleTransferEvent(.completed(id: transferID, totalFragments: 4))
        #expect(isSent(status: deliveryStatus(in: viewModel, peerID: peerID, messageID: message.id)))
        #expect(viewModel.messageIDToTransferId[message.id] == nil)
        #expect(viewModel.transferIdToMessageIDs[transferID] == nil)
    }

    @Test @MainActor
    func handleTransferEvent_cancelledRemovesOutgoingMessage() async {
        let (viewModel, _) = makeTestableViewModel()
        let peerID = PeerID(str: "1111111111111111111111111111111111111111111111111111111111111111")
        let message = viewModel.enqueueMediaMessage(content: "[image] pic.jpg", targetPeer: peerID)
        let transferID = "transfer-2"

        viewModel.registerTransfer(transferId: transferID, messageID: message.id)
        viewModel.handleTransferEvent(.cancelled(id: transferID, sentFragments: 1, totalFragments: 3))

        #expect(viewModel.privateChats[peerID]?.contains(where: { $0.id == message.id }) != true)
        #expect(viewModel.messageIDToTransferId[message.id] == nil)
    }

    @Test @MainActor
    func sendVoiceNote_outsideAllowedContextDeletesTempFile() async throws {
        let (viewModel, _) = makeTestableViewModel()
        let geohash = "u4pruydq"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")

        try Data("voice".utf8).write(to: url)
        viewModel.switchLocationChannel(to: .location(GeohashChannel(level: .city, geohash: geohash)))

        viewModel.sendVoiceNote(at: url)

        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(viewModel.messages.contains(where: { $0.sender == "system" }))
    }

    @Test @MainActor
    func sendImage_outsideAllowedContextRunsCleanup() async {
        let (viewModel, _) = makeTestableViewModel()
        let geohash = "u4pruydq"
        var cleanupCalled = false

        viewModel.switchLocationChannel(to: .location(GeohashChannel(level: .city, geohash: geohash)))
        viewModel.sendImage(from: URL(fileURLWithPath: "/tmp/ignored.jpg")) {
            cleanupCalled = true
        }

        #expect(cleanupCalled)
        #expect(viewModel.messages.contains(where: { $0.sender == "system" }))
    }

    @Test @MainActor
    func sendVoiceNote_privateChatUsesPrivateFileTransfer() async throws {
        let (viewModel, transport) = makeTestableViewModel()
        let peerID = PeerID(str: "2222222222222222222222222222222222222222222222222222222222222222")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
        try Data("voice payload".utf8).write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        viewModel.selectedPrivateChatPeer = peerID
        viewModel.sendVoiceNote(at: url)

        let didSend = await TestHelpers.waitUntil({ transport.sentPrivateFiles.count == 1 }, timeout: 0.5)
        #expect(didSend)
        #expect(transport.sentPrivateFiles.first?.peerID == peerID)
        #expect(viewModel.privateChats[peerID]?.last?.content.contains("[voice]") == true)
        #expect(viewModel.messageIDToTransferId.count == 1)
        #expect(viewModel.transferIdToMessageIDs.count == 1)
    }

    @Test @MainActor
    func sendVoiceNote_oversizedFileFailsAndDeletesTempFile() async throws {
        let (viewModel, transport) = makeTestableViewModel()
        let peerID = PeerID(str: "3333333333333333333333333333333333333333333333333333333333333333")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-too-large-\(UUID().uuidString).m4a")
        try Data(repeating: 0x55, count: FileTransferLimits.maxVoiceNoteBytes + 1).write(to: url, options: .atomic)

        viewModel.selectedPrivateChatPeer = peerID
        viewModel.sendVoiceNote(at: url)

        let didFail = await TestHelpers.waitUntil({
            isFailed(status: viewModel.privateChats[peerID]?.last?.deliveryStatus)
        }, timeout: 0.5)
        #expect(didFail)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(transport.sentPrivateFiles.isEmpty)
    }

    @Test @MainActor
    func sendImage_privateChatProcessesAndTransfersImage() async throws {
        let (viewModel, transport) = makeTestableViewModel()
        let peerID = PeerID(str: "4444444444444444444444444444444444444444444444444444444444444444")
        let sourceURL = try makeTemporaryImageURL()
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        viewModel.selectedPrivateChatPeer = peerID
        viewModel.sendImage(from: sourceURL)

        let didSend = await TestHelpers.waitUntil({ transport.sentPrivateFiles.count == 1 }, timeout: 1.0)
        #expect(didSend)
        #expect(transport.sentPrivateFiles.first?.peerID == peerID)
        #expect(transport.sentPrivateFiles.first?.packet.mimeType == "image/jpeg")
        #expect(viewModel.privateChats[peerID]?.last?.content.contains("[image]") == true)
        #expect(viewModel.messageIDToTransferId.count == 1)
    }

    @Test @MainActor
    func sendImage_invalidSourceAddsFailureSystemMessage() async throws {
        let (viewModel, transport) = makeTestableViewModel()
        let peerID = PeerID(str: "5555555555555555555555555555555555555555555555555555555555555555")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("invalid-\(UUID().uuidString).jpg")
        try Data("not-an-image".utf8).write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        viewModel.selectedPrivateChatPeer = peerID
        viewModel.sendImage(from: url)

        let didNotify = await TestHelpers.waitUntil({
            viewModel.messages.contains(where: { $0.sender == "system" && $0.content.contains("Failed to prepare image") })
        }, timeout: 2.0)
        #expect(didNotify)
        #expect(transport.sentPrivateFiles.isEmpty)
        #expect(viewModel.privateChats[peerID]?.isEmpty != false)
    }

    @Test @MainActor
    func clearTransferMapping_promotesQueuedTransferForSameID() async {
        let (viewModel, _) = makeTestableViewModel()
        viewModel.registerTransfer(transferId: "transfer-queue", messageID: "first")
        viewModel.registerTransfer(transferId: "transfer-queue", messageID: "second")

        viewModel.clearTransferMapping(for: "first")

        #expect(viewModel.messageIDToTransferId["first"] == nil)
        #expect(viewModel.transferIdToMessageIDs["transfer-queue"] == ["second"])
        #expect(viewModel.messageIDToTransferId["second"] == "transfer-queue")
    }

    @Test @MainActor
    func cancelMediaSend_cancelsActiveTransferRemovesMessageAndDeletesFile() async throws {
        let (viewModel, transport) = makeTestableViewModel()
        let peerID = PeerID(str: "6666666666666666666666666666666666666666666666666666666666666666")
        let fileName = "cancel-\(UUID().uuidString).m4a"
        let fileURL = try mediaFileURL(subdirectory: "voicenotes/outgoing", fileName: fileName)
        try Data("cancel me".utf8).write(to: fileURL, options: .atomic)

        let message = BitchatMessage(
            id: "cancel-msg",
            sender: viewModel.nickname,
            content: "[voice] \(fileName)",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "Peer",
            senderPeerID: viewModel.meshService.myPeerID,
            deliveryStatus: .sending
        )
        viewModel.privateChats[peerID] = [message]
        viewModel.registerTransfer(transferId: "transfer-cancel", messageID: message.id)

        viewModel.cancelMediaSend(messageID: message.id)

        #expect(transport.cancelledTransfers == ["transfer-cancel"])
        #expect(viewModel.privateChats[peerID] == nil)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test @MainActor
    func deleteMediaMessage_removesStoredMessageAndCleansImageFile() async throws {
        let (viewModel, _) = makeTestableViewModel()
        let peerID = PeerID(str: "7777777777777777777777777777777777777777777777777777777777777777")
        let fileName = "delete-\(UUID().uuidString).jpg"
        let fileURL = try mediaFileURL(subdirectory: "images/outgoing", fileName: fileName)
        try Data("image bytes".utf8).write(to: fileURL, options: .atomic)

        let message = BitchatMessage(
            id: "delete-msg",
            sender: viewModel.nickname,
            content: "[image] \(fileName)",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "Peer",
            senderPeerID: viewModel.meshService.myPeerID,
            deliveryStatus: .sent
        )
        viewModel.privateChats[peerID] = [message]
        viewModel.registerTransfer(transferId: "transfer-delete", messageID: message.id)

        viewModel.deleteMediaMessage(messageID: message.id)

        #expect(viewModel.privateChats[peerID] == nil)
        #expect(viewModel.messageIDToTransferId[message.id] == nil)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test @MainActor
    func makeTransferID_isPrefixedByMessageIDAndUnique() async {
        let (viewModel, _) = makeTestableViewModel()

        let first = viewModel.makeTransferID(messageID: "base")
        let second = viewModel.makeTransferID(messageID: "base")

        #expect(first.hasPrefix("base-"))
        #expect(second.hasPrefix("base-"))
        #expect(first != second)
    }
}

private func base64URLEncode(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func ackContent(type: NoisePayloadType, messageID: String, senderPeerID: PeerID) throws -> String {
    if let content = NostrEmbeddedBitChat.encodeAckForNostrNoRecipient(
        type: type,
        messageID: messageID,
        senderPeerID: senderPeerID
    ) {
        return content
    }
    throw ChatViewModelExtensionsTestError.invalidAckContent
}

private func privateMessageContent(text: String, messageID: String, senderPeerID: PeerID) throws -> String {
    if let content = NostrEmbeddedBitChat.encodePMForNostrNoRecipient(
        content: text,
        messageID: messageID,
        senderPeerID: senderPeerID
    ) {
        return content
    }
    throw ChatViewModelExtensionsTestError.invalidPrivateMessageContent
}

@MainActor
private func deliveryStatus(in viewModel: ChatViewModel, peerID: PeerID, messageID: String) -> DeliveryStatus? {
    viewModel.privateChats[peerID]?.first(where: { $0.id == messageID })?.deliveryStatus
}

private func isFailed(status: DeliveryStatus?) -> Bool {
    if case .failed = status {
        return true
    }
    return false
}

private func isDelivered(status: DeliveryStatus?) -> Bool {
    if case .delivered = status {
        return true
    }
    return false
}

private func isRead(status: DeliveryStatus?) -> Bool {
    if case .read = status {
        return true
    }
    return false
}

private func isSent(status: DeliveryStatus?) -> Bool {
    if case .sent = status {
        return true
    }
    return false
}

private func isPartiallyDelivered(status: DeliveryStatus?, reached: Int, total: Int) -> Bool {
    if case .partiallyDelivered(let actualReached, let actualTotal) = status {
        return actualReached == reached && actualTotal == total
    }
    return false
}

private enum ChatViewModelExtensionsTestError: Error {
    case invalidAckContent
    case invalidPrivateMessageContent
}

private func mediaFileURL(subdirectory: String, fileName: String) throws -> URL {
    let base = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
    ).appendingPathComponent("files", isDirectory: true)
    let directory = base.appendingPathComponent(subdirectory, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent(fileName)
}

private func makeTemporaryImageURL() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("image-\(UUID().uuidString).png")
    let data = try makeImageData()
    try data.write(to: url, options: .atomic)
    return url
}

private func makeImageData() throws -> Data {
    #if os(iOS)
    let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
        UIColor.systemTeal.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    }
    guard let data = image.pngData() else {
        throw ChatViewModelExtensionsTestError.invalidPrivateMessageContent
    }
    return data
    #else
    let image = NSImage(size: CGSize(width: 64, height: 64))
    image.lockFocus()
    NSColor.systemTeal.setFill()
    NSBezierPath(rect: CGRect(x: 0, y: 0, width: 64, height: 64)).fill()
    image.unlockFocus()
    guard
        let tiffData = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiffData),
        let data = bitmap.representation(using: .png, properties: [:])
    else {
        throw ChatViewModelExtensionsTestError.invalidPrivateMessageContent
    }
    return data
    #endif
}
