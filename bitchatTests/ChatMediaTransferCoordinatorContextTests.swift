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
    private(set) var originalPrivateImageSends: [(peerID: PeerID, transferId: String)] = []
    private(set) var broadcastFileSends: [String] = []
    private(set) var cancelledTransfers: [String] = []
    var sourceURLCheckedDuringOriginalPrivateImageSend: URL?
    private(set) var sourceExistedDuringOriginalPrivateImageSend: Bool?

    func sendFilePrivate(_ packet: BitchatFilePacket, to peerID: PeerID, transferId: String) {
        privateFileSends.append((peerID, transferId))
    }

    func sendOriginalImagePrivate(_ packet: BitchatFilePacket, to peerID: PeerID, transferId: String) {
        if let sourceURLCheckedDuringOriginalPrivateImageSend {
            sourceExistedDuringOriginalPrivateImageSend = FileManager.default.fileExists(atPath: sourceURLCheckedDuringOriginalPrivateImageSend.path)
        }
        originalPrivateImageSends.append((peerID, transferId))
    }

    func sendFileBroadcast(_ packet: BitchatFilePacket, transferId: String) {
        broadcastFileSends.append(transferId)
    }

    func cancelTransfer(_ transferId: String) {
        cancelledTransfers.append(transferId)
    }
}

private func makePNGFileURL(name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
    let data: Data
    #if os(iOS)
    let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
        UIColor.systemTeal.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    }
    guard let png = image.pngData() else { throw PrivateImageFixtureError.encodingFailed }
    data = png
    #else
    let image = NSImage(size: NSSize(width: 64, height: 64))
    image.lockFocus()
    NSColor.systemTeal.setFill()
    NSRect(x: 0, y: 0, width: 64, height: 64).fill()
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw PrivateImageFixtureError.encodingFailed
    }
    data = png
    #endif
    try data.write(to: url, options: .atomic)
    return url
}

private func makeChunkedPNGBytes(size: Int = 150 * 1024) -> Data {
    var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    data.reserveCapacity(size)
    for index in data.count..<size {
        data.append(UInt8(index % 251))
    }
    return data
}

private enum PrivateImageFixtureError: Error {
    case encodingFailed
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
    func handlePrivateFileTransferPayload_reassemblesAndStoresByteIdenticalImage() throws {
        let context = MockChatMediaTransferContext()
        let baseDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("private-image-incoming-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let coordinator = ChatMediaTransferCoordinator(
            context: context,
            incomingFileStore: BLEIncomingFileStore(baseDirectory: baseDirectory)
        )
        let peerID = PeerID(str: "1122334455667788")
        context.nicknamesByPeerID[peerID] = "alice"

        let sourceURL = try makePNGFileURL(name: "original-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let sourceData = try Data(contentsOf: sourceURL)
        let filePacket = BitchatFilePacket(
            fileName: sourceURL.lastPathComponent,
            fileSize: UInt64(sourceData.count),
            mimeType: "image/png",
            content: sourceData
        )
        let chunks = try #require(BLENoisePayloadFactory.privateFileTransferChunks(filePacket, transferId: "rx-image"))

        for typedChunk in chunks.reversed() {
            coordinator.handlePrivateFileTransferPayload(
                from: peerID,
                payload: Data(typedChunk.dropFirst()),
                timestamp: Date(timeIntervalSince1970: 123)
            )
        }

        let message = try #require(context.privateChats[peerID]?.last)
        #expect(message.content.hasPrefix("[image] "))
        let fileName = String(message.content.dropFirst("[image] ".count))
        let storedURL = baseDirectory
            .appendingPathComponent("files/images/incoming", isDirectory: true)
            .appendingPathComponent(fileName)
        #expect(try Data(contentsOf: storedURL) == sourceData)
    }

    @Test @MainActor
    func handlePrivateFileTransferPayload_duplicateChunkIsIdempotent() throws {
        let context = MockChatMediaTransferContext()
        let baseDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("private-image-duplicate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }
        let coordinator = ChatMediaTransferCoordinator(
            context: context,
            incomingFileStore: BLEIncomingFileStore(baseDirectory: baseDirectory)
        )
        let peerID = PeerID(str: "2233445566778899")

        let sourceData = makeChunkedPNGBytes()
        let filePacket = BitchatFilePacket(
            fileName: "duplicate.png",
            fileSize: UInt64(sourceData.count),
            mimeType: "image/png",
            content: sourceData
        )
        let chunks = try #require(BLENoisePayloadFactory.privateFileTransferChunks(filePacket, transferId: "rx-duplicate"))
        #expect(chunks.count > 1)
        let duplicate = try #require(chunks.first)

        coordinator.handlePrivateFileTransferPayload(from: peerID, payload: Data(duplicate.dropFirst()), timestamp: Date())
        coordinator.handlePrivateFileTransferPayload(from: peerID, payload: Data(duplicate.dropFirst()), timestamp: Date())
        for typedChunk in chunks.dropFirst() {
            coordinator.handlePrivateFileTransferPayload(from: peerID, payload: Data(typedChunk.dropFirst()), timestamp: Date())
        }

        let messages = context.privateChats[peerID] ?? []
        #expect(messages.count == 1)
        let fileName = String(try #require(messages.first).content.dropFirst("[image] ".count))
        let storedURL = baseDirectory
            .appendingPathComponent("files/images/incoming", isDirectory: true)
            .appendingPathComponent(fileName)
        #expect(try Data(contentsOf: storedURL) == sourceData)
    }

    @Test @MainActor
    func sendImage_privateSourceRunsCleanupBeforePrivateSendIsIssued() async throws {
        let context = MockChatMediaTransferContext()
        let coordinator = ChatMediaTransferCoordinator(context: context)
        let peerID = PeerID(str: "3344556677889900")
        context.selectedPrivateChatPeer = peerID

        let sourceURL = try makePNGFileURL(name: "private-source-cleanup-\(UUID().uuidString).png")
        context.sourceURLCheckedDuringOriginalPrivateImageSend = sourceURL
        var cleanupCount = 0

        coordinator.sendImage(from: sourceURL) {
            cleanupCount += 1
            ImageUtils.removePhotoLibraryStagedImage(at: sourceURL)
        }

        let didSend = await TestHelpers.waitUntil({
            context.originalPrivateImageSends.count == 1
        }, timeout: TestConstants.longTimeout)

        #expect(didSend)
        #expect(cleanupCount == 1)
        #expect(context.sourceExistedDuringOriginalPrivateImageSend == false)
        #expect(!FileManager.default.fileExists(atPath: sourceURL.path))
    }

    @Test @MainActor
    func clearAllTransferStateForPanicRemovesPhotoLibraryStagingDirectory() throws {
        let context = MockChatMediaTransferContext()
        let coordinator = ChatMediaTransferCoordinator(context: context)
        let sourceURL = try makePNGFileURL(name: "panic-staging-source-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let stagedURL = try ImageUtils.stagePhotoLibraryImageFile(at: sourceURL, suggestedName: "panic-staged.png")
        let stagingDirectory = stagedURL.deletingLastPathComponent()
        let leftoverURL = stagingDirectory.appendingPathComponent("leftover-from-crash.bin")
        try Data([0xAA, 0xBB]).write(to: leftoverURL, options: .atomic)

        #expect(FileManager.default.fileExists(atPath: stagedURL.path))
        #expect(FileManager.default.fileExists(atPath: leftoverURL.path))

        coordinator.clearAllTransferStateForPanic()

        #expect(!FileManager.default.fileExists(atPath: stagedURL.path))
        #expect(!FileManager.default.fileExists(atPath: leftoverURL.path))
        #expect(!FileManager.default.fileExists(atPath: stagingDirectory.path))
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
