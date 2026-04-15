import BitFoundation
import BitLogger
import Foundation

@MainActor
final class ChatPrivateConversationCoordinator {
    private unowned let viewModel: ChatViewModel

    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
    }

    func sendPrivateMessage(_ content: String, to peerID: PeerID) {
        guard !content.isEmpty else { return }

        if viewModel.unifiedPeerService.isBlocked(peerID) {
            let nickname = viewModel.meshService.peerNickname(peerID: peerID) ?? "user"
            viewModel.addSystemMessage(
                String(
                    format: String(localized: "system.dm.blocked_recipient", comment: "System message when attempting to message a blocked user"),
                    locale: .current,
                    nickname
                )
            )
            return
        }

        if peerID.isGeoDM {
            sendGeohashDM(content, to: peerID)
            return
        }

        guard let noiseKey = Data(hexString: peerID.id) else { return }
        let isConnected = viewModel.meshService.isPeerConnected(peerID)
        let isReachable = viewModel.meshService.isPeerReachable(peerID)
        let favoriteStatus = FavoritesPersistenceService.shared.getFavoriteStatus(for: noiseKey)
        let isMutualFavorite = favoriteStatus?.isMutual ?? false
        let hasNostrKey = favoriteStatus?.peerNostrPublicKey != nil

        var recipientNickname = viewModel.meshService.peerNickname(peerID: peerID)
        if recipientNickname == nil && favoriteStatus != nil {
            recipientNickname = favoriteStatus?.peerNickname
        }
        recipientNickname = recipientNickname ?? "user"

        let messageID = UUID().uuidString
        let message = BitchatMessage(
            id: messageID,
            sender: viewModel.nickname,
            content: content,
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: true,
            recipientNickname: recipientNickname,
            senderPeerID: viewModel.meshService.myPeerID,
            mentions: nil,
            deliveryStatus: .sending
        )

        if viewModel.privateChats[peerID] == nil {
            viewModel.privateChats[peerID] = []
        }
        viewModel.privateChats[peerID]?.append(message)
        viewModel.objectWillChange.send()

        if isConnected || isReachable || (isMutualFavorite && hasNostrKey) {
            viewModel.messageRouter.sendPrivate(
                content,
                to: peerID,
                recipientNickname: recipientNickname ?? "user",
                messageID: messageID
            )
            if let idx = viewModel.privateChats[peerID]?.firstIndex(where: { $0.id == messageID }) {
                viewModel.privateChats[peerID]?[idx].deliveryStatus = .sent
            }
        } else {
            if let index = viewModel.privateChats[peerID]?.firstIndex(where: { $0.id == messageID }) {
                viewModel.privateChats[peerID]?[index].deliveryStatus = .failed(
                    reason: String(localized: "content.delivery.reason.unreachable", comment: "Failure reason when a peer is unreachable")
                )
            }
            let name = recipientNickname ?? "user"
            viewModel.addSystemMessage(
                String(
                    format: String(localized: "system.dm.unreachable", comment: "System message when a recipient is unreachable"),
                    locale: .current,
                    name
                )
            )
        }
    }

    func sendGeohashDM(_ content: String, to peerID: PeerID) {
        guard case .location(let channel) = viewModel.activeChannel else {
            viewModel.addSystemMessage(
                String(localized: "system.location.not_in_channel", comment: "System message when attempting to send without being in a location channel")
            )
            return
        }

        let messageID = UUID().uuidString
        let message = BitchatMessage(
            id: messageID,
            sender: viewModel.nickname,
            content: content,
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: viewModel.nickname,
            senderPeerID: viewModel.meshService.myPeerID,
            deliveryStatus: .sending
        )

        if viewModel.privateChats[peerID] == nil {
            viewModel.privateChats[peerID] = []
        }

        viewModel.privateChats[peerID]?.append(message)
        viewModel.objectWillChange.send()

        guard let recipientHex = viewModel.nostrKeyMapping[peerID] else {
            if let msgIdx = viewModel.privateChats[peerID]?.firstIndex(where: { $0.id == messageID }) {
                viewModel.privateChats[peerID]?[msgIdx].deliveryStatus = .failed(
                    reason: String(localized: "content.delivery.reason.unknown_recipient", comment: "Failure reason when the recipient is unknown")
                )
            }
            return
        }

        if viewModel.identityManager.isNostrBlocked(pubkeyHexLowercased: recipientHex) {
            if let msgIdx = viewModel.privateChats[peerID]?.firstIndex(where: { $0.id == messageID }) {
                viewModel.privateChats[peerID]?[msgIdx].deliveryStatus = .failed(
                    reason: String(localized: "content.delivery.reason.blocked", comment: "Failure reason when the user is blocked")
                )
            }
            viewModel.addSystemMessage(
                String(localized: "system.dm.blocked_generic", comment: "System message when sending fails because user is blocked")
            )
            return
        }

        do {
            let identity = try viewModel.idBridge.deriveIdentity(forGeohash: channel.geohash)
            if recipientHex.lowercased() == identity.publicKeyHex.lowercased() {
                if let idx = viewModel.privateChats[peerID]?.firstIndex(where: { $0.id == messageID }) {
                    viewModel.privateChats[peerID]?[idx].deliveryStatus = .failed(
                        reason: String(localized: "content.delivery.reason.self", comment: "Failure reason when attempting to message yourself")
                    )
                }
                return
            }

            SecureLogger.debug(
                "GeoDM: local send mid=\(messageID.prefix(8))… to=\(recipientHex.prefix(8))… conv=\(peerID)",
                category: .session
            )
            let transport = NostrTransport(keychain: viewModel.keychain, idBridge: viewModel.idBridge)
            transport.senderPeerID = viewModel.meshService.myPeerID
            transport.sendPrivateMessageGeohash(
                content: content,
                toRecipientHex: recipientHex,
                from: identity,
                messageID: messageID
            )
            if let msgIdx = viewModel.privateChats[peerID]?.firstIndex(where: { $0.id == messageID }) {
                viewModel.privateChats[peerID]?[msgIdx].deliveryStatus = .sent
            }
        } catch {
            if let idx = viewModel.privateChats[peerID]?.firstIndex(where: { $0.id == messageID }) {
                viewModel.privateChats[peerID]?[idx].deliveryStatus = .failed(
                    reason: String(localized: "content.delivery.reason.send_error", comment: "Failure reason for a generic send error")
                )
            }
        }
    }

    func handlePrivateMessage(
        _ payload: NoisePayload,
        senderPubkey: String,
        convKey: PeerID,
        id: NostrIdentity,
        messageTimestamp: Date
    ) {
        guard let pm = PrivateMessagePacket.decode(from: payload.data) else { return }
        let messageId = pm.messageID

        SecureLogger.info("GeoDM: recv PM <- sender=\(senderPubkey.prefix(8))… mid=\(messageId.prefix(8))…", category: .session)

        sendDeliveryAckIfNeeded(to: messageId, senderPubKey: senderPubkey, from: id)

        if viewModel.identityManager.isNostrBlocked(pubkeyHexLowercased: senderPubkey) {
            return
        }

        if viewModel.privateChats[convKey]?.contains(where: { $0.id == messageId }) == true { return }
        for (_, arr) in viewModel.privateChats where arr.contains(where: { $0.id == messageId }) {
            return
        }

        let senderName = viewModel.displayNameForNostrPubkey(senderPubkey)
        let message = BitchatMessage(
            id: messageId,
            sender: senderName,
            content: pm.content,
            timestamp: messageTimestamp,
            isRelay: false,
            isPrivate: true,
            recipientNickname: viewModel.nickname,
            senderPeerID: convKey,
            deliveryStatus: .delivered(to: viewModel.nickname, at: Date())
        )

        if viewModel.privateChats[convKey] == nil {
            viewModel.privateChats[convKey] = []
        }
        viewModel.privateChats[convKey]?.append(message)

        let isViewing = viewModel.selectedPrivateChatPeer == convKey
        let wasReadBefore = viewModel.sentReadReceipts.contains(messageId)
        let isRecentMessage = Date().timeIntervalSince(messageTimestamp) < 30
        let shouldMarkUnread = !wasReadBefore && !isViewing && isRecentMessage
        if shouldMarkUnread {
            viewModel.unreadPrivateMessages.insert(convKey)
        }

        if isViewing {
            sendReadReceiptIfNeeded(to: messageId, senderPubKey: senderPubkey, from: id)
        }

        if !isViewing && shouldMarkUnread {
            NotificationService.shared.sendPrivateMessageNotification(
                from: senderName,
                message: pm.content,
                peerID: convKey
            )
        }

        viewModel.objectWillChange.send()
    }

    func handleDelivered(_ payload: NoisePayload, senderPubkey: String, convKey: PeerID) {
        guard let messageID = String(data: payload.data, encoding: .utf8) else { return }

        if let idx = viewModel.privateChats[convKey]?.firstIndex(where: { $0.id == messageID }) {
            viewModel.privateChats[convKey]?[idx].deliveryStatus = .delivered(
                to: viewModel.displayNameForNostrPubkey(senderPubkey),
                at: Date()
            )
            viewModel.objectWillChange.send()
            SecureLogger.info(
                "GeoDM: recv DELIVERED for mid=\(messageID.prefix(8))… from=\(senderPubkey.prefix(8))…",
                category: .session
            )
        } else {
            SecureLogger.warning("GeoDM: delivered ack for unknown mid=\(messageID.prefix(8))… conv=\(convKey)", category: .session)
        }
    }

    func handleReadReceipt(_ payload: NoisePayload, senderPubkey: String, convKey: PeerID) {
        guard let messageID = String(data: payload.data, encoding: .utf8) else { return }

        if let idx = viewModel.privateChats[convKey]?.firstIndex(where: { $0.id == messageID }) {
            viewModel.privateChats[convKey]?[idx].deliveryStatus = .read(
                by: viewModel.displayNameForNostrPubkey(senderPubkey),
                at: Date()
            )
            viewModel.objectWillChange.send()
            SecureLogger.info("GeoDM: recv READ for mid=\(messageID.prefix(8))… from=\(senderPubkey.prefix(8))…", category: .session)
        } else {
            SecureLogger.warning("GeoDM: read ack for unknown mid=\(messageID.prefix(8))… conv=\(convKey)", category: .session)
        }
    }

    func sendDeliveryAckIfNeeded(to messageId: String, senderPubKey: String, from id: NostrIdentity) {
        guard !viewModel.sentGeoDeliveryAcks.contains(messageId) else { return }
        let transport = NostrTransport(keychain: viewModel.keychain, idBridge: viewModel.idBridge)
        transport.senderPeerID = viewModel.meshService.myPeerID
        transport.sendDeliveryAckGeohash(for: messageId, toRecipientHex: senderPubKey, from: id)
        viewModel.sentGeoDeliveryAcks.insert(messageId)
    }

    func sendReadReceiptIfNeeded(to messageId: String, senderPubKey: String, from id: NostrIdentity) {
        guard !viewModel.sentReadReceipts.contains(messageId) else { return }
        let transport = NostrTransport(keychain: viewModel.keychain, idBridge: viewModel.idBridge)
        transport.senderPeerID = viewModel.meshService.myPeerID
        transport.sendReadReceiptGeohash(messageId, toRecipientHex: senderPubKey, from: id)
        viewModel.sentReadReceipts.insert(messageId)
    }

    func handlePrivateMessage(
        _ payload: NoisePayload,
        actualSenderNoiseKey: Data?,
        senderNickname: String,
        targetPeerID: PeerID,
        messageTimestamp: Date,
        senderPubkey: String
    ) {
        guard let pm = PrivateMessagePacket.decode(from: payload.data) else { return }
        let messageId = pm.messageID
        let messageContent = pm.content

        if messageContent.hasPrefix("[FAVORITED]") || messageContent.hasPrefix("[UNFAVORITED]") {
            if let key = actualSenderNoiseKey {
                handleFavoriteNotificationFromMesh(
                    messageContent,
                    from: PeerID(hexData: key),
                    senderNickname: senderNickname
                )
            }
            return
        }

        if isDuplicateMessage(messageId, targetPeerID: targetPeerID) {
            return
        }

        let wasReadBefore = viewModel.sentReadReceipts.contains(messageId)

        var isViewingThisChat = false
        if viewModel.selectedPrivateChatPeer == targetPeerID {
            isViewingThisChat = true
        } else if let selectedPeer = viewModel.selectedPrivateChatPeer,
                  let selectedPeerData = viewModel.unifiedPeerService.getPeer(by: selectedPeer),
                  let key = actualSenderNoiseKey,
                  selectedPeerData.noisePublicKey == key {
            isViewingThisChat = true
        }

        let isRecentMessage = Date().timeIntervalSince(messageTimestamp) < 30
        let shouldMarkAsUnread = !wasReadBefore && !isViewingThisChat && isRecentMessage

        let message = BitchatMessage(
            id: messageId,
            sender: senderNickname,
            content: messageContent,
            timestamp: messageTimestamp,
            isRelay: false,
            isPrivate: true,
            recipientNickname: viewModel.nickname,
            senderPeerID: targetPeerID,
            deliveryStatus: .delivered(to: viewModel.nickname, at: Date())
        )

        addMessageToPrivateChatsIfNeeded(message, targetPeerID: targetPeerID)
        mirrorToEphemeralIfNeeded(message, targetPeerID: targetPeerID, key: actualSenderNoiseKey)

        viewModel.sendDeliveryAckViaNostrEmbedded(
            message,
            wasReadBefore: wasReadBefore,
            senderPubkey: senderPubkey,
            key: actualSenderNoiseKey
        )

        if wasReadBefore {
            // No-op.
        } else if isViewingThisChat {
            handleViewingThisChat(
                message,
                targetPeerID: targetPeerID,
                key: actualSenderNoiseKey,
                senderPubkey: senderPubkey
            )
        } else {
            markAsUnreadIfNeeded(
                shouldMarkAsUnread: shouldMarkAsUnread,
                targetPeerID: targetPeerID,
                key: actualSenderNoiseKey,
                isRecentMessage: isRecentMessage,
                senderNickname: senderNickname,
                messageContent: messageContent
            )
        }

        viewModel.objectWillChange.send()
    }

    func handlePrivateMessage(_ message: BitchatMessage) {
        SecureLogger.debug("📥 handlePrivateMessage called for message from \(message.sender)", category: .session)
        let senderPeerID = message.senderPeerID ?? viewModel.getPeerIDForNickname(message.sender)

        guard let peerID = senderPeerID else {
            SecureLogger.warning("⚠️ Could not get peer ID for sender \(message.sender)", category: .session)
            return
        }

        if message.content.hasPrefix("[FAVORITED]") || message.content.hasPrefix("[UNFAVORITED]") {
            handleFavoriteNotificationFromMesh(message.content, from: peerID, senderNickname: message.sender)
            return
        }

        migratePrivateChatsIfNeeded(for: peerID, senderNickname: message.sender)

        if peerID.id.count == 16, let peer = viewModel.unifiedPeerService.getPeer(by: peerID) {
            let stableKeyHex = PeerID(hexData: peer.noisePublicKey)
            if stableKeyHex != peerID,
               let nostrMessages = viewModel.privateChats[stableKeyHex],
               !nostrMessages.isEmpty {
                if viewModel.privateChats[peerID] == nil {
                    viewModel.privateChats[peerID] = []
                }

                let existingMessageIds = Set(viewModel.privateChats[peerID]?.map { $0.id } ?? [])
                for nostrMessage in nostrMessages where !existingMessageIds.contains(nostrMessage.id) {
                    viewModel.privateChats[peerID]?.append(nostrMessage)
                }

                viewModel.privateChats[peerID]?.sort { $0.timestamp < $1.timestamp }
                viewModel.privateChats.removeValue(forKey: stableKeyHex)

                SecureLogger.info(
                    "📥 Consolidated \(nostrMessages.count) Nostr messages from stable key to ephemeral peer \(peerID)",
                    category: .session
                )
            }
        }

        if isDuplicateMessage(message.id, targetPeerID: peerID) {
            return
        }

        addMessageToPrivateChatsIfNeeded(message, targetPeerID: peerID)
        let noiseKey = peerID.noiseKey ?? viewModel.unifiedPeerService.getPeer(by: peerID)?.noisePublicKey
        mirrorToEphemeralIfNeeded(message, targetPeerID: peerID, key: noiseKey)

        let isViewing = viewModel.selectedPrivateChatPeer == peerID
        if isViewing {
            let receipt = ReadReceipt(
                originalMessageID: message.id,
                readerID: viewModel.meshService.myPeerID,
                readerNickname: viewModel.nickname
            )
            viewModel.meshService.sendReadReceipt(receipt, to: peerID)
            viewModel.sentReadReceipts.insert(message.id)
        } else {
            viewModel.unreadPrivateMessages.insert(peerID)
            NotificationService.shared.sendPrivateMessageNotification(
                from: message.sender,
                message: message.content,
                peerID: peerID
            )
        }

        viewModel.objectWillChange.send()
    }

    func isDuplicateMessage(_ messageId: String, targetPeerID: PeerID) -> Bool {
        if viewModel.privateChats[targetPeerID]?.contains(where: { $0.id == messageId }) == true {
            return true
        }
        for (_, messages) in viewModel.privateChats where messages.contains(where: { $0.id == messageId }) {
            return true
        }
        return false
    }

    func addMessageToPrivateChatsIfNeeded(_ message: BitchatMessage, targetPeerID: PeerID) {
        if viewModel.privateChats[targetPeerID] == nil {
            viewModel.privateChats[targetPeerID] = []
        }
        if let idx = viewModel.privateChats[targetPeerID]?.firstIndex(where: { $0.id == message.id }) {
            viewModel.privateChats[targetPeerID]?[idx] = message
        } else {
            viewModel.privateChats[targetPeerID]?.append(message)
        }
        viewModel.privateChatManager.sanitizeChat(for: targetPeerID)
    }

    func mirrorToEphemeralIfNeeded(_ message: BitchatMessage, targetPeerID: PeerID, key: Data?) {
        guard let key,
              let ephemeralPeerID = viewModel.unifiedPeerService.peers.first(where: { $0.noisePublicKey == key })?.peerID,
              ephemeralPeerID != targetPeerID
        else {
            return
        }

        if viewModel.privateChats[ephemeralPeerID] == nil {
            viewModel.privateChats[ephemeralPeerID] = []
        }
        if let idx = viewModel.privateChats[ephemeralPeerID]?.firstIndex(where: { $0.id == message.id }) {
            viewModel.privateChats[ephemeralPeerID]?[idx] = message
        } else {
            viewModel.privateChats[ephemeralPeerID]?.append(message)
        }
        viewModel.privateChatManager.sanitizeChat(for: ephemeralPeerID)
    }

    func handleViewingThisChat(
        _ message: BitchatMessage,
        targetPeerID: PeerID,
        key: Data?,
        senderPubkey: String
    ) {
        viewModel.unreadPrivateMessages.remove(targetPeerID)
        if let key,
           let ephemeralPeerID = viewModel.unifiedPeerService.peers.first(where: { $0.noisePublicKey == key })?.peerID {
            viewModel.unreadPrivateMessages.remove(ephemeralPeerID)
        }
        guard !viewModel.sentReadReceipts.contains(message.id) else { return }

        if let key {
            let receipt = ReadReceipt(
                originalMessageID: message.id,
                readerID: viewModel.meshService.myPeerID,
                readerNickname: viewModel.nickname
            )
            SecureLogger.debug("Viewing chat; sending READ ack for \(message.id.prefix(8))… via router", category: .session)
            viewModel.messageRouter.sendReadReceipt(receipt, to: PeerID(hexData: key))
            viewModel.sentReadReceipts.insert(message.id)
        } else if let identity = try? viewModel.idBridge.getCurrentNostrIdentity() {
            let transport = NostrTransport(keychain: viewModel.keychain, idBridge: viewModel.idBridge)
            transport.senderPeerID = viewModel.meshService.myPeerID
            transport.sendReadReceiptGeohash(message.id, toRecipientHex: senderPubkey, from: identity)
            viewModel.sentReadReceipts.insert(message.id)
            SecureLogger.debug(
                "Viewing chat; sent READ ack directly to Nostr pub=\(senderPubkey.prefix(8))… for mid=\(message.id.prefix(8))…",
                category: .session
            )
        }
    }

    func markAsUnreadIfNeeded(
        shouldMarkAsUnread: Bool,
        targetPeerID: PeerID,
        key: Data?,
        isRecentMessage: Bool,
        senderNickname: String,
        messageContent: String
    ) {
        guard shouldMarkAsUnread else { return }

        viewModel.unreadPrivateMessages.insert(targetPeerID)
        if let key,
           let ephemeralPeerID = viewModel.unifiedPeerService.peers.first(where: { $0.noisePublicKey == key })?.peerID,
           ephemeralPeerID != targetPeerID {
            viewModel.unreadPrivateMessages.insert(ephemeralPeerID)
        }
        if isRecentMessage {
            NotificationService.shared.sendPrivateMessageNotification(
                from: senderNickname,
                message: messageContent,
                peerID: targetPeerID
            )
        }
    }

    func handleFavoriteNotificationFromMesh(_ content: String, from peerID: PeerID, senderNickname: String) {
        let isFavorite = content.hasPrefix("[FAVORITED]")
        let parts = content.split(separator: ":")

        var nostrPubkey: String?
        if parts.count > 1 {
            nostrPubkey = String(parts[1])
            SecureLogger.info("📝 Received Nostr npub in favorite notification: \(nostrPubkey ?? "none")", category: .session)
        }

        let noiseKey = peerID.noiseKey ?? viewModel.unifiedPeerService.getPeer(by: peerID)?.noisePublicKey
        guard let finalNoiseKey = noiseKey else {
            SecureLogger.warning("⚠️ Cannot get Noise key for peer \(peerID)", category: .session)
            return
        }

        let prior = FavoritesPersistenceService.shared.getFavoriteStatus(for: finalNoiseKey)?.theyFavoritedUs ?? false
        FavoritesPersistenceService.shared.updatePeerFavoritedUs(
            peerNoisePublicKey: finalNoiseKey,
            favorited: isFavorite,
            peerNickname: senderNickname,
            peerNostrPublicKey: nostrPubkey
        )

        if isFavorite && nostrPubkey != nil {
            SecureLogger.info(
                "💾 Storing Nostr key association for \(senderNickname): \(nostrPubkey!.prefix(16))...",
                category: .session
            )
        }

        if prior != isFavorite {
            let action = isFavorite ? "favorited" : "unfavorited"
            viewModel.addMeshOnlySystemMessage("\(senderNickname) \(action) you")
        }
    }

    func processActionMessage(_ message: BitchatMessage) -> BitchatMessage {
        let isActionMessage = message.content.hasPrefix("* ")
            && message.content.hasSuffix(" *")
            && (message.content.contains("🫂")
                || message.content.contains("🐟")
                || message.content.contains("took a screenshot"))

        guard isActionMessage else { return message }

        return BitchatMessage(
            id: message.id,
            sender: "system",
            content: String(message.content.dropFirst(2).dropLast(2)),
            timestamp: message.timestamp,
            isRelay: message.isRelay,
            originalSender: message.originalSender,
            isPrivate: message.isPrivate,
            recipientNickname: message.recipientNickname,
            senderPeerID: message.senderPeerID,
            mentions: message.mentions,
            deliveryStatus: message.deliveryStatus
        )
    }

    func migratePrivateChatsIfNeeded(for peerID: PeerID, senderNickname: String) {
        let currentFingerprint = viewModel.getFingerprint(for: peerID)

        if viewModel.privateChats[peerID] == nil || viewModel.privateChats[peerID]?.isEmpty == true {
            var migratedMessages: [BitchatMessage] = []
            var oldPeerIDsToRemove: [PeerID] = []
            let cutoffTime = Date().addingTimeInterval(-TransportConfig.uiMigrationCutoffSeconds)

            for (oldPeerID, messages) in viewModel.privateChats where oldPeerID != peerID {
                let oldFingerprint = viewModel.peerIDToPublicKeyFingerprint[oldPeerID]
                let recentMessages = messages.filter { $0.timestamp > cutoffTime }
                guard !recentMessages.isEmpty else { continue }

                if let currentFp = currentFingerprint,
                   let oldFp = oldFingerprint,
                   currentFp == oldFp {
                    migratedMessages.append(contentsOf: recentMessages)
                    if recentMessages.count == messages.count {
                        oldPeerIDsToRemove.append(oldPeerID)
                    } else {
                        SecureLogger.info(
                            "📦 Partially migrating \(recentMessages.count) of \(messages.count) messages from \(oldPeerID)",
                            category: .session
                        )
                    }

                    SecureLogger.info(
                        "📦 Migrating \(recentMessages.count) recent messages from old peer ID \(oldPeerID) to \(peerID) (fingerprint match)",
                        category: .session
                    )
                } else if currentFingerprint == nil || oldFingerprint == nil {
                    let isRelevantChat = recentMessages.contains { msg in
                        (msg.sender == senderNickname && msg.sender != viewModel.nickname)
                            || (msg.sender == viewModel.nickname && msg.recipientNickname == senderNickname)
                    }

                    if isRelevantChat {
                        migratedMessages.append(contentsOf: recentMessages)
                        if recentMessages.count == messages.count {
                            oldPeerIDsToRemove.append(oldPeerID)
                        }

                        SecureLogger.warning(
                            "📦 Migrating \(recentMessages.count) recent messages from old peer ID \(oldPeerID) to \(peerID) (nickname match)",
                            category: .session
                        )
                    }
                }
            }

            if !oldPeerIDsToRemove.isEmpty {
                let needsSelectedUpdate = oldPeerIDsToRemove.contains { viewModel.selectedPrivateChatPeer == $0 }

                for oldID in oldPeerIDsToRemove {
                    viewModel.privateChats.removeValue(forKey: oldID)
                    viewModel.unreadPrivateMessages.remove(oldID)
                    viewModel.peerIdentityStore.setFingerprint(nil, for: oldID)
                }

                if needsSelectedUpdate {
                    viewModel.selectedPrivateChatPeer = peerID
                }
            }

            if !migratedMessages.isEmpty {
                if viewModel.privateChats[peerID] == nil {
                    viewModel.privateChats[peerID] = []
                }
                viewModel.privateChats[peerID]?.append(contentsOf: migratedMessages)
                viewModel.privateChats[peerID]?.sort { $0.timestamp < $1.timestamp }
                viewModel.privateChatManager.sanitizeChat(for: peerID)
                viewModel.objectWillChange.send()
            }
        }
    }

    func sendFavoriteNotification(to peerID: PeerID, isFavorite: Bool) {
        var noiseKey: Data?

        if let hexKey = Data(hexString: peerID.id) {
            noiseKey = hexKey
        } else if let peer = viewModel.unifiedPeerService.getPeer(by: peerID) {
            noiseKey = peer.noisePublicKey
        }

        if viewModel.meshService.isPeerConnected(peerID) {
            viewModel.messageRouter.sendFavoriteNotification(to: peerID, isFavorite: isFavorite)
            SecureLogger.debug("📤 Sent favorite notification via BLE to \(peerID)", category: .session)
        } else if let key = noiseKey {
            viewModel.messageRouter.sendFavoriteNotification(to: PeerID(hexData: key), isFavorite: isFavorite)
        } else {
            SecureLogger.warning("⚠️ Cannot send favorite notification - peer not connected and no Nostr pubkey", category: .session)
        }
    }

    func isMessageBlocked(_ message: BitchatMessage) -> Bool {
        if let peerID = message.senderPeerID ?? viewModel.getPeerIDForNickname(message.sender) {
            if viewModel.isPeerBlocked(peerID) { return true }
            if peerID.isGeoChat || peerID.isGeoDM,
               let full = viewModel.nostrKeyMapping[peerID]?.lowercased(),
               viewModel.identityManager.isNostrBlocked(pubkeyHexLowercased: full) {
                return true
            }
        }
        return false
    }
}
