import BitFoundation
import BitLogger
import CoreBluetooth
import Foundation

final class ChatPeerIdentityCoordinator {
    private unowned let viewModel: ChatViewModel

    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
    }

    @MainActor
    func openMostRelevantPrivateChat() {
        let unreadSorted = viewModel.unreadPrivateMessages
            .map { ($0, viewModel.privateChats[$0]?.last?.timestamp ?? Date.distantPast) }
            .sorted { $0.1 > $1.1 }
        if let target = unreadSorted.first?.0 {
            startPrivateChat(with: target)
            return
        }

        let recent = viewModel.privateChats
            .map { (id: $0.key, ts: $0.value.last?.timestamp ?? Date.distantPast) }
            .sorted { $0.ts > $1.ts }
        if let target = recent.first?.id {
            startPrivateChat(with: target)
        }
    }

    @MainActor
    func isPeerBlocked(_ peerID: PeerID) -> Bool {
        viewModel.unifiedPeerService.isBlocked(peerID)
    }

    @MainActor
    func updatePrivateChatPeerIfNeeded() {
        guard let chatFingerprint = viewModel.selectedPrivateChatFingerprint,
              let currentPeerID = currentPeerID(forFingerprint: chatFingerprint) else {
            return
        }

        if let oldPeerID = viewModel.selectedPrivateChatPeer, oldPeerID != currentPeerID {
            migrateChatState(from: oldPeerID, to: currentPeerID)
            viewModel.selectedPrivateChatPeer = currentPeerID
        } else if viewModel.selectedPrivateChatPeer == nil {
            viewModel.selectedPrivateChatPeer = currentPeerID
        }

        var unread = viewModel.unreadPrivateMessages
        unread.remove(currentPeerID)
        viewModel.unreadPrivateMessages = unread
    }

    @MainActor
    func startPrivateChat(with peerID: PeerID) {
        guard peerID != viewModel.meshService.myPeerID else { return }

        let peerNickname = viewModel.meshService.peerNickname(peerID: peerID) ?? "unknown"

        if viewModel.unifiedPeerService.isBlocked(peerID) {
            viewModel.addSystemMessage(
                String(
                    format: String(
                        localized: "system.chat.blocked",
                        comment: "System message when starting chat fails because peer is blocked"
                    ),
                    locale: .current,
                    peerNickname
                )
            )
            return
        }

        if let peer = viewModel.unifiedPeerService.getPeer(by: peerID),
           peer.isFavorite && !peer.theyFavoritedUs && !peer.isConnected {
            viewModel.addSystemMessage(
                String(
                    format: String(
                        localized: "system.chat.requires_favorite",
                        comment: "System message when mutual favorite requirement blocks chat"
                    ),
                    locale: .current,
                    peerNickname
                )
            )
            return
        }

        _ = viewModel.privateChatManager.consolidateMessages(
            for: peerID,
            peerNickname: peerNickname,
            persistedReadReceipts: viewModel.sentReadReceipts
        )

        if !peerID.isGeoDM && !peerID.isGeoChat {
            switch viewModel.meshService.getNoiseSessionState(for: peerID) {
            case .none, .failed:
                viewModel.meshService.triggerHandshake(with: peerID)
            case .handshakeQueued, .handshaking, .established:
                break
            }
        } else {
            SecureLogger.debug("GeoDM: skipping mesh handshake for virtual peerID=\(peerID)", category: .session)
        }

        viewModel.privateChatManager.syncReadReceiptsForSentMessages(
            peerID: peerID,
            nickname: viewModel.nickname,
            externalReceipts: &viewModel.sentReadReceipts
        )

        if let fingerprint = getFingerprint(for: peerID) {
            viewModel.peerIdentityStore.setFingerprint(fingerprint, for: peerID)
            viewModel.peerIdentityStore.setSelectedPrivateChatFingerprint(fingerprint)
        } else {
            viewModel.peerIdentityStore.setSelectedPrivateChatFingerprint(nil)
        }
        viewModel.privateChatManager.startChat(with: peerID)
        viewModel.synchronizePrivateConversationStore()
        viewModel.synchronizeConversationSelectionStore()
        viewModel.markPrivateMessagesAsRead(from: peerID)
    }

    @MainActor
    func endPrivateChat() {
        viewModel.selectedPrivateChatPeer = nil
        viewModel.peerIdentityStore.setSelectedPrivateChatFingerprint(nil)
    }

    @MainActor
    func handlePeerStatusUpdate() {
        updatePrivateChatPeerIfNeeded()
    }

    func handleFavoriteStatusChanged(_ notification: Notification) {
        guard let peerPublicKey = notification.userInfo?["peerPublicKey"] as? Data else { return }

        Task { @MainActor [weak viewModel] in
            guard let viewModel else { return }

            if let isKeyUpdate = notification.userInfo?["isKeyUpdate"] as? Bool,
               isKeyUpdate,
               let oldKey = notification.userInfo?["oldPeerPublicKey"] as? Data {
                migrateNoiseKeyUpdate(
                    oldPeerID: PeerID(hexData: oldKey),
                    newPeerID: PeerID(hexData: peerPublicKey)
                )
            }

            updatePrivateChatPeerIfNeeded()

            if let isFavorite = notification.userInfo?["isFavorite"] as? Bool {
                let peerID = PeerID(hexData: peerPublicKey)
                let action = isFavorite ? "favorited" : "unfavorited"
                let peerNickname = favoriteNotificationNickname(for: peerID, peerPublicKey: peerPublicKey)
                viewModel.addSystemMessage("\(peerNickname) \(action) you")
            }
        }
    }

    @MainActor
    func updateEncryptionStatusForPeers() {
        for peerID in viewModel.connectedPeers {
            updateEncryptionStatus(for: peerID)
        }
    }

    @MainActor
    func updateEncryptionStatus(for peerID: PeerID) {
        let noiseService = viewModel.meshService.getNoiseService()

        if noiseService.hasEstablishedSession(with: peerID) {
            viewModel.peerIdentityStore.setEncryptionStatus(verifiedEncryptionStatus(for: peerID), for: peerID)
        } else if noiseService.hasSession(with: peerID) {
            viewModel.peerIdentityStore.setEncryptionStatus(.noiseHandshaking, for: peerID)
        } else {
            viewModel.peerIdentityStore.setEncryptionStatus(nil, for: peerID)
        }

        invalidateEncryptionCache(for: peerID)
    }

    @MainActor
    func getEncryptionStatus(for peerID: PeerID) -> EncryptionStatus {
        if let cachedStatus = viewModel.peerIdentityStore.cachedEncryptionStatus(for: peerID) {
            return cachedStatus
        }

        let hasEverEstablishedSession = getFingerprint(for: peerID) != nil
        let sessionState = viewModel.meshService.getNoiseSessionState(for: peerID)

        let status: EncryptionStatus
        switch sessionState {
        case .established:
            status = verifiedEncryptionStatus(for: peerID)
        case .handshaking, .handshakeQueued:
            status = hasEverEstablishedSession ? verifiedEncryptionStatus(for: peerID) : .noiseHandshaking
        case .none:
            status = hasEverEstablishedSession ? verifiedEncryptionStatus(for: peerID) : .noHandshake
        case .failed:
            status = hasEverEstablishedSession ? verifiedEncryptionStatus(for: peerID) : .none
        }

        viewModel.peerIdentityStore.setCachedEncryptionStatus(status, for: peerID)
        return status
    }

    @MainActor
    func invalidateEncryptionCache(for peerID: PeerID? = nil) {
        viewModel.peerIdentityStore.invalidateEncryptionCache(for: peerID)
    }

    @MainActor
    func getFingerprint(for peerID: PeerID) -> String? {
        viewModel.unifiedPeerService.getFingerprint(for: peerID)
    }

    @MainActor
    func resolveNickname(for peerID: PeerID) -> String {
        guard !peerID.isEmpty else { return "unknown" }

        if !peerID.isHex {
            return peerID.id
        }

        if let nickname = viewModel.meshService.getPeerNicknames()[peerID] {
            return nickname
        }

        if let fingerprint = getFingerprint(for: peerID),
           let identity = viewModel.identityManager.getSocialIdentity(for: fingerprint) {
            if let petname = identity.localPetname {
                return petname
            }
            return identity.claimedNickname
        }

        let prefixLength = min(4, peerID.id.count)
        let prefix = String(peerID.id.prefix(prefixLength))
        return prefix.starts(with: "anon") ? "peer\(prefix)" : "anon\(prefix)"
    }

    @MainActor
    func getMyFingerprint() -> String {
        viewModel.meshService.getNoiseService().getIdentityFingerprint()
    }

    @MainActor
    func getPeerIDForNickname(_ nickname: String) -> PeerID? {
        switch viewModel.activeChannel {
        case .location:
            if nickname.contains("#"),
               let person = viewModel.publicConversationCoordinator
                .visibleGeohashPeople()
                .first(where: { $0.displayName == nickname }) {
                let conversationKey = PeerID(nostr_: person.id)
                viewModel.nostrKeyMapping[conversationKey] = person.id
                return conversationKey
            }

            let base = nickname
                .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                .first
                .map(String.init)?
                .lowercased() ?? nickname.lowercased()
            if let pubkey = viewModel.geoNicknames.first(where: { $0.value.lowercased() == base })?.key {
                let conversationKey = PeerID(nostr_: pubkey)
                viewModel.nostrKeyMapping[conversationKey] = pubkey
                return conversationKey
            }

        case .mesh:
            break
        }

        return viewModel.unifiedPeerService.getPeerID(for: nickname)
    }

    @MainActor
    func nicknameForPeer(_ peerID: PeerID) -> String {
        if let name = viewModel.meshService.peerNickname(peerID: peerID) {
            return name
        }
        if let favorite = FavoritesPersistenceService.shared.getFavoriteStatus(forPeerID: peerID),
           !favorite.peerNickname.isEmpty {
            return favorite.peerNickname
        }
        if let noiseKey = Data(hexString: peerID.id),
           let favorite = FavoritesPersistenceService.shared.getFavoriteStatus(for: noiseKey),
           !favorite.peerNickname.isEmpty {
            return favorite.peerNickname
        }
        return "user"
    }
}

private extension ChatPeerIdentityCoordinator {
    @MainActor
    func currentPeerID(forFingerprint fingerprint: String) -> PeerID? {
        for peerID in viewModel.connectedPeers where getFingerprint(for: peerID) == fingerprint {
            return peerID
        }
        return nil
    }

    @MainActor
    func migrateChatState(from oldPeerID: PeerID, to newPeerID: PeerID) {
        if let oldMessages = viewModel.privateChats[oldPeerID] {
            var chats = viewModel.privateChats
            chats[newPeerID, default: []].append(contentsOf: oldMessages)
            chats[newPeerID]?.sort { $0.timestamp < $1.timestamp }

            var seenMessageIDs = Set<String>()
            chats[newPeerID] = chats[newPeerID]?.filter { message in
                if seenMessageIDs.contains(message.id) {
                    return false
                }
                seenMessageIDs.insert(message.id)
                return true
            }

            chats.removeValue(forKey: oldPeerID)
            viewModel.privateChats = chats
        }

        var unread = viewModel.unreadPrivateMessages
        if unread.contains(oldPeerID) {
            unread.remove(oldPeerID)
            unread.insert(newPeerID)
            viewModel.unreadPrivateMessages = unread
        }
    }

    @MainActor
    func migrateNoiseKeyUpdate(oldPeerID: PeerID, newPeerID: PeerID) {
        if viewModel.selectedPrivateChatPeer == oldPeerID {
            SecureLogger.info("📱 Updating private chat peer ID due to key change: \(oldPeerID) -> \(newPeerID)", category: .session)
        } else if viewModel.privateChats[oldPeerID] != nil {
            SecureLogger.debug("📱 Migrating private chat messages from \(oldPeerID) to \(newPeerID)", category: .session)
        }

        migrateChatState(from: oldPeerID, to: newPeerID)

        if viewModel.selectedPrivateChatPeer == oldPeerID {
            viewModel.selectedPrivateChatPeer = newPeerID
        }

        if let fingerprint = viewModel.peerIdentityStore.migrateFingerprintMapping(
            from: oldPeerID,
            to: newPeerID,
            fallback: getFingerprint(for: newPeerID)
        ) {
            if viewModel.selectedPrivateChatPeer == newPeerID {
                viewModel.peerIdentityStore.setSelectedPrivateChatFingerprint(fingerprint)
            }
        }
    }

    @MainActor
    func favoriteNotificationNickname(for peerID: PeerID, peerPublicKey: Data) -> String {
        if let nickname = viewModel.meshService.peerNickname(peerID: peerID) {
            return nickname
        }
        if let favorite = FavoritesPersistenceService.shared.getFavoriteStatus(for: peerPublicKey) {
            return favorite.peerNickname
        }
        return "Unknown"
    }

    @MainActor
    func verifiedEncryptionStatus(for peerID: PeerID) -> EncryptionStatus {
        if let fingerprint = getFingerprint(for: peerID),
           viewModel.peerIdentityStore.isVerified(fingerprint) {
            return .noiseVerified
        }
        return .noiseSecured
    }
}
