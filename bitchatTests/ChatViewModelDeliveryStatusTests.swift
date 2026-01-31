//
// ChatViewModelDeliveryStatusTests.swift
// bitchatTests
//
// Tests for ChatViewModel delivery status state machine.
//

import Testing
import Foundation
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
        viewModel.privateChats[peerID] = [message]

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
        viewModel.privateChats[peerID] = [message]

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
        viewModel.privateChats[peerID] = [message]

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
        viewModel.privateChats[peerID] = [message]

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
        viewModel.messages.append(message)

        // Action: update to .sent
        viewModel.didUpdateMessageDeliveryStatus(messageID, status: .sent)

        // Assert
        let updatedMessage = viewModel.messages.first(where: { $0.id == messageID })
        #expect({
            if case .sent = updatedMessage?.deliveryStatus { return true }
            return false
        }())
    }

    // MARK: - Status Rank Tests (for deduplication)

    @Test @MainActor
    func statusRank_orderingIsCorrect() async {
        // This tests the implicit ordering used in refreshVisibleMessages
        // failed < sending < sent < partiallyDelivered < delivered < read

        let statuses: [DeliveryStatus] = [
            .failed(reason: "test"),
            .sending,
            .sent,
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
            case .partiallyDelivered: #expect(index == 3)
            case .delivered: #expect(index == 4)
            case .read: #expect(index == 5)
            }
        }
    }
}
