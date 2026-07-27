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
// tests inject paused media preparers to exercise cancellation ownership
// across the detached-preparation/MainActor boundary deterministically.
//

import Testing
import Foundation
import BitFoundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif
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
    private(set) var untombstonedMediaRemovals: [String] = []
    private(set) var outgoingMediaRemovals: [String] = []
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

    func removeUntombstonedMediaMessage(withID messageID: String) {
        untombstonedMediaRemovals.append(messageID)
        removedMessages.append((messageID, false))
    }

    func removeOutgoingMediaMessage(withID messageID: String) {
        outgoingMediaRemovals.append(messageID)
        removedMessages.append((messageID, false))
    }

    func addSystemMessage(_ content: String) { systemMessages.append(content) }
    private(set) var mediaDeletionRefusals: [String] = []
    func notifyMediaDeletionRefused(messageID: String) {
        mediaDeletionRefusals.append(messageID)
    }
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
    private(set) var privateFileSends: [(
        packet: BitchatFilePacket,
        peerID: PeerID,
        transferId: String
    )] = []
    private(set) var privateFileLegacyAllowances: [Bool] = []
    private(set) var privateFileReceiptRetryTransferIDs: [String] = []
    private(set) var broadcastFileSends: [String] = []
    private(set) var cancelledTransfers: [String] = []
    private(set) var privateMediaPolicyResolutionRequests: [PeerID] = []
    private(set) var persistedDeletionBatches: [[String]] = []
    var requiredTombstoneIDs: Set<String> = []
    var deletedMediaPersistenceResult = true
    var deferDeletedMediaPersistence = false
    private var pendingDeletionCompletions: [
        @MainActor (Bool) -> Void
    ] = []
    var privateMediaPolicy: PrivateMediaSendPolicy = .encrypted
    var resolvedPrivateMediaPolicy: PrivateMediaSendPolicy?
    var resolvesPrivateMediaPolicyImmediately = true
    var supportsAuthenticatedPrivateMediaReceipts = false
    var authenticatedPrivateMediaReceiptGeneration = UUID(
        uuidString: "00000000-0000-0000-0000-000000000001"
    )!
    private var pendingPrivateMediaPolicyResolutions: [
        @MainActor (PrivateMediaSendPolicy) -> Void
    ] = []
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

    func authenticatedPrivateMediaReceiptSessionGeneration(
        to peerID: PeerID
    ) -> UUID? {
        supportsAuthenticatedPrivateMediaReceipts
            ? authenticatedPrivateMediaReceiptGeneration
            : nil
    }

    func resolvePrivateMediaSendPolicy(
        to peerID: PeerID,
        completion: @escaping @MainActor (PrivateMediaSendPolicy) -> Void
    ) {
        privateMediaPolicyResolutionRequests.append(peerID)
        if resolvesPrivateMediaPolicyImmediately {
            completion(resolvedPrivateMediaPolicy ?? privateMediaPolicy)
        } else {
            pendingPrivateMediaPolicyResolutions.append(completion)
        }
    }

    var pendingPrivateMediaPolicyResolutionCount: Int {
        pendingPrivateMediaPolicyResolutions.count
    }

    func resolveNextPrivateMediaPolicy(
        _ policy: PrivateMediaSendPolicy? = nil
    ) {
        guard !pendingPrivateMediaPolicyResolutions.isEmpty else { return }
        let completion = pendingPrivateMediaPolicyResolutions.removeFirst()
        completion(
            policy
                ?? resolvedPrivateMediaPolicy
                ?? privateMediaPolicy
        )
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
        privateFileSends.append((packet, peerID, transferId))
        privateFileLegacyAllowances.append(allowLegacyFallback)
    }

    func sendFilePrivateReceiptRetry(
        _ packet: BitchatFilePacket,
        to peerID: PeerID,
        transferId: String
    ) {
        privateFileSends.append((packet, peerID, transferId))
        privateFileLegacyAllowances.append(false)
        privateFileReceiptRetryTransferIDs.append(transferId)
    }

    func sendFileBroadcast(_ packet: BitchatFilePacket, transferId: String) {
        broadcastFileSends.append(transferId)
    }

    func cancelTransfer(_ transferId: String) {
        cancelledTransfers.append(transferId)
    }

    func persistDeletedPrivateMedia(
        messageIDs: [String],
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        persistedDeletionBatches.append(messageIDs)
        if deferDeletedMediaPersistence {
            pendingDeletionCompletions.append(completion)
        } else {
            completion(deletedMediaPersistenceResult)
        }
    }

    func requiresPrivateMediaTombstone(messageID: String) -> Bool {
        requiredTombstoneIDs.contains(messageID)
    }

    func resolveNextDeletionPersistence(_ result: Bool? = nil) {
        guard !pendingDeletionCompletions.isEmpty else { return }
        let completion = pendingDeletionCompletions.removeFirst()
        completion(result ?? deletedMediaPersistenceResult)
    }
}

private final class PausedVoiceNotePreparer: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var released = false
    private var finished = false

    func prepare(_ url: URL) throws -> BitchatFilePacket {
        condition.lock()
        started = true
        condition.broadcast()
        while !released {
            condition.wait()
        }
        finished = true
        condition.broadcast()
        condition.unlock()
        let content = Data("voice".utf8)
        return BitchatFilePacket(
            fileName: url.lastPathComponent,
            fileSize: UInt64(content.count),
            mimeType: "audio/mp4",
            content: content
        )
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

private final class StaticVoiceNotePreparer: @unchecked Sendable {
    private let packet: BitchatFilePacket

    init(fileName: String, content: Data = Data("voice".utf8)) {
        packet = BitchatFilePacket(
            fileName: fileName,
            fileSize: UInt64(content.count),
            mimeType: "audio/mp4",
            content: content
        )
    }

    func prepare(_ _: URL) throws -> BitchatFilePacket {
        packet
    }
}

private final class DeterministicMediaTransferIDFactory:
    @unchecked Sendable {
    private let lock = NSLock()
    private var nextOrdinal = 0

    func make(messageID: String) -> String {
        lock.lock()
        defer {
            nextOrdinal += 1
            lock.unlock()
        }
        return "\(messageID)-attempt-\(nextOrdinal)"
    }
}

private final class MutableMediaRetryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
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
        #expect(context.removedMessages.first?.cleanupFile == false)
        #expect(context.outgoingMediaRemovals == ["m2"])

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
    func resetForPanic_cancelsEveryTransportTransferAndClearsMappings() {
        let context = MockChatMediaTransferContext()
        let coordinator = ChatMediaTransferCoordinator(context: context)
        coordinator.registerTransfer(transferId: "t1", messageID: "m1")
        coordinator.registerTransfer(transferId: "t1", messageID: "m2")
        coordinator.registerTransfer(transferId: "t2", messageID: "m3")

        coordinator.resetForPanic()

        #expect(Set(context.cancelledTransfers) == Set(["t1", "t2"]))
        #expect(coordinator.transferIdToMessageIDs.isEmpty)
        #expect(coordinator.messageIDToTransferId.isEmpty)
    }

    @Test @MainActor
    func resetForPanic_waitsForActiveImageWriterBeforeReturning() async throws {
        let context = MockChatMediaTransferContext()
        let sourceURL = try makeCoordinatorTestImageURL()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("panic-prepared-\(UUID().uuidString).jpg")
        let preparer = PausedImagePreparer(outputURL: outputURL)
        let coordinator = ChatMediaTransferCoordinator(
            context: context,
            prepareImagePacket: { sourceURL in
                try preparer.prepare(sourceURL)
            }
        )
        defer {
            preparer.release()
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: outputURL)
        }

        coordinator.sendImage(from: sourceURL)
        #expect(await TestHelpers.waitUntil(
            { preparer.hasStarted },
            timeout: TestConstants.longTimeout
        ))

        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + .milliseconds(100)
        ) {
            preparer.release()
        }
        coordinator.resetForPanic()

        // The synchronous reset boundary cannot return while a pre-panic
        // writer can still create output. The real panic path deletes media
        // immediately after this method returns.
        #expect(preparer.hasFinished)

        try? FileManager.default.removeItem(at: outputURL)
        #expect(await TestHelpers.waitUntil(
            { !FileManager.default.fileExists(atPath: outputURL.path) },
            timeout: TestConstants.longTimeout
        ))
        await Task.yield()
        #expect(context.privateFileSends.isEmpty)
        #expect(context.broadcastFileSends.isEmpty)
        #expect(context.systemMessages.isEmpty)
    }

    @Test @MainActor
    func imagePreparation_doesNotRetainCoordinatorOrDeallocatedContext() async throws {
        let sourceURL = try makeCoordinatorTestImageURL()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("released-context-\(UUID().uuidString).jpg")
        let preparer = PausedImagePreparer(outputURL: outputURL)
        var context: MockChatMediaTransferContext? = MockChatMediaTransferContext()
        var coordinator: ChatMediaTransferCoordinator? = ChatMediaTransferCoordinator(
            context: context!,
            prepareImagePacket: { sourceURL in
                try preparer.prepare(sourceURL)
            }
        )
        weak var weakContext: MockChatMediaTransferContext?
        weak var weakCoordinator: ChatMediaTransferCoordinator?
        weakContext = context
        weakCoordinator = coordinator
        defer {
            preparer.release()
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: outputURL)
        }

        coordinator?.sendImage(from: sourceURL)
        #expect(await TestHelpers.waitUntil(
            { preparer.hasStarted },
            timeout: TestConstants.longTimeout
        ))

        coordinator = nil
        context = nil
        #expect(weakCoordinator == nil)
        #expect(weakContext == nil)

        preparer.release()
        #expect(await TestHelpers.waitUntil(
            { preparer.hasFinished },
            timeout: TestConstants.longTimeout
        ))
        #expect(await TestHelpers.waitUntil(
            { !FileManager.default.fileExists(atPath: outputURL.path) },
            timeout: TestConstants.longTimeout
        ))
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
        #expect(context.removedMessages.first?.cleanupFile == false)
        #expect(
            context.untombstonedMediaRemovals == ["message-delete"]
        )
    }

    @Test @MainActor
    func deleteIncomingStableMediaWaitsForDurableTombstone() {
        let context = MockChatMediaTransferContext()
        let coordinator = ChatMediaTransferCoordinator(context: context)
        let messageID = "media-00112233445566778899aabbccddeeff"
        context.requiredTombstoneIDs = [messageID]
        context.deferDeletedMediaPersistence = true
        coordinator.registerTransfer(
            transferId: "incoming-delete",
            messageID: messageID
        )

        coordinator.deleteMediaMessage(messageID: messageID)

        #expect(context.persistedDeletionBatches == [[messageID]])
        #expect(context.removedMessages.isEmpty)
        #expect(context.cancelledTransfers == ["incoming-delete"])
        #expect(coordinator.messageIDToTransferId[messageID] == nil)

        context.resolveNextDeletionPersistence(true)

        #expect(context.cancelledTransfers == ["incoming-delete"])
        #expect(context.removedMessages.map(\.messageID) == [messageID])
        #expect(context.removedMessages.first?.cleanupFile == false)
        #expect(context.untombstonedMediaRemovals.isEmpty)
        #expect(coordinator.messageIDToTransferId[messageID] == nil)
    }

    @Test @MainActor
    func deleteIncomingStableMediaCompletionAfterPanicIsIgnored() {
        let context = MockChatMediaTransferContext()
        let coordinator = ChatMediaTransferCoordinator(context: context)
        let messageID = "media-11223344556677889900aabbccddeeff"
        context.requiredTombstoneIDs = [messageID]
        context.deferDeletedMediaPersistence = true

        coordinator.deleteMediaMessage(messageID: messageID)
        #expect(context.persistedDeletionBatches == [[messageID]])

        coordinator.resetForPanic()
        context.resolveNextDeletionPersistence(true)

        #expect(context.removedMessages.isEmpty)
        #expect(context.untombstonedMediaRemovals.isEmpty)
    }

    @Test @MainActor
    func deleteIncomingStableMediaPreservesStateWhenTombstoneFails() {
        let context = MockChatMediaTransferContext()
        let coordinator = ChatMediaTransferCoordinator(context: context)
        let messageID = "media-ffeeddccbbaa99887766554433221100"
        context.requiredTombstoneIDs = [messageID]
        context.deletedMediaPersistenceResult = false
        coordinator.registerTransfer(
            transferId: "failed-delete",
            messageID: messageID
        )

        coordinator.deleteMediaMessage(messageID: messageID)

        #expect(context.persistedDeletionBatches == [[messageID]])
        #expect(context.removedMessages.isEmpty)
        #expect(context.cancelledTransfers == ["failed-delete"])
        #expect(coordinator.messageIDToTransferId[messageID] == nil)
        // The refusal must be visible in the affected chat, not just logged.
        #expect(context.mediaDeletionRefusals == [messageID])
    }

    @Test @MainActor
    func deleteStableMediaReleasesRetainedRetryBeforeTombstoneCommit()
        async throws
    {
        let context = MockChatMediaTransferContext()
        let peerID = PeerID(str: "1122334455667788")
        context.selectedPrivateChatPeer = peerID
        context.supportsAuthenticatedPrivateMediaReceipts = true
        context.deferDeletedMediaPersistence = true
        let fileName = "voice_deadbeefdeadbeef.m4a"
        let preparer = StaticVoiceNotePreparer(fileName: fileName)
        let coordinator = ChatMediaTransferCoordinator(
            context: context,
            prepareVoiceNotePacket: { url in
                try preparer.prepare(url)
            }
        )
        let url = try makeCoordinatorVoiceURL(fileName: fileName)
        defer {
            try? FileManager.default.removeItem(
                at: url.deletingLastPathComponent()
            )
        }

        coordinator.sendVoiceNote(at: url)
        #expect(await TestHelpers.waitUntil(
            { context.privateFileSends.count == 1 },
            timeout: TestConstants.longTimeout
        ))
        let messageID = try #require(
            context.privateChats[peerID]?.first?.id
        )
        let transferID = try #require(
            context.privateFileSends.first?.transferId
        )
        context.requiredTombstoneIDs = [messageID]
        #expect(coordinator.retainedReconnectRetryCount == 1)

        coordinator.deleteMediaMessage(messageID: messageID)

        #expect(context.persistedDeletionBatches == [[messageID]])
        #expect(coordinator.retainedReconnectRetryCount == 0)
        #expect(coordinator.retainedReconnectRetryBytes == 0)
        #expect(context.cancelledTransfers == [transferID])
        #expect(context.removedMessages.isEmpty)

        coordinator.peerDidReconnect(peerID)
        #expect(context.privateFileSends.count == 1)

        context.resolveNextDeletionPersistence(true)
        #expect(context.removedMessages.map(\.messageID) == [messageID])
    }

    @Test @MainActor
    func legacyCleanupNeverRecursivelyDeletesDirectoryTarget() throws {
        let context = MockChatMediaTransferContext()
        let coordinator = ChatMediaTransferCoordinator(context: context)
        let incoming = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent(
            "files/images/incoming",
            isDirectory: true
        )
        let directoryName = "cleanup-dir-\(UUID().uuidString)"
        let directory = incoming.appendingPathComponent(
            directoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let child = directory.appendingPathComponent("child.jpg")
        try Data([0x01]).write(to: child)
        defer { try? FileManager.default.removeItem(at: directory) }
        let message = BitchatMessage(
            id: UUID().uuidString,
            sender: "Peer",
            content:
                "\(MimeType.Category.image.messagePrefix)\(directoryName)",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "Me"
        )

        coordinator.cleanupIncomingLocalFile(forMessage: message)

        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(FileManager.default.fileExists(atPath: child.path))
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
    func privateVoiceNoteUsesWireDerivableMessageID() async throws {
        let context = MockChatMediaTransferContext()
        let coordinator = ChatMediaTransferCoordinator(context: context)
        let peerID = PeerID(str: "1122334455667788")
        context.selectedPrivateChatPeer = peerID
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice_receipt_\(UUID().uuidString).m4a")
        try Data("voice".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        coordinator.sendVoiceNote(at: url)

        #expect(await TestHelpers.waitUntil(
            { context.privateFileSends.count == 1 },
            timeout: TestConstants.longTimeout
        ))
        let message = try #require(context.privateChats[peerID]?.first)
        let sentPacket = try #require(context.privateFileSends.first?.packet)
        #expect(message.id == PrivateMediaMessageIdentity.stableID(
            for: sentPacket,
            senderPeerID: context.myPeerID,
            recipientPeerID: peerID
        ))
    }

    @Test @MainActor
    func privateImageUsesWireDerivableMessageID() async throws {
        let context = MockChatMediaTransferContext()
        let coordinator = ChatMediaTransferCoordinator(context: context)
        let peerID = PeerID(str: "99aabbccddeeff00")
        context.selectedPrivateChatPeer = peerID
        let sourceURL = try makeCoordinatorTestImageURL()
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        coordinator.sendImage(from: sourceURL)

        #expect(await TestHelpers.waitUntil(
            { context.privateFileSends.count == 1 },
            timeout: TestConstants.longTimeout
        ))
        let message = try #require(context.privateChats[peerID]?.first)
        let sentPacket = try #require(context.privateFileSends.first?.packet)
        #expect(message.id == PrivateMediaMessageIdentity.stableID(
            for: sentPacket,
            senderPeerID: context.myPeerID,
            recipientPeerID: peerID
        ))
        coordinator.cleanupLocalFile(forMessage: message)
    }

    @Test @MainActor
    func panicDuringImagePreparationDeletesStaleOutputWithoutSideEffects() async throws {
        let context = MockChatMediaTransferContext()
        let peerID = PeerID(str: "99aabbccddeeff00")
        context.selectedPrivateChatPeer = peerID
        let sourceURL = try makeCoordinatorTestImageURL()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "panic-stale-image-\(UUID().uuidString).jpg"
            )
        let preparer = PausedImagePreparer(outputURL: outputURL)
        let coordinator = ChatMediaTransferCoordinator(
            context: context,
            prepareImagePacket: { url in try preparer.prepare(url) }
        )
        defer {
            preparer.release()
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: outputURL)
        }

        coordinator.sendImage(from: sourceURL)
        #expect(await TestHelpers.waitUntil(
            { preparer.hasStarted },
            timeout: TestConstants.longTimeout
        ))

        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + .milliseconds(100)
        ) {
            preparer.release()
        }
        coordinator.resetForPanic()

        #expect(await TestHelpers.waitUntil(
            { preparer.hasFinished },
            timeout: TestConstants.longTimeout
        ))
        #expect(await TestHelpers.waitUntil(
            { !FileManager.default.fileExists(atPath: outputURL.path) },
            timeout: TestConstants.longTimeout
        ))
        #expect(context.privateChats[peerID]?.isEmpty != false)
        #expect(context.appendedPublicMessages.isEmpty)
        #expect(context.privateFileSends.isEmpty)
        #expect(context.broadcastFileSends.isEmpty)
        #expect(context.systemMessages.isEmpty)
        #expect(context.deliveryStatusUpdates.isEmpty)
        #expect(coordinator.transferIdToMessageIDs.isEmpty)
        #expect(coordinator.messageIDToTransferId.isEmpty)
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
    func capabilityProofTimeoutTransitionsToConsentWithoutAutomaticRawSend() async throws {
        let context = MockChatMediaTransferContext()
        let coordinator = ChatMediaTransferCoordinator(context: context)
        let peerID = PeerID(str: "1020304050607080")
        context.selectedPrivateChatPeer = peerID
        context.privateMediaPolicy = .awaitingCapabilityProof
        context.resolvedPrivateMediaPolicy = .legacyRequiresConsent
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("proof-timeout-consent-\(UUID().uuidString).m4a")
        try Data("voice".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        coordinator.sendVoiceNote(at: url)

        let prompted = await TestHelpers.waitUntil(
            { context.legacyConsentRequests.count == 1 },
            timeout: TestConstants.longTimeout
        )
        #expect(prompted)
        #expect(context.privateFileSends.isEmpty)
        context.resolveNextLegacyConsent(false)
        #expect(context.privateFileSends.isEmpty)
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

    @Test @MainActor
    func receiptCapableEncryptedMediaRetriesExactPacketAfterReconnect() async throws {
        let context = MockChatMediaTransferContext()
        let peerID = PeerID(str: "1122334455667788")
        context.selectedPrivateChatPeer = peerID
        context.supportsAuthenticatedPrivateMediaReceipts = true
        let fileName = "voice_0011223344556677.m4a"
        let preparer = StaticVoiceNotePreparer(fileName: fileName)
        let transferIDs = DeterministicMediaTransferIDFactory()
        let coordinator = ChatMediaTransferCoordinator(
            context: context,
            prepareVoiceNotePacket: { url in
                try preparer.prepare(url)
            },
            transferIDFactory: transferIDs.make
        )
        let url = try makeCoordinatorVoiceURL(fileName: fileName)
        defer {
            try? FileManager.default.removeItem(
                at: url.deletingLastPathComponent()
            )
        }

        coordinator.sendVoiceNote(at: url)
        #expect(await TestHelpers.waitUntil(
            { context.privateFileSends.count == 1 },
            timeout: TestConstants.longTimeout
        ))
        let messageID = try #require(
            context.privateChats[peerID]?.first?.id
        )
        let initial = try #require(
            context.privateFileSends.first
        )
        #expect(PrivateMediaMessageIdentity.isStableID(messageID))
        #expect(coordinator.retainedReconnectRetryCount == 1)

        coordinator.handleTransferEvent(.completed(
            id: initial.transferId,
            totalFragments: 1
        ))
        #expect(coordinator.retainedReconnectRetryCount == 1)
        #expect(context.deliveryStatusUpdates.last?.status == .sent)

        coordinator.peerDidReconnect(peerID)
        #expect(context.privateFileSends.count == 2)
        let retry = try #require(context.privateFileSends.last)
        #expect(retry.packet.encode() == initial.packet.encode())
        #expect(retry.peerID == peerID)
        #expect(retry.transferId != initial.transferId)
        #expect(context.privateFileReceiptRetryTransferIDs == [
            retry.transferId
        ])
        #expect(context.privateFileLegacyAllowances == [false, false])

        coordinator.confirmPrivateMediaDelivery(messageID: messageID)
        #expect(coordinator.retainedReconnectRetryCount == 0)
        #expect(context.cancelledTransfers == [retry.transferId])
        #expect(context.removedMessages.isEmpty)
        #expect(!context.deliveryStatusUpdates.contains {
            if case .failed = $0.status { return true }
            return false
        })

        // Receipt confirmation removes retry ownership before transport
        // cancellation, so its late callback cannot delete the delivered row
        // or re-arm another reconnect retry.
        coordinator.handleTransferEvent(.cancelled(
            id: retry.transferId,
            sentFragments: 1,
            totalFragments: 2
        ))
        coordinator.peerDidReconnect(peerID)
        #expect(context.privateFileSends.count == 2)
        #expect(context.removedMessages.isEmpty)
        #expect(coordinator.messageIDToTransferId[messageID] == nil)
    }

    @Test @MainActor
    func disconnectClearsDroppedPolicyResolutionSoRetriesRecover() async throws {
        let context = MockChatMediaTransferContext()
        let peerID = PeerID(str: "1122334455667788")
        context.selectedPrivateChatPeer = peerID
        context.supportsAuthenticatedPrivateMediaReceipts = true
        let fileName = "voice_3333444455556666.m4a"
        let preparer = StaticVoiceNotePreparer(fileName: fileName)
        let coordinator = ChatMediaTransferCoordinator(
            context: context,
            prepareVoiceNotePacket: { url in
                try preparer.prepare(url)
            }
        )
        let url = try makeCoordinatorVoiceURL(fileName: fileName)
        defer {
            try? FileManager.default.removeItem(
                at: url.deletingLastPathComponent()
            )
        }

        coordinator.sendVoiceNote(at: url)
        #expect(await TestHelpers.waitUntil(
            { context.privateFileSends.count == 1 },
            timeout: TestConstants.longTimeout
        ))
        let initial = try #require(context.privateFileSends.first)
        coordinator.handleTransferEvent(.completed(
            id: initial.transferId,
            totalFragments: 1
        ))
        #expect(coordinator.retainedReconnectRetryCount == 1)

        // The transport accepts this resolution but its completion is never
        // invoked (BLEService queue teardown drops the closure), so the
        // pending entry parks every subsequent reconnect resolution.
        context.resolvesPrivateMediaPolicyImmediately = false
        coordinator.peerDidReconnect(peerID)
        #expect(context.privateMediaPolicyResolutionRequests.count == 1)
        coordinator.peerDidReconnect(peerID)
        #expect(context.privateMediaPolicyResolutionRequests.count == 1)

        // Disconnection invalidates the dropped resolution; the next
        // reconnect must start fresh and complete the retry.
        coordinator.peerDidDisconnect(peerID)
        context.resolvesPrivateMediaPolicyImmediately = true
        coordinator.peerDidReconnect(peerID)
        #expect(context.privateMediaPolicyResolutionRequests.count == 2)
        #expect(context.privateFileSends.count == 2)
        let retry = try #require(context.privateFileSends.last)
        #expect(retry.packet.encode() == initial.packet.encode())
        #expect(retry.peerID == peerID)
        #expect(context.privateFileReceiptRetryTransferIDs == [
            retry.transferId
        ])
    }

    @Test @MainActor
    func bit8OnlyEncryptedMediaNeverRetainsOrAutomaticallyRetries() async throws {
        let context = MockChatMediaTransferContext()
        let peerID = PeerID(str: "1122334455667788")
        context.selectedPrivateChatPeer = peerID
        context.privateMediaPolicy = .encrypted
        context.supportsAuthenticatedPrivateMediaReceipts = false
        let fileName = "voice_1111222233334444.m4a"
        let preparer = StaticVoiceNotePreparer(fileName: fileName)
        let coordinator = ChatMediaTransferCoordinator(
            context: context,
            prepareVoiceNotePacket: { url in
                try preparer.prepare(url)
            }
        )
        let url = try makeCoordinatorVoiceURL(fileName: fileName)
        defer {
            try? FileManager.default.removeItem(
                at: url.deletingLastPathComponent()
            )
        }

        coordinator.sendVoiceNote(at: url)
        #expect(await TestHelpers.waitUntil(
            { context.privateFileSends.count == 1 },
            timeout: TestConstants.longTimeout
        ))
        let initial = try #require(context.privateFileSends.first)
        coordinator.handleTransferEvent(.completed(
            id: initial.transferId,
            totalFragments: 1
        ))
        coordinator.peerDidReconnect(peerID)
        coordinator.peerDidAuthenticate(peerID)

        #expect(coordinator.retainedReconnectRetryCount == 0)
        #expect(context.privateFileSends.count == 1)
        #expect(context.privateFileReceiptRetryTransferIDs.isEmpty)
        #expect(context.privateMediaPolicyResolutionRequests.isEmpty)
    }

    @Test @MainActor
    func consentedRawLegacyMediaNeverEntersAutomaticRetry() async throws {
        let context = MockChatMediaTransferContext()
        let peerID = PeerID(str: "1122334455667788")
        context.selectedPrivateChatPeer = peerID
        context.privateMediaPolicy = .legacyRequiresConsent
        // Even a contradictory stale bit-9 observation must not retain an
        // invocation that actually selected the explicit raw path.
        context.supportsAuthenticatedPrivateMediaReceipts = true
        let fileName = "voice_2222333344445555.m4a"
        let preparer = StaticVoiceNotePreparer(fileName: fileName)
        let coordinator = ChatMediaTransferCoordinator(
            context: context,
            prepareVoiceNotePacket: { url in
                try preparer.prepare(url)
            }
        )
        let url = try makeCoordinatorVoiceURL(fileName: fileName)
        defer {
            try? FileManager.default.removeItem(
                at: url.deletingLastPathComponent()
            )
        }

        coordinator.sendVoiceNote(at: url)
        #expect(await TestHelpers.waitUntil(
            { context.legacyConsentRequests.count == 1 },
            timeout: TestConstants.longTimeout
        ))
        context.resolveNextLegacyConsent(true)
        let initial = try #require(context.privateFileSends.first)
        #expect(context.privateFileLegacyAllowances == [true])
        #expect(coordinator.retainedReconnectRetryCount == 0)

        coordinator.handleTransferEvent(.completed(
            id: initial.transferId,
            totalFragments: 1
        ))
        context.privateMediaPolicy = .encrypted
        coordinator.peerDidReconnect(peerID)
        coordinator.peerDidAuthenticate(peerID)

        #expect(context.privateFileSends.count == 1)
        #expect(context.privateFileReceiptRetryTransferIDs.isEmpty)
        #expect(coordinator.retainedReconnectRetryCount == 0)
    }

    @Test @MainActor
    func authenticatedGenerationSupersedesStaleReconnectResolution() async throws {
        let context = MockChatMediaTransferContext()
        let peerID = PeerID(str: "1122334455667788")
        context.selectedPrivateChatPeer = peerID
        context.supportsAuthenticatedPrivateMediaReceipts = true
        context.resolvesPrivateMediaPolicyImmediately = false
        let oldGeneration = context
            .authenticatedPrivateMediaReceiptGeneration
        let newGeneration = UUID(
            uuidString: "00000000-0000-0000-0000-000000000002"
        )!
        let fileName = "voice_3333444455556666.m4a"
        let preparer = StaticVoiceNotePreparer(fileName: fileName)
        let transferIDs = DeterministicMediaTransferIDFactory()
        let coordinator = ChatMediaTransferCoordinator(
            context: context,
            prepareVoiceNotePacket: { url in
                try preparer.prepare(url)
            },
            transferIDFactory: transferIDs.make
        )
        let url = try makeCoordinatorVoiceURL(fileName: fileName)
        defer {
            try? FileManager.default.removeItem(
                at: url.deletingLastPathComponent()
            )
        }

        coordinator.sendVoiceNote(at: url)
        #expect(await TestHelpers.waitUntil(
            { context.privateFileSends.count == 1 },
            timeout: TestConstants.longTimeout
        ))
        let initial = try #require(context.privateFileSends.first)
        coordinator.peerDidReconnect(peerID)
        #expect(context.pendingPrivateMediaPolicyResolutionCount == 1)

        context.authenticatedPrivateMediaReceiptGeneration = newGeneration
        coordinator.peerDidAuthenticate(peerID)
        #expect(context.pendingPrivateMediaPolicyResolutionCount == 2)

        // The old-generation completion lost ownership and is inert.
        context.resolveNextPrivateMediaPolicy(.encrypted)
        #expect(context.privateFileReceiptRetryTransferIDs.isEmpty)
        #expect(context.cancelledTransfers.isEmpty)

        context.resolveNextPrivateMediaPolicy(.encrypted)
        #expect(context.cancelledTransfers == [initial.transferId])
        #expect(context.privateFileReceiptRetryTransferIDs.count == 1)
        #expect(
            context.authenticatedPrivateMediaReceiptGeneration
                == newGeneration
        )
        #expect(oldGeneration != newGeneration)
    }

    @Test @MainActor
    func panicClearsRetainedRetryPendingResolutionAndExpiry() async throws {
        let context = MockChatMediaTransferContext()
        let peerID = PeerID(str: "1122334455667788")
        context.selectedPrivateChatPeer = peerID
        context.supportsAuthenticatedPrivateMediaReceipts = true
        context.resolvesPrivateMediaPolicyImmediately = false
        let fileName = "voice_3333444455556666.m4a"
        let preparer = StaticVoiceNotePreparer(fileName: fileName)
        let coordinator = ChatMediaTransferCoordinator(
            context: context,
            prepareVoiceNotePacket: { url in
                try preparer.prepare(url)
            },
            reconnectRetryLimits: PrivateMediaReconnectRetryLimits(
                maxRetainedPackets: 1,
                maxRetainedBytes: 1_024,
                maxRetriesPerMessage: 1,
                retentionSeconds: 0.1,
                maxRetriesPerReconnect: 1
            )
        )
        let url = try makeCoordinatorVoiceURL(fileName: fileName)
        defer {
            try? FileManager.default.removeItem(
                at: url.deletingLastPathComponent()
            )
        }

        coordinator.sendVoiceNote(at: url)
        #expect(await TestHelpers.waitUntil(
            { context.privateFileSends.count == 1 },
            timeout: TestConstants.longTimeout
        ))
        let initial = try #require(context.privateFileSends.first)
        coordinator.handleTransferEvent(.completed(
            id: initial.transferId,
            totalFragments: 1
        ))
        #expect(coordinator.retainedReconnectRetryCount == 1)

        coordinator.peerDidReconnect(peerID)
        #expect(context.pendingPrivateMediaPolicyResolutionCount == 1)
        let failedBeforePanic = context.deliveryStatusUpdates.filter {
            if case .failed = $0.status { return true }
            return false
        }.count

        coordinator.resetForPanic()
        context.resolveNextPrivateMediaPolicy(.encrypted)
        try await Task.sleep(nanoseconds: 250_000_000)
        coordinator._test_expireReconnectRetries()

        #expect(coordinator.retainedReconnectRetryCount == 0)
        #expect(coordinator.retainedReconnectRetryBytes == 0)
        #expect(coordinator.transferIdToMessageIDs.isEmpty)
        #expect(coordinator.messageIDToTransferId.isEmpty)
        #expect(context.privateFileSends.count == 1)
        #expect(context.privateFileReceiptRetryTransferIDs.isEmpty)
        #expect(context.deliveryStatusUpdates.filter {
            if case .failed = $0.status { return true }
            return false
        }.count == failedBeforePanic)
    }

    @Test @MainActor
    func retryCountAndRetentionTimeEndInVisibleFailure() async throws {
        let context = MockChatMediaTransferContext()
        let peerID = PeerID(str: "1122334455667788")
        context.selectedPrivateChatPeer = peerID
        context.supportsAuthenticatedPrivateMediaReceipts = true
        let clock = MutableMediaRetryClock(
            Date(timeIntervalSince1970: 4_000)
        )
        let limits = PrivateMediaReconnectRetryLimits(
            maxRetainedPackets: 2,
            maxRetainedBytes: 1_024,
            maxRetriesPerMessage: 1,
            retentionSeconds: 10,
            maxRetriesPerReconnect: 1
        )
        let fileName = "voice_4444555566667777.m4a"
        let preparer = StaticVoiceNotePreparer(fileName: fileName)
        let transferIDs = DeterministicMediaTransferIDFactory()
        let coordinator = ChatMediaTransferCoordinator(
            context: context,
            prepareVoiceNotePacket: { url in
                try preparer.prepare(url)
            },
            reconnectRetryLimits: limits,
            now: clock.now,
            transferIDFactory: transferIDs.make
        )
        let url = try makeCoordinatorVoiceURL(fileName: fileName)
        defer {
            try? FileManager.default.removeItem(
                at: url.deletingLastPathComponent()
            )
        }

        coordinator.sendVoiceNote(at: url)
        #expect(await TestHelpers.waitUntil(
            { context.privateFileSends.count == 1 },
            timeout: TestConstants.longTimeout
        ))
        let initial = try #require(context.privateFileSends.first)
        coordinator.handleTransferEvent(.completed(
            id: initial.transferId,
            totalFragments: 1
        ))
        coordinator.peerDidReconnect(peerID)
        let retryID = try #require(
            context.privateFileReceiptRetryTransferIDs.first
        )
        coordinator.handleTransferEvent(.cancelled(
            id: retryID,
            sentFragments: 0,
            totalFragments: 1
        ))

        #expect(coordinator.retainedReconnectRetryCount == 0)
        #expect(context.removedMessages.isEmpty)
        #expect(context.deliveryStatusUpdates.contains {
            $0.messageID.hasPrefix("media-")
                && $0.status == .failed(reason: String(
                    localized: "content.delivery.reason.not_delivered",
                    defaultValue: "Not delivered",
                    comment: "Failure reason shown when a private media transfer could not finish"
                ))
        })

        // A separate retained row that locally completed but never received a
        // remote receipt expires to a distinct visible failure.
        let ttlFileName = "voice_5555666677778888.m4a"
        let ttlPreparer = StaticVoiceNotePreparer(
            fileName: ttlFileName
        )
        let ttlCoordinator = ChatMediaTransferCoordinator(
            context: context,
            prepareVoiceNotePacket: { url in
                try ttlPreparer.prepare(url)
            },
            reconnectRetryLimits: limits,
            now: clock.now,
            transferIDFactory: transferIDs.make
        )
        let ttlURL = try makeCoordinatorVoiceURL(
            fileName: ttlFileName
        )
        defer {
            try? FileManager.default.removeItem(
                at: ttlURL.deletingLastPathComponent()
            )
        }
        let sendsBeforeTTL = context.privateFileSends.count
        ttlCoordinator.sendVoiceNote(at: ttlURL)
        #expect(await TestHelpers.waitUntil(
            {
                context.privateFileSends.count
                    == sendsBeforeTTL + 1
            },
            timeout: TestConstants.longTimeout
        ))
        let ttlInitial = try #require(context.privateFileSends.last)
        ttlCoordinator.handleTransferEvent(.completed(
            id: ttlInitial.transferId,
            totalFragments: 1
        ))
        clock.advance(by: 10)
        ttlCoordinator._test_expireReconnectRetries()

        #expect(ttlCoordinator.retainedReconnectRetryCount == 0)
        #expect(context.deliveryStatusUpdates.contains {
            $0.status == .failed(
                reason: String(
                    localized:
                        "content.delivery.reason.private_media_delivery_unconfirmed",
                    defaultValue: "Delivery could not be confirmed"
                )
            )
        })
    }

    @Test @MainActor
    func retentionAndPerReconnectWorkAreBounded() async throws {
        let context = MockChatMediaTransferContext()
        let peerID = PeerID(str: "1122334455667788")
        context.selectedPrivateChatPeer = peerID
        context.supportsAuthenticatedPrivateMediaReceipts = true
        let limits = PrivateMediaReconnectRetryLimits(
            maxRetainedPackets: 2,
            maxRetainedBytes: 10,
            maxRetriesPerMessage: 2,
            retentionSeconds: 120,
            maxRetriesPerReconnect: 1
        )
        let transferIDs = DeterministicMediaTransferIDFactory()
        let coordinator = ChatMediaTransferCoordinator(
            context: context,
            prepareVoiceNotePacket: { url in
                let content = Data("voice".utf8)
                return BitchatFilePacket(
                    fileName: url.lastPathComponent,
                    fileSize: UInt64(content.count),
                    mimeType: "audio/mp4",
                    content: content
                )
            },
            reconnectRetryLimits: limits,
            transferIDFactory: transferIDs.make
        )
        let fileNames = [
            "voice_6666777788889999.m4a",
            "voice_777788889999aaaa.m4a",
            "voice_88889999aaaabbbb.m4a"
        ]
        var roots: [URL] = []
        defer {
            for root in roots {
                try? FileManager.default.removeItem(at: root)
            }
        }

        for fileName in fileNames {
            let url = try makeCoordinatorVoiceURL(
                fileName: fileName,
                bytes: Data("voice".utf8)
            )
            roots.append(url.deletingLastPathComponent())
            // The production preparer preserves this stable filename.
            coordinator.sendVoiceNote(at: url)
        }
        #expect(await TestHelpers.waitUntil(
            { context.privateFileSends.count == 3 },
            timeout: TestConstants.longTimeout
        ))
        #expect(coordinator.retainedReconnectRetryCount == 2)
        #expect(coordinator.retainedReconnectRetryBytes <= 10)

        for send in context.privateFileSends {
            coordinator.handleTransferEvent(.completed(
                id: send.transferId,
                totalFragments: 1
            ))
        }
        coordinator.peerDidReconnect(peerID)
        #expect(context.privateFileReceiptRetryTransferIDs.count == 1)
    }

    @Test @MainActor
    func userCancellationReleasesRetainedBytesAndIgnoresLateEvent() async throws {
        let context = MockChatMediaTransferContext()
        let peerID = PeerID(str: "1122334455667788")
        context.selectedPrivateChatPeer = peerID
        context.supportsAuthenticatedPrivateMediaReceipts = true
        let fileName = "voice_9999aaaabbbbcccc.m4a"
        let preparer = StaticVoiceNotePreparer(fileName: fileName)
        let coordinator = ChatMediaTransferCoordinator(
            context: context,
            prepareVoiceNotePacket: { url in
                try preparer.prepare(url)
            }
        )
        let url = try makeCoordinatorVoiceURL(fileName: fileName)
        defer {
            try? FileManager.default.removeItem(
                at: url.deletingLastPathComponent()
            )
        }

        coordinator.sendVoiceNote(at: url)
        #expect(await TestHelpers.waitUntil(
            { context.privateFileSends.count == 1 },
            timeout: TestConstants.longTimeout
        ))
        let messageID = try #require(
            context.privateChats[peerID]?.first?.id
        )
        let transferID = try #require(
            context.privateFileSends.first?.transferId
        )

        coordinator.cancelMediaSend(messageID: messageID)
        coordinator.handleTransferEvent(.cancelled(
            id: transferID,
            sentFragments: 0,
            totalFragments: 1
        ))

        #expect(coordinator.retainedReconnectRetryCount == 0)
        #expect(coordinator.retainedReconnectRetryBytes == 0)
        #expect(context.cancelledTransfers == [transferID])
        #expect(context.removedMessages.map(\.messageID) == [
            messageID
        ])
        #expect(!context.deliveryStatusUpdates.contains {
            if case .failed = $0.status { return true }
            return false
        })
    }
}

private func makeCoordinatorVoiceURL(
    fileName: String,
    bytes: Data = Data("voice".utf8)
) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "media-retry-\(UUID().uuidString)",
            isDirectory: true
        )
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let url = directory.appendingPathComponent(fileName)
    try bytes.write(to: url)
    return url
}

private final class PausedImagePreparer: @unchecked Sendable {
    private let condition = NSCondition()
    private let outputURL: URL
    private var started = false
    private var released = false
    private var finished = false

    init(outputURL: URL) {
        self.outputURL = outputURL
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

    func prepare(_ _: URL) throws -> ChatPreparedImage {
        condition.lock()
        started = true
        condition.broadcast()
        while !released {
            condition.wait()
        }
        condition.unlock()

        let data = Data("prepared image".utf8)
        try data.write(to: outputURL, options: .atomic)
        let packet = BitchatFilePacket(
            fileName: outputURL.lastPathComponent,
            fileSize: UInt64(data.count),
            mimeType: "image/jpeg",
            content: data
        )

        condition.lock()
        finished = true
        condition.broadcast()
        condition.unlock()
        return ChatPreparedImage(outputURL: outputURL, packet: packet)
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private func makeCoordinatorTestImageURL() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("coordinator-image-\(UUID().uuidString).png")
    #if os(iOS)
    let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16))
        .image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
    guard let data = image.pngData() else {
        throw CoordinatorImageTestError.encodingFailed
    }
    #else
    let image = NSImage(size: NSSize(width: 16, height: 16))
    image.lockFocus()
    NSColor.systemBlue.setFill()
    NSRect(x: 0, y: 0, width: 16, height: 16).fill()
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CoordinatorImageTestError.encodingFailed
    }
    #endif
    try data.write(to: url, options: .atomic)
    return url
}

private enum CoordinatorImageTestError: Error {
    case encodingFailed
}
