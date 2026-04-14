import BitFoundation
import BitLogger
import Foundation

@MainActor
final class TransportRuntimeController: PublicMessagePipelineDelegate {
    private weak var viewModel: ChatViewModel?
    private let sessionStore: SessionStore
    private let publicTimelineStore: PublicTimelineStore
    private let privateConversationsStore: PrivateConversationsStore
    private let peerStore: UnifiedPeerService
    private let peerPresentationStore: PeerPresentationStore
    private let transportEventBridge: TransportEventBridge
    private var recentlySeenPeers: Set<PeerID> = []
    private var lastNetworkNotificationTime = Date.distantPast
    private var networkResetTimer: Timer?
    private var networkEmptyTimer: Timer?

    init(
        viewModel: ChatViewModel,
        sessionStore: SessionStore,
        publicTimelineStore: PublicTimelineStore,
        privateConversationsStore: PrivateConversationsStore,
        peerStore: UnifiedPeerService,
        peerPresentationStore: PeerPresentationStore,
        transportEventBridge: TransportEventBridge
    ) {
        self.viewModel = viewModel
        self.sessionStore = sessionStore
        self.publicTimelineStore = publicTimelineStore
        self.privateConversationsStore = privateConversationsStore
        self.peerStore = peerStore
        self.peerPresentationStore = peerPresentationStore
        self.transportEventBridge = transportEventBridge
    }

    deinit {
        networkResetTimer?.invalidate()
        networkEmptyTimer?.invalidate()
    }

    func bind() {
        guard let viewModel else { return }
        viewModel.meshService.delegate = transportEventBridge
        viewModel.meshService.peerEventsDelegate = transportEventBridge
        viewModel.publicMessagePipeline.delegate = self
    }

    func handle(_ event: TransportEvent) {
        switch event {
        case .messageReceived(let message):
            handleIncomingMessage(message)
        case .peerListUpdated(let peers):
            handlePeerListUpdated(peers)
        case .peerSnapshotsUpdated(let peers):
            peerStore.applyTransportPeerSnapshots(peers)
        case .publicMessageReceived(let peerID, let nickname, let content, let timestamp, let messageID):
            handleIncomingPublicMessage(
                from: peerID,
                nickname: nickname,
                content: content,
                timestamp: timestamp,
                messageID: messageID
            )
        case .noisePayloadReceived(let peerID, let type, let payload, let timestamp):
            handleNoisePayload(from: peerID, type: type, payload: payload, timestamp: timestamp)
        case .messageDeliveryStatusUpdated(let messageID, let status):
            updateMessageDeliveryStatus(messageID, status: status)
        case .bluetoothStateUpdated(let state):
            sessionStore.setBluetoothState(state)
        case .connected(let peerID):
            handleConnected(peerID)
        case .disconnected(let peerID):
            handleDisconnected(peerID)
        }
    }

    func pipelineCurrentMessages(_ pipeline: PublicMessagePipeline) -> [BitchatMessage] {
        publicTimelineStore.visibleMessages
    }

    func pipeline(_ pipeline: PublicMessagePipeline, setMessages messages: [BitchatMessage]) {
        publicTimelineStore.setVisibleMessages(messages)
    }

    func pipeline(_ pipeline: PublicMessagePipeline, normalizeContent content: String) -> String {
        guard let viewModel else { return content }
        return viewModel.deduplicationService.normalizedContentKey(content)
    }

    func pipeline(_ pipeline: PublicMessagePipeline, contentTimestampForKey key: String) -> Date? {
        guard let viewModel else { return nil }
        return viewModel.deduplicationService.contentTimestamp(forKey: key)
    }

    func pipeline(_ pipeline: PublicMessagePipeline, recordContentKey key: String, timestamp: Date) {
        guard let viewModel else { return }
        viewModel.deduplicationService.recordContentKey(key, timestamp: timestamp)
    }

    func pipelineTrimMessages(_ pipeline: PublicMessagePipeline) {
        guard let viewModel else { return }
        viewModel.trimMessagesIfNeeded()
    }

    func pipelinePrewarmMessage(_ pipeline: PublicMessagePipeline, message: BitchatMessage) {
        guard let viewModel else { return }
        _ = viewModel.formatMessageAsText(message, colorScheme: viewModel.currentColorScheme)
    }

    func pipelineSetBatchingState(_ pipeline: PublicMessagePipeline, isBatching: Bool) {
        sessionStore.setPublicBatching(isBatching)
    }
}

private extension TransportRuntimeController {
    func handleIncomingMessage(_ message: BitchatMessage) {
        guard let viewModel else { return }
        guard !viewModel.isMessageBlocked(message) else { return }
        guard !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || message.isPrivate else { return }

        if message.isPrivate {
            viewModel.handlePrivateMessage(message)
        } else {
            viewModel.handlePublicMessage(message)
        }

        viewModel.checkForMentions(message)
        viewModel.sendHapticFeedback(for: message)
    }

    func handleIncomingPublicMessage(
        from peerID: PeerID,
        nickname: String,
        content: String,
        timestamp: Date,
        messageID: String?
    ) {
        guard let viewModel else { return }
        let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let mentions = viewModel.parseMentions(from: normalized)
        let message = BitchatMessage(
            id: messageID,
            sender: nickname,
            content: normalized,
            timestamp: timestamp,
            isRelay: false,
            originalSender: nil,
            isPrivate: false,
            recipientNickname: nil,
            senderPeerID: peerID,
            mentions: mentions.isEmpty ? nil : mentions
        )
        viewModel.handlePublicMessage(message)
        viewModel.checkForMentions(message)
        viewModel.sendHapticFeedback(for: message)
    }

    func handleNoisePayload(from peerID: PeerID, type: NoisePayloadType, payload: Data, timestamp: Date) {
        guard let viewModel else { return }
        switch type {
        case .privateMessage:
            guard let privateMessage = PrivateMessagePacket.decode(from: payload) else { return }
            guard !viewModel.isPeerBlocked(peerID) else {
                SecureLogger.debug("🚫 Ignoring Noise payload from blocked peer: \(peerID)", category: .security)
                return
            }

            let senderName = viewModel.unifiedPeerService.getPeer(by: peerID)?.nickname ?? "Unknown"
            let mentions = viewModel.parseMentions(from: privateMessage.content)
            let message = BitchatMessage(
                id: privateMessage.messageID,
                sender: senderName,
                content: privateMessage.content,
                timestamp: timestamp,
                isRelay: false,
                originalSender: nil,
                isPrivate: true,
                recipientNickname: viewModel.nickname,
                senderPeerID: peerID,
                mentions: mentions.isEmpty ? nil : mentions
            )

            viewModel.handlePrivateMessage(message)
            viewModel.meshService.sendDeliveryAck(for: privateMessage.messageID, to: peerID)
        case .delivered:
            guard let messageID = String(data: payload, encoding: .utf8),
                  let targetPeerID = privateConversationsStore.findMessagePeerID(messageID: messageID, near: peerID) else {
                return
            }

            let currentStatus = privateConversationsStore.privateChats[targetPeerID]?
                .first(where: { $0.id == messageID })?
                .deliveryStatus
            guard !shouldSkipUpdate(currentStatus: currentStatus, newStatus: .delivered(to: "", at: .distantPast)) else {
                return
            }

            let displayName = peerDisplayName(for: peerID)
            _ = privateConversationsStore.updateDeliveryStatus(
                .delivered(to: displayName, at: Date()),
                forMessageID: messageID,
                in: targetPeerID
            )
        case .readReceipt:
            guard let messageID = String(data: payload, encoding: .utf8),
                  let targetPeerID = privateConversationsStore.findMessagePeerID(messageID: messageID, near: peerID) else {
                return
            }

            let displayName = peerDisplayName(for: peerID)
            _ = privateConversationsStore.updateDeliveryStatus(
                .read(by: displayName, at: Date()),
                forMessageID: messageID,
                in: targetPeerID
            )
        case .verifyChallenge, .verifyResponse:
            viewModel.verificationStore.handleVerificationPayload(type, payload: payload, from: peerID)
        }
    }

    func handlePeerListUpdated(_ peers: [PeerID]) {
        guard let viewModel else { return }
        sessionStore.setConnected(!peers.isEmpty)

        let removedUnreadCount = privateConversationsStore.cleanupStaleUnreadPeerIDs(currentPeerIDs: Set(peers))
        if removedUnreadCount > 0 {
            SecureLogger.debug("🧹 Cleaned up \(removedUnreadCount) stale unread peer IDs", category: .session)
        }

        let removedReceiptCount = privateConversationsStore.cleanupOldReadReceipts(isStartupPhase: viewModel.isStartupPhaseActive)
        if removedReceiptCount > 0 {
            SecureLogger.debug("🧹 Cleaned up \(removedReceiptCount) old read receipts", category: .session)
        }

        let meshPeers = peers.filter { peerID in
            viewModel.meshService.isPeerConnected(peerID) || viewModel.meshService.isPeerReachable(peerID)
        }
        let meshPeerSet = Set(meshPeers)

        if meshPeerSet.isEmpty {
            scheduleNetworkEmptyTimer()
        } else {
            invalidateNetworkEmptyTimer()
            let newPeers = meshPeerSet.subtracting(recentlySeenPeers)

            if !newPeers.isEmpty {
                let cooldown = TransportConfig.networkNotificationCooldownSeconds
                if Date().timeIntervalSince(lastNetworkNotificationTime) >= cooldown {
                    recentlySeenPeers.formUnion(newPeers)
                    lastNetworkNotificationTime = Date()
                    NotificationService.shared.sendNetworkAvailableNotification(peerCount: meshPeers.count)
                    SecureLogger.info(
                        "👥 Sent bitchatters nearby notification for \(meshPeers.count) mesh peers (new: \(newPeers.count))",
                        category: .session
                    )
                }
                scheduleNetworkResetTimer()
            }
        }

        let currentPeerIDs = Set(peers)
        for peerID in currentPeerIDs {
            viewModel.identityManager.registerEphemeralSession(peerID: peerID, handshakeState: .none)
            peerPresentationStore.cacheNoiseKeyMapping(for: peerID)
        }

        peerPresentationStore.refreshEncryptionStatuses(for: currentPeerIDs)

        if privateConversationsStore.hasSelectedPeerFingerprint {
            _ = privateConversationsStore.reconcileSelectedPeerForCurrentFingerprint()
        }
    }

    func handleConnected(_ peerID: PeerID) {
        guard let viewModel else { return }
        sessionStore.setConnected(true)
        viewModel.identityManager.registerEphemeralSession(peerID: peerID, handshakeState: .none)
        peerPresentationStore.cacheNoiseKeyMapping(for: peerID)
        viewModel.messageRouter.flushOutbox(for: peerID)
    }

    func handleDisconnected(_ peerID: PeerID) {
        guard let viewModel else { return }
        viewModel.identityManager.removeEphemeralSession(peerID: peerID)
        peerPresentationStore.clearEncryptionStatus(for: peerID)

        if let stableKeyHex = peerPresentationStore.stableNoiseKey(for: peerID) {
            privateConversationsStore.migrateSelectedPeerOnDisconnect(
                from: peerID,
                to: stableKeyHex,
                myPeerID: viewModel.meshService.myPeerID
            )
        }

        privateConversationsStore.clearSentReadReceipts(from: peerID)
    }

    func updateMessageDeliveryStatus(_ messageID: String, status: DeliveryStatus) {
        if let index = publicTimelineStore.visibleMessages.firstIndex(where: { $0.id == messageID }) {
            let currentStatus = publicTimelineStore.visibleMessages[index].deliveryStatus
            if !shouldSkipUpdate(currentStatus: currentStatus, newStatus: status) {
                _ = publicTimelineStore.updateMessage(id: messageID) { $0.withDeliveryStatus(status) }
            }
        }

        for (peerID, chatMessages) in privateConversationsStore.privateChats {
            guard let index = chatMessages.firstIndex(where: { $0.id == messageID }) else { continue }

            let currentStatus = chatMessages[index].deliveryStatus
            guard !shouldSkipUpdate(currentStatus: currentStatus, newStatus: status) else { continue }
            _ = privateConversationsStore.updateDeliveryStatus(status, forMessageID: messageID, in: peerID)
        }
    }

    func peerDisplayName(for peerID: PeerID) -> String {
        guard let viewModel else { return peerPresentationStore.displayName(for: peerID) }
        if let nickname = viewModel.unifiedPeerService.getPeer(by: peerID)?.nickname, !nickname.isEmpty {
            return nickname
        }
        return peerPresentationStore.displayName(for: peerID)
    }

    func shouldSkipUpdate(currentStatus: DeliveryStatus?, newStatus: DeliveryStatus) -> Bool {
        guard let current = currentStatus else { return false }

        switch current {
        case .read:
            switch newStatus {
            case .delivered, .sent:
                return true
            case .sending, .read, .failed, .partiallyDelivered:
                return false
            }
        case .sending, .sent, .delivered, .failed, .partiallyDelivered:
            return false
        }
    }

    func scheduleNetworkResetTimer() {
        networkResetTimer?.invalidate()
        networkResetTimer = Timer.scheduledTimer(withTimeInterval: TransportConfig.networkResetGraceSeconds, repeats: false) { [weak self] timer in
            Task { @MainActor [weak self] in
                self?.onNetworkResetTimerFired(timer)
            }
        }
    }

    func onNetworkResetTimerFired(_ timer: Timer) {
        guard let viewModel else {
            networkResetTimer = nil
            return
        }
        let activeMeshPeers = viewModel.meshService
            .currentPeerSnapshots()
            .filter { snapshot in
                snapshot.isConnected || viewModel.meshService.isPeerReachable(snapshot.peerID)
            }
        if activeMeshPeers.isEmpty {
            recentlySeenPeers.removeAll()
            SecureLogger.debug("⏱️ Network notification window reset after quiet period", category: .session)
        } else {
            SecureLogger.debug("⏱️ Skipped network notification reset; still seeing \(activeMeshPeers.count) mesh peers", category: .session)
        }
        networkResetTimer = nil
    }

    func scheduleNetworkEmptyTimer() {
        guard networkEmptyTimer == nil else { return }
        networkEmptyTimer = Timer.scheduledTimer(withTimeInterval: TransportConfig.uiMeshEmptyConfirmationSeconds, repeats: false) { [weak self] timer in
            Task { @MainActor [weak self] in
                self?.onNetworkEmptyTimerFired(timer)
            }
        }
        SecureLogger.debug("⏳ Mesh empty — waiting before resetting notification state", category: .session)
    }

    func invalidateNetworkEmptyTimer() {
        guard networkEmptyTimer != nil else { return }
        networkEmptyTimer?.invalidate()
        networkEmptyTimer = nil
    }

    func onNetworkEmptyTimerFired(_ timer: Timer) {
        guard let viewModel else {
            networkEmptyTimer = nil
            return
        }
        let activeMeshPeers = viewModel.meshService
            .currentPeerSnapshots()
            .filter { snapshot in
                snapshot.isConnected || viewModel.meshService.isPeerReachable(snapshot.peerID)
            }
        if activeMeshPeers.isEmpty {
            recentlySeenPeers.removeAll()
            SecureLogger.debug("⏳ Mesh empty — notification state reset after confirmation", category: .session)
        } else {
            SecureLogger.debug("⏳ Mesh empty timer cancelled; \(activeMeshPeers.count) mesh peers detected again", category: .session)
        }
        networkEmptyTimer = nil
    }
}
