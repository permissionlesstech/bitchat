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
