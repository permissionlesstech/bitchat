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
    /// The selected channel's timeline: the one compact timeline, and the
    /// split layout's trailing pane.
    let publicChatModel: PublicChatModel
    #if os(iOS)
    /// The split layout's leading pane: #mesh, whatever is selected.
    let meshPaneTimeline: PublicChatModel
    #endif
    let privateInboxModel: PrivateInboxModel
    let privateConversationModel: PrivateConversationModel
    let verificationModel: VerificationModel
    let conversationUIModel: ConversationUIModel
    let locationChannelsModel: LocationChannelsModel
    let peerListModel: PeerListModel
    let appChromeModel: AppChromeModel
    let boardAlertsModel: BoardAlertsModel
    let sharedContentImportModel: SharedContentImportModel

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
        idBridge: NostrIdentityBridge = NostrIdentityBridge(),
        sharedContentStore: SharedContentStore? = nil
    ) {
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
        self.publicChatModel = PublicChatModel(conversations: conversations)
        #if os(iOS)
        self.meshPaneTimeline = PublicChatModel(conversations: conversations, pinnedTo: .mesh)
        #endif
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
            conversations: conversations
        )
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
        } else if let sharedDefaults = UserDefaults(suiteName: BitchatApp.groupID) {
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

        record(.launched)
        record(.startupCompleted)
    }

    /// Drops media that has outlived the retention window, then applies the
    /// explicit protection class to files that older builds wrote without
    /// one. Expiry runs first so the migration never touches files the
    /// sweep is about to delete. Detached because `AppRuntime` is
    /// main-actor and both passes go file by file through the media tree;
    /// best-effort, nothing at launch depends on their results.
    private func performMediaMaintenance() {
        Task.detached(priority: .utility) {
            let store = BLEIncomingFileStore()
            store.expireAgedMedia()
            store.migrateFileProtectionIfNeeded()
        }
    }

    func handleOpenURL(_ url: URL) {
        record(.openedURL(url.absoluteString))

        if url.scheme == "bitchat", url.host == "share" {
            checkForSharedContent()
        }

        // External #geohash links (geo-activity notification taps, shared
        // invites) open the channel here, once. Message lists only act on the
        // links they draw: each mounted list (two in the split layout) would
        // open, and switch to, the channel again.
        if let geohash = Self.geohashLinkTarget(url), chatViewModel.networkActivationAllowed {
            locationChannelsModel.openLocationChannel(for: geohash)
        }
    }

    /// The geohash a `bitchat://geohash/<geohash>` link names, or nil for any
    /// other URL. `openLocationChannel(for:)` validates it.
    nonisolated static func geohashLinkTarget(_ url: URL) -> String? {
        guard url.scheme == "bitchat", url.host == "geohash" else { return nil }
        let geohash = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return geohash.isEmpty ? nil : geohash
    }

    func handleDidBecomeActiveNotification() {
        guard chatViewModel.networkActivationAllowed else { return }
        chatViewModel.handleDidBecomeActive()
        checkForSharedContent()
    }

    #if os(macOS)
    func handleMacDidBecomeActiveNotification() {
        guard chatViewModel.networkActivationAllowed else { return }
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
            guard chatViewModel.networkActivationAllowed else { return }
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
                guard self?.chatViewModel.networkActivationAllowed == true
                else { return }
                self?.record(.torLifecycleChanged(.willRestart))
                self?.chatViewModel.handleTorWillRestart()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .TorDidBecomeReady)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard self?.chatViewModel.networkActivationAllowed == true
                else { return }
                self?.record(.torLifecycleChanged(.didBecomeReady))
                self?.chatViewModel.handleTorDidBecomeReady()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .TorWillStart)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard self?.chatViewModel.networkActivationAllowed == true
                else { return }
                self?.record(.torLifecycleChanged(.willStart))
                self?.chatViewModel.handleTorWillStart()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .TorBootstrapDidStall)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard self?.chatViewModel.networkActivationAllowed == true
                else { return }
                self?.record(.torLifecycleChanged(.bootstrapDidStall))
                self?.chatViewModel.handleTorBootstrapDidStall()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .TorUserPreferenceChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard self?.chatViewModel.networkActivationAllowed == true
                else { return }
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
        let previousID = sharedContentImportModel.offer?.id
        guard let payload = sharedContentImportModel.refresh(
            destination: currentSharedContentDestination
        ) else { return }

        if previousID != payload.id {
            record(.sharedContentReadyForReview(payload.kind))
        }
    }

    var currentSharedContentDestination: SharedContentDestination {
        SharedContentDestination.resolve(
            selectedPrivatePeerID: privateConversationModel.selectedPeerID,
            privateDisplayName: privateConversationModel.selectedHeaderState?.displayName,
            activeChannel: locationChannelsModel.selectedChannel
        )
    }

    func handleNostrRelayConnectionChanged(_ isConnected: Bool) {
        record(.nostrRelayConnectionChanged(isConnected))

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
        let isLocationChannelActive: Bool = {
            if case .location = chatViewModel.activeChannel { return true }
            return false
        }()
        #if os(iOS)
        let splitLayoutShowsLocation = appChromeModel.splitLayoutShowsLocation
        #else
        let splitLayoutShowsLocation: Bool? = nil
        #endif

        switch Self.resolveScreenshotResponse(
            isLocationChannelsSheetPresented: appChromeModel.isLocationChannelsSheetPresented,
            isAppInfoPresented: appChromeModel.isAppInfoPresented,
            hasPrivateChatOpen: chatViewModel.selectedPrivateChatPeer != nil,
            isLocationChannelActive: isLocationChannelActive,
            splitLayoutShowsLocation: splitLayoutShowsLocation
        ) {
        case .warnLocally:
            appChromeModel.triggerScreenshotPrivacyWarning()
        case .ignore:
            break
        case .forwardToChat:
            chatViewModel.handleScreenshotCaptured()
        case .warnLocallyAndForwardToChat:
            appChromeModel.triggerScreenshotPrivacyWarning()
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

    func record(_ event: AppEvent) {
        Task {
            await events.emit(event)
        }
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
        /// Both of the above: the image reveals a place and an open DM, so
        /// the person gets the warning and the peer the DM's notice.
        case warnLocallyAndForwardToChat
    }

    /// Pure decision table so the screenshot routing is testable without a
    /// runtime.
    /// - Parameter splitLayoutShowsLocation: The split layout's trailing
    ///   pane shows a place (a geohash timeline or the location-channel
    ///   picker) rather than a DM; nil for the single column, where the
    ///   selection and the DM sheet decide.
    nonisolated static func resolveScreenshotResponse(
        isLocationChannelsSheetPresented: Bool,
        isAppInfoPresented: Bool,
        hasPrivateChatOpen: Bool,
        isLocationChannelActive: Bool,
        splitLayoutShowsLocation: Bool? = nil
    ) -> ScreenshotCaptureResponse {
        if isLocationChannelsSheetPresented { return .warnLocally }
        if isAppInfoPresented { return .ignore }
        if let splitLayoutShowsLocation {
            // Split, the panes say what is in the image. A DM covering the
            // trailing pane reveals no place; the #mesh pane beside it
            // reveals none either.
            guard splitLayoutShowsLocation else { return .forwardToChat }
            return hasPrivateChatOpen ? .warnLocallyAndForwardToChat : .warnLocally
        }
        // A geohash timeline screenshot still reveals a place — warn the
        // person taking it, locally, with the same alert the channel sheet
        // uses. The DM's sheet covers it.
        if isLocationChannelActive, !hasPrivateChatOpen { return .warnLocally }
        return .forwardToChat
    }
}
