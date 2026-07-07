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
        meshService: Transport,
        outboxStore: MessageOutboxStore? = nil,
        sfMetrics: StoreAndForwardMetrics? = nil
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
        let messageRouter = MessageRouter(
            transports: [meshService, nostrTransport],
            outboxStore: outboxStore,
            metrics: sfMetrics
        )

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
        configureGateway()
        bindTeleportState()
        requestNotifications()
        registerObservers()
    }
}

private extension ChatViewModelBootstrapper {
    func wireServiceGraph() {
        viewModel.privateChatManager.conversationStore = viewModel.conversations
        viewModel.privateChatManager.messageRouter = viewModel.messageRouter
        viewModel.privateChatManager.unifiedPeerService = viewModel.unifiedPeerService
        viewModel.unifiedPeerService.messageRouter = viewModel.messageRouter
        // Surface silent outbox drops (attempt cap, TTL expiry, overflow
        // eviction) as a visible failure. The store's no-downgrade rule does
        // not cover `.failed` over confirmed receipts, so guard here: a drop
        // of an already-delivered/read message (e.g. a stale retained copy)
        // must not downgrade its status.
        viewModel.messageRouter.onMessageDropped = { [weak viewModel] messageID, peerID in
            guard let viewModel else { return }
            switch viewModel.conversations.deliveryStatus(forMessageID: messageID) {
            case .delivered, .read:
                // Field proof of the no-downgrade guard: the drop arrived
                // after a confirmed receipt, so the `.failed` write is
                // deliberately skipped.
                SecureLogger.warning(
                    "📤 Router dropped message \(messageID.prefix(8))… for \(peerID.id.prefix(8))… → .failed skipped (already delivered/read)",
                    category: .session
                )
            default:
                SecureLogger.warning(
                    "📤 Router dropped message \(messageID.prefix(8))… for \(peerID.id.prefix(8))… → marked failed",
                    category: .session
                )
                viewModel.conversations.setDeliveryStatus(
                    .failed(reason: String(localized: "content.delivery.reason.not_delivered", comment: "Failure reason shown when the router gave up delivering a message")),
                    forMessageID: messageID
                )
            }
        }
        // A message with no reachable transport that was handed to a courier
        // shows a distinct "carried" state instead of sitting in "sending"
        // forever. Never downgrade a confirmed receipt: the courier copy can
        // race direct delivery when the peer reappears.
        viewModel.messageRouter.onMessageCarried = { [weak viewModel] messageID, peerID in
            guard let viewModel else { return }
            switch viewModel.conversations.deliveryStatus(forMessageID: messageID) {
            case .delivered, .read:
                break
            default:
                SecureLogger.debug(
                    "📦 Message \(messageID.prefix(8))… for \(peerID.id.prefix(8))… handed to courier → marked carried",
                    category: .session
                )
                viewModel.conversations.setDeliveryStatus(.carried, forMessageID: messageID)
            }
        }
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

        // Private message state flows through the single-writer
        // `ConversationStore` intents and its `changes` subject; selection
        // is owned by the store too (`PrivateChatManager.selectedPeer` is a
        // read-only mirror), so no selection bridge is needed here.
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
        viewModel.meshService.eventDelegate = viewModel

        DispatchQueue.main.asyncAfter(deadline: .now() + TransportConfig.uiStartupInitialDelaySeconds) { [weak viewModel] in
            guard let viewModel else { return }
            _ = viewModel.getMyFingerprint()
        }

        viewModel.meshService.setNickname(viewModel.nickname)
    }

    func startRuntimeServices() {
        viewModel.meshService.startServices()

        viewModel.publicMessagePipeline.delegate = viewModel.publicConversationCoordinator

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
            context: viewModel
        )
    }

    /// Wires the gateway-mode policy layer (`GatewayService`) to the mesh
    /// transport, the relay manager, and the inbound Nostr pipeline. All
    /// dependencies are closures so the service stays unit-testable with
    /// fakes.
    func configureGateway() {
        // Gateway mode bridges BLE mesh <-> Nostr; a mock transport (tests)
        // has no carrier packets to bridge.
        guard let bleService = viewModel.meshService as? BLEService else { return }
        let gateway = GatewayService.shared

        gateway.publishToRelays = { event, geohash in
            let relays = GeoRelayDirectory.shared.closestRelays(
                toGeohash: geohash,
                count: TransportConfig.nostrGeoRelayCount
            )
            // Symmetric with the local send path (GeohashSubscriptionManager
            // .sendGeohash): with no known geo relay, refuse rather than
            // publish to default relays no geo subscriber reads — that would
            // be silent dead traffic, not delivery.
            guard !relays.isEmpty else {
                SecureLogger.warning("🌐 Gateway: no geo relays for #\(geohash); not publishing carried event", category: .session)
                return
            }
            NostrRelayManager.shared.sendEvent(event, to: relays)
        }
        gateway.broadcastToMesh = { [weak bleService] payload in
            bleService?.broadcastNostrCarrier(payload)
        }
        gateway.sendToGatewayPeer = { [weak bleService] payload, peer in
            bleService?.sendNostrCarrier(payload, to: peer) ?? false
        }
        gateway.availableGatewayPeers = { [weak bleService] in
            bleService?.reachableGatewayPeers() ?? []
        }
        gateway.relaysConnected = { NostrRelayManager.shared.isConnected }
        gateway.currentGeohash = { [weak viewModel] in viewModel?.currentGeohash }
        // Carried events enter the same pipeline as relay-received events so
        // blocking, rate limits, dedup, and rendering behave identically.
        gateway.injectInbound = { [weak viewModel] event in
            viewModel?.handleNostrEvent(event)
        }
        // The capability bit is advertised ONLY while the toggle is on; a
        // change forces a re-announce so peers learn promptly.
        gateway.onEnabledChanged = { [weak bleService] enabled in
            bleService?.setLocalCapability(.gateway, enabled: enabled)
        }
        bleService.onNostrCarrierPacket = { payload, from, directedToUs in
            GatewayService.shared.handleMeshCarrier(payload, from: from, directedToUs: directedToUs)
        }

        // Uplinks deposited while relays were unreachable flush on reconnect.
        NostrRelayManager.shared.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { connected in
                if connected {
                    GatewayService.shared.flushQueuedUplinks()
                }
            }
            .store(in: &viewModel.cancellables)

        // Apply the persisted toggle at launch.
        if gateway.isEnabled {
            bleService.setLocalCapability(.gateway, enabled: true)
        }
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
