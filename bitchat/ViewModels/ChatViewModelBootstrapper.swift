import BitFoundation
import BitLogger
import Combine
import Foundation

struct ChatViewModelServiceBundle {
    let commandProcessor: CommandProcessor
    let messageRouter: MessageRouter
    let privateChatManager: PrivateChatManager
    let unifiedPeerService: UnifiedPeerService
    let autocompleteService: AutocompleteService
    let deduplicationService: MessageDeduplicationService
    let publicMessagePipeline: PublicMessagePipeline

    @MainActor
    init(
        keychain: KeychainManagerProtocol,
        idBridge: NostrIdentityBridge,
        identityManager: SecureIdentityStateManagerProtocol,
        meshService: Transport
    ) {
        let commandProcessor = CommandProcessor(identityManager: identityManager)
        let privateChatManager = PrivateChatManager(meshService: meshService)
        let unifiedPeerService = UnifiedPeerService(
            meshService: meshService,
            idBridge: idBridge,
            identityManager: identityManager
        )
        let nostrTransport = NostrTransport(keychain: keychain, idBridge: idBridge)
        nostrTransport.senderPeerID = meshService.myPeerID
        let messageRouter = MessageRouter(transports: [meshService, nostrTransport])

        self.commandProcessor = commandProcessor
        self.messageRouter = messageRouter
        self.privateChatManager = privateChatManager
        self.unifiedPeerService = unifiedPeerService
        self.autocompleteService = AutocompleteService()
        self.deduplicationService = MessageDeduplicationService()
        self.publicMessagePipeline = PublicMessagePipeline()
    }
}

@MainActor
final class ChatViewModelBootstrapper {
    private unowned let viewModel: ChatViewModel

    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
    }

    static func loadPersistedReadReceipts(userDefaults: UserDefaults = .standard) -> Set<String> {
        guard let data = userDefaults.data(forKey: "sentReadReceipts"),
              let receipts = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(receipts)
    }

    func configure() {
        wireServiceGraph()
        bindFeatureObjectChanges()
        loadPersistedViewState()
        configureTransport()
        startRuntimeServices()
        bindPeerService()
        configureNoiseCallbacks()
        bindTransferProgress()
        configureGeoChannels()
        bindTeleportState()
        requestNotifications()
        registerObservers()
    }
}

private extension ChatViewModelBootstrapper {
    func wireServiceGraph() {
        viewModel.privateChatManager.messageRouter = viewModel.messageRouter
        viewModel.privateChatManager.unifiedPeerService = viewModel.unifiedPeerService
        viewModel.unifiedPeerService.messageRouter = viewModel.messageRouter
        viewModel.commandProcessor.contextProvider = viewModel
        viewModel.commandProcessor.meshService = viewModel.meshService
        viewModel.participantTracker.configure(context: viewModel)
    }

    func bindFeatureObjectChanges() {
        viewModel.privateChatManager.objectWillChange
            .sink { [weak viewModel] _ in
                viewModel?.objectWillChange.send()
            }
            .store(in: &viewModel.cancellables)

        viewModel.privateChatManager.$privateChats
            .receive(on: DispatchQueue.main)
            .sink { [weak viewModel] _ in
                Task { @MainActor [weak viewModel] in
                    viewModel?.synchronizePrivateConversationStore()
                }
            }
            .store(in: &viewModel.cancellables)

        viewModel.privateChatManager.$unreadMessages
            .receive(on: DispatchQueue.main)
            .sink { [weak viewModel] _ in
                Task { @MainActor [weak viewModel] in
                    viewModel?.synchronizePrivateConversationStore()
                }
            }
            .store(in: &viewModel.cancellables)

        viewModel.privateChatManager.$selectedPeer
            .receive(on: DispatchQueue.main)
            .sink { [weak viewModel] _ in
                Task { @MainActor [weak viewModel] in
                    viewModel?.synchronizeConversationSelectionStore()
                }
            }
            .store(in: &viewModel.cancellables)

        viewModel.participantTracker.objectWillChange
            .sink { [weak viewModel] _ in
                viewModel?.objectWillChange.send()
            }
            .store(in: &viewModel.cancellables)
    }

    func loadPersistedViewState() {
        viewModel.loadNickname()
        viewModel.loadVerifiedFingerprints()
    }

    func configureTransport() {
        viewModel.meshService.delegate = viewModel

        DispatchQueue.main.asyncAfter(deadline: .now() + TransportConfig.uiStartupInitialDelaySeconds) { [weak viewModel] in
            guard let viewModel else { return }
            _ = viewModel.getMyFingerprint()
        }

        viewModel.meshService.setNickname(viewModel.nickname)
    }

    func startRuntimeServices() {
        viewModel.meshService.startServices()

        viewModel.publicMessagePipeline.delegate = viewModel.publicConversationCoordinator
        viewModel.publicMessagePipeline.updateActiveChannel(viewModel.activeChannel)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak viewModel] in
            guard let viewModel,
                  let bleService = viewModel.meshService as? BLEService else { return }
            let state = bleService.getCurrentBluetoothState()
            viewModel.updateBluetoothState(state)
        }

        viewModel.nostrRelayManager = NostrRelayManager.shared
        viewModel.messageRouter.flushAllOutbox()

        Task { @MainActor [weak viewModel] in
            guard let viewModel else { return }
            try? await Task.sleep(
                nanoseconds: UInt64(TransportConfig.uiStartupPhaseDurationSeconds * 1_000_000_000)
            )
            viewModel.isStartupPhase = false
        }
    }

    func bindPeerService() {
        viewModel.unifiedPeerService.$peers
            .receive(on: DispatchQueue.main)
            .sink { [weak viewModel] peers in
                Task { @MainActor [weak viewModel] in
                    guard let viewModel else { return }

                    viewModel.allPeers = peers
                    viewModel.identityResolver.register(peers: peers)

                    var uniquePeers: [PeerID: BitchatPeer] = [:]
                    for peer in peers {
                        if uniquePeers[peer.peerID] == nil {
                            uniquePeers[peer.peerID] = peer
                        } else {
                            SecureLogger.warning(
                                "⚠️ Duplicate peer ID detected: \(peer.peerID) (\(peer.displayName))",
                                category: .session
                            )
                        }
                    }
                    viewModel.peerIndex = uniquePeers

                    if viewModel.hasTrackedPrivateChatSelection {
                        viewModel.updatePrivateChatPeerIfNeeded()
                    }

                    viewModel.synchronizePrivateConversationStore()
                    viewModel.synchronizeConversationSelectionStore()
                }
            }
            .store(in: &viewModel.cancellables)
    }

    func configureNoiseCallbacks() {
        viewModel.setupNoiseCallbacks()
    }

    func bindTransferProgress() {
        TransferProgressManager.shared.publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak viewModel] event in
                Task { @MainActor [weak viewModel] in
                    viewModel?.handleTransferEvent(event)
                }
            }
            .store(in: &viewModel.cancellables)
    }

    func configureGeoChannels() {
        viewModel.geoChannelCoordinator = GeoChannelCoordinator(
            locationManager: viewModel.locationManager,
            onChannelSwitch: { [weak viewModel] channel in
                viewModel?.switchLocationChannel(to: channel)
            },
            beginSampling: { [weak viewModel] geohashes in
                viewModel?.beginGeohashSampling(for: geohashes)
            },
            endSampling: { [weak viewModel] in
                viewModel?.endGeohashSampling()
            }
        )
    }

    func bindTeleportState() {
        viewModel.locationManager.$teleported
            .receive(on: DispatchQueue.main)
            .sink { [weak viewModel] isTeleported in
                guard let viewModel else { return }
                Task { @MainActor [weak viewModel] in
                    guard let viewModel,
                          case .location(let channel) = viewModel.activeChannel,
                          let identity = try? viewModel.idBridge.deriveIdentity(forGeohash: channel.geohash)
                    else {
                        return
                    }

                    let key = identity.publicKeyHex.lowercased()
                    let hasRegional = !viewModel.locationManager.availableChannels.isEmpty
                    let inRegional = viewModel.locationManager.availableChannels.contains {
                        $0.geohash == channel.geohash
                    }

                    if isTeleported && hasRegional && !inRegional {
                        viewModel.locationPresenceStore.markTeleported(key)
                    } else {
                        viewModel.locationPresenceStore.clearTeleported(key)
                    }
                }
            }
            .store(in: &viewModel.cancellables)
    }

    func requestNotifications() {
        NotificationService.shared.requestAuthorization()
    }

    func registerObservers() {
        NotificationCenter.default.addObserver(
            viewModel,
            selector: #selector(ChatViewModel.handleFavoriteStatusChanged(_:)),
            name: .favoriteStatusChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            viewModel,
            selector: #selector(ChatViewModel.handlePeerStatusUpdate(_:)),
            name: Notification.Name("peerStatusUpdated"),
            object: nil
        )
    }
}
