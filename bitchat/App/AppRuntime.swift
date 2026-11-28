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
    /// Single source of truth for conversation message state and selection
    /// (docs/CONVERSATION-STORE-DESIGN.md). Owned here; the feature models
    /// and `ChatViewModel` observe and mutate it through its intent API.
    let conversations: ConversationStore
    let publicChatModel: PublicChatModel
    let privateInboxModel: PrivateInboxModel
    let privateConversationModel: PrivateConversationModel
    let verificationModel: VerificationModel
    let conversationUIModel: ConversationUIModel
    let composerAutocompleteModel: ComposerAutocompleteModel
    let composerDraftModel = ComposerDraftModel()
    let locationChannelsModel: LocationChannelsModel
    let peerListModel: PeerListModel
    let appChromeModel: AppChromeModel
    let boardAlertsModel: BoardAlertsModel
    let sharedContentImportModel: SharedContentImportModel

    var environmentModels: AppEnvironmentModels {
        AppEnvironmentModels(
            publicChatModel: publicChatModel,
            privateInboxModel: privateInboxModel,
            privateConversationModel: privateConversationModel,
            verificationModel: verificationModel,
            conversationUIModel: conversationUIModel,
            composerAutocompleteModel: composerAutocompleteModel,
            composerDraftModel: composerDraftModel,
            locationChannelsModel: locationChannelsModel,
            peerListModel: peerListModel,
            appChromeModel: appChromeModel,
            boardAlertsModel: boardAlertsModel,
            sharedContentImportModel: sharedContentImportModel
        )
    }

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
        keychain: KeychainManagerProtocol = KeychainManager.makeDefault(),
        idBridge: NostrIdentityBridge = .shared,
        sharedContentStore: SharedContentStore? = nil
    ) {
        if !TestEnvironment.isRunningTests {
            PrivacyModeSettings.migrateLegacyInstallIfNeeded()
        }
        self.idBridge = idBridge
        let conversations = ConversationStore()
        let peerIdentityStore = PeerIdentityStore()
        let locationPresenceStore = LocationPresenceStore()
        let locationManager = LocationChannelManager.shared
        self.conversations = conversations
        self.chatViewModel = ChatViewModel(
            keychain: keychain,
            idBridge: idBridge,
            identityManager: SecureIdentityStateManager(keychain),
            conversations: conversations,
            peerIdentityStore: peerIdentityStore,
            locationPresenceStore: locationPresenceStore,
            locationManager: locationManager
        )
        let chatVMForPublicModel = self.chatViewModel
        self.publicChatModel = PublicChatModel(
            conversations: conversations,
            myPeerIDProvider: { [weak chatVMForPublicModel] in
                chatVMForPublicModel?.meshService.myPeerID
            }
        )
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
        self.composerAutocompleteModel = ComposerAutocompleteModel(chatViewModel: self.chatViewModel)
        self.peerListModel = PeerListModel(
            chatViewModel: self.chatViewModel,
            conversations: conversations,
            locationChannelsModel: self.locationChannelsModel,
            peerIdentityStore: peerIdentityStore,
            locationPresenceStore: locationPresenceStore
        )
        let resolvedSharedContentStore: SharedContentStore?
        if let sharedContentStore {
            resolvedSharedContentStore = sharedContentStore
        } else if let sharedDefaults = BitchatApp.sharedUserDefaults() {
            resolvedSharedContentStore = SharedContentStore(defaults: sharedDefaults)
        } else {
            resolvedSharedContentStore = nil
        }
        let sharedContentImportModel = SharedContentImportModel(store: resolvedSharedContentStore)
        self.sharedContentImportModel = sharedContentImportModel
        self.appChromeModel = AppChromeModel(
            chatViewModel: self.chatViewModel,
            privateInboxModel: self.privateInboxModel,
            onPanicWipe: { sharedContentImportModel.discardAll() }
        )
        let chatViewModel = self.chatViewModel
        self.boardAlertsModel = BoardAlertsModel(
            arrivals: BoardStore.shared.postArrivals.eraseToAnyPublisher(),
            wipes: BoardStore.shared.didWipe.eraseToAnyPublisher(),
            dependencies: BoardAlertsModel.Dependencies(
                isOwnPost: { post in
                    let key = chatViewModel.meshService.noiseSigningPublicKeyData()
                    return !key.isEmpty && key == post.authorSigningKey
                },
                emitSystemLine: { content, geohash in
                    if geohash.isEmpty {
                        chatViewModel.addMeshOnlySystemMessage(content)
                    } else {
                        chatViewModel.addGeohashSystemMessage(content, geohash: geohash)
                    }
                }
            )
        )
        if chatViewModel.networkActivationAllowed {
            GeoRelayDirectory.shared.prefetchIfNeeded()
        }
        bindRuntimeObservers()
        NotificationDelegate.shared.runtime = self
    }

    func start() {
        guard chatViewModel.networkActivationAllowed else { return }
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
        performMediaMaintenance()
    }

    /// Drops media that has outlived the retention window, then applies the
    /// explicit protection class to files that older builds wrote without
    /// one. Expiry runs first so the migration never touches files the
    /// sweep is about to delete. Detached because `AppRuntime` is
    /// main-actor and both passes go file by file through the media tree;
    /// best-effort, nothing at launch depends on their results.
    private func performMediaMaintenance() {
        Task.detached(priority: .utility) {
            let store = BLEIncomingFileStore.shared
            store.expireAgedMedia()
            store.migrateFileProtectionIfNeeded()
        }
    }

    func handleOpenURL(_ url: URL) {
        if url.scheme == "bitchat", url.host == "share" {
            checkForSharedContent()
            return
        }
        if let invite = FriendInvite.parse(url: url) {
            _ = chatViewModel.acceptFriendInvite(invite)
            return
        }
        if url.scheme?.lowercased() == "bitchat",
           url.host?.lowercased() == "geohash" {
            let geohash = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
            if Geohash.isValidGeohash(geohash) {
                locationChannelsModel.teleport(to: geohash)
            }
        }
    }

    func handleDidBecomeActiveNotification() {
        guard chatViewModel.networkActivationAllowed else { return }
        chatViewModel.handleDidBecomeActive()
        checkForSharedContent()
    }

    #if os(macOS)
    func handleMacDidBecomeActiveNotification() {
        chatViewModel.setAppActive(true)
        guard chatViewModel.networkActivationAllowed else { return }
        chatViewModel.handleDidBecomeActive()
        checkForSharedContent()
    }
    #endif

    #if os(iOS)
    func handleScenePhaseChange(_ newPhase: ScenePhase) {
        switch newPhase {
        case .background:
            chatViewModel.flushPersistedPrivateHistorySynchronously()
            chatViewModel.setAppActive(false)
            TorManager.shared.setAppForeground(false)
            TorManager.shared.goDormantOnBackground()
            LocationStateManager.shared.endLiveRefresh()
            chatViewModel.endGeohashSampling()
            NostrRelayManager.shared.disconnect()
            didEnterBackground = true

        case .active:
            chatViewModel.setAppActive(true)
            guard chatViewModel.networkActivationAllowed else { return }
            chatViewModel.meshService.startServices()
            TorManager.shared.setAppForeground(true)

            let reconnectAction = Self.resolveForegroundNostrReconnectAction(
                didEnterBackground: didEnterBackground,
                activationAllowed: NetworkActivationService.shared.activationAllowed,
                userTorEnabled: NetworkActivationService.shared.userTorEnabled,
                torAutoStartAllowed: TorManager.shared.isAutoStartAllowed()
            )
            didHandleInitialActive = true
            didEnterBackground = false

            switch reconnectAction {
            case .none:
                break
            case .reconnectDirect:
                TorURLSession.shared.rebuild()
                NostrRelayManager.shared.resetAllConnections()
            case .awaitTorAndReconnect:
                if !TorManager.shared.isReady {
                    TorManager.shared.ensureRunningOnForeground()
                }
                Task.detached { [weak self] in
                    let ready = await TorManager.shared.awaitReady(timeout: 60)
                    guard ready else { return }
                    await MainActor.run {
                        guard let self,
                              self.chatViewModel.networkActivationAllowed,
                              NetworkActivationService.shared.activationAllowed,
                              NetworkActivationService.shared.userTorEnabled else { return }
                        TorURLSession.shared.rebuild()
                        NostrRelayManager.shared.resetAllConnections()
                    }
                }
            }

            chatViewModel.pruneAllExpiredPrivateMessages()
            chatViewModel.handleDidBecomeActive()
            checkForSharedContent()

        case .inactive:
            chatViewModel.setAppActive(false)

        @unknown default:
            break
        }
    }
    #endif

    func applicationWillTerminate() {
        chatViewModel.flushPersistedPrivateHistorySynchronously()
        chatViewModel.applicationWillTerminate()
    }

    func handleNotificationResponse(
        identifier: String,
        actionIdentifier: String = UNNotificationDefaultActionIdentifier,
        userInfo: [AnyHashable: Any]
    ) {
        guard chatViewModel.networkActivationAllowed else { return }
        if actionIdentifier == NotificationService.waveActionID {
            chatViewModel.sendMeshWave()
            return
        }

        if identifier.hasPrefix("private-"), let peerID = PeerID(str: userInfo["peerID"] as? String) {
            chatViewModel.startPrivateChat(with: peerID)
        }

        if let deepLink = userInfo["deeplink"] as? String, let url = URL(string: deepLink) {
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
        NetworkActivationService.shared.$activationAllowed
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] allowed in
                guard allowed, let self, self.chatViewModel.networkActivationAllowed else { return }
                GeoRelayDirectory.shared.prefetchIfNeeded()
                // Recover any active location channel whose subscribe() was
                // dropped while offline or during the teleport activation race.
                self.chatViewModel.ensureCurrentGeohashSubscribed()
            }
            .store(in: &cancellables)

        NostrRelayManager.shared.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isConnected in
                self?.handleNostrRelayConnectionChanged(isConnected)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .TorWillRestart)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard self?.chatViewModel.networkActivationAllowed == true
                else { return }
                self?.chatViewModel.handleTorWillRestart()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .TorDidBecomeReady)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard self?.chatViewModel.networkActivationAllowed == true
                else { return }
                self?.chatViewModel.handleTorDidBecomeReady()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .TorWillStart)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard self?.chatViewModel.networkActivationAllowed == true
                else { return }
                self?.chatViewModel.handleTorWillStart()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .TorBootstrapDidStall)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard self?.chatViewModel.networkActivationAllowed == true
                else { return }
                self?.chatViewModel.handleTorBootstrapDidStall()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .TorUserPreferenceChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard self?.chatViewModel.networkActivationAllowed == true
                else { return }
                self?.chatViewModel.handleTorPreferenceChanged()
            }
            .store(in: &cancellables)

        #if os(iOS)
        NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleScreenshotCaptured()
            }
            .store(in: &cancellables)
        #elseif os(macOS)
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.chatViewModel.setAppActive(false)
            }
            .store(in: &cancellables)
        #endif
    }

    func checkForSharedContent() {
        _ = sharedContentImportModel.refresh(destination: currentSharedContentDestination)
    }

    var currentSharedContentDestination: SharedContentDestination {
        SharedContentDestination.resolve(
            selectedPrivatePeerID: privateConversationModel.selectedPeerID,
            privateDisplayName: privateConversationModel.selectedHeaderState?.displayName,
            activeChannel: locationChannelsModel.selectedChannel
        )
    }

    func handleNostrRelayConnectionChanged(_ isConnected: Bool) {
        let becameConnected = isConnected && !lastNostrRelayConnectedState
        lastNostrRelayConnectedState = isConnected

        guard chatViewModel.networkActivationAllowed,
              started,
              becameConnected else { return }

        let isInitialConnection = !didHandleInitialNostrConnection
        didHandleInitialNostrConnection = true

        if !chatViewModel.nostrHandlersSetup {
            chatViewModel.setupNostrMessageHandling()
            chatViewModel.nostrHandlersSetup = true
        }

        if isInitialConnection {
            // If the app launched offline (or teleported before activation
            // opened), the active geohash subscription and sampling were
            // dropped before relays came up. Ensure they are registered now
            // without disturbing an already-subscribed online launch.
            chatViewModel.ensureCurrentGeohashSubscribed()
            chatViewModel.geoChannelCoordinator?.refreshSampling()
            return
        }

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
        let isLocationChannelActive: Bool = {
            if case .location = chatViewModel.activeChannel { return true }
            return false
        }()

        switch Self.resolveScreenshotResponse(
            isLocationChannelsSheetPresented: appChromeModel.isLocationChannelsSheetPresented,
            isAppInfoPresented: appChromeModel.isAppInfoPresented,
            hasPrivateChatOpen: chatViewModel.selectedPrivateChatPeer != nil,
            isLocationChannelActive: isLocationChannelActive
        ) {
        case .warnLocally:
            appChromeModel.triggerScreenshotPrivacyWarning()
        case .ignore:
            break
        case .forwardToChat:
            chatViewModel.handleScreenshotCaptured()
        }
    }

    func openExternalURL(_ url: URL) {
        #if os(iOS)
        UIApplication.shared.open(url)
        #else
        NSWorkspace.shared.open(url)
        #endif
    }
}

// MARK: - Screenshot routing

extension AppRuntime {
    /// What a screenshot triggers. Nothing on this table sends anything to
    /// a public channel (see `ChatLifecycleCoordinator.handleScreenshotCaptured`).
    enum ScreenshotCaptureResponse: Equatable {
        /// Show the local location-privacy alert; nothing is sent anywhere.
        case warnLocally
        /// Do nothing. App Info holds no conversation or location content.
        case ignore
        /// Hand to the chat layer: a DM notice goes to the peer when a
        /// secure session exists; public timelines stay silent. Mesh
        /// deliberately gets no local alert either — a mesh screenshot
        /// reveals no place and triggers no send, so there is nothing to
        /// warn about, and alerting on every screenshot would train people
        /// to dismiss the one alert that matters (the location one).
        case forwardToChat
    }

    /// Pure decision table so the screenshot routing is testable without a
    /// runtime.
    nonisolated static func resolveScreenshotResponse(
        isLocationChannelsSheetPresented: Bool,
        isAppInfoPresented: Bool,
        hasPrivateChatOpen: Bool,
        isLocationChannelActive: Bool
    ) -> ScreenshotCaptureResponse {
        if isLocationChannelsSheetPresented { return .warnLocally }
        if isAppInfoPresented { return .ignore }
        // A geohash timeline screenshot still reveals a place — warn the
        // person taking it, locally, with the same alert the channel sheet
        // uses.
        if !hasPrivateChatOpen, isLocationChannelActive { return .warnLocally }
        return .forwardToChat
    }
}

// MARK: - Foreground Nostr reconnection

extension AppRuntime {
    enum ForegroundNostrReconnectAction: Equatable {
        case none
        case reconnectDirect
        case awaitTorAndReconnect
    }

    /// Pure decision table for foreground Nostr recovery after `.background`
    /// disconnected relay sockets. Everyday Mode (Tor off) must reconnect
    /// directly instead of gating on `TorManager.isAutoStartAllowed()`.
    nonisolated static func resolveForegroundNostrReconnectAction(
        didEnterBackground: Bool,
        activationAllowed: Bool,
        userTorEnabled: Bool,
        torAutoStartAllowed: Bool
    ) -> ForegroundNostrReconnectAction {
        guard didEnterBackground, activationAllowed else { return .none }
        if userTorEnabled {
            return torAutoStartAllowed ? .awaitTorAndReconnect : .none
        }
        return .reconnectDirect
    }
}
