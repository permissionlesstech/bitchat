import Foundation
import SwiftUI
import Tor

@MainActor
final class AppRuntime: ObservableObject {
    static let bundleID = Bundle.main.bundleIdentifier ?? "chat.bitchat"
    static let groupID = "group.\(bundleID)"

    let idBridge: NostrIdentityBridge
    let keychain: KeychainManager
    let identityManager: SecureIdentityStateManager
    let locationManager: LocationChannelManager
    let chatViewModel: ChatViewModel
    let publicTimelineStore: PublicTimelineStore
    let peerStore: UnifiedPeerService
    let privateConversationsStore: PrivateConversationsStore
    let geohashParticipantStore: GeohashParticipantTracker
    let composerStore: ComposerStore
    let sessionStore: SessionStore
    let peerPresentationStore: PeerPresentationStore
    let verificationStore: VerificationStore
    let geohashPeopleStore: GeohashPeopleStore
    let networkActivationService: NetworkActivationService
    let nostrRelayManager: NostrRelayManager
    let transportCore: BLETransportCore
    let transportEventBridge: TransportEventBridge
    let transportController: TransportRuntimeController

    private var didHandleInitialActive = false
    private var didEnterBackground = false
    private var started = false
    private var transportEventsTask: Task<Void, Never>?

    init(transport: Transport? = nil) {
        let keychain = KeychainManager()
        let idBridge = NostrIdentityBridge()
        let identityManager = SecureIdentityStateManager(keychain)
        let locationManager = LocationChannelManager.shared
        let networkActivationService = NetworkActivationService.shared
        let nostrRelayManager = NostrRelayManager.shared
        let meshTransport = transport ?? BLEService(
            keychain: keychain,
            idBridge: idBridge,
            identityManager: identityManager
        )
        let chatViewModel = ChatViewModel(
            keychain: keychain,
            idBridge: idBridge,
            identityManager: identityManager,
            transport: meshTransport,
            locationManager: locationManager,
            nostrRelayManager: nostrRelayManager
        )

        self.keychain = keychain
        self.idBridge = idBridge
        self.identityManager = identityManager
        self.locationManager = locationManager
        self.chatViewModel = chatViewModel
        let composerStore = chatViewModel.composerStore
        let sessionStore = chatViewModel.sessionStore
        let geohashPeopleStore = chatViewModel.geohashPeopleStore
        let peerPresentationStore = chatViewModel.peerPresentationStore
        let transportCore = BLETransportCore()
        let transportEventBridge = TransportEventBridge(transportCore: transportCore)
        let verificationStore = chatViewModel.verificationStore
        let transportController = TransportRuntimeController(
            viewModel: chatViewModel,
            sessionStore: sessionStore,
            publicTimelineStore: chatViewModel.timelineStore,
            privateConversationsStore: chatViewModel.privateChatManager,
            peerStore: chatViewModel.unifiedPeerService,
            peerPresentationStore: peerPresentationStore,
            transportEventBridge: transportEventBridge
        )

        self.publicTimelineStore = chatViewModel.timelineStore
        self.peerStore = chatViewModel.unifiedPeerService
        self.privateConversationsStore = chatViewModel.privateChatManager
        self.geohashParticipantStore = chatViewModel.participantTracker
        self.composerStore = composerStore
        self.sessionStore = sessionStore
        self.geohashPeopleStore = geohashPeopleStore
        self.peerPresentationStore = peerPresentationStore
        self.networkActivationService = networkActivationService
        self.nostrRelayManager = nostrRelayManager
        self.transportCore = transportCore
        self.transportEventBridge = transportEventBridge
        self.verificationStore = verificationStore
        self.transportController = transportController

        transportController.bind()
        bindTransportEvents()
        GeoRelayDirectory.shared.prefetchIfNeeded()
    }

    func start() {
        guard !started else { return }
        started = true

        NotificationDelegate.shared.chatViewModel = chatViewModel
        NotificationDelegate.shared.locationManager = locationManager
        chatViewModel.meshService.setApplicationActive(true)

        verificationStore.warmQRCodeCache()

        networkActivationService.start()
        GeohashPresenceService.shared.start()
    }

    func attach(_ notificationDelegate: NotificationDelegate = .shared) {
        notificationDelegate.chatViewModel = chatViewModel
        notificationDelegate.locationManager = locationManager
    }

    func enterBackground() {
        chatViewModel.meshService.setApplicationActive(false)
        TorManager.shared.setAppForeground(false)
        TorManager.shared.goDormantOnBackground()
        Task { @MainActor in
            chatViewModel.endGeohashSampling()
        }
        nostrRelayManager.disconnect()
        didEnterBackground = true
    }

    func enterForeground() {
        chatViewModel.meshService.setApplicationActive(true)
        chatViewModel.meshService.startServices()
        TorManager.shared.setAppForeground(true)

        if didHandleInitialActive && didEnterBackground {
            if TorManager.shared.isAutoStartAllowed() && !TorManager.shared.isReady {
                TorManager.shared.ensureRunningOnForeground()
            }
        } else {
            didHandleInitialActive = true
        }

        didEnterBackground = false

        if TorManager.shared.isAutoStartAllowed() {
            Task.detached {
                let _ = await TorManager.shared.awaitReady(timeout: 60)
                await MainActor.run {
                    TorURLSession.shared.rebuild()
                    self.nostrRelayManager.resetAllConnections()
                }
            }
        }
    }

    func shutdown() {
        chatViewModel.applicationWillTerminate()
    }

    func handleURL(_ url: URL) {
        if url.scheme == "bitchat" && url.host == "share" {
            checkForSharedContent()
        }
    }

    func checkForSharedContent() {
        guard let userDefaults = UserDefaults(suiteName: Self.groupID) else {
            return
        }

        guard let sharedContent = userDefaults.string(forKey: "sharedContent"),
              let sharedDate = userDefaults.object(forKey: "sharedContentDate") as? Date else {
            return
        }

        if Date().timeIntervalSince(sharedDate) < TransportConfig.uiShareAcceptWindowSeconds {
            let contentType = userDefaults.string(forKey: "sharedContentType") ?? "text"

            userDefaults.removeObject(forKey: "sharedContent")
            userDefaults.removeObject(forKey: "sharedContentType")
            userDefaults.removeObject(forKey: "sharedContentDate")

            if contentType == "url" {
                if let data = sharedContent.data(using: .utf8),
                   let urlData = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                   let url = urlData["url"] {
                    chatViewModel.sendMessage(url)
                } else {
                    chatViewModel.sendMessage(sharedContent)
                }
            } else {
                chatViewModel.sendMessage(sharedContent)
            }
        }
    }

    private func bindTransportEvents() {
        transportEventsTask?.cancel()
        transportEventsTask = Task { [weak self] in
            guard let self else { return }

            let events = await transportCore.subscribe()
            for await event in events {
                await MainActor.run {
                    self.transportController.handle(event)
                }
            }
        }
    }
}
