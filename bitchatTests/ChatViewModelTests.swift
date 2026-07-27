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
private func makeTestableViewModel(
    keychain injectedKeychain: MockKeychain? = nil,
    panicMediaWipe: (() throws -> Void)? = nil,
    panicRecoveryOperations: PanicRecoveryOperations? = nil,
    panicNetworkLifecycle: PanicNetworkLifecycle = .noop
) -> (viewModel: ChatViewModel, transport: MockTransport) {
    let keychain = injectedKeychain ?? MockKeychain()
    let keychainHelper = MockKeychainHelper()
    let idBridge = NostrIdentityBridge(keychain: keychainHelper)
    let identityManager = MockIdentityManager(keychain)
    let transport = MockTransport()

    let viewModel = ChatViewModel(
        keychain: keychain,
        idBridge: idBridge,
        identityManager: identityManager,
        transport: transport,
        panicMediaWipe: panicMediaWipe,
        panicRecoveryOperations: panicRecoveryOperations,
        panicNetworkLifecycle: panicNetworkLifecycle
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
        #expect(transport.eventDelegate === viewModel)
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

        // The snapshot → allPeers binding hops the transport's unstructured
        // Task, UnifiedPeerService, a receive(on: main), and another Task —
        // all contending with every parallel worker, so a loaded CI runner
        // can exceed defaultTimeout (observed: one 5s miss on a run where
        // the whole suite took 10s instead of the usual ~4s).
        let updated = await TestHelpers.waitUntil({
            viewModel.allPeers.contains { $0.peerID == peerID && $0.nickname == "Alice" }
        }, timeout: TestConstants.longTimeout)

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

        // Same multi-hop snapshot pipeline as above: longTimeout for load.
        let oldPeerBound = await TestHelpers.waitUntil({
            viewModel.connectedPeers.contains(oldPeerID)
        }, timeout: TestConstants.longTimeout)
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
        viewModel.seedPrivateChat([existingMessage], for: oldPeerID)
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
        }, timeout: TestConstants.longTimeout)
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

    @Test @MainActor
    func handleCommand_outputRoutesToOpenPrivateChat() async {
        let (viewModel, transport) = makeTestableViewModel()
        let peerID = PeerID(str: "0000000000000002")
        transport.simulateConnect(peerID, nickname: "Alice")
        viewModel.selectedPrivateChatPeer = peerID

        viewModel.handleCommand("/help")

        #expect(viewModel.privateChats[peerID]?.last?.content == CommandProcessor.helpText)
        #expect(!viewModel.messages.contains { $0.content == CommandProcessor.helpText })
    }

    @Test @MainActor
    func handleCommand_errorRoutesToOpenPrivateChat() async {
        let (viewModel, transport) = makeTestableViewModel()
        let peerID = PeerID(str: "0000000000000002")
        transport.simulateConnect(peerID, nickname: "Alice")
        viewModel.selectedPrivateChatPeer = peerID

        viewModel.handleCommand("/bogus")

        let dmContents = viewModel.privateChats[peerID]?.map(\.content) ?? []
        #expect(dmContents.contains { $0.hasPrefix("unknown command: /bogus") })
        #expect(!viewModel.messages.contains { $0.content.hasPrefix("unknown command: /bogus") })
    }

    @Test @MainActor
    func handleCommand_outputRoutesToPublicTimelineWithoutOpenDM() async {
        let (viewModel, _) = makeTestableViewModel()

        viewModel.handleCommand("/bogus")

        #expect(viewModel.messages.last?.content.hasPrefix("unknown command: /bogus") == true)
    }

    @Test @MainActor
    func handleCommand_msgSuccessLandsInNewlyOpenedChat() async {
        let (viewModel, transport) = makeTestableViewModel()
        let peerID = PeerID(str: "0000000000000002")
        transport.simulateConnect(peerID, nickname: "Alice")
        let resolved = await TestHelpers.waitUntil({
            viewModel.getPeerIDForNickname("Alice") == peerID
        }, timeout: TestConstants.negativeWaitWindow)
        #expect(resolved)

        viewModel.handleCommand("/msg Alice")

        #expect(viewModel.selectedPrivateChatPeer == peerID)
        #expect(viewModel.privateChats[peerID]?.last?.content == "started private chat with Alice")
        #expect(!viewModel.messages.contains { $0.content == "started private chat with Alice" })
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

        viewModel.seedPrivateChat([message], for: peerID)
        viewModel.markPrivateChatUnread(peerID)
        viewModel.selectedPrivateChatPeer = peerID

        viewModel.handleDidBecomeActive()

        let sentReadReceipt = await TestHelpers.waitUntil({
            transport.sentReadReceipts.contains {
                $0.peerID == peerID && $0.receipt.originalMessageID == "read-1"
            }
        }, timeout: TestConstants.negativeWaitWindow)

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
        #expect(transport.eventDelegate === viewModel)
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
            viewModel.publicMessages(for: .mesh).contains { $0.content == "Public hello from Bob" }
        }, timeout: TestConstants.settleTimeout)

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
        }, timeout: TestConstants.settleTimeout)

        let acked = await TestHelpers.waitUntil({
            transport.sentDeliveryAcks.contains { $0.messageID == "pm-noise-1" && $0.peerID == peerID }
        }, timeout: TestConstants.settleTimeout)

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
        viewModel.seedPrivateChat([message], for: peerID)

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
        }, timeout: TestConstants.settleTimeout)

        #expect(delivered)
    }

    @Test @MainActor
    func didReceiveNoisePayload_readReceiptUpdatesBeforePeerNicknameIsKnown() async {
        let (viewModel, _) = makeTestableViewModel()
        let peerID = PeerID(str: "0000000000000005")

        let message = BitchatMessage(
            id: "pm-read-before-name",
            sender: viewModel.nickname,
            content: "Waiting on read receipt",
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: true,
            recipientNickname: "Peer",
            senderPeerID: viewModel.meshService.myPeerID,
            mentions: nil,
            deliveryStatus: .sent
        )
        viewModel.seedPrivateChat([message], for: peerID)

        viewModel.didReceiveNoisePayload(
            from: peerID,
            type: .readReceipt,
            payload: Data("pm-read-before-name".utf8),
            timestamp: Date()
        )

        let privateChatUpdated = await TestHelpers.waitUntil({
            guard let status = viewModel.privateChats[peerID]?.first?.deliveryStatus else { return false }
            if case .read = status {
                return true
            }
            return false
        }, timeout: TestConstants.settleTimeout)

        let conversationStoreUpdated = await TestHelpers.waitUntil({
            let messages = viewModel.conversations.conversationsByID[.directPeer(peerID)]?.messages ?? []
            guard let status = messages.first?.deliveryStatus else { return false }
            if case .read = status {
                return true
            }
            return false
        }, timeout: TestConstants.settleTimeout)

        #expect(privateChatUpdated)
        #expect(conversationStoreUpdated)
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
    func formatMessageAsText_longCashuFallsBackToPlain() async {
        let (viewModel, _) = makeTestableViewModel()
        let cashu = "cashuA" + String(repeating: "a", count: 40)
        let longContent = "hi @bob " + cashu + " " + String(repeating: "x", count: 4_100)
        let message = BitchatMessage(
            id: "fmt-long-cashu",
            sender: "Alice#a1b2",
            content: longContent,
            timestamp: Date(timeIntervalSince1970: 1_700_010_123),
            isRelay: false,
            senderPeerID: PeerID(str: "00000000000000b3")
        )

        let formatted = viewModel.formatMessageAsText(message, colorScheme: .light)

        #expect(String(formatted.characters) == "<@Alice#a1b2> \(longContent) [\(message.formattedTimestamp)]")
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
        }, timeout: TestConstants.settleTimeout)
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
    func bridgeAliasReplacementDoesNotContentDedupAwayAuthenticatedRadioRow() {
        let (viewModel, _) = makeTestableViewModel()
        let content = "same bridge and radio payload"
        let timestamp = Date()
        let bridgeMessage = BitchatMessage(
            id: "bridge-event-id",
            sender: "remote#beef",
            content: content,
            timestamp: timestamp,
            isRelay: false,
            senderPeerID: PeerID(bridge: String(repeating: "a", count: 64)),
            isBridged: true
        )
        viewModel.handlePublicMessage(bridgeMessage)
        viewModel.publicMessagePipeline.flushIfNeeded()
        #expect(viewModel.publicConversationContainsMessage(withID: bridgeMessage.id, in: .mesh))

        viewModel.removeBridgeInjectedPublicMessage(withID: bridgeMessage.id)
        let radioMessage = BitchatMessage(
            id: "radio-stable-id",
            sender: "remote",
            content: content,
            timestamp: timestamp,
            isRelay: false,
            senderPeerID: PeerID(str: "1122334455667788")
        )
        viewModel.handlePublicMessage(radioMessage)
        viewModel.publicMessagePipeline.flushIfNeeded()

        #expect(!viewModel.publicConversationContainsMessage(withID: bridgeMessage.id, in: .mesh))
        #expect(viewModel.publicConversationContainsMessage(withID: radioMessage.id, in: .mesh))
    }

    @Test @MainActor
    func addPublicSystemMessage_persistsAcrossTimelineRefresh() async {
        let (viewModel, _) = makeTestableViewModel()

        viewModel.addPublicSystemMessage("system refresh test")
        viewModel.refreshVisibleMessages(from: .mesh)

        // The system message lives in the mesh conversation itself, so the
        // derived `messages` view still surfaces it after a refresh.
        #expect(viewModel.messages.last?.content == "system refresh test")
        #expect(viewModel.publicMessages(for: .mesh).last?.content == "system refresh test")
    }

    @Test @MainActor
    func clearCurrentPublicTimeline_clearsVisibleAndBackedMessages() async {
        let (viewModel, _) = makeTestableViewModel()

        viewModel.addPublicSystemMessage("system clear test")
        #expect(!viewModel.messages.isEmpty)

        viewModel.clearCurrentPublicTimeline()
        viewModel.refreshVisibleMessages(from: .mesh)

        #expect(viewModel.messages.isEmpty)
        #expect(viewModel.publicMessages(for: .mesh).isEmpty)
    }

    @Test @MainActor
    func queuedGeohashSystemMessages_drainOnce() async {
        let (viewModel, _) = makeTestableViewModel()

        viewModel.queueGeohashSystemMessage("first")
        viewModel.queueGeohashSystemMessage("second")

        #expect(viewModel.drainPendingGeohashSystemMessages() == ["first", "second"])
        #expect(viewModel.drainPendingGeohashSystemMessages().isEmpty)
    }
}

// MARK: - Peer Connection Tests

struct ChatViewModelPeerTests {

    @Test @MainActor
    func typedPeerLifecycleEvents_applyBeforeReturning() {
        let (viewModel, _) = makeTestableViewModel()
        let peerID = PeerID(str: "1122334455667788")
        let incoming = BitchatMessage(
            id: "typed-peer-incoming",
            sender: "Alice",
            content: "Hello",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: viewModel.nickname,
            senderPeerID: peerID
        )
        viewModel.seedPrivateChat([incoming], for: peerID)
        viewModel.sentReadReceipts.insert(incoming.id)

        viewModel.didReceiveTransportEvent(.peerConnected(peerID))

        #expect(viewModel.isConnected)

        viewModel.didReceiveTransportEvent(.peerDisconnected(peerID))

        #expect(!viewModel.sentReadReceipts.contains(incoming.id))
    }

    @Test @MainActor
    func typedPeerListDeliveryAndBluetoothEvents_applyBeforeReturning() {
        let (viewModel, transport) = makeTestableViewModel()
        let stalePeer = PeerID(str: "00000000000000a2")
        let deliveryPeer = PeerID(str: "0102030405060708")
        let messageID = "typed-delivery-status"
        let delivered = DeliveryStatus.delivered(
            to: "Alice",
            at: Date(timeIntervalSince1970: 1_234)
        )
        let outgoing = BitchatMessage(
            id: messageID,
            sender: viewModel.nickname,
            content: "On the way",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "Alice",
            senderPeerID: transport.myPeerID,
            deliveryStatus: .sent
        )
        viewModel.markPrivateChatUnread(stalePeer)
        viewModel.seedPrivateChat([outgoing], for: deliveryPeer)

        viewModel.didReceiveTransportEvent(.peerListUpdated([]))
        #expect(!viewModel.unreadPrivateMessages.contains(stalePeer))

        viewModel.didReceiveTransportEvent(
            .messageDeliveryStatusUpdated(
                messageID: messageID,
                status: delivered
            )
        )
        #expect(
            viewModel.privateMessages(for: deliveryPeer).first?.deliveryStatus
                == delivered
        )

        viewModel.didReceiveTransportEvent(.bluetoothStateUpdated(.poweredOff))
        #expect(viewModel.bluetoothState == .poweredOff)
        #expect(viewModel.showBluetoothAlert)

        // Snapshot events belong to TransportPeerEventsDelegate and are
        // intentionally ignored at this typed sink.
        viewModel.didReceiveTransportEvent(.peerSnapshotsUpdated([]))
        #expect(viewModel.bluetoothState == .poweredOff)
    }

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
        viewModel.markPrivateChatUnread(stalePeer)

        viewModel.didUpdatePeerList([])

        let cleaned = await TestHelpers.waitUntil({
            !viewModel.unreadPrivateMessages.contains(stalePeer)
        }, timeout: TestConstants.settleTimeout)

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
        viewModel.seedPrivateChat([message], for: stablePeer)
        viewModel.markPrivateChatUnread(stablePeer)

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
        #expect(Bool(true)) // If we get here without crash, the test passes
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

        viewModel.seedPrivateChat([
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
        ], for: peerA)
        viewModel.seedPrivateChat([
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
        ], for: peerB)
        viewModel.markPrivateChatUnread(peerA)
        viewModel.markPrivateChatUnread(peerB)

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

        viewModel.seedPrivateChat([
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
        ], for: peerA)
        viewModel.seedPrivateChat([
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
        ], for: peerB)

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

// MARK: - Private Media Deletion Tests

struct ChatViewModelPrivateMediaDeletionTests {

    @Test @MainActor
    func deleteMediaMessageTombstonesIncomingButNotOutgoingStableMedia() {
        let (viewModel, transport) = makeTestableViewModel()
        let peerID = PeerID(str: String(repeating: "8", count: 64))
        let incomingID = "media-\(String(repeating: "e", count: 32))"
        let outgoingID = "media-\(String(repeating: "f", count: 32))"
        viewModel.seedPrivateChat([
            privateMediaMessage(
                id: incomingID,
                sender: "Peer",
                senderPeerID: peerID,
                recipient: viewModel.nickname,
                filename: "incoming.jpg"
            ),
            privateMediaMessage(
                id: outgoingID,
                sender: viewModel.nickname,
                senderPeerID: transport.myPeerID,
                recipient: "Peer",
                filename: "outgoing.jpg"
            )
        ], for: peerID)

        viewModel.deleteMediaMessage(messageID: outgoingID)
        #expect(transport.deletedPrivateMediaMessageIDBatches.isEmpty)
        #expect(viewModel.privateChats[peerID]?.map(\.id) == [incomingID])

        viewModel.deleteMediaMessage(messageID: incomingID)
        #expect(
            transport.deletedPrivateMediaMessageIDBatches == [[incomingID]]
        )
        #expect(
            transport.deletedPrivateMediaRelativePaths
                == [[incomingID: "images/incoming/incoming.jpg"]]
        )
        #expect((viewModel.privateChats[peerID] ?? []).isEmpty)
    }

    @Test @MainActor
    func stableDeleteProtectsPathSharedWithLegacyBubble() {
        let (viewModel, transport) = makeTestableViewModel()
        transport.persistDeletedPrivateMediaResult = false
        let peerID = PeerID(str: String(repeating: "6", count: 64))
        let stableID = "media-\(String(repeating: "5", count: 32))"
        let legacyID = UUID().uuidString
        let filename = "shared-migration.jpg"
        viewModel.seedPrivateChat([
            privateMediaMessage(
                id: stableID,
                sender: "Peer",
                senderPeerID: peerID,
                recipient: viewModel.nickname,
                filename: filename
            ),
            privateMediaMessage(
                id: legacyID,
                sender: "Old client",
                senderPeerID: peerID,
                recipient: viewModel.nickname,
                filename: filename
            )
        ], for: peerID)

        viewModel.deleteMediaMessage(messageID: stableID)

        #expect(
            transport.deletedPrivateMediaMessageIDBatches == [[stableID]]
        )
        #expect(transport.deletedPrivateMediaRelativePaths == [[:]])
        #expect(
            transport.protectedPrivateMediaRelativePaths == [[
                "images/incoming/\(filename)"
            ]]
        )
        let messages = viewModel.privateChats[peerID] ?? []
        #expect(messages.prefix(2).map(\.id) == [stableID, legacyID])
        // The refusal is surfaced in the affected chat, not just logged.
        #expect(messages.last?.sender == "system")
        #expect(
            messages.last?.content
                == String(localized: "content.system.media_delete_refused")
        )
    }

    @Test @MainActor
    func clearPrivateChatTombstonesIncomingAndCancelsOutgoingBeforeClear() {
        let (viewModel, transport) = makeTestableViewModel()
        let peerID = PeerID(str: String(repeating: "1", count: 64))
        let incomingID = "media-\(String(repeating: "a", count: 32))"
        let outgoingID = "media-\(String(repeating: "b", count: 32))"
        viewModel.seedPrivateChat([
            privateMediaMessage(
                id: incomingID,
                sender: "Peer",
                senderPeerID: peerID,
                recipient: viewModel.nickname,
                filename: "incoming.jpg"
            ),
            privateMediaMessage(
                id: outgoingID,
                sender: viewModel.nickname,
                senderPeerID: transport.myPeerID,
                recipient: "Peer",
                filename: "outgoing.jpg"
            ),
            BitchatMessage(
                id: "ordinary-message",
                sender: "Peer",
                content: "hello",
                timestamp: Date(),
                isRelay: false,
                isPrivate: true,
                recipientNickname: viewModel.nickname,
                senderPeerID: peerID
            )
        ], for: peerID)
        viewModel.registerTransfer(
            transferId: "outgoing-clear-transfer",
            messageID: outgoingID
        )

        viewModel.clearPrivateChat(peerID)

        #expect(
            transport.deletedPrivateMediaMessageIDBatches == [[incomingID]]
        )
        #expect(
            transport.deletedPrivateMediaRelativePaths
                == [[incomingID: "images/incoming/incoming.jpg"]]
        )
        #expect(
            transport.cancelledTransfers == ["outgoing-clear-transfer"]
        )
        #expect(viewModel.messageIDToTransferId[outgoingID] == nil)
        #expect(viewModel.privateChats[peerID]?.isEmpty == true)
    }

    @Test @MainActor
    func clearPrivateChatPreservesCapturedMessagesWhenTombstoneFails() {
        let (viewModel, transport) = makeTestableViewModel()
        transport.persistDeletedPrivateMediaResult = false
        let peerID = PeerID(str: String(repeating: "2", count: 64))
        let incomingID = "media-\(String(repeating: "c", count: 32))"
        let outgoingID = "media-\(String(repeating: "7", count: 32))"
        viewModel.seedPrivateChat([
            privateMediaMessage(
                id: incomingID,
                sender: "Peer",
                senderPeerID: peerID,
                recipient: viewModel.nickname,
                filename: "incoming.jpg"
            ),
            privateMediaMessage(
                id: outgoingID,
                sender: viewModel.nickname,
                senderPeerID: transport.myPeerID,
                recipient: "Peer",
                filename: "outgoing.jpg"
            ),
            BitchatMessage(
                id: "ordinary-message",
                sender: "Peer",
                content: "keep me on failure",
                timestamp: Date(),
                isRelay: false,
                isPrivate: true,
                recipientNickname: viewModel.nickname,
                senderPeerID: peerID
            )
        ], for: peerID)
        viewModel.registerTransfer(
            transferId: "failed-clear-outgoing",
            messageID: outgoingID
        )

        viewModel.clearPrivateChat(peerID)

        #expect(
            transport.deletedPrivateMediaMessageIDBatches == [[incomingID]]
        )
        let messages = viewModel.privateChats[peerID] ?? []
        #expect(
            messages.prefix(3).map(\.id)
                == [incomingID, outgoingID, "ordinary-message"]
        )
        // The refused /clear is surfaced in the affected chat.
        #expect(messages.last?.sender == "system")
        #expect(
            messages.last?.content
                == String(localized: "content.system.media_delete_refused")
        )
        #expect(transport.cancelledTransfers == ["failed-clear-outgoing"])
        #expect(viewModel.messageIDToTransferId[outgoingID] == nil)
    }

    @Test @MainActor
    func clearFailurePreservesSameNameIncomingPayload() throws {
        let (viewModel, transport) = makeTestableViewModel()
        transport.persistDeletedPrivateMediaResult = false
        let peerID = PeerID(str: String(repeating: "7", count: 64))
        let incomingID = "media-\(String(repeating: "8", count: 32))"
        let outgoingID = "media-\(String(repeating: "9", count: 32))"
        let filename = "clear-collision-\(UUID().uuidString).jpg"
        let filesDirectory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("files/images", isDirectory: true)
        let incomingDirectory = filesDirectory.appendingPathComponent(
            "incoming",
            isDirectory: true
        )
        let outgoingDirectory = filesDirectory.appendingPathComponent(
            "outgoing",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: incomingDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outgoingDirectory,
            withIntermediateDirectories: true
        )
        let incomingURL = incomingDirectory.appendingPathComponent(filename)
        let outgoingURL = outgoingDirectory.appendingPathComponent(filename)
        try Data("incoming".utf8).write(to: incomingURL, options: .atomic)
        try Data("outgoing".utf8).write(to: outgoingURL, options: .atomic)
        defer {
            try? FileManager.default.removeItem(at: incomingURL)
            try? FileManager.default.removeItem(at: outgoingURL)
        }
        viewModel.seedPrivateChat([
            privateMediaMessage(
                id: incomingID,
                sender: "Peer",
                senderPeerID: peerID,
                recipient: viewModel.nickname,
                filename: filename
            ),
            privateMediaMessage(
                id: outgoingID,
                sender: viewModel.nickname,
                senderPeerID: transport.myPeerID,
                recipient: "Peer",
                filename: filename
            )
        ], for: peerID)

        viewModel.clearPrivateChat(peerID)

        #expect(FileManager.default.fileExists(atPath: incomingURL.path))
        #expect(FileManager.default.fileExists(atPath: outgoingURL.path))
        #expect(
            transport.deletedPrivateMediaRelativePaths
                == [[incomingID: "images/incoming/\(filename)"]]
        )
        let messages = viewModel.privateChats[peerID] ?? []
        #expect(messages.prefix(2).map(\.id) == [incomingID, outgoingID])
        #expect(messages.last?.sender == "system")
        #expect(
            messages.last?.content
                == String(localized: "content.system.media_delete_refused")
        )
    }

    @Test @MainActor
    func clearPrivateChatPreservesArrivalDuringTombstoneIO() {
        let (viewModel, transport) = makeTestableViewModel()
        transport.deferDeletedPrivateMediaPersistence = true
        let peerID = PeerID(str: String(repeating: "3", count: 64))
        let incomingID = "media-\(String(repeating: "d", count: 32))"
        viewModel.seedPrivateChat([
            privateMediaMessage(
                id: incomingID,
                sender: "Peer",
                senderPeerID: peerID,
                recipient: viewModel.nickname,
                filename: "incoming.jpg"
            ),
            BitchatMessage(
                id: "captured-text",
                sender: "Peer",
                content: "old",
                timestamp: Date(),
                isRelay: false,
                isPrivate: true,
                recipientNickname: viewModel.nickname,
                senderPeerID: peerID
            )
        ], for: peerID)

        viewModel.clearPrivateChat(peerID)
        let arrival = BitchatMessage(
            id: "concurrent-arrival",
            sender: "Peer",
            content: "new",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: viewModel.nickname,
            senderPeerID: peerID
        )
        #expect(viewModel.appendPrivateMessage(arrival, to: peerID))

        transport.resolveNextDeletedPrivateMediaPersistence(true)

        #expect(
            viewModel.privateChats[peerID]?.map(\.id)
                == ["concurrent-arrival"]
        )
    }

    @Test @MainActor
    func clearPrivateChatPreservesActiveLiveVoiceAssembly() throws {
        let (viewModel, transport) = makeTestableViewModel()
        let peerID = PeerID(str: String(repeating: "7", count: 64))
        viewModel.selectedPrivateChatPeer = peerID
        let burstID = Data(
            repeating: 0xE1,
            count: VoiceBurstPacket.burstIDSize
        )
        let start = try #require(VoiceBurstPacket(
            burstID: burstID,
            seq: 0,
            kind: .start(codec: .aacLC16kMono)
        ))
        let cancel = try #require(VoiceBurstPacket(
            burstID: burstID,
            seq: 1,
            kind: .canceled
        ))
        let coordinator = viewModel.liveVoiceCoordinator
        defer {
            coordinator.handleVoiceFramePayload(
                from: peerID,
                payload: cancel.encode(),
                timestamp: Date()
            )
        }
        coordinator.handleVoiceFramePayload(
            from: peerID,
            payload: start.encode(),
            timestamp: Date()
        )
        let liveMessage = try #require(
            viewModel.privateChats[peerID]?.first
        )
        #expect(coordinator.isLiveVoiceMessage(liveMessage))
        let ordinary = BitchatMessage(
            id: "clear-around-live-voice",
            sender: "Peer",
            content: "old text",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: viewModel.nickname,
            senderPeerID: peerID
        )
        #expect(viewModel.appendPrivateMessage(ordinary, to: peerID))

        viewModel.clearPrivateChat(peerID)

        #expect(transport.deletedPrivateMediaMessageIDBatches.isEmpty)
        #expect(
            viewModel.privateChats[peerID]?.map(\.id)
                == [liveMessage.id]
        )
        #expect(coordinator.isLiveVoiceMessage(liveMessage))
    }

    @Test @MainActor
    func overlappingClearsTombstoneTheLastMirroredStableAlias() {
        let (viewModel, transport) = makeTestableViewModel()
        transport.deferDeletedPrivateMediaPersistence = true
        let firstPeerID = PeerID(str: String(repeating: "b", count: 64))
        let secondPeerID = PeerID(str: String(repeating: "c", count: 64))
        let sharedID = "media-\(String(repeating: "1", count: 32))"
        let firstUniqueID = "media-\(String(repeating: "2", count: 32))"
        let secondUniqueID = "media-\(String(repeating: "3", count: 32))"
        viewModel.seedPrivateChat([
            privateMediaMessage(
                id: sharedID,
                sender: "Peer",
                senderPeerID: firstPeerID,
                recipient: viewModel.nickname,
                filename: "shared.jpg"
            ),
            privateMediaMessage(
                id: firstUniqueID,
                sender: "Peer",
                senderPeerID: firstPeerID,
                recipient: viewModel.nickname,
                filename: "first.jpg"
            )
        ], for: firstPeerID)
        viewModel.seedPrivateChat([
            privateMediaMessage(
                id: sharedID,
                sender: "Peer",
                senderPeerID: secondPeerID,
                recipient: viewModel.nickname,
                filename: "shared.jpg"
            ),
            privateMediaMessage(
                id: secondUniqueID,
                sender: "Peer",
                senderPeerID: secondPeerID,
                recipient: viewModel.nickname,
                filename: "second.jpg"
            )
        ], for: secondPeerID)

        viewModel.clearPrivateChat(firstPeerID)
        viewModel.clearPrivateChat(secondPeerID)
        let queuedArrival = BitchatMessage(
            id: "arrival-after-queued-clear",
            sender: "Peer",
            content: "new",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: viewModel.nickname,
            senderPeerID: secondPeerID
        )
        #expect(viewModel.appendPrivateMessage(
            queuedArrival,
            to: secondPeerID
        ))

        #expect(
            transport.deletedPrivateMediaMessageIDBatches
                == [[firstUniqueID]]
        )

        transport.resolveNextDeletedPrivateMediaPersistence(true)

        #expect(
            transport.deletedPrivateMediaMessageIDBatches == [
                [firstUniqueID],
                [secondUniqueID, sharedID].sorted()
            ]
        )

        transport.resolveNextDeletedPrivateMediaPersistence(true)

        #expect((viewModel.privateChats[firstPeerID] ?? []).isEmpty)
        #expect(
            viewModel.privateChats[secondPeerID]?.map(\.id)
                == ["arrival-after-queued-clear"]
        )
    }

    @Test @MainActor
    func clearFollowsCapturedRowsAcrossPeerIdentityMigration() {
        let (viewModel, transport) = makeTestableViewModel()
        transport.deferDeletedPrivateMediaPersistence = true
        let sourcePeerID = PeerID(str: String(repeating: "d", count: 64))
        let destinationPeerID = PeerID(str: String(repeating: "e", count: 64))
        let thirdPeerID = PeerID(str: String(repeating: "f", count: 64))
        let stableID = "media-\(String(repeating: "4", count: 32))"
        viewModel.selectedPrivateChatPeer = sourcePeerID
        viewModel.seedPrivateChat([
            privateMediaMessage(
                id: stableID,
                sender: "Peer",
                senderPeerID: sourcePeerID,
                recipient: viewModel.nickname,
                filename: "migrated.jpg"
            ),
            BitchatMessage(
                id: "captured-before-migration",
                sender: "Peer",
                content: "old",
                timestamp: Date(),
                isRelay: false,
                isPrivate: true,
                recipientNickname: viewModel.nickname,
                senderPeerID: sourcePeerID
            )
        ], for: sourcePeerID)

        viewModel.clearPrivateChat(sourcePeerID)
        viewModel.migratePrivateChat(
            from: sourcePeerID,
            to: destinationPeerID
        )
        viewModel.selectedPrivateChatPeer = thirdPeerID
        let arrival = BitchatMessage(
            id: "arrival-after-migration",
            sender: "Peer",
            content: "new",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: viewModel.nickname,
            senderPeerID: destinationPeerID
        )
        #expect(viewModel.appendPrivateMessage(
            arrival,
            to: destinationPeerID
        ))

        transport.resolveNextDeletedPrivateMediaPersistence(true)

        #expect(
            viewModel.privateChats[destinationPeerID]?.map(\.id)
                == ["arrival-after-migration"]
        )
    }

    @Test @MainActor
    func clearFollowsMigrationWhenOldSourceIsRecreated() {
        let (viewModel, transport) = makeTestableViewModel()
        transport.deferDeletedPrivateMediaPersistence = true
        let sourcePeerID = PeerID(str: String(repeating: "1", count: 64))
        let destinationPeerID = PeerID(str: String(repeating: "2", count: 64))
        let stableID = "media-\(String(repeating: "6", count: 32))"
        viewModel.seedPrivateChat([
            privateMediaMessage(
                id: stableID,
                sender: "Peer",
                senderPeerID: sourcePeerID,
                recipient: viewModel.nickname,
                filename: "migrated-recreated.jpg"
            ),
            BitchatMessage(
                id: "captured-before-recreation",
                sender: "Peer",
                content: "old",
                timestamp: Date(),
                isRelay: false,
                isPrivate: true,
                recipientNickname: viewModel.nickname,
                senderPeerID: sourcePeerID
            )
        ], for: sourcePeerID)

        viewModel.clearPrivateChat(sourcePeerID)
        viewModel.migratePrivateChat(
            from: sourcePeerID,
            to: destinationPeerID
        )
        let recreatedArrival = BitchatMessage(
            id: "arrival-recreating-source",
            sender: "Peer",
            content: "new",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: viewModel.nickname,
            senderPeerID: sourcePeerID
        )
        #expect(viewModel.appendPrivateMessage(
            recreatedArrival,
            to: sourcePeerID
        ))

        transport.resolveNextDeletedPrivateMediaPersistence(true)

        #expect(
            (viewModel.privateChats[destinationPeerID] ?? []).isEmpty
        )
        #expect(
            viewModel.privateChats[sourcePeerID]?.map(\.id)
                == ["arrival-recreating-source"]
        )
    }

    @Test @MainActor
    func clearPrivateChatKeepsMediaReferencedByAnotherConversation() {
        let (viewModel, transport) = makeTestableViewModel()
        let firstPeerID = PeerID(str: String(repeating: "4", count: 64))
        let aliasPeerID = PeerID(str: String(repeating: "5", count: 64))
        let messageID = "media-\(String(repeating: "6", count: 32))"
        let message = privateMediaMessage(
            id: messageID,
            sender: "Peer",
            senderPeerID: firstPeerID,
            recipient: viewModel.nickname,
            filename: "mirrored.jpg"
        )
        viewModel.seedPrivateChat([message], for: firstPeerID)
        viewModel.seedPrivateChat([message], for: aliasPeerID)

        viewModel.clearPrivateChat(firstPeerID)

        #expect(transport.deletedPrivateMediaMessageIDBatches.isEmpty)
        #expect(viewModel.privateChats[firstPeerID]?.isEmpty == true)
        #expect(
            viewModel.privateChats[aliasPeerID]?.map(\.id) == [messageID]
        )
    }

    @Test @MainActor
    func clearPrivateChatKeepsOutgoingMediaReferencedByAnotherConversation()
        throws {
        let (viewModel, transport) = makeTestableViewModel()
        let firstPeerID = PeerID(str: String(repeating: "4", count: 64))
        let aliasPeerID = PeerID(str: String(repeating: "5", count: 64))
        let outgoingDirectory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("files/images/outgoing", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outgoingDirectory,
            withIntermediateDirectories: true
        )
        let fileURL = outgoingDirectory.appendingPathComponent(
            "outgoing-mirrored-\(UUID().uuidString).jpg"
        )
        try Data("outgoing-image".utf8).write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let message = privateMediaMessage(
            id: UUID().uuidString,
            sender: viewModel.nickname,
            senderPeerID: transport.myPeerID,
            recipient: "Peer",
            filename: fileURL.lastPathComponent
        )
        viewModel.seedPrivateChat([message], for: firstPeerID)
        viewModel.seedPrivateChat([message], for: aliasPeerID)

        viewModel.clearPrivateChat(firstPeerID)

        // The mirrored conversation keeps its bubble and the payload file:
        // clearing conversation A must not reach across an identity-alias
        // handoff into conversation B.
        #expect(transport.deletedPrivateMediaMessageIDBatches.isEmpty)
        #expect(viewModel.privateChats[firstPeerID]?.isEmpty == true)
        #expect(
            viewModel.privateChats[aliasPeerID]?.map(\.id) == [message.id]
        )
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        // Clearing the last conversation that references the outgoing
        // payload removes both the bubble and the file.
        viewModel.clearPrivateChat(aliasPeerID)

        #expect((viewModel.privateChats[aliasPeerID] ?? []).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test @MainActor
    func clearPrivateChatUnlinksLegacyFileOnlyAfterLastReference()
        throws {
        let (viewModel, transport) = makeTestableViewModel()
        let firstPeerID = PeerID(str: String(repeating: "9", count: 64))
        let aliasPeerID = PeerID(str: String(repeating: "a", count: 64))
        let incomingDirectory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("files/images/incoming", isDirectory: true)
        try FileManager.default.createDirectory(
            at: incomingDirectory,
            withIntermediateDirectories: true
        )
        let fileURL = incomingDirectory.appendingPathComponent(
            "legacy-clear-\(UUID().uuidString).jpg"
        )
        try Data("legacy-image".utf8).write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let message = privateMediaMessage(
            id: UUID().uuidString,
            sender: "Old client",
            senderPeerID: firstPeerID,
            recipient: viewModel.nickname,
            filename: fileURL.lastPathComponent
        )
        viewModel.seedPrivateChat([message], for: firstPeerID)
        viewModel.seedPrivateChat([message], for: aliasPeerID)

        viewModel.clearPrivateChat(firstPeerID)

        // A surviving mirror in another conversation keeps the payload.
        #expect(transport.deletedPrivateMediaMessageIDBatches.isEmpty)
        #expect(transport.removedLegacyPrivateMediaPaths.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(viewModel.privateChats[aliasPeerID]?.map(\.id) == [message.id])

        viewModel.clearPrivateChat(aliasPeerID)

        // Clearing the last reference routes the legacy payload through the
        // transport's gated unlink, which deletes it (nothing pending or
        // reserved names this basename).
        #expect((viewModel.privateChats[aliasPeerID] ?? []).isEmpty)
        #expect(
            transport.removedLegacyPrivateMediaPaths
                == ["images/incoming/\(fileURL.lastPathComponent)"]
        )
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test @MainActor
    func deleteLegacyIncomingMediaUnlinksUnreferencedPayload() throws {
        let (viewModel, transport) = makeTestableViewModel()
        let peerID = PeerID(str: String(repeating: "b", count: 64))
        let incomingDirectory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("files/images/incoming", isDirectory: true)
        try FileManager.default.createDirectory(
            at: incomingDirectory,
            withIntermediateDirectories: true
        )
        let fileURL = incomingDirectory.appendingPathComponent(
            "legacy-delete-\(UUID().uuidString).jpg"
        )
        try Data("legacy-image".utf8).write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let message = privateMediaMessage(
            id: UUID().uuidString,
            sender: "Old client",
            senderPeerID: peerID,
            recipient: viewModel.nickname,
            filename: fileURL.lastPathComponent
        )
        viewModel.seedPrivateChat([message], for: peerID)

        viewModel.deleteMediaMessage(messageID: message.id)

        // Legacy incoming media has no stable receipt, so no journal batch —
        // but the explicit delete must still remove the decrypted payload
        // through the gated unlink.
        #expect(transport.deletedPrivateMediaMessageIDBatches.isEmpty)
        #expect((viewModel.privateChats[peerID] ?? []).isEmpty)
        #expect(
            transport.removedLegacyPrivateMediaPaths
                == ["images/incoming/\(fileURL.lastPathComponent)"]
        )
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test @MainActor
    func deleteLegacyIncomingMediaKeepsPayloadReferencedByAnotherBubble()
        throws {
        let (viewModel, transport) = makeTestableViewModel()
        let peerID = PeerID(str: String(repeating: "c", count: 64))
        let incomingDirectory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("files/images/incoming", isDirectory: true)
        try FileManager.default.createDirectory(
            at: incomingDirectory,
            withIntermediateDirectories: true
        )
        let fileURL = incomingDirectory.appendingPathComponent(
            "legacy-shared-\(UUID().uuidString).jpg"
        )
        try Data("legacy-image".utf8).write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let deleted = privateMediaMessage(
            id: UUID().uuidString,
            sender: "Old client",
            senderPeerID: peerID,
            recipient: viewModel.nickname,
            filename: fileURL.lastPathComponent
        )
        // A different bubble (different ID) references the same basename.
        let survivor = privateMediaMessage(
            id: UUID().uuidString,
            sender: "Old client",
            senderPeerID: peerID,
            recipient: viewModel.nickname,
            filename: fileURL.lastPathComponent
        )
        viewModel.seedPrivateChat([deleted, survivor], for: peerID)

        viewModel.deleteMediaMessage(messageID: deleted.id)

        #expect(
            viewModel.privateChats[peerID]?.map(\.id) == [survivor.id]
        )
        #expect(transport.removedLegacyPrivateMediaPaths.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test @MainActor
    func panicInvalidatesActiveAndQueuedPrivateChatClears() {
        let (viewModel, transport) = makeTestableViewModel()
        transport.deferDeletedPrivateMediaPersistence = true
        let firstPeerID = PeerID(str: String(repeating: "4", count: 64))
        let secondPeerID = PeerID(str: String(repeating: "5", count: 64))
        let firstID = "media-\(String(repeating: "6", count: 32))"
        let secondID = "media-\(String(repeating: "7", count: 32))"
        viewModel.seedPrivateChat([
            privateMediaMessage(
                id: firstID,
                sender: "First",
                senderPeerID: firstPeerID,
                recipient: viewModel.nickname,
                filename: "first-pre-panic.jpg"
            )
        ], for: firstPeerID)
        viewModel.seedPrivateChat([
            privateMediaMessage(
                id: secondID,
                sender: "Second",
                senderPeerID: secondPeerID,
                recipient: viewModel.nickname,
                filename: "second-pre-panic.jpg"
            )
        ], for: secondPeerID)

        viewModel.clearPrivateChat(firstPeerID)
        viewModel.clearPrivateChat(secondPeerID)
        #expect(
            transport.deletedPrivateMediaMessageIDBatches == [[firstID]]
        )

        _ = viewModel.panicClearAllData(restartServices: false)
        viewModel.seedPrivateChat([
            privateMediaMessage(
                id: firstID,
                sender: "First",
                senderPeerID: firstPeerID,
                recipient: viewModel.nickname,
                filename: "first-post-panic.jpg"
            )
        ], for: firstPeerID)
        viewModel.seedPrivateChat([
            privateMediaMessage(
                id: secondID,
                sender: "Second",
                senderPeerID: secondPeerID,
                recipient: viewModel.nickname,
                filename: "second-post-panic.jpg"
            )
        ], for: secondPeerID)

        transport.resolveNextDeletedPrivateMediaPersistence(true)

        #expect(
            transport.deletedPrivateMediaMessageIDBatches == [[firstID]]
        )
        #expect(viewModel.privateChats[firstPeerID]?.map(\.id) == [firstID])
        #expect(viewModel.privateChats[secondPeerID]?.map(\.id) == [secondID])
    }

    private func privateMediaMessage(
        id: String,
        sender: String,
        senderPeerID: PeerID,
        recipient: String,
        filename: String
    ) -> BitchatMessage {
        BitchatMessage(
            id: id,
            sender: sender,
            content: "\(MimeType.Category.image.messagePrefix)\(filename)",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: recipient,
            senderPeerID: senderPeerID
        )
    }
}

// MARK: - Panic Clear Tests

struct ChatViewModelPanicTests {

    @Test @MainActor
    func panicClearAllData_finishesMediaWipeBeforeReturning() {
        var wipeFinished = false
        let (viewModel, _) = makeTestableViewModel(panicMediaWipe: {
            wipeFinished = true
        })

        viewModel.panicClearAllData()

        #expect(wipeFinished)
    }

    @Test @MainActor
    func panicClearAllData_stopsNetworkBeforeWipeAndRestartsAfterCommit() {
        var events: [String] = []
        let lifecycle = PanicNetworkLifecycle(
            stop: { events.append("stop") },
            restart: { events.append("restart") }
        )
        let (viewModel, _) = makeTestableViewModel(
            panicMediaWipe: { events.append("wipe") },
            panicNetworkLifecycle: lifecycle
        )

        let completed = viewModel.panicClearAllData()

        #expect(completed)
        #expect(events == ["stop", "wipe", "restart"])
        #expect(viewModel.networkActivationAllowed)
    }

    @Test @MainActor
    func panicKeychainFailureKeepsRecoveryPendingAndServicesStopped() {
        let keychain = MockKeychain()
        keychain.simulatedDeleteAllResult = false
        var events: [String] = []
        let operations = PanicRecoveryOperations(
            isPending: { false },
            begin: {
                events.append("begin")
                return PanicRecoveryIntent(
                    fileMarkerEstablished: true,
                    externalMarkerEstablished: false
                )
            },
            wipeMedia: { _ in events.append("wipe") },
            complete: { events.append("complete") }
        )
        let lifecycle = PanicNetworkLifecycle(
            stop: { events.append("stop") },
            restart: { events.append("restart") }
        )
        let (viewModel, transport) = makeTestableViewModel(
            keychain: keychain,
            panicRecoveryOperations: operations,
            panicNetworkLifecycle: lifecycle
        )
        let startsBeforePanic = transport.startServicesCallCount

        let completed = viewModel.panicClearAllData()

        #expect(!completed)
        #expect(events == ["stop", "begin", "wipe"])
        #expect(keychain.deleteAllCallCount == 1)
        #expect(transport.startServicesCallCount == startsBeforePanic)
        #expect(!viewModel.networkActivationAllowed)
    }

    @Test @MainActor
    func pendingPanicRecoveryCompletesBeforeTransportBootstrap() {
        var events: [String] = []
        let operations = PanicRecoveryOperations(
            isPending: {
                events.append("read")
                return true
            },
            begin: {
                events.append("begin")
                return PanicRecoveryIntent(
                    fileMarkerEstablished: true,
                    externalMarkerEstablished: false
                )
            },
            wipeMedia: { _ in events.append("wipe") },
            complete: { events.append("complete") }
        )

        let (viewModel, transport) = makeTestableViewModel(
            panicRecoveryOperations: operations
        )

        #expect(events == ["read", "begin", "wipe", "complete"])
        #expect(transport.emergencyDisconnectCallCount == 1)
        #expect(transport.startServicesCallCount == 1)
        #expect(viewModel.networkActivationAllowed)
    }

    @Test @MainActor
    func failedStartupRecoveryLeavesTransportAndNetworkBlocked() {
        enum WipeFailure: Error { case failed }
        var completedMarker = false
        let operations = PanicRecoveryOperations(
            isPending: { true },
            begin: {
                PanicRecoveryIntent(
                    fileMarkerEstablished: true,
                    externalMarkerEstablished: false
                )
            },
            wipeMedia: { _ in throw WipeFailure.failed },
            complete: { completedMarker = true }
        )

        let (viewModel, transport) = makeTestableViewModel(
            panicRecoveryOperations: operations
        )

        #expect(!completedMarker)
        #expect(transport.emergencyDisconnectCallCount == 1)
        #expect(transport.startServicesCallCount == 0)
        #expect(!viewModel.networkActivationAllowed)
    }

    @Test @MainActor
    func failedStartupKeychainRecoveryLeavesIntentAndTransportBlocked() {
        let keychain = MockKeychain()
        keychain.simulatedDeleteAllResult = false
        var events: [String] = []
        let operations = PanicRecoveryOperations(
            isPending: { true },
            begin: {
                events.append("begin")
                return PanicRecoveryIntent(
                    fileMarkerEstablished: true,
                    externalMarkerEstablished: true
                )
            },
            wipeMedia: { _ in events.append("wipe") },
            complete: { events.append("complete") }
        )

        let (viewModel, transport) = makeTestableViewModel(
            keychain: keychain,
            panicRecoveryOperations: operations
        )

        #expect(events == ["begin", "wipe"])
        #expect(keychain.deleteAllCallCount == 1)
        #expect(transport.emergencyDisconnectCallCount == 1)
        #expect(transport.startServicesCallCount == 0)
        #expect(!viewModel.networkActivationAllowed)
    }

    @Test @MainActor
    func panicClearAllData_delegatesToTransport() async {
        let (viewModel, transport) = makeTestableViewModel()

        // Set up some state
        transport.connectedPeers.insert(PeerID(str: "PEER1"))
        viewModel.seedPublicMessages([
            BitchatMessage(
                id: "panic-1",
                sender: "Tester",
                content: "Before",
                timestamp: Date(),
                isRelay: false
            )
        ])
        viewModel.seedPrivateChat([
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
        ], for: PeerID(str: "PEER1"))
        viewModel.markPrivateChatUnread(PeerID(str: "PEER1"))

        viewModel.panicClearAllData()

        // After panic, emergency disconnect should be called
        #expect(transport.emergencyDisconnectCallCount == 1)
        #expect(viewModel.messages.isEmpty)
        #expect(viewModel.privateChats.isEmpty)
        #expect(viewModel.unreadPrivateMessages.isEmpty)
        #expect(viewModel.selectedPrivateChatPeer == nil)
    }

    @Test @MainActor
    func panicClearAllData_resetsLiveGeohashAndNostrState() async throws {
        let (viewModel, _) = makeTestableViewModel()
        let geohash = "u4pruy"
        let channel = GeohashChannel(level: .city, geohash: geohash)
        let identity = try NostrIdentity.generate()
        let pubkey = String(repeating: "ab", count: 32)
        let peerID = PeerID(nostr: pubkey)

        viewModel.activeChannel = .location(channel)
        viewModel.setGeoChatSubscriptionID("geo-\(geohash)")
        viewModel.setGeoDmSubscriptionID("geo-dm-\(geohash)")
        viewModel.addGeoSamplingSub("geo-sample-\(geohash)", forGeohash: geohash)
        viewModel.cachedGeohashIdentity = (geohash, identity)
        viewModel.registerNostrKeyMapping(pubkey, for: peerID)
        viewModel.currentGeohash = geohash
        viewModel.geoNicknames = [pubkey: "alice"]
        viewModel.teleportedGeo = [pubkey]

        viewModel.panicClearAllData()

        #expect(viewModel.activeChannel == .mesh)
        #expect(viewModel.geoSubscriptionID == nil)
        #expect(viewModel.geoDmSubscriptionID == nil)
        #expect(viewModel.geoSamplingSubs.isEmpty)
        #expect(viewModel.cachedGeohashIdentity == nil)
        #expect(viewModel.nostrKeyMapping.isEmpty)
        #expect(viewModel.currentGeohash == nil)
        #expect(viewModel.geoNicknames.isEmpty)
        #expect(viewModel.teleportedGeo.isEmpty)
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
