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
    let publicChatModel: PublicChatModel
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
        expireAgedMedia()
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
            isPeerResolvable: {
                Self.isDirectChatRestorable(
                    $0,
                    favorites: .shared,
                    hasStoredCryptographicIdentity: {
                        !chatViewModel.identityManager
                            .getCryptoIdentitiesByPeerIDPrefix($0.toShort())
                            .isEmpty
                    },
                    isPeerBlocked: { chatViewModel.isPeerBlocked($0) }
                )
            }
        )
        var didOpenDirectChat = false
        if case .restoredDirectChat(let peerID) = presentation {
            // `startPrivateChat`'s gate (ChatPeerIdentityCoordinator) rejects a
            // now-blocked peer by emitting a system message and returning
            // WITHOUT opening the chat. At launch that message would land in
            // the current (public mesh) timeline, so pass
            // `suppressSystemMessages: true` — the reject stays silent and we
            // detect it via `selectedPrivateChatPeer`, which is only set on the
            // success path.
            //
            // Not a second line of defence any more. Post-#1415 that gate
            // screens only self, group and blocked, so it catches nothing
            // `isDirectChatRestorable` has not already caught. It is kept for
            // the narrow race where the peer is blocked between the predicate
            // and this call, and for the silent-failure detection above.
            chatViewModel.startPrivateChat(with: peerID, suppressSystemMessages: true)
            didOpenDirectChat = chatViewModel.selectedPrivateChatPeer == peerID
        }
        // Fall back to the conversation list rather than silently landing on
        // the public mesh timeline when a restore target existed but could not
        // be opened.
        if Self.shouldPresentConversationList(for: presentation, didOpenDirectChat: didOpenDirectChat) {
            appChromeModel.showSidebar = true
        }
    }

    /// Whether a persisted last-active DM peer is genuinely restorable at
    /// launch — validated against *durable* relationship state, never live
    /// presence (mesh discovery is async, so no peer is connected yet). A
    /// syntactically valid `PeerID` is NOT sufficient: an unknown peer would
    /// otherwise fall straight through `startPrivateChat` into an empty phantom
    /// DM.
    ///
    /// Restorable iff the peer is NOT blocked and we hold durable evidence the
    /// conversation is real: either side has favorited the other, or we have a
    /// stored cryptographic identity for them.
    ///
    /// This tracks `ChatPeerIdentityCoordinator.startPrivateChat`, which #1415
    /// relaxed — it no longer requires a mutual favorite, on the grounds that
    /// store-and-forward (couriers, bridge drops, retained outbox) needs only
    /// the recipient's noise key, so "the router decides what delivery looks
    /// like, not chat entry". Keeping the old mutual-favorite rule here would
    /// have made launch-restore stricter than chat entry: a one-way-favorite or
    /// merely-known peer whose DM is perfectly sendable would fail to restore
    /// and drop the user on the conversation list instead.
    ///
    /// It cannot simply defer to that gate, though. Post-#1415 the open path
    /// screens only self, group and blocked, so this predicate is the sole
    /// defence against restoring into a phantom DM, and it has to hold the line
    /// on its own.
    ///
    /// The terms are chosen for durability at launch. Favorites are
    /// keychain-backed; stored cryptographic identities are on disk. The outbox
    /// and live Noise session state are deliberately NOT consulted — the outbox
    /// defers loading until protected data is available and session state is
    /// in-memory, so both read empty at launch regardless of the truth.
    ///
    /// Geohash/Nostr DMs stay excluded: a `nostr_` id's full Nostr key is
    /// rebuilt only from inbound ephemeral events, so at launch it cannot
    /// resolve, and `startPrivateChat` skips the handshake for geoDMs — a
    /// phantom would open with no error at all. Their one durable anchor is a
    /// favorite record, so for them the favorite terms decide and the identity
    /// term is refused outright.
    static func isDirectChatRestorable(
        _ peerID: PeerID,
        isPeerFavorited: (PeerID) -> Bool,
        theyFavoritedUs: (PeerID) -> Bool,
        hasStoredCryptographicIdentity: (PeerID) -> Bool,
        isPeerBlocked: (PeerID) -> Bool
    ) -> Bool {
        // Blocked stays a veto, never one term among several.
        guard !isPeerBlocked(peerID) else { return false }
        if isPeerFavorited(peerID) || theyFavoritedUs(peerID) { return true }
        // Explicit rather than incidental: a `nostr_` id does satisfy
        // `isShort` (the prefix is not part of the length check), and today it
        // misses only because the identity lookup re-attaches that prefix and
        // no hex fingerprint starts with it. That is luck, not a rule.
        guard !peerID.isGeoDM, !peerID.isGeoChat else { return false }
        return hasStoredCryptographicIdentity(peerID)
    }

    /// Production wiring of `isDirectChatRestorable`, extracted so the real
    /// favorites/block lookups (not just stub predicates) are unit-testable via
    /// an injected in-memory-keychain-backed `FavoritesPersistenceService` and a
    /// block closure. `migrateSelectedConversationIfNeeded` can persist the
    /// last-active peer in full 64-hex Noise-key form, but the favorites store is
    /// keyed by the short, Noise-key-derived id — so normalize with `toShort()`
    /// (a no-op on an already-short id) before the lookup, or favorited DMs
    /// silently fail to restore. The block lookup mirrors the open-path gate's
    /// `unifiedIsBlocked` (fingerprint-resolved, so it works for offline
    /// favorites).
    ///
    /// The identity lookup is passed in rather than reached for: it lives on
    /// the injected `SecureIdentityStateManagerProtocol`, so tests stub it the
    /// same way they stub the favorites service instead of sharing
    /// process-wide state. It needs the same `toShort()` normalization —
    /// `getCryptoIdentitiesByPeerIDPrefix` guards on `isShort` and returns an
    /// empty result otherwise, so a 64-hex id would read as "no identity"
    /// rather than as an error. Synchronous and disk-backed, so it is safe on
    /// the launch path.
    static func isDirectChatRestorable(
        _ peerID: PeerID,
        favorites: FavoritesPersistenceService,
        hasStoredCryptographicIdentity: (PeerID) -> Bool,
        isPeerBlocked: (PeerID) -> Bool
    ) -> Bool {
        isDirectChatRestorable(
            peerID,
            isPeerFavorited: {
                favorites.getFavoriteStatus(forPeerID: $0.toShort())?.isFavorite ?? false
            },
            theyFavoritedUs: {
                favorites.getFavoriteStatus(forPeerID: $0.toShort())?.theyFavoritedUs ?? false
            },
            hasStoredCryptographicIdentity: hasStoredCryptographicIdentity,
            isPeerBlocked: isPeerBlocked
        )
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

    /// Drops media that has outlived the retention window. Off the main thread
    /// and best-effort: the sweep walks the media tree, and nothing at launch
    /// depends on its result.
    private func expireAgedMedia() {
        Task(priority: .utility) {
            BLEIncomingFileStore().expireAgedMedia()
        }
    }

    func handleOpenURL(_ url: URL) {
        record(.openedURL(url.absoluteString))

        if url.scheme == "bitchat", url.host == "share" {
            checkForSharedContent()
        }
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
