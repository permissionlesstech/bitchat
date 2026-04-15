import BitFoundation
import BitLogger
import Foundation

final class ChatTransportEventCoordinator {
    private unowned let viewModel: ChatViewModel

    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
    }

    func didReceiveMessage(_ message: BitchatMessage) {
        runOnMain { viewModel in
            guard !viewModel.isMessageBlocked(message) else { return }
            guard !message.content.trimmed.isEmpty || message.isPrivate else { return }

            if message.isPrivate {
                viewModel.handlePrivateMessage(message)
            } else {
                viewModel.handlePublicMessage(message)
            }

            viewModel.checkForMentions(message)
            viewModel.sendHapticFeedback(for: message)
        }
    }

    func didReceivePublicMessage(
        from peerID: PeerID,
        nickname: String,
        content: String,
        timestamp: Date,
        messageID: String?
    ) {
        runOnMain { viewModel in
            let normalized = content.trimmed
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
    }

    func didReceiveNoisePayload(
        from peerID: PeerID,
        type: NoisePayloadType,
        payload: Data,
        timestamp: Date
    ) {
        runOnMain { [self] viewModel in
            handleNoisePayload(
                from: peerID,
                type: type,
                payload: payload,
                timestamp: timestamp,
                in: viewModel
            )
        }
    }

    func didConnectToPeer(_ peerID: PeerID) {
        SecureLogger.debug("🤝 Peer connected: \(peerID)", category: .session)

        runOnMain { viewModel in
            viewModel.isConnected = true
            viewModel.identityManager.registerEphemeralSession(peerID: peerID, handshakeState: .none)
            viewModel.objectWillChange.send()

            if let peer = viewModel.unifiedPeerService.getPeer(by: peerID) {
                let stablePeerID = PeerID(hexData: peer.noisePublicKey)
                viewModel.cacheStablePeerID(stablePeerID, for: peerID)
            }

            viewModel.messageRouter.flushOutbox(for: peerID)
        }
    }

    func didDisconnectFromPeer(_ peerID: PeerID) {
        SecureLogger.debug("👋 Peer disconnected: \(peerID)", category: .session)

        runOnMain { viewModel in
            viewModel.identityManager.removeEphemeralSession(peerID: peerID)

            var stablePeerID = viewModel.cachedStablePeerID(for: peerID)
            if stablePeerID == nil,
               let key = viewModel.meshService.getNoiseService().getPeerPublicKeyData(peerID) {
                let derivedPeerID = PeerID(hexData: key)
                viewModel.cacheStablePeerID(derivedPeerID, for: peerID)
                stablePeerID = derivedPeerID
            }

            if let currentPeerID = viewModel.selectedPrivateChatPeer,
               currentPeerID == peerID,
               let stablePeerID {
                self.migrateSelectedConversationIfNeeded(
                    from: peerID,
                    to: stablePeerID,
                    in: viewModel
                )
            }

            if let messages = viewModel.privateChats[peerID] {
                for message in messages where message.senderPeerID == peerID {
                    viewModel.sentReadReceipts.remove(message.id)
                }
            }

            viewModel.objectWillChange.send()
        }
    }
}

private extension ChatTransportEventCoordinator {
    func runOnMain(_ action: @escaping @MainActor (ChatViewModel) -> Void) {
        Task { @MainActor [weak viewModel = self.viewModel] in
            guard let viewModel else { return }
            action(viewModel)
        }
    }

    @MainActor
    func migrateSelectedConversationIfNeeded(
        from shortPeerID: PeerID,
        to stablePeerID: PeerID,
        in viewModel: ChatViewModel
    ) {
        if let messages = viewModel.privateChats[shortPeerID] {
            if viewModel.privateChats[stablePeerID] == nil {
                viewModel.privateChats[stablePeerID] = []
            }

            let existingIDs = Set(viewModel.privateChats[stablePeerID]?.map(\.id) ?? [])
            for message in messages where !existingIDs.contains(message.id) {
                let migrated = BitchatMessage(
                    id: message.id,
                    sender: message.sender,
                    content: message.content,
                    timestamp: message.timestamp,
                    isRelay: message.isRelay,
                    originalSender: message.originalSender,
                    isPrivate: message.isPrivate,
                    recipientNickname: message.recipientNickname,
                    senderPeerID: message.senderPeerID == viewModel.meshService.myPeerID
                        ? viewModel.meshService.myPeerID
                        : stablePeerID,
                    mentions: message.mentions,
                    deliveryStatus: message.deliveryStatus
                )
                viewModel.privateChats[stablePeerID]?.append(migrated)
            }

            viewModel.privateChats[stablePeerID]?.sort { $0.timestamp < $1.timestamp }
            viewModel.privateChats.removeValue(forKey: shortPeerID)
        }

        if viewModel.unreadPrivateMessages.contains(shortPeerID) {
            viewModel.unreadPrivateMessages.remove(shortPeerID)
            viewModel.unreadPrivateMessages.insert(stablePeerID)
        }

        viewModel.selectedPrivateChatPeer = stablePeerID
    }

    @MainActor
    func handleNoisePayload(
        from peerID: PeerID,
        type: NoisePayloadType,
        payload: Data,
        timestamp: Date,
        in viewModel: ChatViewModel
    ) {
        switch type {
        case .privateMessage:
            guard let packet = PrivateMessagePacket.decode(from: payload) else { return }

            guard !viewModel.isPeerBlocked(peerID) else {
                SecureLogger.debug("🚫 Ignoring Noise payload from blocked peer: \(peerID)", category: .security)
                return
            }

            let senderName = viewModel.unifiedPeerService.getPeer(by: peerID)?.nickname ?? "Unknown"
            let mentions = viewModel.parseMentions(from: packet.content)
            let message = BitchatMessage(
                id: packet.messageID,
                sender: senderName,
                content: packet.content,
                timestamp: timestamp,
                isRelay: false,
                originalSender: nil,
                isPrivate: true,
                recipientNickname: viewModel.nickname,
                senderPeerID: peerID,
                mentions: mentions.isEmpty ? nil : mentions
            )
            viewModel.handlePrivateMessage(message)
            viewModel.meshService.sendDeliveryAck(for: packet.messageID, to: peerID)

        case .delivered:
            guard let messageID = String(data: payload, encoding: .utf8),
                  let name = viewModel.unifiedPeerService.getPeer(by: peerID)?.nickname,
                  let (foundPeerID, index) = findMessageIndex(
                    for: messageID,
                    peerID: peerID,
                    in: viewModel
                  ) else { return }

            if case .read = viewModel.privateChats[foundPeerID]?[index].deliveryStatus { return }

            viewModel.privateChats[foundPeerID]?[index].deliveryStatus = .delivered(to: name, at: Date())
            viewModel.objectWillChange.send()

        case .readReceipt:
            guard let messageID = String(data: payload, encoding: .utf8),
                  let name = viewModel.unifiedPeerService.getPeer(by: peerID)?.nickname,
                  let (foundPeerID, index) = findMessageIndex(
                    for: messageID,
                    peerID: peerID,
                    in: viewModel
                  ),
                  let messages = viewModel.privateChats[foundPeerID],
                  index < messages.count else { return }

            messages[index].deliveryStatus = .read(by: name, at: Date())
            viewModel.privateChats[foundPeerID] = messages
            viewModel.privateChatManager.objectWillChange.send()
            viewModel.objectWillChange.send()

        case .verifyChallenge:
            viewModel.verificationCoordinator.handleVerifyChallengePayload(from: peerID, payload: payload)

        case .verifyResponse:
            viewModel.verificationCoordinator.handleVerifyResponsePayload(from: peerID, payload: payload)
        }
    }

    @MainActor
    func findMessageIndex(
        for messageID: String,
        peerID: PeerID,
        in viewModel: ChatViewModel
    ) -> (peerID: PeerID, index: Int)? {
        if let messages = viewModel.privateChats[peerID],
           let index = messages.firstIndex(where: { $0.id == messageID }) {
            return (peerID, index)
        }

        if peerID.bare.count == 16,
           let peer = viewModel.unifiedPeerService.getPeer(by: peerID),
           !peer.noisePublicKey.isEmpty {
            let longID = PeerID(hexData: peer.noisePublicKey)
            if let messages = viewModel.privateChats[longID],
               let index = messages.firstIndex(where: { $0.id == messageID }) {
                return (longID, index)
            }
        }

        if peerID.bare.count == 64 {
            let shortID = peerID.toShort()
            if let messages = viewModel.privateChats[shortID],
               let index = messages.firstIndex(where: { $0.id == messageID }) {
                return (shortID, index)
            }
        }

        return nil
    }
}
