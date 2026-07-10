//
// ChatMediaTransferCoordinatorContextTests.swift
// bitchatTests
//
// Exercises `ChatMediaTransferCoordinator` against a mock
// `ChatMediaTransferContext` — proving the coordinator works without a
// `ChatViewModel`, following the `ChatDeliveryCoordinatorContextTests` /
// `ChatPrivateConversationCoordinatorContextTests` exemplars.
//
// Scope note: the async media-preparation pipelines (`ImageUtils`,
// `ChatMediaPreparation`) run real file/codec work and remain covered by
// `ChatMediaPreparationTests`; here we cover message enqueueing, transfer
// bookkeeping, and the blocked-context guards.
//

import Testing
import Foundation
import BitFoundation
@testable import bitchat

// MARK: - Mock Context

/// Lightweight stand-in for `ChatMediaTransferContext` proving that
/// `ChatMediaTransferCoordinator` is testable without a `ChatViewModel`.
@MainActor
private final class MockChatMediaTransferContext: ChatMediaTransferContext {
    // Composition state
    var canSendMediaInCurrentContext = true
    var selectedPrivateChatPeer: PeerID?
    var nickname = "me"
    var myPeerID = PeerID(str: "0011223344556677")
    var activeChannel: ChannelID = .mesh
    var nicknamesByPeerID: [PeerID: String] = [:]

    func nicknameForPeer(_ peerID: PeerID) -> String {
        nicknamesByPeerID[peerID] ?? "user"
    }

    func currentPublicSender() -> (name: String, peerID: PeerID) {
        (nickname, myPeerID)
    }

    // Message state
    var privateChats: [PeerID: [BitchatMessage]] = [:]

    @discardableResult
    func appendPrivateMessage(_ message: BitchatMessage, to peerID: PeerID) -> Bool {
        var chat = privateChats[peerID] ?? []
        guard !chat.contains(where: { $0.id == message.id }) else { return false }
        chat.append(message)
        privateChats[peerID] = chat
        return true
    }

    private(set) var appendedPublicMessages: [(message: BitchatMessage, conversationID: ConversationID)] = []
    private(set) var removedMessages: [(messageID: String, cleanupFile: Bool)] = []
    private(set) var systemMessages: [String] = []
    private(set) var notifyUIChangedCount = 0

    @discardableResult
    func appendPublicMessage(_ message: BitchatMessage, to conversationID: ConversationID) -> Bool {
        appendedPublicMessages.append((message, conversationID))
        return true
    }

    func removeMessage(withID messageID: String, cleanupFile: Bool) {
        removedMessages.append((messageID, cleanupFile))
    }

    func addSystemMessage(_ content: String) { systemMessages.append(content) }
    func notifyUIChanged() { notifyUIChangedCount += 1 }

    // Delivery status & dedup
    private(set) var deliveryStatusUpdates: [(messageID: String, status: DeliveryStatus)] = []
    private(set) var recordedContentKeys: [String] = []

    func updateMessageDeliveryStatus(_ messageID: String, status: DeliveryStatus) {
        deliveryStatusUpdates.append((messageID, status))
    }

    func normalizedContentKey(_ content: String) -> String { content.lowercased() }

    func recordContentKey(_ key: String, timestamp: Date) {
        recordedContentKeys.append(key)
    }

    // Mesh file transfer
    private(set) var privateFileSends: [(peerID: PeerID, transferId: String)] = []
    private(set) var broadcastFileSends: [String] = []
    private(set) var cancelledTransfers: [String] = []

    func sendFilePrivate(_ packet: BitchatFilePacket, to peerID: PeerID, transferId: String) {
        privateFileSends.append((peerID, transferId))
    }

    func sendFileBroadcast(_ packet: BitchatFilePacket, transferId: String) {
        broadcastFileSends.append(transferId)
    }

    func cancelTransfer(_ transferId: String) {
        cancelledTransfers.append(transferId)
    }
}

// MARK: - Coordinator Tests Against Mock Context

/// Exercises `ChatMediaTransferCoordinator` against
/// `MockChatMediaTransferContext` with no `ChatViewModel`.
struct ChatMediaTransferCoordinatorContextTests {

    @Test @MainActor
    func enqueueMediaMessage_privateChatAppendsAndRecordsDedupKey() async {
        let context = MockChatMediaTransferContext()
        let coordinator = ChatMediaTransferCoordinator(context: context)
        let peerID = PeerID(str: "1122334455667788")
        context.nicknamesByPeerID[peerID] = "alice"

        let message = coordinator.enqueueMediaMessage(content: "[voice] note.m4a", targetPeer: peerID)

        #expect(context.privateChats[peerID]?.map(\.id) == [message.id])
        #expect(message.isPrivate)
        #expect(message.recipientNickname == "alice")
        #expect(message.senderPeerID == context.myPeerID)
        #expect(message.deliveryStatus == .sending)
        #expect(context.recordedContentKeys == ["[voice] note.m4a"])
        #expect(context.notifyUIChangedCount == 1)
        #expect(context.appendedPublicMessages.isEmpty)
    }

    @Test @MainActor
    func enqueueMediaMessage_publicAppendsToActiveConversation() async {
        let context = MockChatMediaTransferContext()
        let coordinator = ChatMediaTransferCoordinator(context: context)

        let message = coordinator.enqueueMediaMessage(content: "[image] pic.jpg", targetPeer: nil)

        #expect(context.appendedPublicMessages.map(\.message.id) == [message.id])
        #expect(context.appendedPublicMessages.first?.conversationID == .mesh)
        #expect(!message.isPrivate)
        #expect(message.sender == "me")
        #expect(context.privateChats.isEmpty)
        #expect(context.notifyUIChangedCount == 1)
    }

    @Test @MainActor
    func transferEvents_driveDeliveryStatusAndMappingCleanup() async {
        let context = MockChatMediaTransferContext()
        let coordinator = ChatMediaTransferCoordinator(context: context)
        coordinator.registerTransfer(transferId: "t1", messageID: "m1")

        coordinator.handleTransferEvent(.started(id: "t1", totalFragments: 10))
        coordinator.handleTransferEvent(.updated(id: "t1", sentFragments: 4, totalFragments: 10))
        coordinator.handleTransferEvent(.completed(id: "t1", totalFragments: 10))
        // After completion the mapping is gone: further events are ignored.
        coordinator.handleTransferEvent(.updated(id: "t1", sentFragments: 9, totalFragments: 10))

        #expect(context.deliveryStatusUpdates.count == 3)
        #expect(context.deliveryStatusUpdates[0].status == .partiallyDelivered(reached: 0, total: 10))
        #expect(context.deliveryStatusUpdates[1].status == .partiallyDelivered(reached: 4, total: 10))
        #expect(context.deliveryStatusUpdates[2].status == .sent)
        #expect(coordinator.messageIDToTransferId.isEmpty)

        // A cancelled transfer removes the message (with file cleanup).
        coordinator.registerTransfer(transferId: "t2", messageID: "m2")
        coordinator.handleTransferEvent(.cancelled(id: "t2", sentFragments: 1, totalFragments: 5))
        #expect(context.removedMessages.count == 1)
        #expect(context.removedMessages.first?.messageID == "m2")
        #expect(context.removedMessages.first?.cleanupFile == true)
    }

    @Test @MainActor
    func cancelMediaSend_cancelsOnlyActiveTransferAndRemovesMessage() async {
        let context = MockChatMediaTransferContext()
        let coordinator = ChatMediaTransferCoordinator(context: context)
        // Two messages share a transfer queue; only the active head cancels
        // the underlying transfer.
        coordinator.registerTransfer(transferId: "t1", messageID: "m1")
        coordinator.registerTransfer(transferId: "t1", messageID: "m2")

        coordinator.cancelMediaSend(messageID: "m2")
        #expect(context.cancelledTransfers.isEmpty)
        #expect(context.removedMessages.map(\.messageID) == ["m2"])

        coordinator.cancelMediaSend(messageID: "m1")
        #expect(context.cancelledTransfers == ["t1"])
        #expect(context.removedMessages.map(\.messageID) == ["m2", "m1"])
        #expect(coordinator.transferIdToMessageIDs.isEmpty)
        #expect(coordinator.messageIDToTransferId.isEmpty)
    }

    @Test @MainActor
    func sendVoiceNote_blockedContextRemovesFileAndExplains() async throws {
        let context = MockChatMediaTransferContext()
        let coordinator = ChatMediaTransferCoordinator(context: context)
        context.canSendMediaInCurrentContext = false

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-note-test-\(UUID().uuidString).m4a")
        try Data([0x01, 0x02]).write(to: url)

        coordinator.sendVoiceNote(at: url)

        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(context.systemMessages == ["Voice notes are only available in mesh chats."])
        #expect(context.privateChats.isEmpty)
        #expect(context.appendedPublicMessages.isEmpty)
        #expect(coordinator.transferIdToMessageIDs.isEmpty)
    }
}
