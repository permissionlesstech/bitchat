import BitFoundation
import BitLogger
import Foundation

/// The narrow surface `ChatPeerListCoordinator` needs from its owner.
///
/// Follows the `ChatDeliveryContext` exemplar: the coordinator depends on the
/// minimal context it actually uses instead of holding an `unowned` back-ref
/// to the whole `ChatViewModel`. This keeps the coordinator independently
/// testable (see `ChatPeerListCoordinatorContextTests`) and makes its true
/// dependencies explicit.
@MainActor
protocol ChatPeerListContext: AnyObject {
    // MARK: Connection & chat state
    var isConnected: Bool { get set }
    /// A single private chat's timeline (store-direct lookup on
    /// `ChatViewModel`; no `privateChats` dictionary build).
    func privateMessages(for peerID: PeerID) -> [BitchatMessage]
    var unreadPrivateMessages: Set<PeerID> { get }
    /// Clears the peer's unread flag (single-writer store intent).
    func markPrivateChatRead(_ peerID: PeerID)
    var hasTrackedPrivateChatSelection: Bool { get }
    func updatePrivateChatPeerIfNeeded()
    func cleanupOldReadReceipts()

    // MARK: Peers & sessions
    var unifiedPeers: [BitchatPeer] { get }
    func isPeerConnected(_ peerID: PeerID) -> Bool
    func isPeerReachable(_ peerID: PeerID) -> Bool
    /// Number of mesh peers currently connected or reachable, from the
    /// transport's live peer snapshots.
    func activeMeshPeerCount() -> Int
    func registerEphemeralSession(peerID: PeerID)
    func updateEncryptionStatusForPeers()

    // MARK: Notifications
    /// Posts the "bitchatters nearby" local notification.
    func notifyNetworkAvailable(peerCount: Int)

    /// Records peers seen within range for the daily ambient sightings tally.
    func recordMeshSightings(peerIDs: [PeerID])
}

extension ChatViewModel: ChatPeerListContext {
    // `isConnected`, `privateMessages(for:)`, `unreadPrivateMessages`,
    // `hasTrackedPrivateChatSelection`, `updatePrivateChatPeerIfNeeded()`,
    // `cleanupOldReadReceipts()`, `unifiedPeers`, `isPeerConnected(_:)`,
    // `isPeerReachable(_:)`, `registerEphemeralSession(peerID:)`, and
    // `updateEncryptionStatusForPeers()` are shared requirements with the
    // other contexts or satisfied by existing `ChatViewModel` members. The
    // member below flattens the nested transport access into an intent-named
    // call.

    func activeMeshPeerCount() -> Int {
        meshService
            .currentPeerSnapshots()
            .filter { snapshot in
                snapshot.isConnected || meshService.isPeerReachable(snapshot.peerID)
            }
            .count
    }

    func notifyNetworkAvailable(peerCount: Int) {
        NotificationService.shared.sendNetworkAvailableNotification(peerCount: peerCount)
    }

    func recordMeshSightings(peerIDs: [PeerID]) {
        for peerID in peerIDs {
            MeshSightingsTracker.shared.recordSighting(peerID: peerID)
        }
    }
}

final class ChatPeerListCoordinator: @unchecked Sendable {
    private unowned let context: any ChatPeerListContext
    private var recentlySeenPeers: Set<PeerID> = []
    // The "bitchatters nearby" notification only fires on the transition from
    // an empty mesh to a populated one — joining peers while already meshed
    // are visible in the app and must not notify. Set back to true only after
    // a confirmed-empty reset, so brief link flaps stay silent.
    private var meshWasEmpty = true
    private var lastNetworkNotificationTime = Date.distantPast
    private var networkResetTimer: Timer?
    private var networkEmptyTimer: Timer?
    private let networkResetGraceSeconds = TransportConfig.networkResetGraceSeconds
    private let notificationCooldownSeconds: TimeInterval

    init(
        context: any ChatPeerListContext,
        notificationCooldownSeconds: TimeInterval = TransportConfig.networkNotificationCooldownSeconds
    ) {
        self.context = context
        self.notificationCooldownSeconds = notificationCooldownSeconds
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
        context.isConnected = !peers.isEmpty
        cleanupStaleUnreadPeerIDs()

        let meshPeers = peers.filter { peerID in
            context.isPeerConnected(peerID) || context.isPeerReachable(peerID)
        }

        handleNetworkAvailability(meshPeers)

        for peerID in peers {
            context.registerEphemeralSession(peerID: peerID)
        }

        context.updateEncryptionStatusForPeers()

        if context.hasTrackedPrivateChatSelection {
            context.updatePrivateChatPeerIfNeeded()
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
        context.recordMeshSightings(peerIDs: meshPeers)

        let newPeers = meshPeerSet.subtracting(recentlySeenPeers)
        // Record every sighted peer even when no notification fires. A peer
        // first seen during the cooldown (or while already meshed) must not
        // still count as "new" at some later peer-list event — that re-fired
        // the notification while devices sat idle and connected.
        recentlySeenPeers.formUnion(meshPeerSet)

        let cameFromEmpty = meshWasEmpty
        meshWasEmpty = false

        guard cameFromEmpty, !newPeers.isEmpty else { return }

        if Date().timeIntervalSince(lastNetworkNotificationTime) >= notificationCooldownSeconds {
            lastNetworkNotificationTime = Date()
            context.notifyNetworkAvailable(peerCount: meshPeers.count)
            SecureLogger.info(
                "👥 Sent bitchatters nearby notification for \(meshPeers.count) mesh peers (new: \(newPeers.count))",
                category: .session
            )
        }

        scheduleNetworkResetTimer()
    }

    @MainActor
    func cleanupStaleUnreadPeerIDs() {
        let currentPeerIDs = Set(context.unifiedPeers.map(\.peerID))
        let staleIDs = context.unreadPrivateMessages.subtracting(currentPeerIDs)

        guard !staleIDs.isEmpty else {
            context.cleanupOldReadReceipts()
            return
        }

        var idsToRemove: [PeerID] = []

        for staleID in staleIDs {
            if staleID.isGeoDM, !context.privateMessages(for: staleID).isEmpty {
                continue
            }

            if staleID.isNoiseKeyHex, !context.privateMessages(for: staleID).isEmpty {
                continue
            }

            idsToRemove.append(staleID)
            context.markPrivateChatRead(staleID)
        }

        if !idsToRemove.isEmpty {
            SecureLogger.debug("🧹 Cleaned up \(idsToRemove.count) stale unread peer IDs", category: .session)
        }

        context.cleanupOldReadReceipts()
    }

    @MainActor
    func scheduleNetworkResetTimer() {
        networkResetTimer?.invalidate()
        networkResetTimer = Timer.scheduledTimer(withTimeInterval: networkResetGraceSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                self?.handleNetworkResetTimerFired()
            }
        }
    }

    @MainActor
    func handleNetworkResetTimerFired() {
        let activeMeshPeerCount = context.activeMeshPeerCount()

        if activeMeshPeerCount == 0 {
            recentlySeenPeers.removeAll()
            meshWasEmpty = true
            SecureLogger.debug("⏱️ Network notification window reset after quiet period", category: .session)
        } else {
            SecureLogger.debug(
                "⏱️ Skipped network notification reset; still seeing \(activeMeshPeerCount) mesh peers",
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
            MainActor.assumeIsolated { [weak self] in
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
        let activeMeshPeerCount = context.activeMeshPeerCount()

        if activeMeshPeerCount == 0 {
            recentlySeenPeers.removeAll()
            meshWasEmpty = true
            SecureLogger.debug("⏳ Mesh empty — notification state reset after confirmation", category: .session)
        } else {
            SecureLogger.debug(
                "⏳ Mesh empty timer cancelled; \(activeMeshPeerCount) mesh peers detected again",
                category: .session
            )
        }

        networkEmptyTimer = nil
    }
}
