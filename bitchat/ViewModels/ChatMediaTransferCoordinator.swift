import BitFoundation
import BitLogger
import Foundation

#if os(iOS)
import UIKit
#endif

struct LegacyPrivateMediaConsentRequest: Identifiable, Equatable {
    let id: UUID
    let peerID: PeerID
    let peerName: String
    let transferId: String
    let messageID: String
}

struct PendingLegacyPrivateMediaConsent {
    let request: LegacyPrivateMediaConsentRequest
    let completion: @MainActor (Bool) -> Void
}

struct PrivateMediaReconnectRetryLimits: Equatable {
    var maxRetainedPackets = 8
    var maxRetainedBytes = 4 * 1024 * 1024
    var maxRetriesPerMessage = 2
    var retentionSeconds: TimeInterval = 120
    var maxRetriesPerReconnect = 2
}

private struct PrivateMediaReconnectRetryRecord {
    let messageID: String
    let peerID: PeerID
    let packet: BitchatFilePacket
    var receiptSessionGeneration: UUID
    var createdAt: Date
    var retryCount: Int
    var activeTransferID: String?
    var retryAfterCompletion: Bool
    var idleOutcome: PrivateMediaReconnectRetryIdleOutcome
    var deferredTerminalFailureReason: String?
    var expiryToken: UUID?

    var retainedBytes: Int {
        packet.content.count
    }
}

private enum PrivateMediaReconnectRetryIdleOutcome {
    case none
    case locallyCompleted
    case cancelled
    case rejected(reason: String)
}

private struct PrivateMediaReconnectRetryCandidate {
    let messageID: String
    /// The receipt-capable Noise generation that owned this record when the
    /// reconnect/authentication event captured it.
    let receiptSessionGeneration: UUID
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
    /// Removes a media bubble with direction-scoped cleanup instead of the
    /// broad compatibility cleanup path.
    func removeUntombstonedMediaMessage(withID messageID: String)
    func removeOutgoingMediaMessage(withID messageID: String)
    func addSystemMessage(_ content: String)
    /// Surfaces a refused explicit media deletion in the affected chat so a
    /// wedged delete never looks like success.
    func notifyMediaDeletionRefused(messageID: String)
    /// Signals that message state changed so observers refresh (e.g. `objectWillChange.send()`).
    func notifyUIChanged()

    // MARK: Delivery status & dedup
    func updateMessageDeliveryStatus(_ messageID: String, status: DeliveryStatus)
    func normalizedContentKey(_ content: String) -> String
    func recordContentKey(_ key: String, timestamp: Date)

    // MARK: Mesh file transfer
    func privateMediaSendPolicy(to peerID: PeerID) -> PrivateMediaSendPolicy
    func authenticatedPrivateMediaReceiptSessionGeneration(to peerID: PeerID) -> UUID?
    func resolvePrivateMediaSendPolicy(
        to peerID: PeerID,
        completion: @escaping @MainActor (PrivateMediaSendPolicy) -> Void
    )
    func requestLegacyPrivateMediaConsent(
        for peerID: PeerID,
        transferId: String,
        messageID: String,
        completion: @escaping @MainActor (Bool) -> Void
    )
    func cancelLegacyPrivateMediaConsent(transferId: String, messageID: String)
    func sendFilePrivate(
        _ packet: BitchatFilePacket,
        to peerID: PeerID,
        transferId: String,
        allowLegacyFallback: Bool
    )
    func sendFilePrivateReceiptRetry(
        _ packet: BitchatFilePacket,
        to peerID: PeerID,
        transferId: String
    )
    func sendFileBroadcast(_ packet: BitchatFilePacket, transferId: String)
    func cancelTransfer(_ transferId: String)
    /// Receiver-side stable-ID deletion commit. Implementations must invoke
    /// completion only after the entire batch is durably tombstoned.
    func persistDeletedPrivateMedia(
        messageIDs: [String],
        completion: @escaping @MainActor (Bool) -> Void
    )
    /// Whether any current private-chat copy of this stable ID came from a
    /// remote peer and therefore requires a receiver tombstone.
    func requiresPrivateMediaTombstone(messageID: String) -> Bool
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

    /// File transfer rides the mesh only. Without that capability the
    /// policy degrades to the safe floor (blocked), matching the old
    /// inert protocol defaults.
    private var fileTransport: MeshFileTransferring? { meshService as? MeshFileTransferring }

    func privateMediaSendPolicy(to peerID: PeerID) -> PrivateMediaSendPolicy {
        fileTransport?.privateMediaSendPolicy(to: peerID) ?? .blockedDowngrade
    }

    func authenticatedPrivateMediaReceiptSessionGeneration(
        to peerID: PeerID
    ) -> UUID? {
        fileTransport?.authenticatedPrivateMediaReceiptSessionGeneration(
            to: peerID
        )
    }

    func resolvePrivateMediaSendPolicy(
        to peerID: PeerID,
        completion: @escaping @MainActor (PrivateMediaSendPolicy) -> Void
    ) {
        guard let fileTransport else {
            Task { @MainActor in completion(.blockedDowngrade) }
            return
        }
        fileTransport.resolvePrivateMediaSendPolicy(to: peerID, completion: completion)
    }

    func requestLegacyPrivateMediaConsent(
        for peerID: PeerID,
        transferId: String,
        messageID: String,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        enqueueLegacyPrivateMediaConsent(
            for: peerID,
            transferId: transferId,
            messageID: messageID,
            completion: completion
        )
    }

    func cancelLegacyPrivateMediaConsent(transferId: String, messageID: String) {
        invalidateLegacyPrivateMediaConsent(
            transferId: transferId,
            messageID: messageID
        )
    }

    func sendFilePrivate(
        _ packet: BitchatFilePacket,
        to peerID: PeerID,
        transferId: String,
        allowLegacyFallback: Bool
    ) {
        fileTransport?.sendFilePrivate(
            packet,
            to: peerID,
            transferId: transferId,
            allowLegacyFallback: allowLegacyFallback
        )
    }

    func sendFilePrivateReceiptRetry(
        _ packet: BitchatFilePacket,
        to peerID: PeerID,
        transferId: String
    ) {
        fileTransport?.sendFilePrivateReceiptRetry(
            packet,
            to: peerID,
            transferId: transferId
        )
    }

    func sendFileBroadcast(_ packet: BitchatFilePacket, transferId: String) {
        fileTransport?.sendFileBroadcast(packet, transferId: transferId)
    }

    func cancelTransfer(_ transferId: String) {
        fileTransport?.cancelTransfer(transferId)
    }

    func removeUntombstonedMediaMessage(withID messageID: String) {
        let message = conversations.conversationsByID.values.lazy
            .flatMap(\.messages)
            .first { $0.id == messageID }
        if let message, !isIncomingPrivateMessage(message) {
            mediaTransferCoordinator.cleanupOutgoingLocalFile(
                forMessage: message
            )
        }
        removeMessage(withID: messageID, cleanupFile: false)
        if let message {
            cleanupLegacyIncomingMediaPayloads(for: [message])
        }
    }

    /// Explicitly deleted LEGACY (non-stable-ID) incoming media has no
    /// durable ID-to-file ownership, so the actual unlink is delegated to
    /// the transport's gated cleanup: a basename that is pending delivery or
    /// reserved by a receipt/deletion transaction stays on disk for bounded
    /// quota cleanup instead. Must run after the bubbles were removed; a
    /// surviving reference in any conversation keeps the payload.
    func cleanupLegacyIncomingMediaPayloads(for messages: [BitchatMessage]) {
        guard let cleanup =
                meshService as? any PrivateMediaDeletionPersisting else {
            return
        }
        let legacyPaths = Set(messages.compactMap { message -> String? in
            guard !PrivateMediaMessageIdentity.isStableID(message.id),
                  isIncomingPrivateMessage(message) else {
                return nil
            }
            return incomingMediaRelativePath(for: message)
        })
        guard !legacyPaths.isEmpty else { return }
        let survivingPaths = Set(
            conversations.conversationsByID.values.lazy
                .flatMap(\.messages)
                .compactMap { message -> String? in
                    guard self.isIncomingPrivateMessage(message) else {
                        return nil
                    }
                    return self.incomingMediaRelativePath(for: message)
                }
        )
        for relativePath in legacyPaths.subtracting(survivingPaths).sorted() {
            cleanup.removeLegacyPrivateMediaPayload(
                relativePath: relativePath
            )
        }
    }

    func removeOutgoingMediaMessage(withID messageID: String) {
        let message = conversations.conversationsByID.values.lazy
            .flatMap(\.messages)
            .first { $0.id == messageID }
        if let message {
            mediaTransferCoordinator.cleanupOutgoingLocalFile(
                forMessage: message
            )
        }
        removeMessage(withID: messageID, cleanupFile: false)
    }

    func persistDeletedPrivateMedia(
        messageIDs: [String],
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        guard !messageIDs.isEmpty else {
            completion(true)
            return
        }
        guard let persistence =
                meshService as? any PrivateMediaDeletionPersisting else {
            completion(false)
            return
        }
        let requestedIDs = Set(messageIDs)
        let incomingPathReferences = Array(
            conversations.conversationsByID.values
                .lazy
                .flatMap(\.messages)
                .compactMap { message -> (
                    messageID: String,
                    path: String
                )? in
                guard self.isIncomingPrivateMessage(message),
                      let path = self.incomingMediaRelativePath(
                          for: message
                      ) else {
                    return nil
                }
                return (message.id, path)
            }
        )
        let ownerIDsByPath = Dictionary(
            grouping: incomingPathReferences,
            by: { $0.path }
        ).mapValues { Set($0.map(\.messageID)) }
        let protectedPayloadRelativePaths = Set(
            ownerIDsByPath.compactMap { path, ownerIDs in
                ownerIDs.isSubset(of: requestedIDs) ? nil : path
            }
        )
        var payloadRelativePaths: [String: String] = [:]
        for reference in incomingPathReferences
        where requestedIDs.contains(reference.messageID)
            && ownerIDsByPath[reference.path, default: []]
                .isSubset(of: requestedIDs) {
            payloadRelativePaths[reference.messageID] = reference.path
        }
        persistence.persistDeletedPrivateMedia(
            messageIDs: messageIDs,
            payloadRelativePaths: payloadRelativePaths,
            protectedPayloadRelativePaths:
                protectedPayloadRelativePaths,
            completion: completion
        )
    }

    func requiresPrivateMediaTombstone(messageID: String) -> Bool {
        guard PrivateMediaMessageIdentity.isStableID(messageID) else {
            return false
        }
        return privateChats.values.lazy.flatMap { $0 }.contains { message in
            message.id == messageID && isIncomingPrivateMessage(message)
        }
    }

    func notifyMediaDeletionRefused(messageID: String) {
        let owningPeerID = privateChats.first { _, messages in
            messages.contains { $0.id == messageID }
        }?.key
        notifyPrivateMediaDeletionRefused(peerID: owningPeerID)
    }

    /// A refused deletion/clear previously surfaced only in SecureLogger, so
    /// a wedged /clear looked like success. Tell the affected chat that its
    /// bubbles and payloads were intentionally kept.
    func notifyPrivateMediaDeletionRefused(peerID: PeerID?) {
        let copy = String(
            localized: "content.system.media_delete_refused",
            comment: "System message when an explicit media delete or /clear was refused and bubbles/files were kept"
        )
        if let peerID = peerID ?? selectedPrivateChatPeer {
            addLocalPrivateSystemMessage(copy, to: peerID)
        } else {
            addSystemMessage(copy)
        }
    }

    private func isIncomingPrivateMessage(
        _ message: BitchatMessage
    ) -> Bool {
        if let senderPeerID = message.senderPeerID {
            return senderPeerID.toShort() != meshService.myPeerID.toShort()
        }
        return message.sender != nickname
            && !message.sender.hasPrefix(nickname + "#")
    }

    private func incomingMediaRelativePath(
        for message: BitchatMessage
    ) -> String? {
        let categories: [MimeType.Category] = [.audio, .image, .file]
        guard let category = categories.first(where: {
            message.content.hasPrefix($0.messagePrefix)
        }),
        let rawFilename = String(
            message.content.dropFirst(category.messagePrefix.count)
        ).trimmedOrNilIfEmpty,
        let safeFilename =
            (rawFilename as NSString).lastPathComponent.nilIfEmpty,
        safeFilename != ".",
        safeFilename != ".." else {
            return nil
        }
        return "\(category.mediaDir)/incoming/\(safeFilename)"
    }
}

/// Synchronous boundary between detached image writers and panic deletion.
///
/// Invalidation closes admission before waiting for writers that already
/// entered. Those writers never need the main actor while inside the boundary,
/// so a synchronous panic transaction can safely join them and then delete
/// every output before reporting completion.
private final class ImagePreparationBarrier: @unchecked Sendable {
    private let condition = NSCondition()
    private var generation: UInt64 = 0
    private var activeOperations = 0

    var currentGeneration: UInt64 {
        condition.lock()
        defer { condition.unlock() }
        return generation
    }

    func isCurrent(_ candidate: UInt64) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return generation == candidate
    }

    func performIfCurrent<T>(
        generation candidate: UInt64,
        operation: () throws -> T
    ) rethrows -> T? {
        condition.lock()
        guard generation == candidate else {
            condition.unlock()
            return nil
        }
        activeOperations += 1
        condition.unlock()

        defer {
            condition.lock()
            activeOperations -= 1
            if activeOperations == 0 {
                condition.broadcast()
            }
            condition.unlock()
        }
        return try operation()
    }

    func invalidateAndWait() {
        condition.lock()
        generation &+= 1
        while activeOperations > 0 {
            condition.wait()
        }
        condition.unlock()
    }
}

/// Runs synchronous media encoding and file I/O on a dispatch worker.
///
/// These operations can legitimately block. Keeping them off Swift's
/// cooperative executor preserves forward progress when several transfers or
/// test doubles wait at the same time.
private func runBlockingMediaPreparation<T>(
    _ operation: @escaping @Sendable () throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                continuation.resume(returning: try operation())
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

@MainActor
final class ChatMediaTransferCoordinator {
    private unowned let context: any ChatMediaTransferContext
    private let prepareImagePacket: @Sendable (URL) throws -> ChatPreparedImage
    private let imagePreparationBarrier = ImagePreparationBarrier()
    private let prepareVoiceNotePacket: @Sendable (URL) throws -> BitchatFilePacket
    private let reconnectRetryLimits: PrivateMediaReconnectRetryLimits
    private let now: () -> Date
    private let transferIDFactory: (String) -> String

    private(set) var transferIdToMessageIDs: [String: [String]] = [:]
    private(set) var messageIDToTransferId: [String: String] = [:]
    private var deletionGeneration: UInt64 = 0
    private var reconnectRetryRecords: [
        String: PrivateMediaReconnectRetryRecord
    ] = [:]
    /// A newly authenticated session supersedes any raw-connect policy
    /// resolution still in flight for that peer.
    private var peersResolvingReconnectRetry: [
        PeerID: (
            id: UUID,
            replacingActiveTransfer: Bool,
            candidates: [PrivateMediaReconnectRetryCandidate]
        )
    ] = [:]
    private var reconnectRetryExpiryTasks: [String: Task<Void, Never>] = [:]

    var retainedReconnectRetryCount: Int {
        reconnectRetryRecords.count
    }

    var retainedReconnectRetryBytes: Int {
        reconnectRetryRecords.values.reduce(0) { $0 + $1.retainedBytes }
    }

    init(
        context: any ChatMediaTransferContext,
        prepareImagePacket: @escaping @Sendable (URL) throws -> ChatPreparedImage = {
            try ChatMediaPreparation.prepareImagePacket(from: $0)
        },
        prepareVoiceNotePacket: @escaping @Sendable (URL) throws -> BitchatFilePacket = {
            try ChatMediaPreparation.prepareVoiceNotePacket(at: $0)
        },
        reconnectRetryLimits: PrivateMediaReconnectRetryLimits =
            PrivateMediaReconnectRetryLimits(),
        now: @escaping () -> Date = Date.init,
        transferIDFactory: @escaping (String) -> String = {
            "\($0)-\(UUID().uuidString)"
        }
    ) {
        self.context = context
        self.prepareImagePacket = prepareImagePacket
        self.prepareVoiceNotePacket = prepareVoiceNotePacket
        self.reconnectRetryLimits = reconnectRetryLimits
        self.now = now
        self.transferIDFactory = transferIDFactory
    }

    func sendVoiceNote(at url: URL) {
        guard context.canSendMediaInCurrentContext else {
            SecureLogger.info("Voice note blocked outside mesh/private context", category: .session)
            try? FileManager.default.removeItem(at: url)
            context.addSystemMessage("Voice notes are only available in mesh chats.")
            return
        }

        let targetPeer = context.selectedPrivateChatPeer
        let privateMessageID = targetPeer.flatMap { peerID in
            PrivateMediaMessageIdentity.stableID(
                senderPeerID: context.myPeerID,
                recipientPeerID: peerID,
                fileName: url.lastPathComponent
            )
        }
        let message = enqueueMediaMessage(
            content: "\(MimeType.Category.audio.messagePrefix)\(url.lastPathComponent)",
            targetPeer: targetPeer,
            messageID: privateMessageID
        )
        let messageID = message.id
        let transferId = makeTransferID(messageID: messageID)
        // Own the transfer before detached preparation begins. Cancel/delete
        // must be able to invalidate this exact invocation even while file I/O
        // is still running off the main actor.
        registerTransfer(transferId: transferId, messageID: messageID)
        let prepareVoiceNotePacket = self.prepareVoiceNotePacket
        let barrier = imagePreparationBarrier
        let generation = barrier.currentGeneration

        Task.detached(priority: .userInitiated) { [weak self, barrier] in
            do {
                let packet = try await runBlockingMediaPreparation {
                    try prepareVoiceNotePacket(url)
                }

                await MainActor.run { [weak self, barrier] in
                    guard let self,
                          barrier.isCurrent(generation),
                          self.isRegisteredTransfer(transferId, messageID: messageID) else {
                        return
                    }
                    if let peerID = targetPeer {
                        self.beginPrivateMediaSend(
                            packet,
                            to: peerID,
                            transferId: transferId,
                            messageID: messageID
                        )
                    } else {
                        self.context.sendFileBroadcast(packet, transferId: transferId)
                    }
                }
            } catch ChatMediaPreparationError.voiceNoteTooLarge(let size) {
                SecureLogger.warning("Voice note exceeds size limit (\(size) bytes)", category: .session)
                try? FileManager.default.removeItem(at: url)
                await MainActor.run { [weak self, barrier] in
                    guard let self,
                          barrier.isCurrent(generation),
                          self.isRegisteredTransfer(transferId, messageID: messageID) else {
                        return
                    }
                    self.handleMediaSendFailure(messageID: messageID, reason: String(localized: "content.delivery.reason.voice_too_large", comment: "Failure reason shown when a voice note exceeds the size limit"))
                }
            } catch {
                SecureLogger.error("Voice note send failed: \(error)", category: .session)
                await MainActor.run { [weak self, barrier] in
                    guard let self,
                          barrier.isCurrent(generation),
                          self.isRegisteredTransfer(transferId, messageID: messageID) else {
                        return
                    }
                    self.handleMediaSendFailure(messageID: messageID, reason: String(localized: "content.delivery.reason.voice_send_failed", comment: "Failure reason shown when a voice note could not be sent"))
                }
            }
        }
    }

    #if os(iOS)
    func processThenSendImage(_ image: UIImage?) {
        guard let image else { return }
        let generation = imagePreparationBarrier.currentGeneration
        let barrier = imagePreparationBarrier
        Task.detached(priority: .userInitiated) { [weak self, barrier] in
            do {
                let processedURL = try await runBlockingMediaPreparation {
                    try barrier.performIfCurrent(
                        generation: generation,
                        operation: {
                            try ImageUtils.processImage(image)
                        }
                    )
                }
                guard let processedURL else {
                    return
                }
                await MainActor.run { [weak self, barrier] in
                    guard let self,
                          barrier.isCurrent(generation) else {
                        try? FileManager.default.removeItem(at: processedURL)
                        return
                    }
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
        let generation = imagePreparationBarrier.currentGeneration
        let barrier = imagePreparationBarrier
        Task.detached(priority: .userInitiated) { [weak self, barrier] in
            do {
                let processedURL = try await runBlockingMediaPreparation {
                    try barrier.performIfCurrent(
                        generation: generation,
                        operation: {
                            try ImageUtils.processImage(at: url)
                        }
                    )
                }
                guard let processedURL else {
                    return
                }
                await MainActor.run { [weak self, barrier] in
                    guard let self,
                          barrier.isCurrent(generation) else {
                        try? FileManager.default.removeItem(at: processedURL)
                        return
                    }
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
        let generation = imagePreparationBarrier.currentGeneration

        do {
            try ImageUtils.validateImageSource(at: sourceURL)
        } catch {
            SecureLogger.error("Image send preparation failed: \(error)", category: .session)
            context.addSystemMessage("Failed to prepare image for sending.")
            return
        }

        let prepareImagePacket = self.prepareImagePacket
        let barrier = imagePreparationBarrier
        Task.detached(priority: .userInitiated) { [weak self, barrier] in
            do {
                let prepared = try await runBlockingMediaPreparation {
                    try barrier.performIfCurrent(
                        generation: generation,
                        operation: {
                            try prepareImagePacket(sourceURL)
                        }
                    )
                }
                guard let prepared else {
                    return
                }

                await MainActor.run { [weak self, barrier] in
                    guard let self,
                          barrier.isCurrent(generation) else {
                        try? FileManager.default.removeItem(at: prepared.outputURL)
                        return
                    }
                    let privateMessageID = targetPeer.flatMap { peerID in
                        PrivateMediaMessageIdentity.stableID(
                            for: prepared.packet,
                            senderPeerID: self.context.myPeerID,
                            recipientPeerID: peerID
                        )
                    }
                    let message = self.enqueueMediaMessage(
                        content: "\(MimeType.Category.image.messagePrefix)\(prepared.outputURL.lastPathComponent)",
                        targetPeer: targetPeer,
                        messageID: privateMessageID
                    )
                    let messageID = message.id
                    let transferId = self.makeTransferID(messageID: messageID)
                    self.registerTransfer(transferId: transferId, messageID: messageID)
                    if let peerID = targetPeer {
                        self.beginPrivateMediaSend(
                            prepared.packet,
                            to: peerID,
                            transferId: transferId,
                            messageID: messageID
                        )
                    } else {
                        self.context.sendFileBroadcast(prepared.packet, transferId: transferId)
                    }
                }
            } catch ChatMediaPreparationError.imageTooLarge(let size) {
                SecureLogger.warning("Processed image exceeds size limit (\(size) bytes)", category: .session)
                await MainActor.run { [weak self, barrier] in
                    guard let self,
                          barrier.isCurrent(generation) else {
                        return
                    }
                    self.context.addSystemMessage("Image is too large to send.")
                }
            } catch {
                SecureLogger.error("Image send preparation failed: \(error)", category: .session)
                await MainActor.run { [weak self, barrier] in
                    guard let self,
                          barrier.isCurrent(generation) else {
                        return
                    }
                    self.context.addSystemMessage("Failed to prepare image for sending.")
                }
            }
        }
    }

    func enqueueMediaMessage(
        content: String,
        targetPeer: PeerID?,
        messageID: String? = nil
    ) -> BitchatMessage {
        let timestamp = Date()
        let message: BitchatMessage

        if let peerID = targetPeer {
            message = BitchatMessage(
                id: messageID,
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

    private func beginPrivateMediaSend(
        _ packet: BitchatFilePacket,
        to peerID: PeerID,
        transferId: String,
        messageID: String
    ) {
        continuePrivateMediaSend(
            packet,
            to: peerID,
            transferId: transferId,
            messageID: messageID,
            policy: context.privateMediaSendPolicy(to: peerID)
        )
    }

    private func continuePrivateMediaSend(
        _ packet: BitchatFilePacket,
        to peerID: PeerID,
        transferId: String,
        messageID: String,
        policy: PrivateMediaSendPolicy
    ) {
        switch policy {
        case .encrypted:
            retainForReconnectRetryIfEligible(
                packet,
                peerID: peerID,
                messageID: messageID,
                activeTransferID: transferId
            )
            context.sendFilePrivate(
                packet,
                to: peerID,
                transferId: transferId,
                allowLegacyFallback: false
            )

        case .awaitingCapabilityProof:
            context.resolvePrivateMediaSendPolicy(to: peerID) { [weak self] resolvedPolicy in
                guard let self,
                      self.isRegisteredTransfer(transferId, messageID: messageID) else {
                    return
                }
                guard resolvedPolicy != .awaitingCapabilityProof else {
                    self.handleMediaSendFailure(
                        messageID: messageID,
                        reason: String(
                            localized: "content.delivery.reason.private_media_capability_unresolved",
                            defaultValue: "Could not confirm encrypted media support",
                            comment: "Failure reason when private-media capability negotiation did not resolve"
                        )
                    )
                    return
                }
                self.continuePrivateMediaSend(
                    packet,
                    to: peerID,
                    transferId: transferId,
                    messageID: messageID,
                    policy: resolvedPolicy
                )
            }

        case .legacyRequiresConsent:
            context.requestLegacyPrivateMediaConsent(
                for: peerID,
                transferId: transferId,
                messageID: messageID
            ) { [weak self] approved in
                guard let self else { return }
                // Consent belongs to this exact placeholder/transfer. A late
                // dialog callback after cancel/delete must never resurrect it.
                guard self.messageIDToTransferId[messageID] == transferId,
                      self.transferIdToMessageIDs[transferId]?.contains(messageID) == true else {
                    return
                }
                guard approved else {
                    self.handleMediaSendFailure(
                        messageID: messageID,
                        reason: String(
                            localized: "content.delivery.reason.legacy_media_declined",
                            defaultValue: "Not sent without end-to-end encryption",
                            comment: "Failure reason after declining the warning for a legacy clear private-media send"
                        )
                    )
                    return
                }
                self.context.sendFilePrivate(
                    packet,
                    to: peerID,
                    transferId: transferId,
                    allowLegacyFallback: true
                )
            }

        case .blockedDowngrade:
            handleMediaSendFailure(
                messageID: messageID,
                reason: String(
                    localized: "content.delivery.reason.private_media_downgrade_blocked",
                    defaultValue: "Encrypted media required; ask this contact to upgrade",
                    comment: "Failure reason when a peer that previously supported encrypted media appears to downgrade"
                )
            )
        }
    }

    func registerTransfer(transferId: String, messageID: String) {
        transferIdToMessageIDs[transferId, default: []].append(messageID)
        messageIDToTransferId[messageID] = transferId
    }

    private func isRegisteredTransfer(_ transferId: String, messageID: String) -> Bool {
        messageIDToTransferId[messageID] == transferId
            && transferIdToMessageIDs[transferId]?.contains(messageID) == true
    }

    func makeTransferID(messageID: String) -> String {
        transferIDFactory(messageID)
    }

    func clearTransferMapping(for messageID: String) {
        guard let transferId = messageIDToTransferId[messageID] else { return }
        clearTransferMapping(
            transferID: transferId,
            messageID: messageID,
            clearCurrentOwner: true
        )
    }

    private func clearTransferMapping(
        transferID: String,
        messageID: String,
        clearCurrentOwner: Bool
    ) {
        if clearCurrentOwner,
           messageIDToTransferId[messageID] == transferID {
            messageIDToTransferId.removeValue(forKey: messageID)
        }
        context.cancelLegacyPrivateMediaConsent(
            transferId: transferID,
            messageID: messageID
        )
        guard var queue = transferIdToMessageIDs[transferID] else { return }

        if !queue.isEmpty {
            if queue.first == messageID {
                queue.removeFirst()
            } else if let index = queue.firstIndex(of: messageID) {
                queue.remove(at: index)
            }
        }

        transferIdToMessageIDs[transferID] = queue.isEmpty ? nil : queue
    }

    /// Returns the message still owned by this exact transfer. Replacement
    /// retries can receive late callbacks from the cancelled predecessor;
    /// those callbacks may clear only their stale queue entry.
    private func currentMessageID(forTransferID transferID: String) -> String? {
        guard let messageID = transferIdToMessageIDs[transferID]?.first else {
            return nil
        }
        guard messageIDToTransferId[messageID] == transferID else {
            clearTransferMapping(
                transferID: transferID,
                messageID: messageID,
                clearCurrentOwner: false
            )
            return nil
        }
        return messageID
    }

    func handleMediaSendFailure(messageID: String, reason: String) {
        discardReconnectRetry(
            messageID: messageID,
            cancelActiveTransfer: false
        )
        context.updateMessageDeliveryStatus(messageID, status: .failed(reason: reason))
        clearTransferMapping(for: messageID)
    }

    func handleTransferEvent(_ event: TransferProgressManager.Event) {
        switch event {
        case .started(let id, let total):
            guard let messageID = currentMessageID(forTransferID: id) else {
                return
            }
            if isReconnectRetryTransfer(id, messageID: messageID) {
                return
            }
            context.updateMessageDeliveryStatus(messageID, status: .partiallyDelivered(reached: 0, total: total))

        case .updated(let id, let sent, let total):
            guard let messageID = currentMessageID(forTransferID: id) else {
                return
            }
            if isReconnectRetryTransfer(id, messageID: messageID) {
                return
            }
            context.updateMessageDeliveryStatus(messageID, status: .partiallyDelivered(reached: sent, total: total))

        case .completed(let id, _):
            guard let messageID = currentMessageID(forTransferID: id) else {
                return
            }
            let ownsRetainedRecord =
                reconnectRetryRecords[messageID]?.activeTransferID == id
            let retryAfterCompletion = ownsRetainedRecord
                && reconnectRetryRecords[messageID]?.retryAfterCompletion == true
            let deferredTerminalReason = ownsRetainedRecord
                ? reconnectRetryRecords[messageID]?
                    .deferredTerminalFailureReason
                : nil
            if ownsRetainedRecord {
                reconnectRetryRecords[messageID]?.activeTransferID = nil
                reconnectRetryRecords[messageID]?.retryAfterCompletion = false
                reconnectRetryRecords[messageID]?.idleOutcome =
                    .locallyCompleted
                reconnectRetryRecords[messageID]?.createdAt = now()
            }
            context.updateMessageDeliveryStatus(messageID, status: .sent)
            clearTransferMapping(for: messageID)
            if let deferredTerminalReason {
                terminalizeReconnectRetry(
                    messageID: messageID,
                    reason: deferredTerminalReason
                )
            } else if retryAfterCompletion {
                startReconnectRetry(messageID: messageID)
            } else if ownsRetainedRecord {
                scheduleReconnectRetryExpiry(messageID: messageID)
            }

        case .cancelled(let id, _, _):
            guard let messageID = currentMessageID(forTransferID: id) else {
                return
            }
            if isRetainedPrivateMediaTransfer(id, messageID: messageID) {
                finishRetainedTransfer(
                    id,
                    messageID: messageID,
                    outcome: .cancelled,
                    rejectionReason: nil
                )
                return
            }
            discardReconnectRetry(
                messageID: messageID,
                cancelActiveTransfer: false
            )
            clearTransferMapping(for: messageID)
            context.removeOutgoingMediaMessage(withID: messageID)
        case .rejected(let id, let reason):
            guard let messageID = currentMessageID(forTransferID: id) else {
                return
            }
            if isRetainedPrivateMediaTransfer(id, messageID: messageID) {
                finishRetainedTransfer(
                    id,
                    messageID: messageID,
                    outcome: .rejected(reason: reason),
                    rejectionReason: reason
                )
                return
            }
            handleMediaSendFailure(messageID: messageID, reason: reason)
        }
    }

    func cleanupLocalFile(forMessage message: BitchatMessage) {
        cleanupLocalFile(
            forMessage: message,
            directions: ["outgoing", "incoming"],
            searchAllCategories: true
        )
    }

    /// `/clear` may cancel an outgoing message before receiver tombstones are
    /// committed. Restrict cleanup to that message's outgoing directory so a
    /// same-name incoming payload cannot be removed prematurely.
    func cleanupOutgoingLocalFile(forMessage message: BitchatMessage) {
        cleanupLocalFile(
            forMessage: message,
            directions: ["outgoing"],
            searchAllCategories: false
        )
    }

    /// Receiver cleanup runs only after any required tombstone commit. Keep it
    /// scoped to the parsed media category and incoming directory so unrelated
    /// outgoing or cross-category payloads with the same basename survive.
    func cleanupIncomingLocalFile(forMessage message: BitchatMessage) {
        cleanupLocalFile(
            forMessage: message,
            directions: ["incoming"],
            searchAllCategories: false
        )
    }

    private func cleanupLocalFile(
        forMessage message: BitchatMessage,
        directions: [String],
        searchAllCategories: Bool
    ) {
        let categories: [MimeType.Category] = [.audio, .image, .file]
        guard let category = categories.first(where: { message.content.hasPrefix($0.messagePrefix) }),
              let rawFilename = String(message.content.dropFirst(category.messagePrefix.count)).trimmedOrNilIfEmpty,
              let base = try? applicationFilesDirectory(),
              let safeFilename = (rawFilename as NSString).lastPathComponent.nilIfEmpty,
              safeFilename != ".",
              safeFilename != ".." else {
            return
        }

        let targetCategories = searchAllCategories ? categories : [category]
        let subdirs = targetCategories.flatMap { category in
            directions.map { "\(category.mediaDir)/\($0)" }
        }
        for subdir in subdirs {
            let target = base.appendingPathComponent(subdir, isDirectory: true).appendingPathComponent(safeFilename)
            guard target.path.hasPrefix(base.path) else { continue }

            guard FileManager.default.fileExists(atPath: target.path) else {
                continue
            }
            guard let values = try? target.resourceValues(
                forKeys: [.isRegularFileKey]
            ),
            values.isRegularFile == true else {
                SecureLogger.warning(
                    "Refusing to cleanup non-file media target \(safeFilename)",
                    category: .session
                )
                continue
            }
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
        cancelAllMediaSendOwners(messageID: messageID)
        context.removeOutgoingMediaMessage(withID: messageID)
    }

    /// Lets `/clear` cancel send ownership without implicitly deciding which
    /// bubbles/files its deletion transaction may remove.
    func cancelMediaTransferForConversationClear(messageID: String) {
        cancelAllMediaSendOwners(messageID: messageID)
    }

    func deleteMediaMessage(messageID: String) {
        // Stop every exact sender owner before the durable receiver commit.
        // Otherwise a retained retry or admitted legacy send could transmit
        // after the bubble and payload have been deleted.
        cancelAllMediaSendOwners(messageID: messageID)

        guard context.requiresPrivateMediaTombstone(
            messageID: messageID
        ) else {
            finishMediaDeletion(
                messageID: messageID,
                receiverJournalOwnsPayload: false
            )
            return
        }

        let generation = deletionGeneration
        context.persistDeletedPrivateMedia(
            messageIDs: [messageID]
        ) { [weak self] persisted in
            guard let self,
                  self.deletionGeneration == generation else {
                return
            }
            guard persisted else {
                SecureLogger.error(
                    "Refusing to delete private media without a durable tombstone id=\(messageID.prefix(12))…",
                    category: .session
                )
                self.context.notifyMediaDeletionRefused(
                    messageID: messageID
                )
                return
            }
            self.finishMediaDeletion(
                messageID: messageID,
                receiverJournalOwnsPayload: true
            )
        }
    }

    private func finishMediaDeletion(
        messageID: String,
        receiverJournalOwnsPayload: Bool
    ) {
        if receiverJournalOwnsPayload {
            // The journal already owns the exact path. A basename cleanup here
            // could delete a different arrival that reused it after unlink.
            context.removeMessage(withID: messageID, cleanupFile: false)
        } else {
            context.removeUntombstonedMediaMessage(withID: messageID)
        }
    }

    private func cancelAllMediaSendOwners(messageID: String) {
        // This releases the retained packet and expiry/retry owner. When its
        // exact active transfer still owns the mapping, it cancels that owner
        // before any deletion persistence or UI mutation can proceed.
        discardReconnectRetry(
            messageID: messageID,
            cancelActiveTransfer: true
        )
        // In particular, an approved legacy send may still be waiting on
        // BLEService.messageQueue. Its admission must be canceled before the
        // mapping/consent owner is released.
        if let transferId = messageIDToTransferId[messageID],
           transferIdToMessageIDs[transferId]?.first == messageID {
            context.cancelTransfer(transferId)
        }
        clearTransferMapping(for: messageID)
    }

    /// A raw link callback can arrive before the replacement Noise session
    /// proves its capabilities. Resolve against the exact session before
    /// releasing any retained bytes into a whole-file retry.
    func peerDidReconnect(_ peerID: PeerID) {
        resolveReconnectRetries(
            for: peerID,
            replacingActiveTransfer: false
        )
    }

    /// Authentication supersedes a raw-connect resolution that may still
    /// refer to the cached generation and replaces only stale active sends.
    func peerDidAuthenticate(_ peerID: PeerID) {
        resolveReconnectRetries(
            for: peerID,
            replacingActiveTransfer: true
        )
    }

    /// A policy resolution's completion can be dropped entirely when the
    /// transport tears down mid-flight (BLEService's queue guards on a
    /// deallocated self), which would leave the pending entry blocking every
    /// future resolution for this peer. Disconnection invalidates the
    /// resolution's premise anyway, so drop it; retained records stay and the
    /// next reconnect starts a fresh resolution.
    func peerDidDisconnect(_ peerID: PeerID) {
        peersResolvingReconnectRetry.removeValue(forKey: peerID.toShort())
    }

    /// Local fragment completion is not proof that the recipient reconstructed
    /// the file. Only a remote delivery/read receipt releases retry ownership.
    func confirmPrivateMediaDelivery(messageID: String) {
        guard PrivateMediaMessageIdentity.isStableID(messageID) else {
            return
        }
        discardReconnectRetry(
            messageID: messageID,
            cancelActiveTransfer: true
        )
    }

    /// Deterministic clock seam for focused tests. Production records also own
    /// wall-clock expiry tasks.
    func _test_expireReconnectRetries() {
        pruneExpiredReconnectRetries()
    }

    /// Invalidates detached preparation work and cancels every transfer that
    /// reached the transport. Closing image-preparation admission and joining
    /// active synchronous writers ensures the following panic media deletion
    /// is the last filesystem mutation before the transaction can complete.
    func resetForPanic() {
        imagePreparationBarrier.invalidateAndWait()
        deletionGeneration &+= 1
        peersResolvingReconnectRetry.removeAll(keepingCapacity: false)
        for task in reconnectRetryExpiryTasks.values {
            task.cancel()
        }
        reconnectRetryExpiryTasks.removeAll(keepingCapacity: false)
        reconnectRetryRecords.removeAll(keepingCapacity: false)
        let transferIDs = Set(transferIdToMessageIDs.keys)
        transferIdToMessageIDs.removeAll(keepingCapacity: false)
        messageIDToTransferId.removeAll(keepingCapacity: false)
        for transferID in transferIDs {
            context.cancelTransfer(transferID)
        }
    }
}

private extension ChatMediaTransferCoordinator {
    func reconnectRetryCandidates(
        for peerID: PeerID,
        limit: Int?
    ) -> [PrivateMediaReconnectRetryCandidate] {
        let records = reconnectRetryRecords.values
            .filter {
                $0.peerID == peerID
                    && $0.retryCount
                        < reconnectRetryLimits.maxRetriesPerMessage
            }
            .sorted {
                if $0.createdAt == $1.createdAt {
                    return $0.messageID < $1.messageID
                }
                return $0.createdAt < $1.createdAt
            }
        let selected: ArraySlice<PrivateMediaReconnectRetryRecord>
        if let limit {
            selected = records.prefix(max(0, limit))
        } else {
            selected = records[...]
        }
        return selected.map {
            PrivateMediaReconnectRetryCandidate(
                messageID: $0.messageID,
                receiptSessionGeneration: $0.receiptSessionGeneration
            )
        }
    }

    func resolveReconnectRetries(
        for peerID: PeerID,
        replacingActiveTransfer: Bool
    ) {
        pruneExpiredReconnectRetries()
        let normalizedPeerID = peerID.toShort()
        let candidates: [PrivateMediaReconnectRetryCandidate]
        if let pending = peersResolvingReconnectRetry[normalizedPeerID] {
            // Authentication is the only event that may supersede a raw-link
            // resolution; duplicate callbacks add no new proof.
            guard replacingActiveTransfer,
                  !pending.replacingActiveTransfer else {
                return
            }
            candidates = reconnectRetryCandidates(
                for: normalizedPeerID,
                limit: nil
            )
        } else {
            candidates = reconnectRetryCandidates(
                for: normalizedPeerID,
                limit: replacingActiveTransfer
                    ? nil
                    : max(
                        0,
                        reconnectRetryLimits.maxRetriesPerReconnect
                    )
            )
        }
        guard !candidates.isEmpty else { return }

        let resolutionID = UUID()
        peersResolvingReconnectRetry[normalizedPeerID] = (
            id: resolutionID,
            replacingActiveTransfer: replacingActiveTransfer,
            candidates: candidates
        )
        context.resolvePrivateMediaSendPolicy(
            to: normalizedPeerID
        ) { [weak self] policy in
            guard let self,
                  let pending =
                    self.peersResolvingReconnectRetry[normalizedPeerID],
                  pending.id == resolutionID else {
                return
            }
            self.peersResolvingReconnectRetry.removeValue(
                forKey: normalizedPeerID
            )
            guard policy == .encrypted,
                  let provenGeneration = self.context
                    .authenticatedPrivateMediaReceiptSessionGeneration(
                        to: normalizedPeerID
                    ) else {
                self.terminalizeUnavailableCapabilityProof(
                    pending.candidates,
                    for: normalizedPeerID
                )
                return
            }
            self.scheduleReconnectRetries(
                pending.candidates,
                for: normalizedPeerID,
                replacingActiveTransfer:
                    pending.replacingActiveTransfer,
                provenGeneration: provenGeneration
            )
        }
    }

    func retainForReconnectRetryIfEligible(
        _ packet: BitchatFilePacket,
        peerID: PeerID,
        messageID: String,
        activeTransferID: String
    ) {
        let normalizedPeerID = peerID.toShort()
        guard let receiptSessionGeneration = context
                .authenticatedPrivateMediaReceiptSessionGeneration(
                    to: normalizedPeerID
                ),
              reconnectRetryLimits.maxRetainedPackets > 0,
              reconnectRetryLimits.maxRetainedBytes > 0,
              reconnectRetryLimits.maxRetriesPerMessage > 0,
              packet.content.count
                <= reconnectRetryLimits.maxRetainedBytes,
              PrivateMediaMessageIdentity.isStableID(messageID),
              PrivateMediaMessageIdentity.stableID(
                for: packet,
                senderPeerID: context.myPeerID,
                recipientPeerID: normalizedPeerID
              ) == messageID else {
            return
        }

        pruneExpiredReconnectRetries()
        if var existing = reconnectRetryRecords[messageID] {
            cancelReconnectRetryExpiry(messageID: messageID)
            existing.receiptSessionGeneration = receiptSessionGeneration
            existing.createdAt = now()
            existing.activeTransferID = activeTransferID
            existing.retryAfterCompletion = false
            existing.idleOutcome = .none
            existing.deferredTerminalFailureReason = nil
            existing.expiryToken = nil
            reconnectRetryRecords[messageID] = existing
            return
        }

        makeReconnectRetryCapacity(for: packet.content.count)
        guard reconnectRetryRecords.count
                < reconnectRetryLimits.maxRetainedPackets,
              retainedReconnectRetryBytes + packet.content.count
                <= reconnectRetryLimits.maxRetainedBytes else {
            SecureLogger.debug(
                "Private media retry retention full; sending once id=\(messageID.prefix(12))…",
                category: .session
            )
            return
        }

        reconnectRetryRecords[messageID] =
            PrivateMediaReconnectRetryRecord(
                messageID: messageID,
                peerID: normalizedPeerID,
                packet: packet,
                receiptSessionGeneration: receiptSessionGeneration,
                createdAt: now(),
                retryCount: 0,
                activeTransferID: activeTransferID,
                retryAfterCompletion: false,
                idleOutcome: .none,
                deferredTerminalFailureReason: nil,
                expiryToken: nil
            )
    }

    func terminalizeUnavailableCapabilityProof(
        _ candidates: [PrivateMediaReconnectRetryCandidate],
        for peerID: PeerID
    ) {
        let reason = privateMediaCapabilityUnresolvedReason
        for candidate in candidates {
            guard var record =
                    reconnectRetryRecords[candidate.messageID],
                  record.peerID == peerID,
                  record.receiptSessionGeneration
                    == candidate.receiptSessionGeneration else {
                continue
            }
            if record.activeTransferID != nil {
                // The original transport owner can still produce a valid
                // remote receipt. Defer failure until it releases ownership.
                record.deferredTerminalFailureReason = reason
                reconnectRetryRecords[candidate.messageID] = record
            } else {
                terminalizeReconnectRetry(
                    messageID: candidate.messageID,
                    reason: reason
                )
            }
        }
    }

    func scheduleReconnectRetries(
        _ candidates: [PrivateMediaReconnectRetryCandidate],
        for peerID: PeerID,
        replacingActiveTransfer: Bool,
        provenGeneration: UUID
    ) {
        pruneExpiredReconnectRetries()

        var scheduledCount = 0
        let limit = max(
            0,
            reconnectRetryLimits.maxRetriesPerReconnect
        )
        for candidate in candidates {
            guard scheduledCount < limit else { break }
            let messageID = candidate.messageID
            guard var record = reconnectRetryRecords[messageID],
                  record.peerID == peerID,
                  record.receiptSessionGeneration
                    == candidate.receiptSessionGeneration,
                  record.retryCount
                    < reconnectRetryLimits.maxRetriesPerMessage else {
                continue
            }
            if record.deferredTerminalFailureReason != nil {
                record.deferredTerminalFailureReason = nil
                reconnectRetryRecords[messageID] = record
            }
            if replacingActiveTransfer,
               candidate.receiptSessionGeneration == provenGeneration {
                continue
            }
            if record.activeTransferID != nil {
                if replacingActiveTransfer {
                    if replaceActiveTransferAfterAuthentication(
                        messageID: messageID
                    ) {
                        scheduledCount += 1
                    }
                    continue
                }
                // Arm one retry after the current transfer drains. Duplicate
                // reconnect callbacks cannot chain more work.
                if record.retryCount == 0 {
                    record.retryAfterCompletion = true
                    reconnectRetryRecords[messageID] = record
                    scheduledCount += 1
                }
            } else if startReconnectRetry(messageID: messageID) {
                scheduledCount += 1
            }
        }
    }

    @discardableResult
    func replaceActiveTransferAfterAuthentication(
        messageID: String
    ) -> Bool {
        guard var record = reconnectRetryRecords[messageID],
              let staleTransferID = record.activeTransferID,
              record.retryCount
                < reconnectRetryLimits.maxRetriesPerMessage else {
            return false
        }
        record.activeTransferID = nil
        record.retryAfterCompletion = false
        record.createdAt = now()
        reconnectRetryRecords[messageID] = record

        if messageIDToTransferId[messageID] == staleTransferID {
            clearTransferMapping(for: messageID)
        }
        context.cancelTransfer(staleTransferID)
        return startReconnectRetry(messageID: messageID)
    }

    @discardableResult
    func startReconnectRetry(messageID: String) -> Bool {
        pruneExpiredReconnectRetries()
        guard var record = reconnectRetryRecords[messageID],
              record.activeTransferID == nil,
              record.retryCount
                < reconnectRetryLimits.maxRetriesPerMessage else {
            return false
        }
        guard context.privateMediaSendPolicy(to: record.peerID)
                == .encrypted,
              let receiptSessionGeneration = context
                .authenticatedPrivateMediaReceiptSessionGeneration(
                    to: record.peerID
                ) else {
            terminalizeReconnectRetry(
                messageID: messageID,
                reason: privateMediaCapabilityUnresolvedReason
            )
            return false
        }

        cancelReconnectRetryExpiry(messageID: messageID)
        let transferID = makeTransferID(messageID: messageID)
        record.retryCount += 1
        record.receiptSessionGeneration = receiptSessionGeneration
        record.activeTransferID = transferID
        record.retryAfterCompletion = false
        record.idleOutcome = .none
        record.deferredTerminalFailureReason = nil
        record.expiryToken = nil
        reconnectRetryRecords[messageID] = record
        registerTransfer(
            transferId: transferID,
            messageID: messageID
        )

        SecureLogger.debug(
            "🔄 Retrying private media after reconnect id=\(messageID.prefix(12))… attempt=\(record.retryCount)",
            category: .session
        )
        context.sendFilePrivateReceiptRetry(
            record.packet,
            to: record.peerID,
            transferId: transferID
        )
        return true
    }

    func finishRetainedTransfer(
        _ transferID: String,
        messageID: String,
        outcome: PrivateMediaReconnectRetryIdleOutcome,
        rejectionReason: String?
    ) {
        guard var record = reconnectRetryRecords[messageID],
              record.activeTransferID == transferID else {
            return
        }
        let retryAfterCompletion = record.retryAfterCompletion
        let deferredTerminalReason =
            record.deferredTerminalFailureReason
        record.activeTransferID = nil
        record.retryAfterCompletion = false
        record.idleOutcome = outcome
        record.createdAt = now()
        reconnectRetryRecords[messageID] = record
        clearTransferMapping(for: messageID)

        if let deferredTerminalReason {
            terminalizeReconnectRetry(
                messageID: messageID,
                reason: deferredTerminalReason
            )
        } else if retryAfterCompletion {
            startReconnectRetry(messageID: messageID)
        } else if record.retryCount
                    >= reconnectRetryLimits.maxRetriesPerMessage {
            terminalizeReconnectRetry(
                messageID: messageID,
                reason: rejectionReason
                    ?? privateMediaNotDeliveredReason
            )
        } else {
            scheduleReconnectRetryExpiry(messageID: messageID)
        }

        if let rejectionReason {
            SecureLogger.debug(
                "Private media retry rejected id=\(messageID.prefix(12))…: \(rejectionReason)",
                category: .session
            )
        }
    }

    func isReconnectRetryTransfer(
        _ transferID: String,
        messageID: String
    ) -> Bool {
        guard let record = reconnectRetryRecords[messageID] else {
            return false
        }
        return record.retryCount > 0
            && record.activeTransferID == transferID
    }

    func isRetainedPrivateMediaTransfer(
        _ transferID: String,
        messageID: String
    ) -> Bool {
        reconnectRetryRecords[messageID]?.activeTransferID
            == transferID
    }

    func discardReconnectRetry(
        messageID: String,
        cancelActiveTransfer: Bool
    ) {
        cancelReconnectRetryExpiry(messageID: messageID)
        guard let record =
                reconnectRetryRecords.removeValue(forKey: messageID) else {
            return
        }
        guard cancelActiveTransfer,
              let transferID = record.activeTransferID,
              messageIDToTransferId[messageID] == transferID else {
            return
        }
        // Release ownership before cancellation so its late callback cannot
        // remove a remotely confirmed row.
        clearTransferMapping(for: messageID)
        context.cancelTransfer(transferID)
    }

    func pruneExpiredReconnectRetries() {
        let current = now()
        let lifetime = max(
            0,
            reconnectRetryLimits.retentionSeconds
        )
        let expiredMessageIDs: [String] =
            reconnectRetryRecords.values.compactMap { record in
                guard record.activeTransferID == nil,
                      current.timeIntervalSince(record.createdAt)
                        >= lifetime else {
                    return nil
                }
                return record.messageID
            }
        for messageID in expiredMessageIDs {
            guard let record = reconnectRetryRecords[messageID],
                  record.activeTransferID == nil else {
                continue
            }
            terminalizeReconnectRetry(
                messageID: messageID,
                reason: expiryFailureReason(for: record)
            )
        }
    }

    func makeReconnectRetryCapacity(for incomingBytes: Int) {
        while reconnectRetryRecords.count
                >= reconnectRetryLimits.maxRetainedPackets
            || retainedReconnectRetryBytes + incomingBytes
                > reconnectRetryLimits.maxRetainedBytes {
            guard let victim = reconnectRetryRecords.values
                .filter({ $0.activeTransferID == nil })
                .min(by: {
                    if $0.createdAt == $1.createdAt {
                        return $0.messageID < $1.messageID
                    }
                    return $0.createdAt < $1.createdAt
                }) else {
                return
            }
            terminalizeReconnectRetry(
                messageID: victim.messageID,
                reason: expiryFailureReason(for: victim)
            )
        }
    }

    var privateMediaNotDeliveredReason: String {
        String(
            localized: "content.delivery.reason.not_delivered",
            defaultValue: "Not delivered",
            comment: "Failure reason shown when a private media transfer could not finish"
        )
    }

    var privateMediaCapabilityUnresolvedReason: String {
        String(
            localized:
                "content.delivery.reason.private_media_capability_unresolved",
            defaultValue: "Could not confirm encrypted media support",
            comment: "Failure reason when private-media capability negotiation did not resolve"
        )
    }

    var privateMediaDeliveryUnconfirmedReason: String {
        String(
            localized:
                "content.delivery.reason.private_media_delivery_unconfirmed",
            defaultValue: "Delivery could not be confirmed",
            comment: "Failure reason when private media left this device but no delivery receipt arrived"
        )
    }

    func expiryFailureReason(
        for record: PrivateMediaReconnectRetryRecord
    ) -> String {
        switch record.idleOutcome {
        case .locallyCompleted:
            return privateMediaDeliveryUnconfirmedReason
        case .rejected(let reason):
            return reason
        case .none, .cancelled:
            return privateMediaNotDeliveredReason
        }
    }

    func terminalizeReconnectRetry(
        messageID: String,
        reason: String
    ) {
        guard let record = reconnectRetryRecords[messageID],
              record.activeTransferID == nil else {
            return
        }
        cancelReconnectRetryExpiry(messageID: messageID)
        guard reconnectRetryRecords.removeValue(forKey: messageID) != nil else {
            return
        }
        context.updateMessageDeliveryStatus(
            messageID,
            status: .failed(reason: reason)
        )
    }

    func scheduleReconnectRetryExpiry(messageID: String) {
        guard var record = reconnectRetryRecords[messageID],
              record.activeTransferID == nil else {
            return
        }
        cancelReconnectRetryExpiry(messageID: messageID)

        let lifetime = max(
            0,
            reconnectRetryLimits.retentionSeconds
        )
        let elapsed = max(
            0,
            now().timeIntervalSince(record.createdAt)
        )
        let delay = max(0, lifetime - elapsed)
        let token = UUID()
        record.expiryToken = token
        reconnectRetryRecords[messageID] = record

        let nanoseconds = UInt64(
            min(
                delay,
                TimeInterval(UInt64.max) / 1_000_000_000
            ) * 1_000_000_000
        )
        reconnectRetryExpiryTasks[messageID] = Task {
            @MainActor [weak self] in
            if nanoseconds > 0 {
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
            guard !Task.isCancelled,
                  let self,
                  let current =
                    self.reconnectRetryRecords[messageID],
                  current.activeTransferID == nil,
                  current.expiryToken == token else {
                return
            }
            self.terminalizeReconnectRetry(
                messageID: messageID,
                reason: self.expiryFailureReason(for: current)
            )
        }
    }

    func cancelReconnectRetryExpiry(messageID: String) {
        reconnectRetryExpiryTasks.removeValue(
            forKey: messageID
        )?.cancel()
        if reconnectRetryRecords[messageID]?.expiryToken != nil {
            reconnectRetryRecords[messageID]?.expiryToken = nil
        }
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
