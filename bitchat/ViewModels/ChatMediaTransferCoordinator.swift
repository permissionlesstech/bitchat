import BitFoundation
import BitLogger
import Foundation

#if os(iOS)
import UIKit
#endif

struct PrivateFileFallbackConsentRequest: Identifiable {
    let id: UUID
    let peerID: PeerID
    let peerNickname: String
}

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
    func peerCapabilities(for peerID: PeerID) -> PeerCapabilities
    func requestUnencryptedPrivateFileFallback(
        to peerID: PeerID,
        peerNickname: String,
        send: @escaping @MainActor () -> Void,
        cancel: @escaping @MainActor () -> Void
    )
    func sendFilePrivate(_ packet: BitchatFilePacket, to peerID: PeerID, transferId: String)
    func sendOriginalImagePrivate(_ packet: BitchatFilePacket, to peerID: PeerID, transferId: String)
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

    func sendOriginalImagePrivate(_ packet: BitchatFilePacket, to peerID: PeerID, transferId: String) {
        meshService.sendOriginalImagePrivate(packet, to: peerID, transferId: transferId)
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
    private let incomingFileStore: BLEIncomingFileStore

    private(set) var transferIdToMessageIDs: [String: [String]] = [:]
    private(set) var messageIDToTransferId: [String: String] = [:]
    private var receivedPrivateFileTransfers: Set<String> = []

    init(context: any ChatMediaTransferContext, incomingFileStore: BLEIncomingFileStore = BLEIncomingFileStore()) {
        self.context = context
        self.incomingFileStore = incomingFileStore
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
                let targetPeer = await MainActor.run { [weak self] in
                    self?.context.selectedPrivateChatPeer
                }
                let processedURL = try targetPeer == nil
                    ? ImageUtils.processImage(image)
                    : ImageUtils.writeCameraOriginalCandidate(image)
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

    func processThenSendImage(from url: URL?, cleanup: (() -> Void)? = nil) {
        guard let url else { return }
        sendImage(from: url, cleanup: cleanup)
    }

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
            cleanup?()
            context.addSystemMessage("Failed to prepare image for sending.")
            return
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            var didCleanupSource = false
            func cleanupSource() {
                guard !didCleanupSource else { return }
                didCleanupSource = true
                cleanup?()
            }
            defer { cleanupSource() }

            do {
                let prepared = try targetPeer == nil
                    ? ChatMediaPreparation.prepareImagePacket(from: sourceURL)
                    : ChatMediaPreparation.prepareOriginalImagePacket(from: sourceURL)
                cleanupSource()

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
                        self.sendPreparedPrivateImage(prepared, to: peerID, transferId: transferId, messageID: messageID)
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

    func clearAllTransferStateForPanic() {
        transferIdToMessageIDs.removeAll()
        messageIDToTransferId.removeAll()
        receivedPrivateFileTransfers.removeAll()
        ImageUtils.clearPhotoLibraryStagingDirectory()
    }

    func handlePrivateFileTransferPayload(from peerID: PeerID, payload: Data, timestamp: Date) {
        guard let privatePacket = PrivateFileTransferPacket.decode(payload) else {
            SecureLogger.warning("🚫 Dropping malformed private file-transfer payload", category: .security)
            return
        }

        let transferKey = "\(peerID.id)-\(privatePacket.transferID)"
        guard !receivedPrivateFileTransfers.contains(transferKey) else {
            SecureLogger.debug("📷 Dropping duplicate private file transfer \(privatePacket.transferID.prefix(8))…", category: .session)
            return
        }

        let decodedFilePacket = privatePacket.filePacket
        guard decodedFilePacket.content.sha256Hash() == privatePacket.fileSHA256 else {
            SecureLogger.warning("🚫 Dropping private file transfer with invalid digest or size", category: .security)
            return
        }
        #if DEBUG
        SecureLogger.debug("📷 Private original image received bytes=\(decodedFilePacket.content.count) sha256=\(decodedFilePacket.content.sha256Hex())", category: .session)
        #endif

        guard let encoded = decodedFilePacket.encode() else { return }
        let filePacket: BitchatFilePacket
        let mime: MimeType
        switch BLEIncomingFileValidator.validate(payload: encoded) {
        case .success(let acceptance):
            filePacket = acceptance.filePacket
            mime = acceptance.mime
        case .failure(let error):
            SecureLogger.warning("🚫 Dropping invalid private file transfer: \(error)", category: .security)
            return
        }

        incomingFileStore.enforceQuota(reservingBytes: filePacket.content.count)
        guard let destination = incomingFileStore.save(
            data: filePacket.content,
            preferredName: filePacket.fileName,
            subdirectory: "\(mime.category.mediaDir)/incoming",
            fallbackExtension: mime.defaultExtension,
            defaultPrefix: mime.category.rawValue
        ) else {
            return
        }
        receivedPrivateFileTransfers.insert(transferKey)

        let senderName = context.nicknameForPeer(peerID)
        let message = BitchatMessage(
            sender: senderName,
            content: "\(mime.category.messagePrefix)\(destination.lastPathComponent)",
            timestamp: timestamp,
            isRelay: false,
            originalSender: nil,
            isPrivate: true,
            recipientNickname: context.nickname,
            senderPeerID: peerID,
            deliveryStatus: .delivered(to: context.nickname, at: timestamp)
        )
        context.appendPrivateMessage(message, to: peerID)
        context.notifyUIChanged()
    }
}

private extension ChatMediaTransferCoordinator {
    func sendPreparedPrivateImage(
        _ prepared: ChatPreparedImage,
        to peerID: PeerID,
        transferId: String,
        messageID: String
    ) {
        let capabilities = context.peerCapabilities(for: peerID)
        guard capabilities.supportsPrivateFileNoiseEnvelope else {
            let peerNickname = context.nicknameForPeer(peerID)
            context.requestUnencryptedPrivateFileFallback(
                to: peerID,
                peerNickname: peerNickname,
                send: { [weak self] in
                    guard let self else { return }
                    self.context.sendFilePrivate(prepared.packet, to: peerID, transferId: transferId)
                },
                cancel: { [weak self] in
                    guard let self else { return }
                    self.handleMediaSendFailure(
                        messageID: messageID,
                        reason: String(localized: "content.delivery.reason.private_file_unsupported", defaultValue: "Peer does not support encrypted original image transfer.", comment: "Failure reason shown when a private image cannot be sent with encrypted original-file support")
                    )
                    try? FileManager.default.removeItem(at: prepared.outputURL)
                }
            )
            return
        }

        context.sendOriginalImagePrivate(prepared.packet, to: peerID, transferId: transferId)
    }

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

private extension PeerCapabilities {
    var supportsPrivateFileNoiseEnvelope: Bool {
        contains(.privateFileNoiseEnvelope) && contains(.largeNoiseFileCiphertext)
    }
}
