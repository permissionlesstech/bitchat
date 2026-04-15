import BitFoundation
import BitLogger
import Foundation

final class ChatPeerListCoordinator {
    private unowned let viewModel: ChatViewModel
    private var recentlySeenPeers: Set<PeerID> = []
    private var lastNetworkNotificationTime = Date.distantPast
    private var networkResetTimer: Timer?
    private var networkEmptyTimer: Timer?
    private let networkResetGraceSeconds = TransportConfig.networkResetGraceSeconds

    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
    }

    deinit {
        networkResetTimer?.invalidate()
        networkEmptyTimer?.invalidate()
    }

    func didUpdatePeerList(_ peers: [PeerID]) {
        Task { @MainActor [weak self] in
            self?.handlePeerListUpdate(peers)
        }
    }
}

private extension ChatPeerListCoordinator {
    @MainActor
    func handlePeerListUpdate(_ peers: [PeerID]) {
        viewModel.isConnected = !peers.isEmpty
        cleanupStaleUnreadPeerIDs()

        let meshPeers = peers.filter { peerID in
            viewModel.meshService.isPeerConnected(peerID) || viewModel.meshService.isPeerReachable(peerID)
        }

        handleNetworkAvailability(meshPeers)

        for peerID in peers {
            viewModel.identityManager.registerEphemeralSession(peerID: peerID, handshakeState: .none)
        }

        viewModel.updateEncryptionStatusForPeers()

        if viewModel.hasTrackedPrivateChatSelection {
            viewModel.updatePrivateChatPeerIfNeeded()
        }
    }

    @MainActor
    func handleNetworkAvailability(_ meshPeers: [PeerID]) {
        let meshPeerSet = Set(meshPeers)

        if meshPeerSet.isEmpty {
            scheduleNetworkEmptyTimer()
            return
        }

        invalidateNetworkEmptyTimer()

        let newPeers = meshPeerSet.subtracting(recentlySeenPeers)
        guard !newPeers.isEmpty else { return }

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

    @MainActor
    func cleanupStaleUnreadPeerIDs() {
        let currentPeerIDs = Set(viewModel.unifiedPeerService.peers.map(\.peerID))
        let staleIDs = viewModel.unreadPrivateMessages.subtracting(currentPeerIDs)

        guard !staleIDs.isEmpty else {
            viewModel.cleanupOldReadReceipts()
            return
        }

        var idsToRemove: [PeerID] = []

        for staleID in staleIDs {
            if staleID.isGeoDM, let messages = viewModel.privateChats[staleID], !messages.isEmpty {
                continue
            }

            if staleID.isNoiseKeyHex, let messages = viewModel.privateChats[staleID], !messages.isEmpty {
                continue
            }

            idsToRemove.append(staleID)
            viewModel.unreadPrivateMessages.remove(staleID)
        }

        if !idsToRemove.isEmpty {
            SecureLogger.debug("🧹 Cleaned up \(idsToRemove.count) stale unread peer IDs", category: .session)
        }

        viewModel.cleanupOldReadReceipts()
    }

    @MainActor
    func scheduleNetworkResetTimer() {
        networkResetTimer?.invalidate()
        networkResetTimer = Timer.scheduledTimer(withTimeInterval: networkResetGraceSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleNetworkResetTimerFired()
            }
        }
    }

    @MainActor
    func handleNetworkResetTimerFired() {
        let activeMeshPeers = viewModel.meshService
            .currentPeerSnapshots()
            .filter { snapshot in
                snapshot.isConnected || viewModel.meshService.isPeerReachable(snapshot.peerID)
            }

        if activeMeshPeers.isEmpty {
            recentlySeenPeers.removeAll()
            SecureLogger.debug("⏱️ Network notification window reset after quiet period", category: .session)
        } else {
            SecureLogger.debug(
                "⏱️ Skipped network notification reset; still seeing \(activeMeshPeers.count) mesh peers",
                category: .session
            )
        }

        networkResetTimer = nil
    }

    @MainActor
    func scheduleNetworkEmptyTimer() {
        guard networkEmptyTimer == nil else { return }

        networkEmptyTimer = Timer.scheduledTimer(
            withTimeInterval: TransportConfig.uiMeshEmptyConfirmationSeconds,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleNetworkEmptyTimerFired()
            }
        }

        SecureLogger.debug("⏳ Mesh empty — waiting before resetting notification state", category: .session)
    }

    @MainActor
    func invalidateNetworkEmptyTimer() {
        guard networkEmptyTimer != nil else { return }
        networkEmptyTimer?.invalidate()
        networkEmptyTimer = nil
    }

    @MainActor
    func handleNetworkEmptyTimerFired() {
        let activeMeshPeers = viewModel.meshService
            .currentPeerSnapshots()
            .filter { snapshot in
                snapshot.isConnected || viewModel.meshService.isPeerReachable(snapshot.peerID)
            }

        if activeMeshPeers.isEmpty {
            recentlySeenPeers.removeAll()
            SecureLogger.debug("⏳ Mesh empty — notification state reset after confirmation", category: .session)
        } else {
            SecureLogger.debug(
                "⏳ Mesh empty timer cancelled; \(activeMeshPeers.count) mesh peers detected again",
                category: .session
            )
        }

        networkEmptyTimer = nil
    }
}
