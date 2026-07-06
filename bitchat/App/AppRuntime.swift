import BitFoundation
import Combine
import Foundation
import SwiftUI
import Tor
import UserNotifications
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
final class AppRuntime: ObservableObject {
    let chatViewModel: ChatViewModel
    let events = AppEventStream()
    /// Single source of truth for conversation message state and selection
    /// (docs/CONVERSATION-STORE-DESIGN.md). Owned here; the feature models
    /// and `ChatViewModel` observe and mutate it through its intent API.
    let conversations: ConversationStore
    let peerIdentityStore: PeerIdentityStore
    let locationPresenceStore: LocationPresenceStore
    let publicChatModel: PublicChatModel
    let privateInboxModel: PrivateInboxModel
    let privateConversationModel: PrivateConversationModel
    let verificationModel: VerificationModel
    let conversationUIModel: ConversationUIModel
    let locationChannelsModel: LocationChannelsModel
    let peerListModel: PeerListModel
    let appChromeModel: AppChromeModel

    private let idBridge: NostrIdentityBridge
    private var cancellables = Set<AnyCancellable>()
    private var started = false
    private var lastNostrRelayConnectedState = false
    private var didHandleInitialNostrConnection = false

    #if os(iOS)
    private var didHandleInitialActive = false
    private var didEnterBackground = false
    #endif

    init(
        keychain: KeychainManagerProtocol = KeychainManager(),
        idBridge: NostrIdentityBridge = NostrIdentityBridge()
    ) {
        self.idBridge = idBridge
        let conversations = ConversationStore()
        let peerIdentityStore = PeerIdentityStore()
        let locationPresenceStore = LocationPresenceStore()
        let locationManager = LocationChannelManager.shared
        self.conversations = conversations
        self.peerIdentityStore = peerIdentityStore
        self.locationPresenceStore = locationPresenceStore
        self.chatViewModel = ChatViewModel(
            keychain: keychain,
            idBridge: idBridge,
            identityManager: SecureIdentityStateManager(keychain),
            conversations: conversations,
            peerIdentityStore: peerIdentityStore,
            locationPresenceStore: locationPresenceStore,
            locationManager: locationManager
        )
        self.publicChatModel = PublicChatModel(conversations: conversations)
        self.privateInboxModel = PrivateInboxModel(conversations: conversations)
        self.locationChannelsModel = LocationChannelsModel(manager: locationManager)
        self.privateConversationModel = PrivateConversationModel(
            chatViewModel: self.chatViewModel,
            conversations: conversations,
            locationChannelsModel: self.locationChannelsModel,
            peerIdentityStore: peerIdentityStore
        )
        self.verificationModel = VerificationModel(
            chatViewModel: self.chatViewModel,
            privateConversationModel: self.privateConversationModel,
            peerIdentityStore: peerIdentityStore
        )
        self.conversationUIModel = ConversationUIModel(
            chatViewModel: self.chatViewModel,
            privateConversationModel: self.privateConversationModel,
            conversations: conversations
        )
        self.peerListModel = PeerListModel(
            chatViewModel: self.chatViewModel,
            conversations: conversations,
            locationChannelsModel: self.locationChannelsModel,
            peerIdentityStore: peerIdentityStore,
            locationPresenceStore: locationPresenceStore
        )
        self.appChromeModel = AppChromeModel(
            chatViewModel: self.chatViewModel,
            privateInboxModel: self.privateInboxModel
        )

        GeoRelayDirectory.shared.prefetchIfNeeded()
        bindRuntimeObservers()
        NotificationDelegate.shared.runtime = self
    }

    func start() {
        guard !started else {
            checkForSharedContent()
            return
        }

        started = true
        NotificationDelegate.shared.runtime = self
        VerificationService.shared.configure(with: chatViewModel.meshService)
        announceInitialTorStatusIfNeeded()

        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            let nickname = await MainActor.run { self.chatViewModel.nickname }
            let npub = await MainActor.run {
                try? self.idBridge.getCurrentNostrIdentity()?.npub
            }
            await MainActor.run {
                _ = VerificationService.shared.buildMyQRString(nickname: nickname, npub: npub)
            }
        }

        NetworkActivationService.shared.start()
        GeohashPresenceService.shared.start()
        checkForSharedContent()
        restoreLastActiveConversationOnLaunch()

        record(.launched)
        record(.startupCompleted)
    }

    /// #1064: restore the last-active conversation at launch. A persisted DM
    /// re-opens via the normal private-chat path (which never writes
    /// `activeChannel`); a first-ever launch or a stale DM peer presents the
    /// conversation list; a public channel defers to the existing mesh /
    /// `GeoChannelCoordinator` restore (the sole launch-time writer of
    /// `activeChannel`), so there is no race.
    private func restoreLastActiveConversationOnLaunch() {
        let presentation = conversations.restoreLastActiveConversation(
            isPeerResolvable: { Self.isDirectChatRestorable($0, favorites: .shared) }
        )
        var didOpenDirectChat = false
        if case .restoredDirectChat(let peerID) = presentation {
            // `startPrivateChat` silently no-ops when the peer is now blocked
            // or fails the mutual-favorite-and-connected gate
            // (ChatPeerIdentityCoordinator.startPrivateChat), leaving no chat
            // open — `selectedPrivateChatPeer` is only set on the success path.
            chatViewModel.startPrivateChat(with: peerID)
            didOpenDirectChat = chatViewModel.selectedPrivateChatPeer == peerID
        }
        // Fall back to the conversation list rather than silently landing on
        // the public mesh timeline when a restore target existed but could not
        // be opened.
        if Self.shouldPresentConversationList(for: presentation, didOpenDirectChat: didOpenDirectChat) {
            appChromeModel.presentsConversationListOnLaunch = true
        }
    }

    /// Whether a persisted last-active DM peer is genuinely restorable at
    /// launch — validated against *durable* conversation state, never live
    /// presence (mesh discovery is async, so no peer is connected yet). A
    /// syntactically valid `PeerID` is NOT sufficient: an unknown peer would
    /// otherwise fall straight through `startPrivateChat` into an empty phantom
    /// DM. Restorable iff the peerID is a geohash/Nostr DM (its stable Nostr
    /// identity is embedded in the id itself) or the peer is a persisted
    /// favorite (keychain-backed, stored by stable Noise public key across
    /// launches). Presence-independent and pure, so it is unit-testable.
    static func isDirectChatRestorable(
        _ peerID: PeerID,
        isPeerFavorited: (PeerID) -> Bool
    ) -> Bool {
        if peerID.isGeoDM { return true }
        return isPeerFavorited(peerID)
    }

    /// Production wiring of `isDirectChatRestorable`, extracted so the real
    /// favorites lookup (not just a stub predicate) is unit-testable via an
    /// injected in-memory-keychain-backed `FavoritesPersistenceService`.
    /// `migrateSelectedConversationIfNeeded` can persist the last-active peer in
    /// full 64-hex Noise-key form, but the favorites store is keyed by the
    /// short, Noise-key-derived id — so normalize with `toShort()` (a no-op on
    /// an already-short id) before the lookup, or favorited DMs silently fail to
    /// restore.
    static func isDirectChatRestorable(
        _ peerID: PeerID,
        favorites: FavoritesPersistenceService
    ) -> Bool {
        isDirectChatRestorable(peerID, isPeerFavorited: {
            favorites.getFavoriteStatus(forPeerID: $0.toShort())?.isFavorite ?? false
        })
    }

    /// Pure launch-effect decision, extracted so the fallback is unit-testable
    /// without constructing `AppRuntime`: present the conversation list on a
    /// first-ever launch, or when a persisted DM could not actually be opened
    /// (blocked / stale / gated peer). A public-channel restore is left to
    /// `GeoChannelCoordinator`.
    static func shouldPresentConversationList(
        for presentation: ConversationStore.LaunchPresentation,
        didOpenDirectChat: Bool
    ) -> Bool {
        switch presentation {
        case .conversationList:
            return true
        case .restoredDirectChat:
            return !didOpenDirectChat
        case .deferToChannelRestore:
            return false
        }
    }

    func handleOpenURL(_ url: URL) {
        record(.openedURL(url.absoluteString))

        if url.scheme == "bitchat", url.host == "share" {
            checkForSharedContent()
        }
    }

    func handleDidBecomeActiveNotification() {
        chatViewModel.handleDidBecomeActive()
        checkForSharedContent()
    }

    #if os(macOS)
    func handleMacDidBecomeActiveNotification() {
        record(.scenePhaseChanged(.active))
        chatViewModel.handleDidBecomeActive()
        checkForSharedContent()
    }
    #endif

    #if os(iOS)
    func handleScenePhaseChange(_ newPhase: ScenePhase) {
        switch newPhase {
        case .background:
            record(.scenePhaseChanged(.background))
            TorManager.shared.setAppForeground(false)
            TorManager.shared.goDormantOnBackground()
            chatViewModel.endGeohashSampling()
            NostrRelayManager.shared.disconnect()
            didEnterBackground = true

        case .active:
            record(.scenePhaseChanged(.active))
            chatViewModel.meshService.startServices()
            TorManager.shared.setAppForeground(true)
            let shouldRefreshNostrConnections = didHandleInitialActive && didEnterBackground

            if didHandleInitialActive && didEnterBackground {
                if TorManager.shared.isAutoStartAllowed() && !TorManager.shared.isReady {
                    TorManager.shared.ensureRunningOnForeground()
                }
            } else {
                didHandleInitialActive = true
            }

            didEnterBackground = false

            if shouldRefreshNostrConnections && TorManager.shared.isAutoStartAllowed() {
                Task.detached {
                    let _ = await TorManager.shared.awaitReady(timeout: 60)
                    await MainActor.run {
                        TorURLSession.shared.rebuild()
                        NostrRelayManager.shared.resetAllConnections()
                    }
                }
            }

            chatViewModel.handleDidBecomeActive()
            checkForSharedContent()

        case .inactive:
            record(.scenePhaseChanged(.inactive))

        @unknown default:
            break
        }
    }
    #endif

    func applicationWillTerminate() {
        record(.terminationRequested)
        chatViewModel.applicationWillTerminate()
    }

    func handleNotificationResponse(identifier: String, userInfo: [AnyHashable: Any]) {
        if identifier.hasPrefix("private-"), let peerID = PeerID(str: userInfo["peerID"] as? String) {
            record(.notificationOpened(peerID: peerID))
            chatViewModel.startPrivateChat(with: peerID)
        }

        if let deepLink = userInfo["deeplink"] as? String, let url = URL(string: deepLink) {
            record(.deepLinkOpened(deepLink))
            openExternalURL(url)
        }
    }

    func presentationOptions(
        forNotificationIdentifier identifier: String,
        userInfo: [AnyHashable: Any]
    ) async -> UNNotificationPresentationOptions {
        if identifier.hasPrefix("private-"), let peerID = PeerID(str: userInfo["peerID"] as? String) {
            if conversations.selectedPrivatePeerID == peerID {
                return []
            }
            return [.banner, .sound]
        }

        if identifier.hasPrefix("geo-activity-"),
           let deepLink = userInfo["deeplink"] as? String,
           let geohash = deepLink.components(separatedBy: "/").last,
           case .location(let channel) = locationChannelsModel.selectedChannel,
           channel.geohash == geohash {
            return []
        }

        return [.banner, .sound]
    }
}

private extension AppRuntime {
    func bindRuntimeObservers() {
        NostrRelayManager.shared.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isConnected in
                self?.handleNostrRelayConnectionChanged(isConnected)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .TorWillRestart)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.record(.torLifecycleChanged(.willRestart))
                self?.chatViewModel.handleTorWillRestart()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .TorDidBecomeReady)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.record(.torLifecycleChanged(.didBecomeReady))
                self?.chatViewModel.handleTorDidBecomeReady()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .TorWillStart)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.record(.torLifecycleChanged(.willStart))
                self?.chatViewModel.handleTorWillStart()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .TorUserPreferenceChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.record(.torLifecycleChanged(.preferenceChanged))
                self?.chatViewModel.handleTorPreferenceChanged(notification)
            }
            .store(in: &cancellables)

        #if os(iOS)
        NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleScreenshotCaptured()
            }
            .store(in: &cancellables)
        #endif
    }

    func checkForSharedContent() {
        guard let userDefaults = UserDefaults(suiteName: BitchatApp.groupID),
              let sharedContent = userDefaults.string(forKey: "sharedContent"),
              let sharedDate = userDefaults.object(forKey: "sharedContentDate") as? Date else {
            return
        }

        guard Date().timeIntervalSince(sharedDate) < TransportConfig.uiShareAcceptWindowSeconds else {
            return
        }

        let contentKind = SharedContentKind(rawValue: userDefaults.string(forKey: "sharedContentType") ?? "") ?? .text

        userDefaults.removeObject(forKey: "sharedContent")
        userDefaults.removeObject(forKey: "sharedContentType")
        userDefaults.removeObject(forKey: "sharedContentDate")

        switch contentKind {
        case .url:
            if let data = sharedContent.data(using: .utf8),
               let urlData = try? JSONSerialization.jsonObject(with: data) as? [String: String],
               let url = urlData["url"] {
                chatViewModel.sendMessage(url)
            } else {
                chatViewModel.sendMessage(sharedContent)
            }
        case .text:
            chatViewModel.sendMessage(sharedContent)
        }

        record(.sharedContentAccepted(contentKind))
    }

    func handleNostrRelayConnectionChanged(_ isConnected: Bool) {
        record(.nostrRelayConnectionChanged(isConnected))

        let becameConnected = isConnected && !lastNostrRelayConnectedState
        lastNostrRelayConnectedState = isConnected

        guard started, becameConnected else { return }

        let isInitialConnection = !didHandleInitialNostrConnection
        didHandleInitialNostrConnection = true

        if !chatViewModel.nostrHandlersSetup {
            chatViewModel.setupNostrMessageHandling()
            chatViewModel.nostrHandlersSetup = true
        }

        guard !isInitialConnection else { return }

        chatViewModel.resubscribeCurrentGeohash()
        chatViewModel.geoChannelCoordinator?.refreshSampling()
    }

    func announceInitialTorStatusIfNeeded() {
        if TorManager.shared.torEnforced &&
            !chatViewModel.torStatusAnnounced &&
            TorManager.shared.isAutoStartAllowed() {
            chatViewModel.torStatusAnnounced = true
            chatViewModel.addGeohashOnlySystemMessage(
                String(localized: "system.tor.starting", comment: "System message when Tor is starting")
            )
        } else if !TorManager.shared.torEnforced && !chatViewModel.torStatusAnnounced {
            chatViewModel.torStatusAnnounced = true
            chatViewModel.addGeohashOnlySystemMessage(
                String(localized: "system.tor.dev_bypass", comment: "System message when Tor bypass is enabled in development")
            )
        }
    }

    func handleScreenshotCaptured() {
        if appChromeModel.isLocationChannelsSheetPresented {
            appChromeModel.triggerScreenshotPrivacyWarning()
            return
        }

        if appChromeModel.isAppInfoPresented {
            return
        }

        chatViewModel.handleScreenshotCaptured()
    }

    func openExternalURL(_ url: URL) {
        #if os(iOS)
        UIApplication.shared.open(url)
        #else
        NSWorkspace.shared.open(url)
        #endif
    }

    func record(_ event: AppEvent) {
        Task {
            await events.emit(event)
        }
    }
}
