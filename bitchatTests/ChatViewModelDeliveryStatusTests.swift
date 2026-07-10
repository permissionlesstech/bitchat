//
// ChatViewModelDeliveryStatusTests.swift
// bitchatTests
//
// Tests for ChatViewModel delivery status state machine.
//

import Testing
import Foundation
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

// MARK: - Delivery Status Tests

struct ChatViewModelDeliveryStatusTests {

    // MARK: - Status Transition Tests

    @Test @MainActor
    func deliveryStatus_noDowngrade_readToDelivered() async {
        let (viewModel, transport) = makeTestableViewModel()
        let peerID = PeerID(str: "0102030405060708")
        let messageID = "test-msg-1"

        // Setup: create a message with .read status
        let message = BitchatMessage(
            id: messageID,
            sender: viewModel.nickname,
            content: "Test message",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "Peer",
            senderPeerID: transport.myPeerID,
            deliveryStatus: .read(by: "Peer", at: Date())
        )
        viewModel.seedPrivateChat([message], for: peerID)

        // Action: try to downgrade to .delivered
        viewModel.didUpdateMessageDeliveryStatus(messageID, status: .delivered(to: "Peer", at: Date()))

        // Assert: status should remain .read (no downgrade)
        let currentStatus = viewModel.privateChats[peerID]?.first?.deliveryStatus
        #expect({
            if case .read = currentStatus { return true }
            return false
        }())
    }

    @Test @MainActor
    func deliveryStatus_noDowngrade_carriedToSent() async {
        // Regression: the optimistic `.sent` stamp the send path writes after
        // routing must not clobber the `.carried` the router already set when
        // it handed a copy to a courier/bridge (store-and-forward), or the
        // offline-favorite flow shows "sent" instead of 📦 carried.
        let (viewModel, transport) = makeTestableViewModel()
        let peerID = PeerID(str: "0102030405060708")
        let messageID = "test-msg-carried"

        let message = BitchatMessage(
            id: messageID,
            sender: viewModel.nickname,
            content: "Test message",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "Peer",
            senderPeerID: transport.myPeerID,
            deliveryStatus: .carried
        )
        viewModel.seedPrivateChat([message], for: peerID)

        viewModel.didUpdateMessageDeliveryStatus(messageID, status: .sent)

        let currentStatus = viewModel.privateChats[peerID]?.first?.deliveryStatus
        #expect({
            if case .carried = currentStatus { return true }
            return false
        }())
    }

    @Test @MainActor
    func deliveryStatus_noDowngrade_carriedToSending() async {
        // Regression: a pre-handshake resend stamps `.sending`; it must not
        // wipe the 📦 carried indicator (nor a delivered/read ack).
        let (viewModel, transport) = makeTestableViewModel()
        let peerID = PeerID(str: "0102030405060708")
        let messageID = "test-msg-carried-sending"

        let message = BitchatMessage(
            id: messageID,
            sender: viewModel.nickname,
            content: "Test message",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "Peer",
            senderPeerID: transport.myPeerID,
            deliveryStatus: .carried
        )
        viewModel.seedPrivateChat([message], for: peerID)

        viewModel.didUpdateMessageDeliveryStatus(messageID, status: .sending)

        let currentStatus = viewModel.privateChats[peerID]?.first?.deliveryStatus
        #expect({
            if case .carried = currentStatus { return true }
            return false
        }())

        #expect(Conversation.shouldSkipStatusUpdate(current: .delivered(to: "Peer", at: Date()), new: .sending))
        #expect(Conversation.shouldSkipStatusUpdate(current: .read(by: "Peer", at: Date()), new: .sending))
        #expect(Conversation.shouldSkipStatusUpdate(
            current: .delivered(to: "Peer", at: Date()),
            new: .failed(reason: "late transport failure")
        ))
        #expect(Conversation.shouldSkipStatusUpdate(
            current: .read(by: "Peer", at: Date()),
            new: .failed(reason: "late transfer failure")
        ))
        // A late async `.sending` (pre-handshake resend) must not visibly
        // downgrade a truthful "Sent" either...
        #expect(Conversation.shouldSkipStatusUpdate(current: .sent, new: .sending))
        // ...but a retry after a real failure stays visible.
        #expect(!Conversation.shouldSkipStatusUpdate(current: .failed(reason: "no route"), new: .sending))
    }

    @Test @MainActor
    func deliveryStatus_upgrade_carriedToDelivered() async {
        // A delivery ack must still promote a carried message.
        let (viewModel, transport) = makeTestableViewModel()
        let peerID = PeerID(str: "0102030405060708")
        let messageID = "test-msg-carried-delivered"

        let message = BitchatMessage(
            id: messageID,
            sender: viewModel.nickname,
            content: "Test message",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "Peer",
            senderPeerID: transport.myPeerID,
            deliveryStatus: .carried
        )
        viewModel.seedPrivateChat([message], for: peerID)

        viewModel.didUpdateMessageDeliveryStatus(messageID, status: .delivered(to: "Peer", at: Date()))

        let currentStatus = viewModel.privateChats[peerID]?.first?.deliveryStatus
        #expect({
            if case .delivered = currentStatus { return true }
            return false
        }())
    }

    @Test @MainActor
    func deliveryStatus_upgrade_sentToDelivered() async {
        let (viewModel, transport) = makeTestableViewModel()
        let peerID = PeerID(str: "0102030405060708")
        let messageID = "test-msg-2"

        // Setup: create a message with .sent status
        let message = BitchatMessage(
            id: messageID,
            sender: viewModel.nickname,
            content: "Test message",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "Peer",
            senderPeerID: transport.myPeerID,
            deliveryStatus: .sent
        )
        viewModel.seedPrivateChat([message], for: peerID)

        // Action: upgrade to .delivered
        viewModel.didUpdateMessageDeliveryStatus(messageID, status: .delivered(to: "Peer", at: Date()))

        // Assert: status should be .delivered
        let currentStatus = viewModel.privateChats[peerID]?.first?.deliveryStatus
        #expect({
            if case .delivered = currentStatus { return true }
            return false
        }())
    }

    @Test @MainActor
    func deliveryStatus_identicalUpdateIsNoop() async {
        let (viewModel, transport) = makeTestableViewModel()
        let peerID = PeerID(str: "0102030405060708")
        let messageID = "test-msg-identical"
        let message = BitchatMessage(
            id: messageID,
            sender: viewModel.nickname,
            content: "Test message",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "Peer",
            senderPeerID: transport.myPeerID,
            deliveryStatus: .sent
        )
        viewModel.seedPrivateChat([message], for: peerID)

        let didUpdate = viewModel.deliveryCoordinator.updateMessageDeliveryStatus(messageID, status: .sent)

        #expect(!didUpdate)
        #expect(isSent(viewModel.privateChats[peerID]?.first?.deliveryStatus))
    }

    @Test @MainActor
    func deliveryStatus_upgrade_deliveredToRead() async {
        let (viewModel, transport) = makeTestableViewModel()
        let peerID = PeerID(str: "0102030405060708")
        let messageID = "test-msg-3"

        // Setup: create a message with .delivered status
        let message = BitchatMessage(
            id: messageID,
            sender: viewModel.nickname,
            content: "Test message",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "Peer",
            senderPeerID: transport.myPeerID,
            deliveryStatus: .delivered(to: "Peer", at: Date().addingTimeInterval(-60))
        )
        viewModel.seedPrivateChat([message], for: peerID)

        // Action: upgrade to .read
        viewModel.didUpdateMessageDeliveryStatus(messageID, status: .read(by: "Peer", at: Date()))

        // Assert: status should be .read
        let currentStatus = viewModel.privateChats[peerID]?.first?.deliveryStatus
        #expect({
            if case .read = currentStatus { return true }
            return false
        }())
    }

    // MARK: - Read Receipt Handling

    @Test @MainActor
    func didReceiveReadReceipt_updatesMessageStatus() async {
        let (viewModel, transport) = makeTestableViewModel()
        let peerID = PeerID(str: "0102030405060708")
        let messageID = "test-msg-4"

        // Setup: create a message with .sent status
        let message = BitchatMessage(
            id: messageID,
            sender: viewModel.nickname,
            content: "Test message",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "Peer",
            senderPeerID: transport.myPeerID,
            deliveryStatus: .sent
        )
        viewModel.seedPrivateChat([message], for: peerID)

        // Action: receive read receipt
        let receipt = ReadReceipt(
            originalMessageID: messageID,
            readerID: peerID,
            readerNickname: "Peer"
        )
        viewModel.didReceiveReadReceipt(receipt)

        // Assert: status should be .read
        let currentStatus = viewModel.privateChats[peerID]?.first?.deliveryStatus
        #expect({
            if case .read = currentStatus { return true }
            return false
        }())
    }

    @Test @MainActor
    func cleanupOldReadReceipts_removesReceiptIDsWithoutMessages() async {
        let (viewModel, transport) = makeTestableViewModel()
        let peerID = PeerID(str: "0102030405060709")

        let message = BitchatMessage(
            id: "keep-receipt",
            sender: viewModel.nickname,
            content: "Keep me",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "Peer",
            senderPeerID: transport.myPeerID,
            deliveryStatus: .sent
        )
        viewModel.seedPrivateChat([message], for: peerID)
        viewModel.sentReadReceipts = ["keep-receipt", "drop-receipt"]
        viewModel.isStartupPhase = false

        viewModel.cleanupOldReadReceipts()

        #expect(viewModel.sentReadReceipts == ["keep-receipt"])
    }

    // MARK: - Public Timeline Status Tests

    @Test @MainActor
    func deliveryStatus_publicTimeline_updatesCorrectly() async {
        let (viewModel, _) = makeTestableViewModel()
        let messageID = "public-msg-1"

        // Setup: add a message to public timeline with .sending status
        let message = BitchatMessage(
            id: messageID,
            sender: viewModel.nickname,
            content: "Public message",
            timestamp: Date(),
            isRelay: false,
            isPrivate: false,
            deliveryStatus: .sending
        )
        viewModel.seedPublicMessages([message])

        // Action: update to .sent
        viewModel.didUpdateMessageDeliveryStatus(messageID, status: .sent)

        // Assert
        let updatedMessage = viewModel.messages.first(where: { $0.id == messageID })
        #expect({
            if case .sent = updatedMessage?.deliveryStatus { return true }
            return false
        }())
    }

    @Test @MainActor
    func deliveryStatus_updatesPublicAndMirroredPrivateMessages() async {
        let (viewModel, transport) = makeTestableViewModel()
        let messageID = "mirrored-msg-1"
        let firstPeerID = PeerID(str: "0102030405060708")
        let secondPeerID = PeerID(str: "1112131415161718")

        viewModel.seedPublicMessages([
            BitchatMessage(
                id: messageID,
                sender: viewModel.nickname,
                content: "Public copy",
                timestamp: Date(),
                isRelay: false,
                isPrivate: false,
                senderPeerID: transport.myPeerID,
                deliveryStatus: .sent
            )
        ])
        viewModel.seedPrivateChat([
            BitchatMessage(
                id: messageID,
                sender: viewModel.nickname,
                content: "Private copy A",
                timestamp: Date(),
                isRelay: false,
                isPrivate: true,
                recipientNickname: "Peer A",
                senderPeerID: transport.myPeerID,
                deliveryStatus: .sent
            )
        ], for: firstPeerID)
        viewModel.seedPrivateChat([
            BitchatMessage(
                id: messageID,
                sender: viewModel.nickname,
                content: "Private copy B",
                timestamp: Date(),
                isRelay: false,
                isPrivate: true,
                recipientNickname: "Peer B",
                senderPeerID: transport.myPeerID,
                deliveryStatus: .sent
            )
        ], for: secondPeerID)

        let didUpdate = viewModel.deliveryCoordinator.updateMessageDeliveryStatus(
            messageID,
            status: .delivered(to: "Peer", at: Date())
        )

        #expect(didUpdate)
        #expect(isDelivered(viewModel.messages.first?.deliveryStatus))
        #expect(isDelivered(viewModel.privateChats[firstPeerID]?.first?.deliveryStatus))
        #expect(isDelivered(viewModel.privateChats[secondPeerID]?.first?.deliveryStatus))
    }

    @Test @MainActor
    func deliveryStatus_survivesPrivateChatReorder() async {
        let (viewModel, transport) = makeTestableViewModel()
        let peerID = PeerID(str: "0102030405060708")
        let messageID = "reordered-msg-1"
        let olderMessage = BitchatMessage(
            id: "older-msg",
            sender: viewModel.nickname,
            content: "Older message",
            timestamp: Date(timeIntervalSince1970: 1),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "Peer",
            senderPeerID: transport.myPeerID,
            deliveryStatus: .sent
        )
        let targetMessage = BitchatMessage(
            id: messageID,
            sender: viewModel.nickname,
            content: "Target message",
            timestamp: Date(timeIntervalSince1970: 2),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "Peer",
            senderPeerID: transport.myPeerID,
            deliveryStatus: .sent
        )

        viewModel.seedPrivateChat([targetMessage], for: peerID)
        #expect(isSent(viewModel.deliveryCoordinator.deliveryStatus(for: messageID)))

        // A late arrival with an older timestamp is inserted before the
        // target by the store, shifting its position; the store's ID-keyed
        // indexes must keep the target updatable.
        viewModel.seedPrivateChat([olderMessage], for: peerID)
        #expect(viewModel.privateChats[peerID]?.map(\.id) == ["older-msg", messageID])

        let didUpdate = viewModel.deliveryCoordinator.updateMessageDeliveryStatus(
            messageID,
            status: .read(by: "Peer", at: Date())
        )

        #expect(didUpdate)
        #expect(isRead(viewModel.privateChats[peerID]?.last?.deliveryStatus))
    }

    // MARK: - MessageRouter Drop Wiring Tests

    /// Drives a real outbox drop (per-peer overflow eviction with no
    /// reachable transport) and proves the bootstrapper wiring marks the
    /// dropped message `.failed` in the conversation store.
    @Test @MainActor
    func messageRouterDrop_marksMessageFailedInStore() async {
        let (viewModel, transport) = makeTestableViewModel()
        let peerID = PeerID(str: "0102030405060708")
        let droppedID = "router-drop-0"

        let message = BitchatMessage(
            id: droppedID,
            sender: viewModel.nickname,
            content: "Will be dropped",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "Peer",
            senderPeerID: transport.myPeerID,
            deliveryStatus: .sent
        )
        viewModel.seedPrivateChat([message], for: peerID)

        // No transport is reachable, so every send is queued; the 101st
        // enqueue for this peer evicts the oldest queued message.
        viewModel.messageRouter.sendPrivate("Will be dropped", to: peerID, recipientNickname: "Peer", messageID: droppedID)
        for i in 1...100 {
            viewModel.messageRouter.sendPrivate("Filler \(i)", to: peerID, recipientNickname: "Peer", messageID: "router-drop-\(i)")
        }

        let status = viewModel.conversations.deliveryStatus(forMessageID: droppedID)
        #expect({
            if case .failed = status { return true }
            return false
        }())
    }

    /// The store's no-downgrade rule does not cover `.failed` over confirmed
    /// receipts, so the wiring guards it: a drop of an already-delivered
    /// message must not downgrade its status.
    @Test @MainActor
    func messageRouterDrop_doesNotDowngradeDeliveredStatus() async {
        let (viewModel, transport) = makeTestableViewModel()
        let peerID = PeerID(str: "0102030405060708")
        let droppedID = "router-drop-delivered"

        let message = BitchatMessage(
            id: droppedID,
            sender: viewModel.nickname,
            content: "Already delivered",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "Peer",
            senderPeerID: transport.myPeerID,
            deliveryStatus: .delivered(to: "Peer", at: Date())
        )
        viewModel.seedPrivateChat([message], for: peerID)

        // Same eviction-driven drop as above, but the store already recorded
        // a delivery confirmation for the message.
        viewModel.messageRouter.sendPrivate("Already delivered", to: peerID, recipientNickname: "Peer", messageID: droppedID)
        for i in 1...100 {
            viewModel.messageRouter.sendPrivate("Filler \(i)", to: peerID, recipientNickname: "Peer", messageID: "router-keep-\(i)")
        }

        let status = viewModel.conversations.deliveryStatus(forMessageID: droppedID)
        #expect({
            if case .delivered = status { return true }
            return false
        }())
    }

    // MARK: - Status Rank Tests (for deduplication)

    @Test @MainActor
    func statusRank_orderingIsCorrect() async {
        // This tests the implicit ordering used in refreshVisibleMessages
        // failed < sending < sent < carried < partiallyDelivered < delivered < read

        let statuses: [DeliveryStatus] = [
            .failed(reason: "test"),
            .sending,
            .sent,
            .carried,
            .partiallyDelivered(reached: 1, total: 3),
            .delivered(to: "B", at: Date()),
            .read(by: "C", at: Date())
        ]

        // Verify each status has a logical progression
        // This is more of a documentation test to ensure the ranking logic is understood
        for (index, status) in statuses.enumerated() {
            switch status {
            case .failed: #expect(index == 0)
            case .sending: #expect(index == 1)
            case .sent: #expect(index == 2)
            case .carried: #expect(index == 3)
            case .partiallyDelivered: #expect(index == 4)
            case .delivered: #expect(index == 5)
            case .read: #expect(index == 6)
            }
        }
    }
}

// MARK: - Mock Delivery Context

/// Lightweight stand-in for `ChatDeliveryContext` proving that
/// `ChatDeliveryCoordinator` is testable without constructing a
/// `ChatViewModel`: the delivery surface forwards to a real
/// `ConversationStore` (the coordinator is a thin mapper over store
/// intents), and assertions read store state.
@MainActor
private final class MockChatDeliveryContext: ChatDeliveryContext {
    let store = ConversationStore()
    var sentReadReceipts: Set<String> = []
    var isStartupPhase = false
    private(set) var notifyUIChangedCount = 0
    private(set) var markedDeliveredMessageIDs: [String] = []

    @discardableResult
    func setDeliveryStatus(_ status: DeliveryStatus, forMessageID messageID: String) -> Bool {
        store.setDeliveryStatus(status, forMessageID: messageID)
    }

    func deliveryStatus(forMessageID messageID: String) -> DeliveryStatus? {
        store.deliveryStatus(forMessageID: messageID)
    }

    func privateMessageIDs() -> Set<String> {
        store.directMessageIDs()
    }

    func pruneSentReadReceipts(keeping validMessageIDs: Set<String>) -> Int {
        let oldCount = sentReadReceipts.count
        sentReadReceipts = sentReadReceipts.intersection(validMessageIDs)
        return oldCount - sentReadReceipts.count
    }

    func notifyUIChanged() {
        notifyUIChangedCount += 1
    }

    func markMessageDelivered(_ messageID: String) {
        markedDeliveredMessageIDs.append(messageID)
    }
}

@MainActor
private func makePrivateMessage(
    id: String,
    status: DeliveryStatus,
    timestamp: Date = Date()
) -> BitchatMessage {
    BitchatMessage(
        id: id,
        sender: "me",
        content: "Test message",
        timestamp: timestamp,
        isRelay: false,
        isPrivate: true,
        recipientNickname: "Peer",
        senderPeerID: PeerID(str: "aabbccddeeff0011"),
        deliveryStatus: status
    )
}

@MainActor
private func makePublicMessage(
    id: String,
    status: DeliveryStatus,
    timestamp: Date = Date()
) -> BitchatMessage {
    BitchatMessage(
        id: id,
        sender: "me",
        content: "Public message",
        timestamp: timestamp,
        isRelay: false,
        isPrivate: false,
        deliveryStatus: status
    )
}

// MARK: - Coordinator Tests Against Mock Context

/// Exercises `ChatDeliveryCoordinator` against `MockChatDeliveryContext` —
/// the exemplar for the narrow-dependency coordinator pattern. State is
/// seeded into and asserted against the mock's `ConversationStore`.
struct ChatDeliveryCoordinatorContextTests {

    @Test @MainActor
    func updateDeliveryStatus_updatesPrivateChatNotifiesAndMarksDelivered() async {
        let context = MockChatDeliveryContext()
        let coordinator = ChatDeliveryCoordinator(context: context)
        let peerID = PeerID(str: "0102030405060708")
        let messageID = "mock-msg-1"
        context.store.append(makePrivateMessage(id: messageID, status: .sent), to: .directPeer(peerID))

        let didUpdate = coordinator.updateMessageDeliveryStatus(
            messageID,
            status: .delivered(to: "Peer", at: Date())
        )

        #expect(didUpdate)
        #expect(isDelivered(context.store.conversation(for: .directPeer(peerID)).message(withID: messageID)?.deliveryStatus))
        #expect(context.notifyUIChangedCount == 1)
        #expect(context.markedDeliveredMessageIDs == [messageID])
    }

    @Test @MainActor
    func readReceipt_marksDeliveredAndUpgradesStatus() async {
        let context = MockChatDeliveryContext()
        let coordinator = ChatDeliveryCoordinator(context: context)
        let peerID = PeerID(str: "0102030405060708")
        let messageID = "mock-msg-2"
        context.store.append(
            makePrivateMessage(id: messageID, status: .delivered(to: "Peer", at: Date())),
            to: .directPeer(peerID)
        )

        coordinator.didReceiveReadReceipt(
            ReadReceipt(originalMessageID: messageID, readerID: peerID, readerNickname: "Peer")
        )

        #expect(isRead(coordinator.deliveryStatus(for: messageID)))
        #expect(context.notifyUIChangedCount == 1)
        #expect(context.markedDeliveredMessageIDs == [messageID])
    }

    @Test @MainActor
    func sentStatus_doesNotMarkDeliveredAndUnknownMessageDoesNotNotify() async {
        let context = MockChatDeliveryContext()
        let coordinator = ChatDeliveryCoordinator(context: context)
        context.store.append(makePublicMessage(id: "public-mock-1", status: .sending), to: .mesh)

        // .sent is not a confirmed receipt — must not reach markMessageDelivered.
        let didUpdate = coordinator.updateMessageDeliveryStatus("public-mock-1", status: .sent)
        #expect(didUpdate)
        #expect(isSent(context.store.conversation(for: .mesh).message(withID: "public-mock-1")?.deliveryStatus))
        #expect(context.markedDeliveredMessageIDs.isEmpty)
        #expect(context.notifyUIChangedCount == 1)

        // Unknown message: no state change, no extra UI notification.
        let didUpdateUnknown = coordinator.updateMessageDeliveryStatus("missing-msg", status: .sent)
        #expect(!didUpdateUnknown)
        #expect(context.notifyUIChangedCount == 1)
    }

    // The old positional `messageLocationIndex` could go stale when a late
    // arrival was inserted mid-array (count grew but indexed locations
    // shifted). The store's per-conversation ID index is reindexed inside the
    // same mutation, so staleness is structurally impossible — these tests
    // pin the equivalent behavior through the new path: after out-of-order
    // insertion, updates keyed by ID still land on the right messages.

    @Test @MainActor
    func middleInsertedMessage_isStillUpdatableByID() async {
        let context = MockChatDeliveryContext()
        let coordinator = ChatDeliveryCoordinator(context: context)
        context.store.append(
            makePublicMessage(id: "public-a", status: .sending, timestamp: Date(timeIntervalSince1970: 10)),
            to: .mesh
        )
        context.store.append(
            makePublicMessage(id: "public-b", status: .sending, timestamp: Date(timeIntervalSince1970: 30)),
            to: .mesh
        )

        #expect(coordinator.updateMessageDeliveryStatus("public-a", status: .sent))

        // Out-of-order arrival: the store inserts by timestamp, shifting the
        // tail's position.
        context.store.append(
            makePublicMessage(id: "public-mid", status: .sending, timestamp: Date(timeIntervalSince1970: 20)),
            to: .mesh
        )
        let mesh = context.store.conversation(for: .mesh)
        #expect(mesh.messages.map(\.id) == ["public-a", "public-mid", "public-b"])

        // Both the inserted message and the shifted tail stay updatable.
        #expect(coordinator.updateMessageDeliveryStatus("public-mid", status: .sent))
        #expect(isSent(mesh.message(withID: "public-mid")?.deliveryStatus))
        #expect(coordinator.updateMessageDeliveryStatus("public-b", status: .sent))
        #expect(isSent(mesh.message(withID: "public-b")?.deliveryStatus))
    }

    @Test @MainActor
    func middleInsertedPrivateMessage_isStillUpdatableByID() async {
        let context = MockChatDeliveryContext()
        let coordinator = ChatDeliveryCoordinator(context: context)
        let peerID = PeerID(str: "0102030405060708")
        let conversationID = ConversationID.directPeer(peerID)
        context.store.append(
            makePrivateMessage(id: "pm-a", status: .sending, timestamp: Date(timeIntervalSince1970: 10)),
            to: conversationID
        )
        context.store.append(
            makePrivateMessage(id: "pm-b", status: .sending, timestamp: Date(timeIntervalSince1970: 30)),
            to: conversationID
        )

        #expect(coordinator.updateMessageDeliveryStatus("pm-a", status: .sent))

        // A late arrival with an older timestamp lands mid-array.
        context.store.append(
            makePrivateMessage(id: "pm-mid", status: .sending, timestamp: Date(timeIntervalSince1970: 20)),
            to: conversationID
        )
        let chat = context.store.conversation(for: conversationID)
        #expect(chat.messages.map(\.id) == ["pm-a", "pm-mid", "pm-b"])

        #expect(coordinator.updateMessageDeliveryStatus("pm-mid", status: .sent))
        #expect(isSent(chat.message(withID: "pm-mid")?.deliveryStatus))
        #expect(coordinator.updateMessageDeliveryStatus("pm-b", status: .sent))
        #expect(isSent(chat.message(withID: "pm-b")?.deliveryStatus))
    }

    @Test @MainActor
    func mirroredPrivateCopies_bothReceiveDeliveryUpdate() async {
        let context = MockChatDeliveryContext()
        let coordinator = ChatDeliveryCoordinator(context: context)
        let stablePeerID = PeerID(str: String(repeating: "ab", count: 32))
        let ephemeralPeerID = PeerID(str: "0102030405060708")
        let messageID = "mirrored-mock-1"

        // Step 2's keying mirrors a private message into both the stable-key
        // and ephemeral-peer conversations (distinct copies here to prove
        // per-conversation application, not shared-reference aliasing).
        context.store.append(makePrivateMessage(id: messageID, status: .sent), to: .directPeer(stablePeerID))
        context.store.append(makePrivateMessage(id: messageID, status: .sent), to: .directPeer(ephemeralPeerID))

        let didUpdate = coordinator.updateMessageDeliveryStatus(
            messageID,
            status: .delivered(to: "Peer", at: Date())
        )

        #expect(didUpdate)
        #expect(isDelivered(context.store.conversation(for: .directPeer(stablePeerID)).message(withID: messageID)?.deliveryStatus))
        #expect(isDelivered(context.store.conversation(for: .directPeer(ephemeralPeerID)).message(withID: messageID)?.deliveryStatus))
        #expect(context.markedDeliveredMessageIDs == [messageID])
    }

    @Test @MainActor
    func cleanupOldReadReceipts_prunesReceiptsAgainstMockContext() async {
        let context = MockChatDeliveryContext()
        let coordinator = ChatDeliveryCoordinator(context: context)
        let peerID = PeerID(str: "0102030405060708")
        context.store.append(makePrivateMessage(id: "keep-receipt", status: .sent), to: .directPeer(peerID))
        context.sentReadReceipts = ["keep-receipt", "drop-receipt"]

        // Startup phase: cleanup must be a no-op.
        context.isStartupPhase = true
        coordinator.cleanupOldReadReceipts()
        #expect(context.sentReadReceipts == ["keep-receipt", "drop-receipt"])

        context.isStartupPhase = false
        coordinator.cleanupOldReadReceipts()
        #expect(context.sentReadReceipts == ["keep-receipt"])
    }
}

private func isSent(_ status: DeliveryStatus?) -> Bool {
    if case .sent = status { return true }
    return false
}

private func isDelivered(_ status: DeliveryStatus?) -> Bool {
    if case .delivered = status { return true }
    return false
}

private func isRead(_ status: DeliveryStatus?) -> Bool {
    if case .read = status { return true }
    return false
}
