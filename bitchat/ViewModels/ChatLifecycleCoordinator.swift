import BitFoundation
import BitLogger
import Foundation

@MainActor
final class ChatLifecycleCoordinator {
    private unowned let viewModel: ChatViewModel

    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
    }

    func handleDidBecomeActive() {
        if let bleService = viewModel.meshService as? BLEService {
            let currentState = bleService.getCurrentBluetoothState()
            viewModel.updateBluetoothState(currentState)
        }

        guard let peerID = viewModel.selectedPrivateChatPeer else { return }

        markPrivateMessagesAsRead(from: peerID)

        let viewModel = self.viewModel
        DispatchQueue.main.asyncAfter(deadline: .now() + TransportConfig.uiAnimationMediumSeconds) { [weak viewModel] in
            Task { @MainActor in
                viewModel?.markPrivateMessagesAsRead(from: peerID)
            }
        }
    }

    func handleScreenshotCaptured() {
        let screenshotMessage = "* \(viewModel.nickname) took a screenshot *"

        if let peerID = viewModel.selectedPrivateChatPeer {
            sendPrivateScreenshotNotificationIfPossible(
                screenshotMessage,
                to: peerID
            )
            appendPrivateScreenshotNotice(for: peerID)
            return
        }

        switch viewModel.activeChannel {
        case .mesh:
            viewModel.meshService.sendMessage(
                screenshotMessage,
                mentions: [],
                messageID: UUID().uuidString,
                timestamp: Date()
            )

        case .location(let channel):
            sendPublicGeohashScreenshotMessage(
                screenshotMessage,
                channel: channel
            )
        }

        viewModel.addSystemMessage("you took a screenshot")
    }

    func saveIdentityState() {
        viewModel.identityManager.forceSave()
        _ = viewModel.keychain.verifyIdentityKeyExists()
    }

    func applicationWillTerminate() {
        viewModel.meshService.stopServices()
        saveIdentityState()
    }

    func markPrivateMessagesAsRead(from peerID: PeerID) {
        viewModel.privateChatManager.markAsRead(from: peerID)
        viewModel.synchronizePrivateConversationStore()

        if peerID.isGeoDM,
           let recipientHex = viewModel.nostrKeyMapping[peerID],
           case .location(let channel) = viewModel.activeChannel,
           let identity = try? viewModel.idBridge.deriveIdentity(forGeohash: channel.geohash) {
            let messages = viewModel.privateChats[peerID] ?? []
            for message in messages where message.senderPeerID == peerID && !message.isRelay {
                guard !viewModel.sentReadReceipts.contains(message.id) else { continue }

                SecureLogger.debug(
                    "GeoDM: sending READ for mid=\(message.id.prefix(8))… to=\(recipientHex.prefix(8))…",
                    category: .session
                )
                let nostrTransport = NostrTransport(keychain: viewModel.keychain, idBridge: viewModel.idBridge)
                nostrTransport.senderPeerID = viewModel.meshService.myPeerID
                nostrTransport.sendReadReceiptGeohash(
                    message.id,
                    toRecipientHex: recipientHex,
                    from: identity
                )
                viewModel.sentReadReceipts.insert(message.id)
            }
            return
        }

        var noiseKeyHex: PeerID?
        var peerNostrPubkey: String?

        if let noiseKey = Data(hexString: peerID.id),
           let favoriteStatus = FavoritesPersistenceService.shared.getFavoriteStatus(for: noiseKey) {
            noiseKeyHex = peerID
            peerNostrPubkey = favoriteStatus.peerNostrPublicKey
        } else if let peer = viewModel.unifiedPeerService.getPeer(by: peerID) {
            noiseKeyHex = PeerID(hexData: peer.noisePublicKey)
            let favoriteStatus = FavoritesPersistenceService.shared.getFavoriteStatus(for: peer.noisePublicKey)
            peerNostrPubkey = favoriteStatus?.peerNostrPublicKey

            if let noiseKeyHex, viewModel.unreadPrivateMessages.contains(noiseKeyHex) {
                viewModel.unreadPrivateMessages.remove(noiseKeyHex)
            }
        }

        guard peerNostrPubkey != nil else { return }

        for message in getPrivateChatMessages(for: peerID) {
            guard (message.senderPeerID == peerID || message.senderPeerID == noiseKeyHex) && !message.isRelay else {
                continue
            }

            guard !viewModel.sentReadReceipts.contains(message.id) else { continue }

            let receipt = ReadReceipt(
                originalMessageID: message.id,
                readerID: viewModel.meshService.myPeerID,
                readerNickname: viewModel.nickname
            )
            let recipientPeerID = peerID.isHex
                ? peerID
                : (viewModel.unifiedPeerService.getPeer(by: peerID)?.peerID ?? peerID)

            viewModel.messageRouter.sendReadReceipt(receipt, to: recipientPeerID)
            viewModel.sentReadReceipts.insert(message.id)
        }
    }

    func getMessages(for peerID: PeerID?) -> [BitchatMessage] {
        guard let peerID else { return viewModel.messages }
        return getPrivateChatMessages(for: peerID)
    }

    func getPrivateChatMessages(for peerID: PeerID) -> [BitchatMessage] {
        var combined: [BitchatMessage] = []

        if let ephemeralMessages = viewModel.privateChats[peerID] {
            combined.append(contentsOf: ephemeralMessages)
        }

        if let peer = viewModel.unifiedPeerService.getPeer(by: peerID) {
            let noiseKeyHex = PeerID(hexData: peer.noisePublicKey)
            if noiseKeyHex != peerID, let stableMessages = viewModel.privateChats[noiseKeyHex] {
                combined.append(contentsOf: stableMessages)
            }
        }

        var bestByID: [String: BitchatMessage] = [:]
        for message in combined {
            if let existing = bestByID[message.id] {
                let existingRank = deliveryStatusRank(existing.deliveryStatus)
                let candidateRank = deliveryStatusRank(message.deliveryStatus)
                if candidateRank > existingRank || (candidateRank == existingRank && message.timestamp > existing.timestamp) {
                    bestByID[message.id] = message
                }
            } else {
                bestByID[message.id] = message
            }
        }

        return bestByID.values.sorted { $0.timestamp < $1.timestamp }
    }
}

private extension ChatLifecycleCoordinator {
    func sendPrivateScreenshotNotificationIfPossible(_ message: String, to peerID: PeerID) {
        guard let peerNickname = viewModel.meshService.peerNickname(peerID: peerID) else { return }

        let sessionState = viewModel.meshService.getNoiseSessionState(for: peerID)
        switch sessionState {
        case .established:
            viewModel.messageRouter.sendPrivate(
                message,
                to: peerID,
                recipientNickname: peerNickname,
                messageID: UUID().uuidString
            )

        case .none, .failed, .handshakeQueued, .handshaking:
            SecureLogger.debug(
                "Skipping screenshot notification to \(peerID) - no established session",
                category: .security
            )
        }
    }

    func appendPrivateScreenshotNotice(for peerID: PeerID) {
        let notice = BitchatMessage(
            sender: "system",
            content: "you took a screenshot",
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: true,
            recipientNickname: viewModel.meshService.peerNickname(peerID: peerID),
            senderPeerID: viewModel.meshService.myPeerID
        )

        var chats = viewModel.privateChats
        if chats[peerID] == nil {
            chats[peerID] = []
        }
        chats[peerID]?.append(notice)
        viewModel.privateChats = chats
    }

    func sendPublicGeohashScreenshotMessage(_ message: String, channel: GeohashChannel) {
        Task { @MainActor [weak viewModel] in
            guard let viewModel else { return }

            do {
                let identity = try viewModel.idBridge.deriveIdentity(forGeohash: channel.geohash)
                let event = try NostrProtocol.createEphemeralGeohashEvent(
                    content: message,
                    geohash: channel.geohash,
                    senderIdentity: identity,
                    nickname: viewModel.nickname,
                    teleported: viewModel.locationManager.teleported
                )

                let targetRelays = GeoRelayDirectory.shared.closestRelays(toGeohash: channel.geohash, count: 5)
                if targetRelays.isEmpty {
                    SecureLogger.warning("Geo: no geohash relays available for \(channel.geohash); not sending", category: .session)
                } else {
                    NostrRelayManager.shared.sendEvent(event, to: targetRelays)
                }

                viewModel.participantTracker.recordParticipant(pubkeyHex: identity.publicKeyHex)
            } catch {
                SecureLogger.error("❌ Failed to send geohash screenshot message: \(error)", category: .session)
                viewModel.addSystemMessage(
                    String(localized: "system.location.send_failed", comment: "System message when a location channel send fails")
                )
            }
        }
    }

    func deliveryStatusRank(_ status: DeliveryStatus?) -> Int {
        guard let status else { return 0 }
        switch status {
        case .failed: return 1
        case .sending: return 2
        case .sent: return 3
        case .partiallyDelivered: return 4
        case .delivered: return 5
        case .read: return 6
        }
    }
}
