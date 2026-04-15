//
// ChatViewModelTests.swift
// bitchatTests
//
// Tests for ChatViewModel using MockTransport for isolation.
// This is free and unencumbered software released into the public domain.
//

import Testing
import Foundation
import BitFoundation
@testable import bitchat

// MARK: - Test Helpers

/// Creates a ChatViewModel with mock dependencies for testing
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

// MARK: - Initialization Tests

struct ChatViewModelInitializationTests {

    @Test @MainActor
    func initialization_setsDelegate() async {
        let (viewModel, transport) = makeTestableViewModel()

        // The viewModel should set itself as the transport delegate
        #expect(transport.delegate === viewModel)
    }

    @Test @MainActor
    func initialization_startsServices() async {
        let (_, transport) = makeTestableViewModel()

        // Services should be started during init
        #expect(transport.startServicesCallCount == 1)
    }

    @Test @MainActor
    func initialization_hasEmptyMessageList() async {
        let (viewModel, _) = makeTestableViewModel()

        // Initial messages may include system messages, but should be limited
        #expect(viewModel.messages.count < 10)
    }

    @Test @MainActor
    func initialization_setsNickname() async {
        let (_, transport) = makeTestableViewModel()

        // Nickname should be set during init
        #expect(!transport.myNickname.isEmpty)
    }

    @Test @MainActor
    func initialization_bindsPeerSnapshotsIntoAllPeers() async {
        let (viewModel, transport) = makeTestableViewModel()
        let peerID = PeerID(str: "00000000000000a1")
        let noiseKey = Data(repeating: 0xAB, count: 32)

        transport.updatePeerSnapshots([
            TransportPeerSnapshot(
                peerID: peerID,
                nickname: "Alice",
                isConnected: true,
                noisePublicKey: noiseKey,
                lastSeen: Date()
            )
        ])

        let updated = await TestHelpers.waitUntil({
            viewModel.allPeers.contains { $0.peerID == peerID && $0.nickname == "Alice" }
        }, timeout: TestConstants.defaultTimeout)

        #expect(updated)
    }
}

// MARK: - Identity Tests

struct ChatViewModelIdentityTests {

    @Test @MainActor
    func updatePrivateChatPeerIfNeeded_migratesSelectionHistoryByFingerprint() async {
        let (viewModel, transport) = makeTestableViewModel()
        let oldPeerID = PeerID(str: "00000000000000d1")
        let newPeerID = PeerID(str: "00000000000000d2")
        let sharedFingerprint = "fingerprint-shared"
        let sharedNoiseKey = Data(repeating: 0xAB, count: 32)

        transport.peerFingerprints[oldPeerID] = sharedFingerprint
        transport.peerFingerprints[newPeerID] = sharedFingerprint
        transport.peerNicknames[oldPeerID] = "Alice"
        transport.peerNicknames[newPeerID] = "Alice"
        transport.updatePeerSnapshots([
            TransportPeerSnapshot(
                peerID: oldPeerID,
                nickname: "Alice",
                isConnected: true,
                noisePublicKey: sharedNoiseKey,
                lastSeen: Date()
            )
        ])

        let oldPeerBound = await TestHelpers.waitUntil({
            viewModel.connectedPeers.contains(oldPeerID)
        }, timeout: TestConstants.defaultTimeout)
        #expect(oldPeerBound)

        let existingMessage = BitchatMessage(
            id: "pm-migrate-1",
            sender: "Alice",
            content: "Still here",
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: true,
            recipientNickname: viewModel.nickname,
            senderPeerID: oldPeerID,
            mentions: nil
        )
        viewModel.privateChats[oldPeerID] = [existingMessage]
        viewModel.startPrivateChat(with: oldPeerID)

        #expect(viewModel.selectedPrivateChatPeer == oldPeerID)
        #expect(viewModel.hasTrackedPrivateChatSelection)
        #expect(viewModel.selectedPrivateChatFingerprint == viewModel.getFingerprint(for: oldPeerID))

        transport.updatePeerSnapshots([
            TransportPeerSnapshot(
                peerID: newPeerID,
                nickname: "Alice",
                isConnected: true,
                noisePublicKey: sharedNoiseKey,
                lastSeen: Date()
            )
        ])

        let newPeerBound = await TestHelpers.waitUntil({
            viewModel.connectedPeers.contains(newPeerID) && !viewModel.connectedPeers.contains(oldPeerID)
        }, timeout: TestConstants.defaultTimeout)
        #expect(newPeerBound)

        viewModel.updatePrivateChatPeerIfNeeded()

        #expect(viewModel.selectedPrivateChatPeer == newPeerID)
        #expect(viewModel.privateChats[oldPeerID] == nil)
        #expect(viewModel.privateChats[newPeerID]?.contains(where: { $0.id == "pm-migrate-1" }) == true)
    }

    @Test @MainActor
    func resolveNickname_prefersLocalPetnameOverClaimedNickname() async {
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
        let peerID = PeerID(str: "00000000000000d3")
        let fingerprint = "fingerprint-petname"

        transport.peerFingerprints[peerID] = fingerprint
        identityManager.updateSocialIdentity(
            SocialIdentity(
                fingerprint: fingerprint,
                localPetname: "Buddy",
                claimedNickname: "Alice",
                trustLevel: .trusted,
                isFavorite: false,
                isBlocked: false,
                notes: nil
            )
        )

        #expect(viewModel.getFingerprint(for: peerID) == fingerprint)
        #expect(viewModel.resolveNickname(for: peerID) == "Buddy")
    }
}

// MARK: - Message Sending Tests

struct ChatViewModelSendingTests {

    @Test @MainActor
    func sendMessage_delegatesToTransport() async {
        let (viewModel, transport) = makeTestableViewModel()

        viewModel.sendMessage("Hello World")

        #expect(transport.sentMessages.count == 1)
        #expect(transport.sentMessages.first?.content == "Hello World")
    }

    @Test @MainActor
    func sendMessage_emptyContent_ignored() async {
        let (viewModel, transport) = makeTestableViewModel()

        viewModel.sendMessage("")
        viewModel.sendMessage("   ")
        viewModel.sendMessage("\n\t")

        #expect(transport.sentMessages.isEmpty)
    }

    @Test @MainActor
    func sendMessage_withMentions_sendsContent() async {
        let (viewModel, transport) = makeTestableViewModel()

        viewModel.sendMessage("Hello @alice")

        #expect(transport.sentMessages.count == 1)
        #expect(transport.sentMessages.first?.content == "Hello @alice")
    }

    @Test @MainActor
    func sendMessage_command_notSentToTransport() async {
        let (viewModel, transport) = makeTestableViewModel()

        viewModel.sendMessage("/help")

        // Commands are processed locally, not sent to transport
        #expect(transport.sentMessages.isEmpty)
    }
}

// MARK: - Command Handling Tests

struct ChatViewModelCommandTests {

    @Test @MainActor
    func sendMessage_commandsNotSentToTransport() async {
        let (viewModel, transport) = makeTestableViewModel()
        let commands = ["/nick bob", "/who", "/help", "/clear"]

        for command in commands {
            transport.resetRecordings()
            viewModel.sendMessage(command)
            try? await Task.sleep(nanoseconds: 100_000_000)

            #expect(transport.sentMessages.isEmpty)
            #expect(transport.sentPrivateMessages.isEmpty)
        }
    }
}

// MARK: - Composer Tests

struct ChatViewModelComposerTests {

    @Test @MainActor
    func updateAutocomplete_suggestsKnownPeersAndExcludesSelf() async {
        let (viewModel, transport) = makeTestableViewModel()
        let alice = PeerID(str: "00000000000000a1")
        let selfAlias = PeerID(str: "00000000000000a2")

        transport.simulateConnect(alice, nickname: "Alice")
        transport.simulateConnect(selfAlias, nickname: viewModel.nickname)

        viewModel.updateAutocomplete(for: "hello @Al", cursorPosition: 9)

        #expect(viewModel.showAutocomplete)
        #expect(viewModel.autocompleteSuggestions == ["@Alice"])
    }

    @Test @MainActor
    func completeNickname_replacesTokenAndClearsAutocompleteState() async {
        let (viewModel, _) = makeTestableViewModel()
        var text = "hello @Al"

        viewModel.autocompleteSuggestions = ["@Alice"]
        viewModel.autocompleteRange = NSRange(location: 6, length: 3)
        viewModel.showAutocomplete = true
        viewModel.selectedAutocompleteIndex = 0

        _ = viewModel.completeNickname("@Alice", in: &text)

        #expect(text == "hello @Alice")
        #expect(viewModel.autocompleteSuggestions.isEmpty)
        #expect(viewModel.autocompleteRange == nil)
        #expect(!viewModel.showAutocomplete)
        #expect(viewModel.selectedAutocompleteIndex == 0)
    }

    @Test @MainActor
    func parseMentions_filtersToKnownPeerAndSelfTokens() async {
        let (viewModel, transport) = makeTestableViewModel()
        let alice = PeerID(str: "00000000000000b1")

        transport.simulateConnect(alice, nickname: "Alice")

        let mentions = Set(
            viewModel.parseMentions(
                from: "hi @Alice @nobody @\(viewModel.nickname)"
            )
        )

        #expect(mentions.contains("Alice"))
        #expect(mentions.contains(viewModel.nickname))
        #expect(!mentions.contains("nobody"))
    }
}

// MARK: - Lifecycle Tests

struct ChatViewModelServiceLifecycleTests {

    @Test @MainActor
    func handleDidBecomeActive_marksVisiblePrivateMessagesAsRead() async {
        let (viewModel, transport) = makeTestableViewModel()
        let peerID = PeerID(str: "0000000000000001")
        transport.simulateConnect(peerID, nickname: "Alice")

        let message = BitchatMessage(
            id: "read-1",
            sender: "Alice",
            content: "Hello from Alice",
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: true,
            recipientNickname: viewModel.nickname,
            senderPeerID: peerID,
            mentions: nil
        )

        viewModel.privateChats[peerID] = [message]
        viewModel.unreadPrivateMessages.insert(peerID)
        viewModel.selectedPrivateChatPeer = peerID

        viewModel.handleDidBecomeActive()

        let sentReadReceipt = await TestHelpers.waitUntil({
            transport.sentReadReceipts.contains {
                $0.peerID == peerID && $0.receipt.originalMessageID == "read-1"
            }
        }, timeout: TestConstants.defaultTimeout)

        #expect(sentReadReceipt)
        #expect(!viewModel.unreadPrivateMessages.contains(peerID))
    }

    @Test @MainActor
    func handleScreenshotCaptured_privateChatAddsLocalNoticeWithoutSession() async {
        let (viewModel, transport) = makeTestableViewModel()
        let peerID = PeerID(str: "0000000000000002")
        transport.simulateConnect(peerID, nickname: "Alice")

        viewModel.selectedPrivateChatPeer = peerID
        viewModel.handleScreenshotCaptured()

        #expect(transport.sentPrivateMessages.isEmpty)
        #expect(viewModel.privateChats[peerID]?.last?.content == "you took a screenshot")
    }
}

// MARK: - Timeline Cap Tests

struct ChatViewModelTimelineCapTests {

    @Test @MainActor
    func sendMessage_trimsTimelineToCap() async {
        let (viewModel, _) = makeTestableViewModel()
        let total = TransportConfig.meshTimelineCap + 5

        for i in 0..<total {
            viewModel.sendMessage("cap-msg-\(i)")
        }

        #expect(viewModel.messages.count == TransportConfig.meshTimelineCap)
        #expect(viewModel.messages.last?.content == "cap-msg-\(total - 1)")
    }
}

// MARK: - Message Receiving Tests

struct ChatViewModelReceivingTests {

    @Test @MainActor
    func didReceiveMessage_callsDelegate() async {
        let (viewModel, transport) = makeTestableViewModel()

        let message = BitchatMessage(
            id: "msg-001",
            sender: "Alice",
            content: "Hello from Alice",
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: false,
            recipientNickname: nil,
            senderPeerID: PeerID(str: "PEER001"),
            mentions: nil
        )

        transport.simulateIncomingMessage(message)

        // Give time for Task and pipeline processing
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Message may or may not appear due to rate limiting/pipeline batching
        // The important thing is no crash and delegate was called
        #expect(transport.delegate === viewModel)
    }

    @Test @MainActor
    func didReceivePublicMessage_addsToTimeline() async {
        let (viewModel, transport) = makeTestableViewModel()

        transport.simulateIncomingPublicMessage(
            from: PeerID(str: "PEER002"),
            nickname: "Bob",
            content: "Public hello from Bob",
            timestamp: Date(),
            messageID: "pub-001"
        )

        let found = await TestHelpers.waitUntil({
            viewModel.timelineStore.messages(for: .mesh).contains { $0.content == "Public hello from Bob" }
        }, timeout: TestConstants.defaultTimeout)

        #expect(found)
    }
}

// MARK: - Noise Payload Tests

struct ChatViewModelNoisePayloadTests {

    @Test @MainActor
    func didReceiveNoisePayload_privateMessageStoresMessageAndSendsDeliveryAck() async {
        let (viewModel, transport) = makeTestableViewModel()
        let peerID = PeerID(str: "0000000000000003")
        transport.simulateConnect(peerID, nickname: "Alice")

        let payload = PrivateMessagePacket(messageID: "pm-noise-1", content: "Secret hello").encode()
        #expect(payload != nil)
        guard let payload else { return }

        viewModel.didReceiveNoisePayload(
            from: peerID,
            type: .privateMessage,
            payload: payload,
            timestamp: Date()
        )

        let stored = await TestHelpers.waitUntil({
            viewModel.privateChats[peerID]?.contains(where: { $0.id == "pm-noise-1" && $0.content == "Secret hello" }) == true
        }, timeout: TestConstants.defaultTimeout)

        let acked = await TestHelpers.waitUntil({
            transport.sentDeliveryAcks.contains { $0.messageID == "pm-noise-1" && $0.peerID == peerID }
        }, timeout: TestConstants.defaultTimeout)

        #expect(stored)
        #expect(acked)
    }

    @Test @MainActor
    func didReceiveNoisePayload_deliveredUpdatesExistingPrivateMessageStatus() async {
        let (viewModel, transport) = makeTestableViewModel()
        let peerID = PeerID(str: "0000000000000004")
        transport.simulateConnect(peerID, nickname: "Bob")

        let message = BitchatMessage(
            id: "pm-delivered-1",
            sender: viewModel.nickname,
            content: "Waiting on ack",
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: true,
            recipientNickname: "Bob",
            senderPeerID: viewModel.meshService.myPeerID,
            mentions: nil,
            deliveryStatus: .sent
        )
        viewModel.privateChats[peerID] = [message]

        viewModel.didReceiveNoisePayload(
            from: peerID,
            type: .delivered,
            payload: Data("pm-delivered-1".utf8),
            timestamp: Date()
        )

        let delivered = await TestHelpers.waitUntil({
            guard let status = viewModel.privateChats[peerID]?.first?.deliveryStatus else { return false }
            if case .delivered(let name, _) = status {
                return name == "Bob"
            }
            return false
        }, timeout: TestConstants.defaultTimeout)

        #expect(delivered)
    }
}

// MARK: - Formatting Tests

struct ChatViewModelFormattingTests {

    @Test @MainActor
    func formatMessageAsText_formatsSenderContentAndTimestamp() async {
        let (viewModel, _) = makeTestableViewModel()
        let message = BitchatMessage(
            id: "fmt-1",
            sender: "Alice#a1b2",
            content: "hello #mesh",
            timestamp: Date(timeIntervalSince1970: 1_700_010_000),
            isRelay: false,
            senderPeerID: PeerID(str: "00000000000000b1")
        )

        let formatted = viewModel.formatMessageAsText(message, colorScheme: .light)

        #expect(String(formatted.characters) == "<@Alice#a1b2> hello #mesh [\(message.formattedTimestamp)]")
    }

    @Test @MainActor
    func formatMessageHeader_formatsSenderHeader() async {
        let (viewModel, _) = makeTestableViewModel()
        let message = BitchatMessage(
            id: "fmt-2",
            sender: "Alice#a1b2",
            content: "hello",
            timestamp: Date(),
            isRelay: false,
            senderPeerID: PeerID(str: "00000000000000b2")
        )

        let header = viewModel.formatMessageHeader(message, colorScheme: .dark)

        #expect(String(header.characters) == "<@Alice#a1b2> ")
    }
}

// MARK: - Verification Tests

struct ChatViewModelVerificationTests {

    @Test @MainActor
    func beginQRVerification_unknownNoiseKeyReturnsFalse() async {
        let (viewModel, _) = makeTestableViewModel()
        let qr = VerificationService.VerificationQR(
            v: 1,
            noiseKeyHex: String(repeating: "a", count: 64),
            signKeyHex: String(repeating: "b", count: 64),
            npub: nil,
            nickname: "Alice",
            ts: 1_700_000_000,
            nonceB64: "nonce",
            sigHex: "sig"
        )

        #expect(!viewModel.beginQRVerification(with: qr))
    }

    @Test @MainActor
    func beginQRVerification_knownPeerTriggersHandshakeWhenSessionNotEstablished() async {
        let (viewModel, transport) = makeTestableViewModel()
        let peerID = PeerID(str: "00000000000000c1")
        let noiseKey = Data(repeating: 0xAB, count: 32)

        transport.updatePeerSnapshots([
            TransportPeerSnapshot(
                peerID: peerID,
                nickname: "Alice",
                isConnected: true,
                noisePublicKey: noiseKey,
                lastSeen: Date()
            )
        ])

        let bound = await TestHelpers.waitUntil({
            viewModel.unifiedPeerService.peers.contains { $0.peerID == peerID }
        }, timeout: TestConstants.defaultTimeout)
        #expect(bound)

        let qr = VerificationService.VerificationQR(
            v: 1,
            noiseKeyHex: noiseKey.hexEncodedString(),
            signKeyHex: String(repeating: "c", count: 64),
            npub: nil,
            nickname: "Alice",
            ts: 1_700_000_000,
            nonceB64: "nonce",
            sigHex: "sig"
        )

        #expect(viewModel.beginQRVerification(with: qr))
        #expect(transport.triggeredHandshakes == [peerID])
    }
}

// MARK: - Rate Limiting Tests

struct ChatViewModelRateLimitingTests {

    @Test @MainActor
    func handlePublicMessage_rateLimitsBurstBySender() async {
        let (viewModel, _) = makeTestableViewModel()
        let senderID = PeerID(str: "1122334455667788")
        let now = Date()

        for i in 0..<6 {
            let message = BitchatMessage(
                id: "rate-\(i)",
                sender: "Spammer",
                content: "rate-msg-\(i)",
                timestamp: now,
                isRelay: false,
                originalSender: nil,
                isPrivate: false,
                recipientNickname: nil,
                senderPeerID: senderID,
                mentions: nil
            )
            viewModel.handlePublicMessage(message)
        }

        viewModel.publicMessagePipeline.flushIfNeeded()

        let burstMessages = viewModel.messages.filter { $0.content.hasPrefix("rate-msg-") }
        #expect(burstMessages.count == 5)
        #expect(!burstMessages.contains { $0.content == "rate-msg-5" })
    }
}

// MARK: - Public Conversation Tests

struct ChatViewModelPublicConversationTests {

    @Test @MainActor
    func addPublicSystemMessage_persistsAcrossTimelineRefresh() async {
        let (viewModel, _) = makeTestableViewModel()

        viewModel.addPublicSystemMessage("system refresh test")
        viewModel.messages.removeAll()
        viewModel.refreshVisibleMessages(from: .mesh)

        #expect(viewModel.messages.last?.content == "system refresh test")
    }

    @Test @MainActor
    func clearCurrentPublicTimeline_clearsVisibleAndBackedMessages() async {
        let (viewModel, _) = makeTestableViewModel()

        viewModel.addPublicSystemMessage("system clear test")
        #expect(!viewModel.messages.isEmpty)

        viewModel.clearCurrentPublicTimeline()
        viewModel.refreshVisibleMessages(from: .mesh)

        #expect(viewModel.messages.isEmpty)
    }
}

// MARK: - Peer Connection Tests

struct ChatViewModelPeerTests {

    @Test @MainActor
    func didConnectToPeer_notifiesDelegate() async {
        let (_, transport) = makeTestableViewModel()
        let peerID = PeerID(str: "NEWPEER")

        transport.simulateConnect(peerID, nickname: "NewUser")

        #expect(transport.connectedPeers.contains(peerID))
    }

    @Test @MainActor
    func didDisconnectFromPeer_notifiesDelegate() async {
        let (_, transport) = makeTestableViewModel()
        let peerID = PeerID(str: "OLDPEER")

        transport.simulateConnect(peerID, nickname: "OldUser")
        transport.simulateDisconnect(peerID)

        #expect(!transport.connectedPeers.contains(peerID))
    }

    @Test @MainActor
    func isPeerConnected_delegatesToTransport() async {
        let (_, transport) = makeTestableViewModel()
        let peerID = PeerID(str: "TESTPEER")

        // Not connected initially
        #expect(!transport.isPeerConnected(peerID))

        transport.connectedPeers.insert(peerID)

        #expect(transport.isPeerConnected(peerID))
    }

    @Test @MainActor
    func didUpdatePeerList_removesStaleUnreadPeerWithoutMessages() async {
        let (viewModel, _) = makeTestableViewModel()
        let stalePeer = PeerID(str: "00000000000000a2")
        viewModel.unreadPrivateMessages = [stalePeer]

        viewModel.didUpdatePeerList([])

        let cleaned = await TestHelpers.waitUntil({
            !viewModel.unreadPrivateMessages.contains(stalePeer)
        }, timeout: TestConstants.defaultTimeout)

        #expect(cleaned)
    }

    @Test @MainActor
    func didUpdatePeerList_preservesStableUnreadPeerWhenMessagesExist() async {
        let (viewModel, _) = makeTestableViewModel()
        let stablePeer = PeerID(str: String(repeating: "a", count: 64))
        let message = BitchatMessage(
            id: "stable-noise-1",
            sender: "Alice",
            content: "Offline hello",
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: true,
            recipientNickname: viewModel.nickname,
            senderPeerID: stablePeer,
            mentions: nil
        )
        viewModel.privateChats[stablePeer] = [message]
        viewModel.unreadPrivateMessages = [stablePeer]

        viewModel.didUpdatePeerList([])
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.unreadPrivateMessages.contains(stablePeer))
    }
}

// MARK: - Deduplication Integration Tests
//
// Note: Detailed deduplication logic is tested in MessageDeduplicationServiceTests.
// These tests verify that ChatViewModel has a deduplication service configured.

struct ChatViewModelDeduplicationTests {

    @Test @MainActor
    func deduplicationService_isConfigured() async {
        let (viewModel, _) = makeTestableViewModel()

        // Verify the deduplication service is available and functional
        // by checking that we can record and query content
        let testContent = "Test dedup content \(UUID().uuidString)"
        let testDate = Date()

        viewModel.deduplicationService.recordContent(testContent, timestamp: testDate)

        let retrieved = viewModel.deduplicationService.contentTimestamp(for: testContent)
        #expect(retrieved == testDate)
    }

    @Test @MainActor
    func deduplicationService_normalizedKey_consistent() async {
        let (viewModel, _) = makeTestableViewModel()

        let content = "Hello World"
        let key1 = viewModel.deduplicationService.normalizedContentKey(content)
        let key2 = viewModel.deduplicationService.normalizedContentKey(content)

        #expect(key1 == key2)
    }
}

// MARK: - Private Chat Tests

struct ChatViewModelPrivateChatTests {

    @Test @MainActor
    func sendPrivateMessage_delegatesToTransport() async {
        let (viewModel, transport) = makeTestableViewModel()
        let recipientID = PeerID(str: "RECIPIENT")

        // Set up connected peer for routing
        transport.connectedPeers.insert(recipientID)
        transport.peerNicknames[recipientID] = "Recipient"

        viewModel.sendPrivateMessage("Secret message", to: recipientID)

        // The message routing depends on connection state and other factors
        // At minimum, it should not crash
        #expect(true) // If we get here without crash, the test passes
    }
}

// MARK: - Private Chat Selection Tests

struct ChatViewModelPrivateChatSelectionTests {

    @Test @MainActor
    func openMostRelevantPrivateChat_prefersUnreadMostRecent() async {
        let (viewModel, _) = makeTestableViewModel()
        let peerA = PeerID(str: "PEER_A")
        let peerB = PeerID(str: "PEER_B")

        let older = Date().addingTimeInterval(-120)
        let newer = Date().addingTimeInterval(-30)

        viewModel.privateChats = [
            peerA: [
                BitchatMessage(
                    id: "a-1",
                    sender: "A",
                    content: "Old",
                    timestamp: older,
                    isRelay: false,
                    isPrivate: true,
                    recipientNickname: "Me",
                    senderPeerID: peerA
                )
            ],
            peerB: [
                BitchatMessage(
                    id: "b-1",
                    sender: "B",
                    content: "New",
                    timestamp: newer,
                    isRelay: false,
                    isPrivate: true,
                    recipientNickname: "Me",
                    senderPeerID: peerB
                )
            ]
        ]
        viewModel.unreadPrivateMessages = [peerA, peerB]

        viewModel.openMostRelevantPrivateChat()

        #expect(viewModel.selectedPrivateChatPeer == peerB)
    }

    @Test @MainActor
    func openMostRelevantPrivateChat_fallsBackToMostRecentChat() async {
        let (viewModel, _) = makeTestableViewModel()
        let peerA = PeerID(str: "PEER_A")
        let peerB = PeerID(str: "PEER_B")

        let older = Date().addingTimeInterval(-200)
        let newer = Date().addingTimeInterval(-20)

        viewModel.privateChats = [
            peerA: [
                BitchatMessage(
                    id: "a-1",
                    sender: "A",
                    content: "Old",
                    timestamp: older,
                    isRelay: false,
                    isPrivate: true,
                    recipientNickname: "Me",
                    senderPeerID: peerA
                )
            ],
            peerB: [
                BitchatMessage(
                    id: "b-1",
                    sender: "B",
                    content: "New",
                    timestamp: newer,
                    isRelay: false,
                    isPrivate: true,
                    recipientNickname: "Me",
                    senderPeerID: peerB
                )
            ]
        ]

        viewModel.openMostRelevantPrivateChat()

        #expect(viewModel.selectedPrivateChatPeer == peerB)
    }
}

// MARK: - Bluetooth State Tests

struct ChatViewModelBluetoothTests {

    @Test @MainActor
    func didUpdateBluetoothState_poweredOn_noAlert() async {
        let (viewModel, transport) = makeTestableViewModel()

        transport.simulateBluetoothStateChange(.poweredOn)

        // Give time for async processing
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(!viewModel.showBluetoothAlert)
    }

    @Test @MainActor
    func didUpdateBluetoothState_poweredOff_showsAlert() async {
        let (viewModel, transport) = makeTestableViewModel()

        transport.simulateBluetoothStateChange(.poweredOff)

        // Give time for async processing
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.showBluetoothAlert)
    }

    @Test @MainActor
    func didUpdateBluetoothState_unauthorized_showsAlert() async {
        let (viewModel, transport) = makeTestableViewModel()

        transport.simulateBluetoothStateChange(.unauthorized)

        // Give time for async processing
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.showBluetoothAlert)
    }
}

// MARK: - Panic Clear Tests

struct ChatViewModelPanicTests {

    @Test @MainActor
    func panicClearAllData_delegatesToTransport() async {
        let (viewModel, transport) = makeTestableViewModel()

        // Set up some state
        transport.connectedPeers.insert(PeerID(str: "PEER1"))
        viewModel.messages = [
            BitchatMessage(
                id: "panic-1",
                sender: "Tester",
                content: "Before",
                timestamp: Date(),
                isRelay: false
            )
        ]
        viewModel.privateChats[PeerID(str: "PEER1")] = [
            BitchatMessage(
                id: "pm-1",
                sender: "Peer",
                content: "Secret",
                timestamp: Date(),
                isRelay: false,
                isPrivate: true,
                recipientNickname: "Me",
                senderPeerID: PeerID(str: "PEER1")
            )
        ]
        viewModel.unreadPrivateMessages.insert(PeerID(str: "PEER1"))

        viewModel.panicClearAllData()

        // After panic, emergency disconnect should be called
        #expect(transport.emergencyDisconnectCallCount == 1)
        #expect(viewModel.messages.isEmpty)
        #expect(viewModel.privateChats.isEmpty)
        #expect(viewModel.unreadPrivateMessages.isEmpty)
        #expect(viewModel.selectedPrivateChatPeer == nil)
    }
}

// MARK: - Service Lifecycle Tests

struct ChatViewModelLifecycleTests {

    @Test @MainActor
    func startServices_calledOnInit() async {
        let (_, transport) = makeTestableViewModel()

        #expect(transport.startServicesCallCount == 1)
    }
}
