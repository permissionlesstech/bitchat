import BitFoundation
import BitLogger
import Foundation

#if os(iOS)
import UIKit
#endif

@MainActor
final class ChatMediaTransferCoordinator {
    private enum MediaSendError: Error {
        case encodingFailed
    }

    private unowned let viewModel: ChatViewModel

    private(set) var transferIdToMessageIDs: [String: [String]] = [:]
    private(set) var messageIDToTransferId: [String: String] = [:]

    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
    }

    func sendVoiceNote(at url: URL) {
        guard viewModel.canSendMediaInCurrentContext else {
            SecureLogger.info("Voice note blocked outside mesh/private context", category: .session)
            try? FileManager.default.removeItem(at: url)
            viewModel.addSystemMessage("Voice notes are only available in mesh chats.")
            return
        }

        let targetPeer = viewModel.selectedPrivateChatPeer
        let message = enqueueMediaMessage(
            content: "\(MimeType.Category.audio.messagePrefix)\(url.lastPathComponent)",
            targetPeer: targetPeer
        )
        let messageID = message.id
        let transferId = makeTransferID(messageID: messageID)

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard let fileSize = attributes[.size] as? Int,
                      fileSize <= FileTransferLimits.maxVoiceNoteBytes else {
                    let size = (attributes[.size] as? Int) ?? 0
                    SecureLogger.warning("Voice note exceeds size limit (\(size) bytes)", category: .session)
                    try? FileManager.default.removeItem(at: url)
                    await MainActor.run {
                        self.handleMediaSendFailure(messageID: messageID, reason: "Voice note too large")
                    }
                    return
                }

                let data = try Data(contentsOf: url)
                let packet = BitchatFilePacket(
                    fileName: url.lastPathComponent,
                    fileSize: UInt64(data.count),
                    mimeType: "audio/mp4",
                    content: data
                )
                guard packet.encode() != nil else { throw MediaSendError.encodingFailed }

                await MainActor.run {
                    self.registerTransfer(transferId: transferId, messageID: messageID)
                    if let peerID = targetPeer {
                        self.viewModel.meshService.sendFilePrivate(packet, to: peerID, transferId: transferId)
                    } else {
                        self.viewModel.meshService.sendFileBroadcast(packet, transferId: transferId)
                    }
                }
            } catch {
                SecureLogger.error("Voice note send failed: \(error)", category: .session)
                await MainActor.run {
                    self.handleMediaSendFailure(messageID: messageID, reason: "Failed to send voice note")
                }
            }
        }
    }

    #if os(iOS)
    func processThenSendImage(_ image: UIImage?) {
        guard let image else { return }
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                let processedURL = try ImageUtils.processImage(image)
                await MainActor.run {
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
            guard let self else { return }
            do {
                let processedURL = try ImageUtils.processImage(at: url)
                await MainActor.run {
                    self.sendImage(from: processedURL)
                }
            } catch {
                SecureLogger.error("Image processing failed: \(error)", category: .session)
            }
        }
    }
    #endif

    func sendImage(from sourceURL: URL, cleanup: (() -> Void)? = nil) {
        guard viewModel.canSendMediaInCurrentContext else {
            SecureLogger.info("Image send blocked outside mesh/private context", category: .session)
            cleanup?()
            viewModel.addSystemMessage("Images are only available in mesh chats.")
            return
        }

        let targetPeer = viewModel.selectedPrivateChatPeer

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var processedURL: URL?
            do {
                let outputURL = try ImageUtils.processImage(at: sourceURL)
                processedURL = outputURL
                let data = try Data(contentsOf: outputURL)
                guard data.count <= FileTransferLimits.maxImageBytes else {
                    SecureLogger.warning("Processed image exceeds size limit (\(data.count) bytes)", category: .session)
                    await MainActor.run {
                        self.viewModel.addSystemMessage("Image is too large to send.")
                    }
                    try? FileManager.default.removeItem(at: outputURL)
                    return
                }

                let packet = BitchatFilePacket(
                    fileName: outputURL.lastPathComponent,
                    fileSize: UInt64(data.count),
                    mimeType: "image/jpeg",
                    content: data
                )
                guard packet.encode() != nil else { throw MediaSendError.encodingFailed }

                await MainActor.run {
                    let message = self.enqueueMediaMessage(
                        content: "\(MimeType.Category.image.messagePrefix)\(outputURL.lastPathComponent)",
                        targetPeer: targetPeer
                    )
                    let messageID = message.id
                    let transferId = self.makeTransferID(messageID: messageID)
                    self.registerTransfer(transferId: transferId, messageID: messageID)
                    if let peerID = targetPeer {
                        self.viewModel.meshService.sendFilePrivate(packet, to: peerID, transferId: transferId)
                    } else {
                        self.viewModel.meshService.sendFileBroadcast(packet, transferId: transferId)
                    }
                }
            } catch {
                SecureLogger.error("Image send preparation failed: \(error)", category: .session)
                await MainActor.run {
                    self.viewModel.addSystemMessage("Failed to prepare image for sending.")
                }
                if let processedURL {
                    try? FileManager.default.removeItem(at: processedURL)
                }
            }
        }
    }

    func enqueueMediaMessage(content: String, targetPeer: PeerID?) -> BitchatMessage {
        let timestamp = Date()
        let message: BitchatMessage

        if let peerID = targetPeer {
            message = BitchatMessage(
                sender: viewModel.nickname,
                content: content,
                timestamp: timestamp,
                isRelay: false,
                originalSender: nil,
                isPrivate: true,
                recipientNickname: viewModel.nicknameForPeer(peerID),
                senderPeerID: viewModel.meshService.myPeerID,
                deliveryStatus: .sending
            )
            var chats = viewModel.privateChats
            chats[peerID, default: []].append(message)
            viewModel.privateChats = chats
            viewModel.trimMessagesIfNeeded()
        } else {
            let (displayName, senderPeerID) = viewModel.currentPublicSender()
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
            viewModel.timelineStore.append(message, to: viewModel.activeChannel)
            viewModel.refreshVisibleMessages(from: viewModel.activeChannel)
            viewModel.trimMessagesIfNeeded()
        }

        let key = viewModel.deduplicationService.normalizedContentKey(message.content)
        viewModel.deduplicationService.recordContentKey(key, timestamp: timestamp)
        viewModel.objectWillChange.send()
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
        viewModel.updateMessageDeliveryStatus(messageID, status: .failed(reason: reason))
        clearTransferMapping(for: messageID)
    }

    func handleTransferEvent(_ event: TransferProgressManager.Event) {
        switch event {
        case .started(let id, let total):
            guard let messageID = transferIdToMessageIDs[id]?.first else { return }
            viewModel.updateMessageDeliveryStatus(messageID, status: .partiallyDelivered(reached: 0, total: total))
        case .updated(let id, let sent, let total):
            guard let messageID = transferIdToMessageIDs[id]?.first else { return }
            viewModel.updateMessageDeliveryStatus(messageID, status: .partiallyDelivered(reached: sent, total: total))
        case .completed(let id, _):
            guard let messageID = transferIdToMessageIDs[id]?.first else { return }
            viewModel.updateMessageDeliveryStatus(messageID, status: .sent)
            clearTransferMapping(for: messageID)
        case .cancelled(let id, _, _):
            guard let messageID = transferIdToMessageIDs[id]?.first else { return }
            clearTransferMapping(for: messageID)
            viewModel.removeMessage(withID: messageID, cleanupFile: true)
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
            viewModel.meshService.cancelTransfer(transferId)
        }
        clearTransferMapping(for: messageID)
        viewModel.removeMessage(withID: messageID, cleanupFile: true)
    }

    func deleteMediaMessage(messageID: String) {
        clearTransferMapping(for: messageID)
        viewModel.removeMessage(withID: messageID, cleanupFile: true)
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
