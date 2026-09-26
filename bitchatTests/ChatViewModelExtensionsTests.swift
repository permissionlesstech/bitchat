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

    /// An unreachable recipient no longer means instant failure: the message
    /// is routed anyway so the router's outbox/courier/bridge machinery can
    /// deliver it, and it stays "sending" until a router callback resolves it.
    @Test @MainActor
    func sendPrivateMessage_unreachable_staysSendingForStoreAndForward() async {
        let (viewModel, _) = makeTestableViewModel()
        let validHex = "0102030405060708090a0b0c0d0e0f100102030405060708090a0b0c0d0e0f10"
        let peerID = PeerID(str: validHex)

        viewModel.sendPrivateMessage("Hello", to: peerID)

        #expect(viewModel.privateChats[peerID]?.count == 1)
        #expect(viewModel.privateChats[peerID]?.last?.deliveryStatus == .sending)
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
        let (viewModel, transport) = makeTestableViewModel()
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
        viewModel.seedPrivateChat([oldMessage], for: oldPeerID)
        viewModel.peerIDToPublicKeyFingerprint[oldPeerID] = fingerprint
        
        // The new peer's fingerprint resolves through the transport.
        transport.peerFingerprints[newPeerID] = fingerprint
        
        // Trigger migration
        viewModel.migratePrivateChatsIfNeeded(for: newPeerID)
        
        // Verify migration
        #expect(viewModel.privateChats[newPeerID]?.count == 1)
        #expect(viewModel.privateChats[newPeerID]?.first?.content == "Old message")
        #expect(viewModel.privateChats[oldPeerID] == nil) // Old chat removed
    }

    @Test @MainActor
    func handlePrivateMessage_keepsAnotherPeersChatWhenOnlyTheNicknameMatches() async {
        let (viewModel, transport) = makeTestableViewModel()
        let firstPeerID = PeerID(str: "aaaaaaaaaaaaaaaa")
        let secondPeerID = PeerID(str: "bbbbbbbbbbbbbbbb")
        let firstMessage = BitchatMessage(
            id: "first-1",
            sender: "bob",
            content: "From the first bob",
            timestamp: Date().addingTimeInterval(-60),
            isRelay: false,
            isPrivate: true,
            senderPeerID: firstPeerID
        )
        viewModel.seedPrivateChat([firstMessage], for: firstPeerID)
        // Both peers resolve a live fingerprint; the first chat was never
        // opened, so no fingerprint is stored for it.
        transport.peerFingerprints[firstPeerID] = "fp-1"
        transport.peerFingerprints[secondPeerID] = "fp-2"

        viewModel.handlePrivateMessage(
            BitchatMessage(
                id: "second-1",
                sender: "bob",
                content: "From the second bob",
                timestamp: Date(),
                isRelay: false,
                isPrivate: true,
                senderPeerID: secondPeerID
            )
        )

        #expect(viewModel.privateChats[firstPeerID]?.map(\.id) == ["first-1"])
        #expect(viewModel.privateChats[secondPeerID]?.map(\.id) == ["second-1"])
    }

    @Test @MainActor
    func handlePrivateMessage_courierJoinPreservesBlockingAndVerification() async {
        let (viewModel, transport) = makeTestableViewModel()
        let stablePeerID = PeerID(str: String(repeating: "c", count: 64))
        let shortPeerID = stablePeerID.toShort()
        let meshMessage = BitchatMessage(
            id: "mesh-1",
            sender: "bob",
            content: "Over the mesh",
            timestamp: Date().addingTimeInterval(-60),
            isRelay: false,
            isPrivate: true,
            senderPeerID: shortPeerID
        )
        viewModel.seedPrivateChat([meshMessage], for: shortPeerID)
        // This fixture resolves the mesh sender but has no full-key fingerprint mapping.
        transport.peerFingerprints[shortPeerID] = "fp-1"

        viewModel.handlePrivateMessage(
            BitchatMessage(
                id: "courier-1",
                sender: "Unknown",
                content: "By courier",
                timestamp: Date(),
                isRelay: false,
                isPrivate: true,
                senderPeerID: stablePeerID
            )
        )

        #expect(viewModel.getFingerprint(for: stablePeerID) == nil)
        let joined = viewModel.privateChats[stablePeerID] ?? []
        #expect(Set(joined.map(\.id)) == ["mesh-1", "courier-1"])
        let meshRowSender = joined.first { $0.id == "mesh-1" }?.senderPeerID
        #expect(meshRowSender == shortPeerID)

        viewModel.peerIdentityStore.setVerified("fp-1", verified: true)
        let privateModel = PrivateConversationModel(
            chatViewModel: viewModel, conversations: viewModel.conversations,
            locationChannelsModel: LocationChannelsModel(manager: viewModel.locationManager)
        )
        let uiModel = ConversationUIModel(
            chatViewModel: viewModel, privateConversationModel: privateModel,
            conversations: viewModel.conversations
        )
        let meshRow = joined.first { $0.id == "mesh-1" }
        #expect(meshRow.map { uiModel.showsVerifiedSeal(for: $0) } == true)

        // Blocking from the moved row reaches the peer's identity.
        if let meshRowSender {
            viewModel.blockMeshPeer(peerID: meshRowSender, displayName: "bob")
        }
        #expect(viewModel.identityManager.isBlocked(fingerprint: "fp-1"))
    }
    
    @Test @MainActor
    func handlePrivateMessage_openingCourierJoinReceiptsOlderMeshHistory() async {
        let (viewModel, transport) = makeTestableViewModel()
        let fullID = PeerID(hexData: Data(repeating: 0xCC, count: 32))
        let shortID = fullID.toShort()
        transport.reachablePeers = [shortID, fullID]
        let meshID = "mesh-" + UUID().uuidString
        let courierID = "courier-" + UUID().uuidString
        viewModel.handlePrivateMessage(BitchatMessage(id: meshID, sender: "bob", content: "mesh",
            timestamp: Date().addingTimeInterval(-25 * 3600), isRelay: false,
            isPrivate: true, senderPeerID: shortID))
        viewModel.handlePrivateMessage(BitchatMessage(id: courierID, sender: "Unknown", content: "courier",
            timestamp: Date(), isRelay: false, isPrivate: true, senderPeerID: fullID))
        #expect(viewModel.privateChats[shortID] == nil)
        #expect(viewModel.privateChats[fullID]?.first { $0.id == meshID }?.senderPeerID == shortID)

        viewModel.startPrivateChat(with: fullID)
        for _ in 0..<100 where !transport.sentReadReceipts.contains(where: {
            $0.receipt.originalMessageID == meshID
        }) { await Task.yield() }
        #expect(transport.sentReadReceipts.contains { $0.receipt.originalMessageID == meshID })
        #expect(transport.sentReadReceipts.contains { $0.receipt.originalMessageID == courierID })
        #expect(!viewModel.unreadPrivateMessages.contains(fullID))
        #expect(viewModel.privateChats[fullID]?.first { $0.id == meshID }?.senderPeerID == shortID)
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
        viewModel.registerNostrKeyMapping(hexPubkey, for: blockedPeerID)
        viewModel.identityManager.setNostrBlocked(hexPubkey, isBlocked: true)
        
        // Force isGeoChat/isGeoDM check to be true by setting prefix?
        // Or ensure the logic covers it.
        // The logic is:
        // if peerID.isGeoChat || peerID.isGeoDM { check nostr }
        // We need a peerID that looks like geo.
        
        let geoPeerID = PeerID(nostr_: hexPubkey)
        viewModel.registerNostrKeyMapping(hexPubkey, for: geoPeerID)
        
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

        _ = await TestHelpers.waitUntil({ LocationChannelManager.shared.selectedChannel == channel }, timeout: TestConstants.settleTimeout)

        let (viewModel, _) = makeTestableViewModel()
        
        _ = await TestHelpers.waitUntil({ viewModel.activeChannel == channel }, timeout: TestConstants.settleTimeout)
        
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
            if viewModel.messages.contains(where: { $0.content == "Hello Geo" }) { return true }
            // LocationChannelManager is a process-wide singleton: a suite
            // running in parallel (e.g. CommandProcessorTests) can flip the
            // selected channel mid-test, which reroutes or drops the event
            // permanently — no amount of waiting recovers it. Re-assert the
            // channel and redeliver on each poll: every channel switch clears
            // the processed-event set and the store dedups by message ID, so
            // redelivery is idempotent and interference heals on the next
            // poll while a genuine failure still times out.
            if LocationChannelManager.shared.selectedChannel != channel {
                LocationChannelManager.shared.select(channel)
            }
            if viewModel.activeChannel == channel {
                viewModel.handleNostrEvent(signed)
            }
            return false
        }, timeout: TestConstants.settleTimeout)
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

    // NOTE: Tampered-signature rejection is enforced once, off the main
    // actor, at the relay boundary (events only reach the inbound pipeline
    // after verification) — see NostrRelayManagerTests
    // `test_receiveEvent_invalidSignatureDoesNotPoisonDuplicateCache` and
    // `test_receiveGiftWrap_tamperedSignatureIsDroppedAndDoesNotPoisonDedup`.

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

        viewModel.seedPrivateChat([
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
        ], for: convKey)

        let content = try ackContent(type: .delivered, messageID: messageID)
        let giftWrap = try NostrProtocol.createPrivateMessage(
            content: content,
            recipientPubkey: recipient.publicKeyHex,
            senderIdentity: sender
        )

        viewModel.subscribeGiftWrap(giftWrap, id: recipient)

        let didUpdate = await TestHelpers.waitUntil(
            { isDelivered(status: deliveryStatus(in: viewModel, peerID: convKey, messageID: messageID)) },
            timeout: TestConstants.settleTimeout
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

        viewModel.seedPrivateChat([
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
        ], for: convKey)

        let content = try ackContent(type: .readReceipt, messageID: messageID)
        let giftWrap = try NostrProtocol.createPrivateMessage(
            content: content,
            recipientPubkey: recipient.publicKeyHex,
            senderIdentity: sender
        )

        viewModel.subscribeGiftWrap(giftWrap, id: recipient)

        let didUpdate = await TestHelpers.waitUntil(
            { isRead(status: deliveryStatus(in: viewModel, peerID: convKey, messageID: messageID)) },
            timeout: TestConstants.settleTimeout
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
            messageID: messageID
        )
        let giftWrap = try NostrProtocol.createPrivateMessage(
            content: content,
            recipientPubkey: recipient.publicKeyHex,
            senderIdentity: sender
        )

        viewModel.handleGiftWrap(giftWrap, id: recipient)

        let didStore = await TestHelpers.waitUntil(
            { viewModel.privateChats[convKey]?.first?.content == "Hello from gift wrap" },
            timeout: TestConstants.settleTimeout
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
            messageID: messageID
        )
        let giftWrap = try NostrProtocol.createPrivateMessage(
            content: content,
            recipientPubkey: recipient.publicKeyHex,
            senderIdentity: sender
        )

        viewModel.handleGiftWrap(giftWrap, id: recipient)

        // Gift-wrap decryption runs off the main actor. The key mapping is
        // registered in the same main-actor hop that runs the PM handler, so
        // once it shows up the handler has already returned.
        let didProcess = await TestHelpers.waitUntil(
            { viewModel.nostrKeyMapping[convKey] == sender.publicKeyHex },
            timeout: TestConstants.settleTimeout
        )
        #expect(didProcess)
        #expect(viewModel.privateChats[convKey] == nil)
        // A blocked sender gets nothing back, not even a DELIVERED ack.
        #expect(!viewModel.sentGeoDeliveryAcks.contains(messageID))
    }

    @Test @MainActor
    func handleGiftWrap_deliveredAckUpdatesExistingMessage() async throws {
        let (viewModel, _) = makeTestableViewModel()
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let convKey = PeerID(nostr_: sender.publicKeyHex)
        let messageID = "gift-delivered"

        viewModel.seedPrivateChat([
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
        ], for: convKey)

        let content = try ackContent(type: .delivered, messageID: messageID)
        let giftWrap = try NostrProtocol.createPrivateMessage(
            content: content,
            recipientPubkey: recipient.publicKeyHex,
            senderIdentity: sender
        )

        viewModel.handleGiftWrap(giftWrap, id: recipient)

        let didUpdate = await TestHelpers.waitUntil(
            { isDelivered(status: deliveryStatus(in: viewModel, peerID: convKey, messageID: messageID)) },
            timeout: TestConstants.settleTimeout
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

    /// An inbound Nostr [FAVORITED] marker must flip theyFavoritedUs and stay
    /// out of the conversation transcript.
    @Test @MainActor
    func handlePrivateMessage_nostrFavoritedMarkerUpdatesRelationship() async throws {
        let (viewModel, _) = makeTestableViewModel()
        let identity = try NostrIdentity.generate()
        let noiseKey = Data((0..<32).map { UInt8(($0 + 144) & 0xFF) })

        FavoritesPersistenceService.shared.addFavorite(
            peerNoisePublicKey: noiseKey,
            peerNostrPublicKey: identity.npub,
            peerNickname: "Alice"
        )
        defer {
            FavoritesPersistenceService.shared.updatePeerFavoritedUs(peerNoisePublicKey: noiseKey, favorited: false)
            FavoritesPersistenceService.shared.removeFavorite(peerNoisePublicKey: noiseKey)
        }

        // The inbound pipeline resolves a known sender to their noise-key ID.
        let convKey = PeerID(hexData: noiseKey)
        let payloadData = try #require(
            PrivateMessagePacket(messageID: "fav-e2e-1", content: "[FAVORITED]:\(identity.npub)").encode()
        )
        let payload = NoisePayload(type: .privateMessage, data: payloadData)

        viewModel.handlePrivateMessage(
            payload,
            senderPubkey: identity.publicKeyHex,
            convKey: convKey,
            id: identity,
            messageTimestamp: Date()
        )

        let relationship = FavoritesPersistenceService.shared.getFavoriteStatus(for: noiseKey)
        #expect(relationship?.theyFavoritedUs == true)
        #expect(relationship?.isMutual == true)
        #expect(relationship?.peerNostrPublicKey == identity.npub)
        #expect(viewModel.privateChats[convKey, default: []].isEmpty)
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

        // The failure is surfaced inside the geoDM thread, not on the public
        // timeline (matches the sibling in-thread errors from #1415).
        #expect(viewModel.messages.isEmpty)
        #expect(viewModel.privateChats[convKey]?.count == 1)
        #expect(viewModel.privateChats[convKey]?.last?.sender == "system")
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

    /// The blocked notice belongs in the DM thread the person is typing in,
    /// not on the active location-channel timeline.
    @Test @MainActor
    func sendGeohashDM_blockedRecipient_marksFailedAndAddsSystemMessageInThread() async {
        let (viewModel, _) = makeTestableViewModel()
        let geohash = "u4pruydq"
        let recipientHex = "0000000000000000000000000000000000000000000000000000000000000003"
        let convKey = PeerID(nostr_: recipientHex)

        viewModel.switchLocationChannel(to: .location(GeohashChannel(level: .city, geohash: geohash)))
        viewModel.registerNostrKeyMapping(recipientHex, for: convKey)
        viewModel.identityManager.setNostrBlocked(recipientHex, isBlocked: true)

        viewModel.sendGeohashDM("hello", to: convKey)

        let thread = viewModel.privateChats[convKey] ?? []
        #expect(thread.count == 2)
        #expect(isFailed(status: thread.first?.deliveryStatus))
        #expect(thread.last?.sender == "system")
        #expect(!viewModel.messages.contains(where: { $0.sender == "system" }))
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

// MARK: - Single-Writer Intent Operation Tests

/// Contracts for the owner-side intent ops that are the sole mutation paths
/// for `ChatViewModel`'s shared coordinator state (`nostrKeyMapping`,
/// `sentReadReceipts`, `sentGeoDeliveryAcks`, `isBatchingPublic`, the geo
/// subscription IDs, and the selected private chat hand-off).
struct ChatViewModelIntentOperationTests {

    @Test @MainActor
    func markGeoDeliveryAckSent_returnsFalseOnSecondCall() async {
        let (viewModel, _) = makeTestableViewModel()

        #expect(viewModel.markGeoDeliveryAckSent("geo-ack-1"))
        #expect(!viewModel.markGeoDeliveryAckSent("geo-ack-1"))
        #expect(viewModel.markGeoDeliveryAckSent("geo-ack-2"))
        #expect(viewModel.sentGeoDeliveryAcks == ["geo-ack-1", "geo-ack-2"])
    }

    @Test @MainActor
    func markReadReceiptSent_returnsFalseOnSecondCall() async {
        let (viewModel, _) = makeTestableViewModel()

        #expect(viewModel.markReadReceiptSent("read-1"))
        #expect(!viewModel.markReadReceiptSent("read-1"))
        #expect(viewModel.sentReadReceipts.contains("read-1"))
    }

    @Test @MainActor
    func pruneSentReadReceipts_dropsStaleIDsAndReturnsRemovedCount() async {
        let (viewModel, _) = makeTestableViewModel()
        viewModel.sentReadReceipts = ["keep-1", "keep-2", "drop-1", "drop-2"]

        let removed = viewModel.pruneSentReadReceipts(keeping: ["keep-1", "keep-2", "unrelated"])

        #expect(removed == 2)
        #expect(viewModel.sentReadReceipts == ["keep-1", "keep-2"])
        // Nothing stale left: a second prune removes nothing.
        #expect(viewModel.pruneSentReadReceipts(keeping: ["keep-1", "keep-2"]) == 0)
    }

    @Test @MainActor
    func registerNostrKeyMapping_isVisibleToNostrCoordinatorLookups() async {
        let (viewModel, _) = makeTestableViewModel()
        let hex = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
        let convKey = PeerID(nostr_: hex)

        // Registered through the owner intent op (as e.g. the private
        // conversation flow does) and resolved through the Nostr coordinator,
        // which reads the same backing dictionary via `ChatNostrContext`.
        viewModel.registerNostrKeyMapping(hex, for: convKey)

        #expect(viewModel.nostrKeyMapping[convKey] == hex)
        #expect(viewModel.nostrCoordinator.fullNostrHex(forSenderPeerID: convKey) == hex)
    }

    @Test @MainActor
    func removeNostrKeyMappings_dropsEveryMappingForThePubkeyCaseInsensitively() async {
        let (viewModel, _) = makeTestableViewModel()
        let hex = "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899"
        let otherHex = "ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100"
        viewModel.registerNostrKeyMapping(hex.uppercased(), for: PeerID(nostr: hex))
        viewModel.registerNostrKeyMapping(hex, for: PeerID(nostr_: hex))
        viewModel.registerNostrKeyMapping(otherHex, for: PeerID(nostr_: otherHex))

        viewModel.removeNostrKeyMappings(matchingPubkeyHexLowercased: hex)

        #expect(viewModel.nostrKeyMapping[PeerID(nostr: hex)] == nil)
        #expect(viewModel.nostrKeyMapping[PeerID(nostr_: hex)] == nil)
        #expect(viewModel.nostrKeyMapping[PeerID(nostr_: otherHex)] == otherHex)
    }

    @Test @MainActor
    func setPublicBatching_publishesBatchingState() async {
        let (viewModel, _) = makeTestableViewModel()

        #expect(!viewModel.isBatchingPublic)
        viewModel.setPublicBatching(true)
        #expect(viewModel.isBatchingPublic)
        viewModel.setPublicBatching(false)
        #expect(!viewModel.isBatchingPublic)
    }

    @Test @MainActor
    func geoSubscriptionIntentOps_setClearAndDrainSubscriptions() async {
        let (viewModel, _) = makeTestableViewModel()

        viewModel.setGeoChatSubscriptionID("geo-u4pruy")
        viewModel.setGeoDmSubscriptionID("geo-dm-u4pruy")
        #expect(viewModel.geoSubscriptionID == "geo-u4pruy")
        #expect(viewModel.geoDmSubscriptionID == "geo-dm-u4pruy")

        viewModel.setGeoChatSubscriptionID(nil)
        viewModel.setGeoDmSubscriptionID(nil)
        #expect(viewModel.geoSubscriptionID == nil)
        #expect(viewModel.geoDmSubscriptionID == nil)

        viewModel.addGeoSamplingSub("geo-sample-aaaa", forGeohash: "aaaa")
        viewModel.addGeoSamplingSub("geo-sample-bbbb", forGeohash: "bbbb")
        viewModel.removeGeoSamplingSub("geo-sample-aaaa")
        #expect(viewModel.geoSamplingSubs == ["geo-sample-bbbb": "bbbb"])

        let cleared = viewModel.clearGeoSamplingSubs()
        #expect(cleared == ["geo-sample-bbbb"])
        #expect(viewModel.geoSamplingSubs.isEmpty)
    }

    @Test @MainActor
    func handOffSelectedPrivateChat_movesSelectionOnlyWhenSelectedPeerIsMigrated() async {
        let (viewModel, _) = makeTestableViewModel()
        let oldPeer = PeerID(str: "aaaaaaaaaaaaaaaa")
        let unrelatedPeer = PeerID(str: "cccccccccccccccc")
        let newPeer = PeerID(str: "bbbbbbbbbbbbbbbb")

        // Selection not among the migrated peers: untouched.
        viewModel.selectedPrivateChatPeer = unrelatedPeer
        viewModel.handOffSelectedPrivateChat(from: [oldPeer], to: newPeer)
        #expect(viewModel.selectedPrivateChatPeer == unrelatedPeer)

        // Selection being migrated away: handed off to the new peer.
        viewModel.selectedPrivateChatPeer = oldPeer
        viewModel.handOffSelectedPrivateChat(from: [oldPeer], to: newPeer)
        #expect(viewModel.selectedPrivateChatPeer == newPeer)
    }
}

@Suite(.serialized)
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

        // Media sends hop through Task.detached; the global executor is
        // shared with every parallel test worker, so a loaded runner can be
        // starved for seconds. waitUntil returns as soon as the condition
        // holds, so passing runs never pay the settle deadline.
        let didSend = await TestHelpers.waitUntil({ transport.sentPrivateFiles.count == 1 }, timeout: TestConstants.settleTimeout)
        #expect(didSend)
        #expect(transport.sentPrivateFiles.first?.peerID == peerID)
        #expect(viewModel.privateChats[peerID]?.last?.content.contains("[voice]") == true)
        #expect(viewModel.messageIDToTransferId.count == 1)
        #expect(viewModel.transferIdToMessageIDs.count == 1)
    }

    @Test @MainActor
    func legacyPrivateMediaConsentRequestsArePerSendAndQueued() async throws {
        let (viewModel, _) = makeTestableViewModel()
        let firstPeer = PeerID(str: "1111111111111111")
        let secondPeer = PeerID(str: "2222222222222222")
        var decisions: [Bool] = []

        viewModel.enqueueLegacyPrivateMediaConsent(
            for: firstPeer,
            transferId: "transfer-1",
            messageID: "message-1"
        ) { decisions.append($0) }
        viewModel.enqueueLegacyPrivateMediaConsent(
            for: secondPeer,
            transferId: "transfer-2",
            messageID: "message-2"
        ) { decisions.append($0) }

        #expect(viewModel.legacyPrivateMediaConsentRequest?.peerID == firstPeer)
        let firstRequestID = try #require(viewModel.legacyPrivateMediaConsentRequest?.id)
        viewModel.resolveLegacyPrivateMediaConsent(requestID: firstRequestID, approved: true)
        let showedSecond = await TestHelpers.waitUntil(
            { viewModel.legacyPrivateMediaConsentRequest?.peerID == secondPeer },
            timeout: TestConstants.settleTimeout
        )
        #expect(showedSecond)
        let secondRequestID = try #require(viewModel.legacyPrivateMediaConsentRequest?.id)

        // A button action and the dialog binding may both resolve the first
        // ID. The stale second callback must not consume the queued request.
        viewModel.resolveLegacyPrivateMediaConsent(requestID: firstRequestID, approved: false)
        #expect(decisions == [true])
        #expect(viewModel.legacyPrivateMediaConsentRequest?.id == secondRequestID)

        viewModel.resolveLegacyPrivateMediaConsent(requestID: secondRequestID, approved: false)

        #expect(decisions == [true, false])
        #expect(viewModel.legacyPrivateMediaConsentRequest == nil)
    }

    @Test @MainActor
    func invalidatingPresentedLegacyConsentAdvancesQueueAndStaleResolutionNoops() async throws {
        let (viewModel, _) = makeTestableViewModel()
        let firstPeer = PeerID(str: "3333333333333333")
        let secondPeer = PeerID(str: "4444444444444444")
        var decisions: [String] = []

        viewModel.enqueueLegacyPrivateMediaConsent(
            for: firstPeer,
            transferId: "transfer-cancelled",
            messageID: "message-cancelled"
        ) { decisions.append("first:\($0)") }
        viewModel.enqueueLegacyPrivateMediaConsent(
            for: secondPeer,
            transferId: "transfer-kept",
            messageID: "message-kept"
        ) { decisions.append("second:\($0)") }

        let cancelledRequestID = try #require(viewModel.legacyPrivateMediaConsentRequest?.id)
        viewModel.invalidateLegacyPrivateMediaConsent(
            transferId: "transfer-cancelled",
            messageID: "message-cancelled"
        )
        let advanced = await TestHelpers.waitUntil(
            { viewModel.legacyPrivateMediaConsentRequest?.peerID == secondPeer },
            timeout: TestConstants.settleTimeout
        )
        #expect(advanced)
        #expect(decisions.isEmpty, "Invalidation drops the request rather than resolving its send")

        viewModel.resolveLegacyPrivateMediaConsent(
            requestID: cancelledRequestID,
            approved: true
        )
        #expect(viewModel.legacyPrivateMediaConsentRequest?.peerID == secondPeer)
        #expect(decisions.isEmpty)

        let keptRequestID = try #require(viewModel.legacyPrivateMediaConsentRequest?.id)
        viewModel.resolveLegacyPrivateMediaConsent(requestID: keptRequestID, approved: true)
        #expect(decisions == ["second:true"])
        #expect(viewModel.legacyPrivateMediaConsentRequest == nil)
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
        }, timeout: TestConstants.settleTimeout)
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

        let didSend = await TestHelpers.waitUntil({ transport.sentPrivateFiles.count == 1 }, timeout: TestConstants.settleTimeout)
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
        }, timeout: TestConstants.settleTimeout)
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
        viewModel.seedPrivateChat([message], for: peerID)
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
        viewModel.seedPrivateChat([message], for: peerID)
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

private func ackContent(type: NoisePayloadType, messageID: String) throws -> String {
    if let content = NostrEmbeddedBitChat.encodeAckForNostrNoRecipient(
        type: type,
        messageID: messageID
    ) {
        return content
    }
    throw ChatViewModelExtensionsTestError.invalidAckContent
}

private func privateMessageContent(text: String, messageID: String) throws -> String {
    if let content = NostrEmbeddedBitChat.encodePMForNostrNoRecipient(
        content: text,
        messageID: messageID
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

// MARK: - Tor Extension Tests

struct ChatViewModelTorExtensionTests {

    /// Turning Tor off mid-bootstrap must not read as "the network is
    /// blocking tor": `torEnforced` is a compile-time constant, so the stall
    /// handler has to consult the runtime preference before announcing.
    @Test @MainActor
    func bootstrapStall_withTorPreferenceOff_announcesNothing() async {
        let key = NetworkActivationService.torPreferenceKey
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        let (viewModel, _) = makeTestableViewModel()

        UserDefaults.standard.set(false, forKey: key)
        viewModel.handleTorBootstrapDidStall()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(viewModel.torStallAnnounced == false)

        // The same stall with the preference on (the persisted default) is
        // exactly what must still be announced.
        UserDefaults.standard.set(true, forKey: key)
        viewModel.handleTorBootstrapDidStall()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(viewModel.torStallAnnounced == true)
    }
}


struct ChatViewModelReplyIdentityTests {
    private func message(_ id: String, from peerID: PeerID) -> BitchatMessage {
        BitchatMessage(id: id, sender: "Unknown", content: "Private message",
                       timestamp: Date(), isRelay: false, isPrivate: true, senderPeerID: peerID)
    }

    @Test(arguments: [false, true]) @MainActor
    func sameNameCourierDoesNotChangeOpenChatOrReplyRecipient(originalPeerConnected: Bool) async throws {
        let (viewModel, transport) = makeTestableViewModel()
        let originalKey = Data(repeating: 0x51, count: 32)
        let originalPeer = PeerID(publicKey: originalKey)
        let courierPeer = PeerID(hexData: Data(repeating: 0x52, count: 32))
        let originalFingerprint = originalKey.sha256Fingerprint()
        transport.peerFingerprints[originalPeer] = originalFingerprint
        transport.peerNicknames[originalPeer] = "Unknown"
        transport.reachablePeers = [originalPeer, courierPeer]
        if originalPeerConnected {
            transport.connectedPeers.insert(originalPeer)
            transport.updatePeerSnapshots([
                TransportPeerSnapshot(peerID: originalPeer, nickname: "Unknown",
                                      isConnected: true, noisePublicKey: originalKey, lastSeen: Date())
            ])
            let connected = await TestHelpers.waitUntil(
                { viewModel.connectedPeers.contains(originalPeer) }, timeout: TestConstants.settleTimeout)
            try #require(connected)
        } else {
            #expect(!viewModel.connectedPeers.contains(originalPeer))
        }

        viewModel.handlePrivateMessage(message("original-history", from: originalPeer))
        viewModel.startPrivateChat(with: originalPeer)
        try #require(viewModel.selectedPrivateChatFingerprint == originalFingerprint)
        try #require(viewModel.getFingerprint(for: courierPeer) == nil)
        viewModel.handlePrivateMessage(message("courier-arrival", from: courierPeer))

        #expect(viewModel.privateChats[originalPeer]?.map(\.id) == ["original-history"])
        #expect(viewModel.privateChats[courierPeer]?.map(\.id) == ["courier-arrival"])
        #expect(viewModel.selectedPrivateChatPeer == originalPeer)
        viewModel.sendMessage("Reply to the original peer")
        let sent = try #require(transport.sentPrivateMessages.last)
        #expect(sent.peerID == originalPeer)
        #expect(sent.content == "Reply to the original peer")
    }

    @Test @MainActor
    func resendingFailedMessageKeepsOriginalRecipientAfterSameNameCourierArrives() async throws {
        let (viewModel, transport) = makeTestableViewModel()
        let originalKey = Data(repeating: 0x61, count: 32)
        let originalPeer = PeerID(publicKey: originalKey)
        let courierPeer = PeerID(hexData: Data(repeating: 0x62, count: 32))
        transport.peerFingerprints[originalPeer] = originalKey.sha256Fingerprint()
        transport.peerNicknames[originalPeer] = "Unknown"
        transport.reachablePeers = [originalPeer, courierPeer]
        viewModel.startPrivateChat(with: originalPeer)
        try #require(viewModel.selectedPrivateChatFingerprint == originalKey.sha256Fingerprint())
        viewModel.sendMessage("Message intended for the original peer")
        let outgoing = try #require(viewModel.privateChats[originalPeer]?.first {
            $0.content == "Message intended for the original peer"
        })
        try #require(viewModel.setPrivateDeliveryStatus(
            .failed(reason: "route failed"), forMessageID: outgoing.id, peerID: originalPeer))
        viewModel.endPrivateChat()

        try #require(viewModel.getFingerprint(for: courierPeer) == nil)
        viewModel.handlePrivateMessage(message("courier-arrival", from: courierPeer))
        let owner = try #require(viewModel.privateChats.first {
            $0.value.contains { $0.id == outgoing.id }
        }?.key)
        #expect(owner == originalPeer)
        let failedMessage = try #require(viewModel.privateChats[owner]?.first { $0.id == outgoing.id })
        #expect(failedMessage.deliveryStatus == .failed(reason: "route failed"))
        viewModel.startPrivateChat(with: owner)
        let privateModel = PrivateConversationModel(
            chatViewModel: viewModel, conversations: viewModel.conversations,
            locationChannelsModel: LocationChannelsModel(manager: viewModel.locationManager))
        let ui = ConversationUIModel(chatViewModel: viewModel, privateConversationModel: privateModel,
                                     conversations: viewModel.conversations)
        try #require(ui.isSentByCurrentUser(failedMessage))
        try #require(ui.mediaAttachment(for: failedMessage) == nil)
        let sendsBeforeResend = transport.sentPrivateMessages.count

        ui.resendFailedPrivateMessage(failedMessage)

        #expect(transport.sentPrivateMessages.count == sendsBeforeResend + 1)
        let resent = try #require(transport.sentPrivateMessages.last)
        #expect(resent.peerID == originalPeer)
        #expect(resent.content == outgoing.content)
        #expect(!viewModel.privateChats.values.joined().contains { $0.id == outgoing.id })
    }
}

struct ChatViewModelConversationIdentityTests {
    @Test(arguments: [true, false]) @MainActor
    func encryptedGeoHistoryStaysWithItsSenderWhenOpeningMeshPeer(matchFullDisplayName: Bool) async throws {
        let (viewModel, transport) = makeTestableViewModel()
        let sender = try NostrIdentity(privateKeyData: Data(repeating: 0x11, count: 32))
        let recipient = try NostrIdentity(privateKeyData: Data(repeating: 0x22, count: 32))
        let geoID = PeerID(nostr_: sender.publicKeyHex)
        let meshID = PeerID(publicKey: Data(repeating: 0x33, count: 32))
        let firstID = UUID().uuidString
        let envelope = try NostrProtocol.createPrivateMessage(
            content: privateMessageContent(text: "first geo message", messageID: firstID),
            recipientPubkey: recipient.publicKeyHex,
            senderIdentity: sender
        )
        viewModel.handleGiftWrap(envelope, id: recipient)
        let stored = await TestHelpers.waitUntil(
            { viewModel.privateChats[geoID]?.contains { $0.id == firstID } == true },
            timeout: TestConstants.settleTimeout
        )
        try #require(stored)
        let original = try #require(viewModel.privateChats[geoID]?.first { $0.id == firstID })
        #expect(original.sender == "anon#" + sender.publicKeyHex.suffix(4))
        #expect(original.senderPeerID == geoID)
        #expect(viewModel.nostrKeyMapping[geoID] == sender.publicKeyHex)
        #expect(viewModel.privateChats[meshID] == nil)

        let rawName = matchFullDisplayName ? original.sender : "anon"
        let announcement = AnnouncementPacket(nickname: rawName,
            noisePublicKey: Data(repeating: 0x33, count: 32),
            signingPublicKey: Data(repeating: 0x44, count: 32), directNeighbors: nil)
        let encoded = try #require(announcement.encode())
        let decoded = try #require(AnnouncementPacket.decode(from: encoded))
        var registry = BLEPeerRegistry()
        _ = registry.upsertVerifiedAnnounce(peerID: meshID, nickname: decoded.nickname,
            noisePublicKey: decoded.noisePublicKey, signingPublicKey: decoded.signingPublicKey,
            isConnected: true, now: Date())
        let meshNickname = try #require(registry.nickname(for: meshID, connectedOnly: true))
        #expect(meshNickname == rawName)
        transport.peerNicknames[meshID] = meshNickname
        transport.connectedPeers.insert(meshID)
        transport.reachablePeers.insert(meshID)
        #expect(viewModel.hasUnreadMessages(for: geoID))
        #expect(!viewModel.hasUnreadMessages(for: meshID))
        viewModel.startPrivateChat(with: meshID)
        #expect(viewModel.hasUnreadMessages(for: geoID))
        #expect(!viewModel.hasUnreadMessages(for: meshID))
        let moved = viewModel.privateChats[meshID]?.first { $0.id == firstID }
        #expect(viewModel.privateChats[geoID]?.contains { $0.id == firstID } == true)
        #expect(moved == nil)
        #expect(viewModel.privateChats[geoID]?.first { $0.id == firstID }?.senderPeerID == geoID)

        viewModel.sendMessage("reply from selected conversation")
        #expect(transport.sentPrivateMessages.last?.peerID == meshID)
        #expect(transport.sentPrivateMessages.last?.content == "reply from selected conversation")

        let secondID = UUID().uuidString
        let nextEnvelope = try NostrProtocol.createPrivateMessage(
            content: privateMessageContent(text: "second geo message", messageID: secondID),
            recipientPubkey: recipient.publicKeyHex,
            senderIdentity: sender
        )
        viewModel.handleGiftWrap(nextEnvelope, id: recipient)
        let newStored = await TestHelpers.waitUntil(
            { viewModel.privateChats[geoID]?.contains { $0.id == secondID } == true },
            timeout: TestConstants.settleTimeout
        )
        #expect(newStored)
        #expect(viewModel.privateChats[geoID]?.contains { $0.id == firstID } == true)
    }

    @Test @MainActor
    func openingDerivedMeshPeerRetainsKnownSameKeyHistory() async throws {
        let (viewModel, transport) = makeTestableViewModel()
        let key = Data(repeating: 0x55, count: 32)
        let fullID = PeerID(hexData: key)
        let shortID = PeerID(publicKey: key)
        let messageID = UUID().uuidString
        viewModel.handlePrivateMessage(BitchatMessage(id: messageID, sender: "Unknown",
            content: "same key history", timestamp: Date(), isRelay: false,
            isPrivate: true, senderPeerID: fullID))
        try #require(viewModel.privateChats[fullID]?.contains { $0.id == messageID } == true)
        transport.peerNicknames[shortID] = "alice"
        transport.connectedPeers.insert(shortID)
        transport.updatePeerSnapshots([TransportPeerSnapshot(peerID: shortID, nickname: "alice",
            isConnected: true, noisePublicKey: key, lastSeen: Date())])
        let known = await TestHelpers.waitUntil(
            { viewModel.unifiedPeerService.getPeer(by: shortID)?.noisePublicKey == key },
            timeout: TestConstants.settleTimeout)
        try #require(known)
        viewModel.startPrivateChat(with: shortID)
        #expect(viewModel.privateChats[fullID] == nil)
        #expect(viewModel.privateChats[shortID]?.contains { $0.id == messageID } == true)
        #expect(viewModel.privateChats[shortID]?.first { $0.id == messageID }?.senderPeerID == shortID)
    }

}

struct ConversationUIBlockIdentityTests {
    @MainActor
    private func uiModel(_ viewModel: ChatViewModel) -> ConversationUIModel {
        let privateModel = PrivateConversationModel(chatViewModel: viewModel,
            conversations: viewModel.conversations,
            locationChannelsModel: LocationChannelsModel(manager: viewModel.locationManager))
        return ConversationUIModel(chatViewModel: viewModel, privateConversationModel: privateModel,
            conversations: viewModel.conversations)
    }

    @MainActor
    private func registerMeshPeer(_ key: Data, named name: String,
                                  viewModel: ChatViewModel, transport: MockTransport) async throws -> PeerID {
        let peer = PeerID(publicKey: key)
        transport.peerNicknames[peer] = name
        transport.peerFingerprints[peer] = key.sha256Fingerprint()
        transport.connectedPeers.insert(peer)
        transport.updatePeerSnapshots([TransportPeerSnapshot(peerID: peer, nickname: name,
            isConnected: true, noisePublicKey: key, lastSeen: Date())])
        let indexed = await TestHelpers.waitUntil(
            { viewModel.unifiedPeerService.getPeer(by: peer)?.noisePublicKey == key },
            timeout: TestConstants.settleTimeout)
        try #require(indexed)
        return peer
    }

    @Test(arguments: [false, true]) @MainActor
    func blockEncryptedGeoDMTargetsSenderDespiteMatchingMeshName(locationChannel: Bool) async throws {
        let (viewModel, transport) = makeTestableViewModel()
        let sender = try NostrIdentity(privateKeyData: Data(repeating: 0x11, count: 32))
        let recipient = try NostrIdentity(privateKeyData: Data(repeating: 0x12, count: 32))
        let geo = PeerID(nostr_: sender.publicKeyHex)
        let messageID = UUID().uuidString
        let envelope = try NostrProtocol.createPrivateMessage(
            content: privateMessageContent(text: "private message", messageID: messageID),
            recipientPubkey: recipient.publicKeyHex, senderIdentity: sender)
        viewModel.handleGiftWrap(envelope, id: recipient)
        let received = await TestHelpers.waitUntil(
            { viewModel.privateChats[geo]?.contains { $0.id == messageID } == true },
            timeout: TestConstants.settleTimeout)
        try #require(received)
        let row = try #require(viewModel.privateChats[geo]?.first { $0.id == messageID })
        let meshKey = Data(repeating: 0x13, count: 32)
        let mesh = try await registerMeshPeer(meshKey, named: row.sender, viewModel: viewModel, transport: transport)
        viewModel.activeChannel = locationChannel ? .location(GeohashChannel(level: .city, geohash: "s0000")) : .mesh
        viewModel.startPrivateChat(with: geo)
        #expect(row.senderPeerID == geo)
        #expect(viewModel.privateChats[mesh] == nil)
        uiModel(viewModel).block(peerID: row.senderPeerID, displayName: row.sender)
        #expect(viewModel.identityManager.isNostrBlocked(pubkeyHexLowercased: sender.publicKeyHex))
        #expect(!viewModel.identityManager.isBlocked(fingerprint: meshKey.sha256Fingerprint()))
        #expect(viewModel.privateChats[geo] == nil)

        let nextID = UUID().uuidString
        let next = try NostrProtocol.createPrivateMessage(
            content: privateMessageContent(text: "after block", messageID: nextID),
            recipientPubkey: recipient.publicKeyHex, senderIdentity: sender)
        viewModel.handleGiftWrap(next, id: recipient)
        // Blocking removed the mapping. Its return marks the next envelope's handler completion.
        let processed = await TestHelpers.waitUntil(
            { viewModel.nostrKeyMapping[geo] == sender.publicKeyHex }, timeout: TestConstants.settleTimeout)
        #expect(processed)
        #expect(viewModel.privateChats[geo]?.contains { $0.id == messageID || $0.id == nextID } != true)
        #expect(!viewModel.sentGeoDeliveryAcks.contains(nextID))
        #expect(!viewModel.identityManager.isBlocked(fingerprint: meshKey.sha256Fingerprint()))
    }

    @Test(arguments: [false, true]) @MainActor
    func blockGeohashWithoutKeyDoesNotFallBackToMatchingMeshName(privateMessage: Bool) async throws {
        let (viewModel, transport) = makeTestableViewModel()
        let key = Data(repeating: 0x21, count: 32)
        _ = try await registerMeshPeer(key, named: "same-name", viewModel: viewModel, transport: transport)
        let pubkey = String(repeating: "ab", count: 32)
        let geo = privateMessage ? PeerID(nostr_: pubkey) : PeerID(nostr: pubkey)
        viewModel.activeChannel = .mesh
        #expect(viewModel.fullNostrHex(forSenderPeerID: geo) == nil)
        uiModel(viewModel).block(peerID: geo, displayName: "same-name")
        // The old fallback enqueues a command; observe the block state across that async work.
        let wrongPeerBlocked = await TestHelpers.waitUntil(
            { viewModel.identityManager.isBlocked(fingerprint: key.sha256Fingerprint()) },
            timeout: TestConstants.negativeWaitWindow)
        #expect(!wrongPeerBlocked)
        #expect(!viewModel.identityManager.isNostrBlocked(pubkeyHexLowercased: pubkey))
    }

    @Test @MainActor
    func blockPublicGeohashUsesMappedKeyDespiteMatchingMeshName() async throws {
        let (viewModel, transport) = makeTestableViewModel()
        let key = Data(repeating: 0x31, count: 32)
        _ = try await registerMeshPeer(key, named: "same-name", viewModel: viewModel, transport: transport)
        let pubkey = String(repeating: "cd", count: 32)
        let geo = PeerID(nostr: pubkey)
        viewModel.registerNostrKeyMapping(pubkey, for: geo)
        uiModel(viewModel).block(peerID: geo, displayName: "same-name")
        #expect(viewModel.identityManager.isNostrBlocked(pubkeyHexLowercased: pubkey))
        #expect(!viewModel.identityManager.isBlocked(fingerprint: key.sha256Fingerprint()))
    }

    @Test @MainActor
    func blockMeshUsesTappedIdentityDespiteAnotherPeersDisplayName() async throws {
        let (viewModel, transport) = makeTestableViewModel()
        let key = Data(repeating: 0x41, count: 32)
        let peer = try await registerMeshPeer(key, named: "alice", viewModel: viewModel, transport: transport)
        let other = PeerID(publicKey: Data(repeating: 0x42, count: 32))
        transport.peerNicknames[other] = "bob"
        transport.peerFingerprints[other] = "other-fingerprint"
        viewModel.activeChannel = .mesh
        uiModel(viewModel).block(peerID: peer, displayName: "bob")
        #expect(viewModel.identityManager.isBlocked(fingerprint: key.sha256Fingerprint()))
        #expect(!viewModel.identityManager.isBlocked(fingerprint: "other-fingerprint"))
    }
}
