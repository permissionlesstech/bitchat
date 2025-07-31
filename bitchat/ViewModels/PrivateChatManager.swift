import Foundation

/// Manages private chat state and utilities.
final class PrivateChatManager {
    unowned let viewModel: ChatViewModel

    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
    }

    // MARK: - Utilities
    func isPeerBlocked(_ peerID: String) -> Bool {
        if let fingerprint = viewModel.peerIDToPublicKeyFingerprint[peerID] {
            return SecureIdentityStateManager.shared.isBlocked(fingerprint: fingerprint)
        }
        if let fingerprint = viewModel.meshService.getPeerFingerprint(peerID) {
            return SecureIdentityStateManager.shared.isBlocked(fingerprint: fingerprint)
        }
        return false
    }

    private func getCurrentPeerIDForFingerprint(_ fingerprint: String) -> String? {
        for peerID in viewModel.connectedPeers {
            if let mapped = viewModel.peerIDToPublicKeyFingerprint[peerID], mapped == fingerprint {
                return peerID
            }
        }
        return nil
    }

    func updatePrivateChatPeerIfNeeded() {
        guard let chatFingerprint = viewModel.selectedPrivateChatFingerprint else { return }
        if let currentPeerID = getCurrentPeerIDForFingerprint(chatFingerprint) {
            if let oldPeerID = viewModel.selectedPrivateChatPeer, oldPeerID != currentPeerID {
                SecureLogger.log("📱 Updating private chat peer from \(oldPeerID) to \(currentPeerID)",
                                category: SecureLogger.session, level: .debug)
                if let oldMessages = viewModel.privateChats[oldPeerID] {
                    if viewModel.privateChats[currentPeerID] == nil {
                        viewModel.privateChats[currentPeerID] = []
                    }
                    viewModel.privateChats[currentPeerID]?.append(contentsOf: oldMessages)
                    viewModel.privateChats[currentPeerID]?.sort { $0.timestamp < $1.timestamp }
                    var seen = Set<String>()
                    viewModel.privateChats[currentPeerID] = viewModel.privateChats[currentPeerID]?.filter { msg in
                        if seen.contains(msg.id) { return false }
                        seen.insert(msg.id)
                        return true
                    }
                    trimPrivateChatMessagesIfNeeded(for: currentPeerID)
                    viewModel.privateChats.removeValue(forKey: oldPeerID)
                }
                if viewModel.unreadPrivateMessages.contains(oldPeerID) {
                    viewModel.unreadPrivateMessages.remove(oldPeerID)
                    viewModel.unreadPrivateMessages.insert(currentPeerID)
                }
                viewModel.selectedPrivateChatPeer = currentPeerID
                DispatchQueue.main.async { [weak viewModel] in
                    viewModel?.scheduleUIUpdate()
                }
                Task { @MainActor [weak viewModel] in
                    viewModel?.peerManager?.updatePeers()
                }
            } else if viewModel.selectedPrivateChatPeer == nil {
                viewModel.selectedPrivateChatPeer = currentPeerID
                DispatchQueue.main.async { [weak viewModel] in
                    viewModel?.scheduleUIUpdate()
                }
            }
            viewModel.unreadPrivateMessages.remove(currentPeerID)
        }
    }

    // MARK: - Chat lifecycle
    @MainActor
    func startPrivateChat(with peerID: String) {
        if peerID == viewModel.meshService.myPeerID {
            SecureLogger.log("⚠️ Attempted to start private chat with self, ignoring",
                            category: SecureLogger.session, level: .warning)
            return
        }
        let peerNickname = viewModel.meshService.getPeerNicknames()[peerID] ??
                          viewModel.peerIndex[peerID]?.displayName ??
                          "unknown"
        if isPeerBlocked(peerID) {
            let systemMessage = BitchatMessage(
                sender: "system",
                content: "cannot start chat with \(peerNickname): user is blocked.",
                timestamp: Date(),
                isRelay: false
            )
            viewModel.messages.append(systemMessage)
            return
        }
        if let peer = viewModel.peerIndex[peerID],
           peer.isFavorite && !peer.theyFavoritedUs && !peer.isConnected && !peer.isRelayConnected {
            let systemMessage = BitchatMessage(
                sender: "system",
                content: "cannot start chat with \(peerNickname): mutual favorite required for offline messaging.",
                timestamp: Date(),
                isRelay: false
            )
            viewModel.messages.append(systemMessage)
            return
        }
        let sessionState = viewModel.meshService.getNoiseSessionState(for: peerID)
        switch sessionState {
        case .none, .failed:
            viewModel.meshService.triggerHandshake(with: peerID)
        default:
            break
        }
        viewModel.selectedPrivateChatPeer = peerID
        viewModel.selectedPrivateChatFingerprint = viewModel.peerIDToPublicKeyFingerprint[peerID]
        viewModel.unreadPrivateMessages.remove(peerID)
        if viewModel.privateChats[peerID] == nil || viewModel.privateChats[peerID]?.isEmpty == true {
            let currentFingerprint = viewModel.getFingerprint(for: peerID)
            var migrated: [BitchatMessage] = []
            var removeIDs: [String] = []
            for (oldPeerID, messages) in viewModel.privateChats {
                if oldPeerID != peerID {
                    let oldFingerprint = viewModel.peerIDToPublicKeyFingerprint[oldPeerID]
                    if let currentFp = currentFingerprint, let oldFp = oldFingerprint, currentFp == oldFp {
                        migrated.append(contentsOf: messages)
                        removeIDs.append(oldPeerID)
                        SecureLogger.log("📦 Migrating \(messages.count) messages from old peer ID \(oldPeerID) to \(peerID) based on fingerprint match",
                                        category: SecureLogger.session, level: .info)
                    } else if currentFingerprint == nil || oldFingerprint == nil {
                        let messagesWithPeer = messages.filter { msg in
                            (msg.sender == peerNickname && msg.sender != viewModel.nickname) ||
                            (msg.sender == viewModel.nickname && (msg.recipientNickname == peerNickname ||
                             (msg.isPrivate && messages.allSatisfy { m in m.sender == viewModel.nickname || m.sender == peerNickname })) )
                        }
                        if !messagesWithPeer.isEmpty {
                            let allMessagesAreWithPeer = messages.allSatisfy { msg in
                                (msg.sender == peerNickname || msg.sender == viewModel.nickname) &&
                                (msg.recipientNickname == nil || msg.recipientNickname == peerNickname || msg.recipientNickname == viewModel.nickname)
                            }
                            if allMessagesAreWithPeer {
                                migrated.append(contentsOf: messages)
                                removeIDs.append(oldPeerID)
                                SecureLogger.log("📦 Migrating \(messages.count) messages from old peer ID \(oldPeerID) to \(peerID) based on nickname match (no fingerprints available)",
                                                category: SecureLogger.session, level: .warning)
                            }
                        }
                    }
                }
            }
            for old in removeIDs {
                viewModel.privateChats.removeValue(forKey: old)
                viewModel.unreadPrivateMessages.remove(old)
            }
            if !migrated.isEmpty {
                viewModel.privateChats[peerID] = migrated.sorted { $0.timestamp < $1.timestamp }
                trimPrivateChatMessagesIfNeeded(for: peerID)
            } else {
                viewModel.privateChats[peerID] = []
            }
        }
        _ = viewModel.privateChats[peerID] ?? []
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.markPrivateMessagesAsRead(from: peerID)
        }
        markPrivateMessagesAsRead(from: peerID)
    }

    func endPrivateChat() {
        viewModel.selectedPrivateChatPeer = nil
        viewModel.selectedPrivateChatFingerprint = nil
    }

    // MARK: - Read receipts
    @MainActor
    func markPrivateMessagesAsRead(from peerID: String) {
        let peerNickname = viewModel.meshService.getPeerNicknames()[peerID] ?? ""
        guard let messages = viewModel.privateChats[peerID], !messages.isEmpty else { return }
        var readReceiptsSent = 0
        for message in messages {
            let isOurMessage = message.sender == viewModel.nickname
            let isFromPeerByNickname = !peerNickname.isEmpty && message.sender == peerNickname
            var isFromPeerByID = false
            if let msgSenderID = message.senderPeerID {
                isFromPeerByID = msgSenderID == peerID
                if !isFromPeerByID {
                    if let noiseKey = Data(hexString: peerID),
                       let favoriteStatus = FavoritesPersistenceService.shared.getFavoriteStatus(for: noiseKey),
                       let nostrKey = favoriteStatus.peerNostrPublicKey {
                        isFromPeerByID = msgSenderID == nostrKey
                    }
                }
            }
            let isPrivateToUs = message.isPrivate && message.recipientNickname == viewModel.nickname
            let isFromPeer = !isOurMessage && (isFromPeerByNickname || isFromPeerByID || isPrivateToUs)
            if isFromPeer {
                if let status = message.deliveryStatus {
                    switch status {
                    case .sent, .delivered:
                        if !viewModel.sentReadReceipts.contains(message.id) {
                            let receipt = ReadReceipt(
                                originalMessageID: message.id,
                                readerID: viewModel.meshService.myPeerID,
                                readerNickname: viewModel.nickname
                            )
                            let recipientID = message.senderPeerID ?? peerID
                            var originalTransport: String? = nil
                            if case .delivered(let transport, _) = status {
                                originalTransport = transport
                            }
                            viewModel.sendReadReceipt(receipt, to: recipientID, originalTransport: originalTransport)
                            viewModel.sentReadReceipts.insert(message.id)
                            readReceiptsSent += 1
                        }
                    case .read:
                        break
                    default:
                        break
                    }
                } else {
                    if !viewModel.sentReadReceipts.contains(message.id) {
                        let receipt = ReadReceipt(
                            originalMessageID: message.id,
                            readerID: viewModel.meshService.myPeerID,
                            readerNickname: viewModel.nickname
                        )
                        let recipientID = message.senderPeerID ?? peerID
                        Task { @MainActor in
                            var originalTransport: String? = nil
                            if let noiseKey = Data(hexString: recipientID),
                               let favoriteStatus = FavoritesPersistenceService.shared.getFavoriteStatus(for: noiseKey),
                               favoriteStatus.peerNostrPublicKey != nil,
                               viewModel.meshService.getPeerNicknames()[recipientID] == nil {
                                originalTransport = "nostr"
                            }
                            self.viewModel.sendReadReceipt(receipt, to: recipientID, originalTransport: originalTransport)
                        }
                        viewModel.sentReadReceipts.insert(message.id)
                        readReceiptsSent += 1
                    }
                }
            }
        }
    }

    func getPrivateChatMessages(for peerID: String) -> [BitchatMessage] {
        return viewModel.privateChats[peerID] ?? []
    }

    private func trimPrivateChatMessagesIfNeeded(for peerID: String) {
        if let count = viewModel.privateChats[peerID]?.count, count > viewModel.maxMessages {
            let removeCount = count - viewModel.maxMessages
            viewModel.privateChats[peerID]?.removeFirst(removeCount)
        }
    }
}
