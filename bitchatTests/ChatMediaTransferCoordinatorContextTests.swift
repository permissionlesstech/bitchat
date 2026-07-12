//
// ChatMediaTransferCoordinatorContextTests.swift
// bitchatTests
//
// Exercises `ChatMediaTransferCoordinator` against a mock
// `ChatMediaTransferContext` — proving the coordinator works without a
// `ChatViewModel`, following the `ChatDeliveryCoordinatorContextTests` /
// `ChatPrivateConversationCoordinatorContextTests` exemplars.
//
// Real file/codec work remains covered by `ChatMediaPreparationTests`. These
// tests inject a paused voice-note preparer to exercise cancellation ownership
// across the detached-preparation/MainActor boundary deterministically.
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
    private(set) var privateFileLegacyAllowances: [Bool] = []
    private(set) var broadcastFileSends: [String] = []
    private(set) var cancelledTransfers: [String] = []
    var privateMediaPolicy: PrivateMediaSendPolicy = .encrypted
    private(set) var legacyConsentRequests: [(
        id: UUID,
        peerID: PeerID,
        transferId: String,
        messageID: String
    )] = []
    private(set) var invalidatedLegacyConsents: [(transferId: String, messageID: String)] = []
    private var pendingLegacyConsentIDs: [UUID] = []
    private var legacyConsentCompletions: [UUID: @MainActor (Bool) -> Void] = [:]

    func privateMediaSendPolicy(to peerID: PeerID) -> PrivateMediaSendPolicy {
        privateMediaPolicy
    }

    func requestLegacyPrivateMediaConsent(
        for peerID: PeerID,
        transferId: String,
        messageID: String,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        let id = UUID()
        legacyConsentRequests.append((id, peerID, transferId, messageID))
        pendingLegacyConsentIDs.append(id)
        legacyConsentCompletions[id] = completion
    }

    func cancelLegacyPrivateMediaConsent(transferId: String, messageID: String) {
        invalidatedLegacyConsents.append((transferId, messageID))
        let matchingIDs = Set(legacyConsentRequests.compactMap { request in
            request.transferId == transferId && request.messageID == messageID
                ? request.id
                : nil
        })
        pendingLegacyConsentIDs.removeAll { matchingIDs.contains($0) }
    }

    func resolveNextLegacyConsent(_ approved: Bool) {
        guard !pendingLegacyConsentIDs.isEmpty else { return }
        let id = pendingLegacyConsentIDs.removeFirst()
        legacyConsentCompletions[id]?(approved)
    }

    func invokeLegacyConsentEvenIfInvalidated(id: UUID, approved: Bool) {
        legacyConsentCompletions[id]?(approved)
    }

    func sendFilePrivate(
        _ packet: BitchatFilePacket,
        to peerID: PeerID,
        transferId: String,
        allowLegacyFallback: Bool
    ) {
        privateFileSends.append((peerID, transferId))
        privateFileLegacyAllowances.append(allowLegacyFallback)
    }

    func sendFileBroadcast(_ packet: BitchatFilePacket, transferId: String) {
        broadcastFileSends.append(transferId)
    }

    func cancelTransfer(_ transferId: String) {
        cancelledTransfers.append(transferId)
    }
}

private final class PausedVoiceNotePreparer: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var released = false
    private var finished = false
    private let packet: BitchatFilePacket

    init() {
        let content = Data("voice".utf8)
        packet = BitchatFilePacket(
            fileName: "paused.m4a",
            fileSize: UInt64(content.count),
            mimeType: "audio/mp4",
            content: content
        )
    }

    func prepare(_: URL) throws -> BitchatFilePacket {
        condition.lock()
        started = true
        condition.broadcast()
        while !released {
            condition.wait()
        }
        finished = true
        condition.broadcast()
        condition.unlock()
        return packet
    }

    var hasStarted: Bool {
        condition.lock()
        defer { condition.unlock() }
        return started
    }

    var hasFinished: Bool {
        condition.lock()
        defer { condition.unlock() }
        return finished
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
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

        // A pre-start rejection keeps the placeholder visible and failed,
        // including queued post-handshake encryption failures.
        coordinator.registerTransfer(transferId: "t3", messageID: "m3")
        coordinator.handleTransferEvent(.rejected(id: "t3", reason: "encryption failed"))
        #expect(context.deliveryStatusUpdates.last?.messageID == "m3")
        #expect(context.deliveryStatusUpdates.last?.status == .failed(reason: "encryption failed"))
        #expect(coordinator.messageIDToTransferId["m3"] == nil)
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
    func deleteMediaMessage_cancelsApprovedTransferBeforeRemovingMapping() {
        let context = MockChatMediaTransferContext()
        let coordinator = ChatMediaTransferCoordinator(context: context)
        coordinator.registerTransfer(transferId: "approved-delete", messageID: "message-delete")

        coordinator.deleteMediaMessage(messageID: "message-delete")

        #expect(context.cancelledTransfers == ["approved-delete"])
        #expect(coordinator.messageIDToTransferId["message-delete"] == nil)
        #expect(context.removedMessages.map(\.messageID) == ["message-delete"])
        #expect(context.removedMessages.first?.cleanupFile == true)
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

    @Test @MainActor
    func cancelVoiceNoteDuringDetachedPreparationCannotSendOrRestoreMapping() async throws {
        let context = MockChatMediaTransferContext()
        let peerID = PeerID(str: "5566778899aabbcc")
        context.selectedPrivateChatPeer = peerID
        let preparer = PausedVoiceNotePreparer()
        let coordinator = ChatMediaTransferCoordinator(
            context: context,
            prepareVoiceNotePacket: { url in try preparer.prepare(url) }
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("paused-private-\(UUID().uuidString).m4a")
        try Data("voice".utf8).write(to: url)
        defer {
            preparer.release()
            try? FileManager.default.removeItem(at: url)
        }

        coordinator.sendVoiceNote(at: url)
        #expect(await TestHelpers.waitUntil({ preparer.hasStarted }, timeout: TestConstants.longTimeout))
        let messageID = try #require(context.privateChats[peerID]?.first?.id)
        let transferId = try #require(coordinator.messageIDToTransferId[messageID])

        coordinator.cancelMediaSend(messageID: messageID)
        preparer.release()
        #expect(await TestHelpers.waitUntil({ preparer.hasFinished }, timeout: TestConstants.longTimeout))
        for _ in 0..<10 { await Task.yield() }

        #expect(context.cancelledTransfers == [transferId])
        #expect(context.privateFileSends.isEmpty)
        #expect(context.broadcastFileSends.isEmpty)
        #expect(coordinator.messageIDToTransferId[messageID] == nil)
        #expect(coordinator.transferIdToMessageIDs[transferId] == nil)
        #expect(context.removedMessages.map(\.messageID) == [messageID])
    }

    @Test @MainActor
    func deletePublicVoiceNoteDuringDetachedPreparationCannotBroadcastOrRestoreMapping() async throws {
        let context = MockChatMediaTransferContext()
        let preparer = PausedVoiceNotePreparer()
        let coordinator = ChatMediaTransferCoordinator(
            context: context,
            prepareVoiceNotePacket: { url in try preparer.prepare(url) }
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("paused-public-\(UUID().uuidString).m4a")
        try Data("voice".utf8).write(to: url)
        defer {
            preparer.release()
            try? FileManager.default.removeItem(at: url)
        }

        coordinator.sendVoiceNote(at: url)
        #expect(await TestHelpers.waitUntil({ preparer.hasStarted }, timeout: TestConstants.longTimeout))
        let messageID = try #require(context.appendedPublicMessages.first?.message.id)
        let transferId = try #require(coordinator.messageIDToTransferId[messageID])

        coordinator.deleteMediaMessage(messageID: messageID)
        preparer.release()
        #expect(await TestHelpers.waitUntil({ preparer.hasFinished }, timeout: TestConstants.longTimeout))
        for _ in 0..<10 { await Task.yield() }

        #expect(context.cancelledTransfers == [transferId])
        #expect(context.broadcastFileSends.isEmpty)
        #expect(context.privateFileSends.isEmpty)
        #expect(coordinator.messageIDToTransferId[messageID] == nil)
        #expect(coordinator.transferIdToMessageIDs[transferId] == nil)
        #expect(context.removedMessages.map(\.messageID) == [messageID])
    }

    @Test @MainActor
    func voicePreparationFailureMarksPlaceholderFailedAndClearsEarlyMapping() async throws {
        let context = MockChatMediaTransferContext()
        let peerID = PeerID(str: "66778899aabbccdd")
        context.selectedPrivateChatPeer = peerID
        let coordinator = ChatMediaTransferCoordinator(
            context: context,
            prepareVoiceNotePacket: { _ in
                throw ChatMediaPreparationError.voiceNoteTooLarge(bytes: 999_999)
            }
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("failing-private-\(UUID().uuidString).m4a")
        try Data("voice".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        coordinator.sendVoiceNote(at: url)
        #expect(await TestHelpers.waitUntil(
            {
                context.deliveryStatusUpdates.contains { update in
                    if case .failed = update.status { return true }
                    return false
                }
            },
            timeout: TestConstants.longTimeout
        ))
        let messageID = try #require(context.privateChats[peerID]?.first?.id)

        #expect(coordinator.messageIDToTransferId[messageID] == nil)
        #expect(coordinator.transferIdToMessageIDs.isEmpty)
        #expect(context.privateFileSends.isEmpty)
        #expect(context.broadcastFileSends.isEmpty)
    }

    @Test @MainActor
    func legacyPrivateVoiceNoteWaitsForPerSendConsent() async throws {
        let context = MockChatMediaTransferContext()
        let coordinator = ChatMediaTransferCoordinator(context: context)
        let peerID = PeerID(str: "1122334455667788")
        context.selectedPrivateChatPeer = peerID
        context.privateMediaPolicy = .legacyRequiresConsent
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-consent-\(UUID().uuidString).m4a")
        try (Data([0x00, 0x00, 0x00, 0x18]) + Data("ftypM4A voice".utf8)).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        coordinator.sendVoiceNote(at: url)

        let prompted = await TestHelpers.waitUntil(
            { context.legacyConsentRequests.count == 1 },
            timeout: TestConstants.longTimeout
        )
        #expect(prompted)
        #expect(context.legacyConsentRequests.map { $0.peerID } == [peerID])
        #expect(context.privateFileSends.isEmpty)

        context.resolveNextLegacyConsent(true)

        #expect(context.privateFileSends.count == 1)
        #expect(context.privateFileLegacyAllowances == [true])
    }

    @Test @MainActor
    func legacyConsentApprovalAfterCancelCannotSend() async throws {
        let context = MockChatMediaTransferContext()
        let coordinator = ChatMediaTransferCoordinator(context: context)
        let peerID = PeerID(str: "2233445566778899")
        context.selectedPrivateChatPeer = peerID
        context.privateMediaPolicy = .legacyRequiresConsent
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-cancel-\(UUID().uuidString).m4a")
        try Data("voice".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        coordinator.sendVoiceNote(at: url)
        let prompted = await TestHelpers.waitUntil(
            { context.legacyConsentRequests.count == 1 },
            timeout: TestConstants.longTimeout
        )
        #expect(prompted)
        let request = try #require(context.legacyConsentRequests.first)

        coordinator.cancelMediaSend(messageID: request.messageID)
        #expect(context.invalidatedLegacyConsents.contains {
            $0.transferId == request.transferId && $0.messageID == request.messageID
        })

        // Model a stale framework callback that escaped active invalidation.
        // The coordinator's transfer/message binding check is the final gate.
        context.invokeLegacyConsentEvenIfInvalidated(id: request.id, approved: true)
        #expect(context.privateFileSends.isEmpty)
        #expect(coordinator.messageIDToTransferId[request.messageID] == nil)
    }

    @Test @MainActor
    func legacyConsentApprovalAfterDeleteCannotSend() async throws {
        let context = MockChatMediaTransferContext()
        let coordinator = ChatMediaTransferCoordinator(context: context)
        let peerID = PeerID(str: "33445566778899aa")
        context.selectedPrivateChatPeer = peerID
        context.privateMediaPolicy = .legacyRequiresConsent
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-delete-\(UUID().uuidString).m4a")
        try Data("voice".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        coordinator.sendVoiceNote(at: url)
        let prompted = await TestHelpers.waitUntil(
            { context.legacyConsentRequests.count == 1 },
            timeout: TestConstants.longTimeout
        )
        #expect(prompted)
        let request = try #require(context.legacyConsentRequests.first)

        coordinator.deleteMediaMessage(messageID: request.messageID)
        context.invokeLegacyConsentEvenIfInvalidated(id: request.id, approved: true)

        #expect(context.invalidatedLegacyConsents.contains {
            $0.transferId == request.transferId && $0.messageID == request.messageID
        })
        #expect(context.privateFileSends.isEmpty)
        #expect(coordinator.messageIDToTransferId[request.messageID] == nil)
    }

    @Test @MainActor
    func pinnedPrivateMediaDowngradeNeverPromptsOrSends() async throws {
        let context = MockChatMediaTransferContext()
        let coordinator = ChatMediaTransferCoordinator(context: context)
        let peerID = PeerID(str: "1122334455667788")
        context.selectedPrivateChatPeer = peerID
        context.privateMediaPolicy = .blockedDowngrade
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("blocked-downgrade-\(UUID().uuidString).m4a")
        try Data("voice".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        coordinator.sendVoiceNote(at: url)

        let failed = await TestHelpers.waitUntil(
            { context.deliveryStatusUpdates.contains { update in
                if case .failed = update.status { return true }
                return false
            } },
            timeout: TestConstants.longTimeout
        )
        #expect(failed)
        #expect(context.legacyConsentRequests.isEmpty)
        #expect(context.privateFileSends.isEmpty)
    }
}
