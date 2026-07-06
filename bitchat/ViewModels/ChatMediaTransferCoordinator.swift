import BitFoundation
import BitLogger
import Foundation

#if os(iOS)
import UIKit
#endif

/// The narrow surface `ChatMediaTransferCoordinator` needs from its owner.
///
/// Follows the `ChatDeliveryContext` exemplar: the coordinator depends on the
/// minimal context it actually uses instead of holding an `unowned` back-ref
/// to the whole `ChatViewModel`. This keeps the coordinator independently
/// testable (see `ChatMediaTransferCoordinatorContextTests`) and makes its
/// true dependencies explicit.
@MainActor
protocol ChatMediaTransferContext: AnyObject {
    // MARK: Composition state
    var canSendMediaInCurrentContext: Bool { get }
    var selectedPrivateChatPeer: PeerID? { get }
    var nickname: String { get }
    var myPeerID: PeerID { get }
    var activeChannel: ChannelID { get }
    func nicknameForPeer(_ peerID: PeerID) -> String
    func currentPublicSender() -> (name: String, peerID: PeerID)

    // MARK: Message state
    /// Appends a private message via the single-writer store intent.
    @discardableResult
    func appendPrivateMessage(_ message: BitchatMessage, to peerID: PeerID) -> Bool
    /// Appends a public message via the single-writer store intent
    /// (immediate: outgoing media placeholders must render without batching).
    @discardableResult
    func appendPublicMessage(_ message: BitchatMessage, to conversationID: ConversationID) -> Bool
    func removeMessage(withID messageID: String, cleanupFile: Bool)
    func addSystemMessage(_ content: String)
    /// Signals that message state changed so observers refresh (e.g. `objectWillChange.send()`).
    func notifyUIChanged()

    // MARK: Delivery status & dedup
    func updateMessageDeliveryStatus(_ messageID: String, status: DeliveryStatus)
    func normalizedContentKey(_ content: String) -> String
    func recordContentKey(_ key: String, timestamp: Date)

    // MARK: Mesh file transfer
    func sendFilePrivate(_ packet: BitchatFilePacket, to peerID: PeerID, transferId: String)
    func sendFileBroadcast(_ packet: BitchatFilePacket, transferId: String)
    func cancelTransfer(_ transferId: String)
}

extension ChatViewModel: ChatMediaTransferContext {
    // `canSendMediaInCurrentContext`, `selectedPrivateChatPeer`, `nickname`,
    // `myPeerID`, `activeChannel`, `nicknameForPeer(_:)`,
    // `currentPublicSender()`,
    // `appendPublicMessage(_:to:)`, `removeMessage(withID:cleanupFile:)`,
    // `addSystemMessage(_:)`, `notifyUIChanged()`,
    // `updateMessageDeliveryStatus(_:status:)`, `normalizedContentKey(_:)`,
    // and `recordContentKey(_:timestamp:)` are shared requirements with the
    // other contexts or satisfied by existing `ChatViewModel` members. The
    // members below flatten mesh service accesses.

    func sendFilePrivate(_ packet: BitchatFilePacket, to peerID: PeerID, transferId: String) {
        meshService.sendFilePrivate(packet, to: peerID, transferId: transferId)
    }

    func sendFileBroadcast(_ packet: BitchatFilePacket, transferId: String) {
        meshService.sendFileBroadcast(packet, transferId: transferId)
    }

    func cancelTransfer(_ transferId: String) {
        meshService.cancelTransfer(transferId)
    }
}

@MainActor
final class ChatMediaTransferCoordinator {
    private unowned let context: any ChatMediaTransferContext

    private(set) var transferIdToMessageIDs: [String: [String]] = [:]
    private(set) var messageIDToTransferId: [String: String] = [:]

    init(context: any ChatMediaTransferContext) {
        self.context = context
    }

    func sendVoiceNote(at url: URL) {
        guard context.canSendMediaInCurrentContext else {
            SecureLogger.info("Voice note blocked outside mesh/private context", category: .session)
            try? FileManager.default.removeItem(at: url)
            context.addSystemMessage("Voice notes are only available in mesh chats.")
            return
        }

        let targetPeer = context.selectedPrivateChatPeer
        let message = enqueueMediaMessage(
            content: "\(MimeType.Category.audio.messagePrefix)\(url.lastPathComponent)",
            targetPeer: targetPeer
        )
        let messageID = message.id
        let transferId = makeTransferID(messageID: messageID)

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let packet = try ChatMediaPreparation.prepareVoiceNotePacket(at: url)

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.registerTransfer(transferId: transferId, messageID: messageID)
                    if let peerID = targetPeer {
                        self.context.sendFilePrivate(packet, to: peerID, transferId: transferId)
                    } else {
                        self.context.sendFileBroadcast(packet, transferId: transferId)
                    }
                }
            } catch ChatMediaPreparationError.voiceNoteTooLarge(let size) {
                SecureLogger.warning("Voice note exceeds size limit (\(size) bytes)", category: .session)
                try? FileManager.default.removeItem(at: url)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.handleMediaSendFailure(messageID: messageID, reason: String(localized: "content.delivery.reason.voice_too_large", comment: "Failure reason shown when a voice note exceeds the size limit"))
                }
            } catch {
                SecureLogger.error("Voice note send failed: \(error)", category: .session)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.handleMediaSendFailure(messageID: messageID, reason: String(localized: "content.delivery.reason.voice_send_failed", comment: "Failure reason shown when a voice note could not be sent"))
                }
            }
        }
    }

    #if os(iOS)
    func processThenSendImage(_ image: UIImage?) {
        guard let image else { return }
        Task.detached { [weak self] in
            do {
                let processedURL = try ImageUtils.processImage(image)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.sendImage(from: processedURL)
                }
            } catch {
                SecureLogger.error("Image processing failed: \(error)", category: .session)
            }
        }
    }
    #elseif os(macOS)
    func processThenSendImage(from url: URL?) {
        guard let url else { return }
        Task.detached { [weak self] in
            do {
                let processedURL = try ImageUtils.processImage(at: url)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.sendImage(from: processedURL)
                }
            } catch {
                SecureLogger.error("Image processing failed: \(error)", category: .session)
            }
        }
    }
    #endif

    func sendImage(from sourceURL: URL, cleanup: (() -> Void)? = nil) {
        guard context.canSendMediaInCurrentContext else {
            SecureLogger.info("Image send blocked outside mesh/private context", category: .session)
            cleanup?()
            context.addSystemMessage("Images are only available in mesh chats.")
            return
        }

        let targetPeer = context.selectedPrivateChatPeer

        do {
            try ImageUtils.validateImageSource(at: sourceURL)
        } catch {
            SecureLogger.error("Image send preparation failed: \(error)", category: .session)
            context.addSystemMessage("Failed to prepare image for sending.")
            return
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let prepared = try ChatMediaPreparation.prepareImagePacket(from: sourceURL)

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    let message = self.enqueueMediaMessage(
                        content: "\(MimeType.Category.image.messagePrefix)\(prepared.outputURL.lastPathComponent)",
                        targetPeer: targetPeer
                    )
                    let messageID = message.id
                    let transferId = self.makeTransferID(messageID: messageID)
                    self.registerTransfer(transferId: transferId, messageID: messageID)
                    if let peerID = targetPeer {
                        self.context.sendFilePrivate(prepared.packet, to: peerID, transferId: transferId)
                    } else {
                        self.context.sendFileBroadcast(prepared.packet, transferId: transferId)
                    }
                }
            } catch ChatMediaPreparationError.imageTooLarge(let size) {
                SecureLogger.warning("Processed image exceeds size limit (\(size) bytes)", category: .session)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.context.addSystemMessage("Image is too large to send.")
                }
            } catch {
                SecureLogger.error("Image send preparation failed: \(error)", category: .session)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.context.addSystemMessage("Failed to prepare image for sending.")
                }
            }
        }
    }

    func enqueueMediaMessage(content: String, targetPeer: PeerID?) -> BitchatMessage {
        let timestamp = Date()
        let message: BitchatMessage

        if let peerID = targetPeer {
            message = BitchatMessage(
                sender: context.nickname,
                content: content,
                timestamp: timestamp,
                isRelay: false,
                originalSender: nil,
                isPrivate: true,
                recipientNickname: context.nicknameForPeer(peerID),
                senderPeerID: context.myPeerID,
                deliveryStatus: .sending
            )
            context.appendPrivateMessage(message, to: peerID)
        } else {
            let (displayName, senderPeerID) = context.currentPublicSender()
            message = BitchatMessage(
                sender: displayName,
                content: content,
                timestamp: timestamp,
                isRelay: false,
                originalSender: nil,
                isPrivate: false,
                recipientNickname: nil,
                senderPeerID: senderPeerID,
                deliveryStatus: .sending
            )
            context.appendPublicMessage(message, to: ConversationID(channelID: context.activeChannel))
        }

        let key = context.normalizedContentKey(message.content)
        context.recordContentKey(key, timestamp: timestamp)
        context.notifyUIChanged()
        return message
    }

    func registerTransfer(transferId: String, messageID: String) {
        transferIdToMessageIDs[transferId, default: []].append(messageID)
        messageIDToTransferId[messageID] = transferId
    }

    func makeTransferID(messageID: String) -> String {
        "\(messageID)-\(UUID().uuidString)"
    }

    func clearTransferMapping(for messageID: String) {
        guard let transferId = messageIDToTransferId.removeValue(forKey: messageID) else { return }
        guard var queue = transferIdToMessageIDs[transferId] else { return }

        if !queue.isEmpty {
            if queue.first == messageID {
                queue.removeFirst()
            } else if let index = queue.firstIndex(of: messageID) {
                queue.remove(at: index)
            }
        }

        transferIdToMessageIDs[transferId] = queue.isEmpty ? nil : queue
    }

    func handleMediaSendFailure(messageID: String, reason: String) {
        context.updateMessageDeliveryStatus(messageID, status: .failed(reason: reason))
        clearTransferMapping(for: messageID)
    }

    func handleTransferEvent(_ event: TransferProgressManager.Event) {
        switch event {
        case .started(let id, let total):
            guard let messageID = transferIdToMessageIDs[id]?.first else { return }
            context.updateMessageDeliveryStatus(messageID, status: .partiallyDelivered(reached: 0, total: total))
        case .updated(let id, let sent, let total):
            guard let messageID = transferIdToMessageIDs[id]?.first else { return }
            context.updateMessageDeliveryStatus(messageID, status: .partiallyDelivered(reached: sent, total: total))
        case .completed(let id, _):
            guard let messageID = transferIdToMessageIDs[id]?.first else { return }
            context.updateMessageDeliveryStatus(messageID, status: .sent)
            clearTransferMapping(for: messageID)
        case .cancelled(let id, _, _):
            guard let messageID = transferIdToMessageIDs[id]?.first else { return }
            clearTransferMapping(for: messageID)
            context.removeMessage(withID: messageID, cleanupFile: true)
        }
    }

    func cleanupLocalFile(forMessage message: BitchatMessage) {
        let categories: [MimeType.Category] = [.audio, .image, .file]
        guard let category = categories.first(where: { message.content.hasPrefix($0.messagePrefix) }),
              let rawFilename = String(message.content.dropFirst(category.messagePrefix.count)).trimmedOrNilIfEmpty,
              let base = try? applicationFilesDirectory(),
              let safeFilename = (rawFilename as NSString).lastPathComponent.nilIfEmpty,
              safeFilename != ".",
              safeFilename != ".." else {
            return
        }

        let subdirs = categories.flatMap { ["\($0.mediaDir)/outgoing", "\($0.mediaDir)/incoming"] }
        for subdir in subdirs {
            let target = base.appendingPathComponent(subdir, isDirectory: true).appendingPathComponent(safeFilename)
            guard target.path.hasPrefix(base.path) else { continue }

            do {
                try FileManager.default.removeItem(at: target)
            } catch CocoaError.fileNoSuchFile {
                continue
            } catch {
                SecureLogger.error("Failed to cleanup \(safeFilename): \(error)", category: .session)
            }
        }
    }

    func cancelMediaSend(messageID: String) {
        if let transferId = messageIDToTransferId[messageID],
           let active = transferIdToMessageIDs[transferId]?.first,
           active == messageID {
            context.cancelTransfer(transferId)
        }
        clearTransferMapping(for: messageID)
        context.removeMessage(withID: messageID, cleanupFile: true)
    }

    func deleteMediaMessage(messageID: String) {
        clearTransferMapping(for: messageID)
        context.removeMessage(withID: messageID, cleanupFile: true)
    }
}

private extension ChatMediaTransferCoordinator {
    func applicationFilesDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let filesDirectory = base.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(
            at: filesDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return filesDirectory
    }
}
