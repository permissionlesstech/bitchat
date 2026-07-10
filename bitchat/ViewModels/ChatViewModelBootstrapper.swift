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
        // Persist processed gift-wrap event IDs: NIP-59 randomizes their
        // timestamps, so the 24h-lookback DM subscriptions redeliver the same
        // events on every launch and only a cross-launch record stops the
        // reprocessing (re-sent DELIVERED bursts, phantom-ack noise).
        self.deduplicationService = MessageDeduplicationService(nostrEventStore: NostrProcessedEventStore())
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
        configureBridge()
        configureBridgeCourier()
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

        loadArchivedEchoes()

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

    /// Surfaces the carried store-and-forward window (up to 6h of public
    /// mesh messages, persisted across restarts) as dimmed "heard here
    /// earlier" rows, so the mesh timeline opens with the place's memory
    /// instead of a void. The archive restore runs async on the sync queue
    /// right after transport start, so give it a beat before asking.
    private func loadArchivedEchoes() {
        DispatchQueue.main.asyncAfter(deadline: .now() + TransportConfig.uiArchivedEchoLoadDelaySeconds) { [weak viewModel] in
            guard let viewModel else { return }
            viewModel.meshService.collectArchivedPublicMessages { [weak viewModel] allArchived in
                guard let viewModel else { return }
                // A previous /clear dismissed everything heard up to its
                // watermark; only newer archive entries come back. Blocking a
                // peer purges their carried messages from the archive at
                // block time (when the fingerprint↔peerID mapping is known);
                // the filter here is defense-in-depth for entries that slip
                // past the purge (e.g. re-synced from a nearby peer), and it
                // only resolves connected peers or favorites.
                let clearedThrough = MeshEchoSettings.clearedThrough ?? .distantPast
                let archived = allArchived.filter {
                    $0.timestamp > clearedThrough && !viewModel.isPeerBlocked($0.senderPeerID)
                }
                guard !archived.isEmpty else { return }
                // Seed only an untouched timeline: with live rows already
                // present (or after /clear) splicing history back in would
                // be wrong.
                guard viewModel.conversations.conversationsByID[.mesh]?.messages.isEmpty != false else { return }

                for item in archived {
                    let echo = BitchatMessage(
                        id: BitchatMessage.archivedEchoIDPrefix + item.packetIdHex,
                        sender: item.senderNickname,
                        content: item.content,
                        timestamp: item.timestamp,
                        isRelay: false,
                        senderPeerID: item.senderPeerID
                    )
                    viewModel.publicConversationCoordinator.registerArchivedEcho(
                        senderPeerID: item.senderPeerID,
                        timestamp: item.timestamp,
                        content: item.content
                    )
                    _ = viewModel.appendPublicMessage(echo, to: .mesh)
                }

                if let firstTimestamp = archived.map(\.timestamp).min() {
                    // Echo-prefixed ID so the divider joins the tinted,
                    // dimmed echo block in the timeline.
                    let divider = BitchatMessage(
                        id: BitchatMessage.archivedEchoIDPrefix + "divider",
                        sender: "system",
                        content: String(localized: "content.echoes.divider", comment: "System line shown above dimmed archived messages replayed on the mesh timeline at launch"),
                        timestamp: firstTimestamp.addingTimeInterval(-1),
                        isRelay: false
                    )
                    _ = viewModel.appendPublicMessage(divider, to: .mesh)
                }
            }
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
            // One decode, two policy engines: geohash-channel carriers go to
            // the gateway, mesh-bridge carriers to the bridge.
            guard let carrier = NostrCarrierPacket.decode(payload) else {
                SecureLogger.debug("🌐 Gateway: dropping undecodable carrier from \(from.id.prefix(8))…", category: .session)
                return
            }
            switch carrier.direction {
            case .toGateway, .fromGateway:
                GatewayService.shared.handleMeshCarrier(payload, from: from, directedToUs: directedToUs)
            case .toBridge, .fromBridge:
                BridgeService.shared.handleMeshCarrier(carrier, from: from, directedToUs: directedToUs)
            }
        }

        // Uplinks deposited while relays were unreachable flush on reconnect.
        // The publisher re-emits `true` on every relay state recompute, so
        // dedupe: field logs showed presence published 5x in one second.
        NostrRelayManager.shared.$isConnected
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { connected in
                if connected {
                    GatewayService.shared.flushQueuedUplinks()
                    BridgeService.shared.flushQueuedUplinks()
                    BridgeService.shared.publishPresence()
                }
            }
            .store(in: &viewModel.cancellables)

        // Apply the persisted toggle at launch.
        if gateway.isEnabled {
            bleService.setLocalCapability(.gateway, enabled: true)
        }
    }

    /// Wires the mesh-bridge policy layer (`BridgeService`) to the mesh
    /// transport, the relay manager, location, and the public timeline. Same
    /// closure-injection style as `configureGateway`.
    func configureBridge() {
        guard let bleService = viewModel.meshService as? BLEService else { return }
        let bridge = BridgeService.shared
        let idBridge = viewModel.idBridge

        bridge.publishToRelays = { event, cell in
            let relays = GeoRelayDirectory.shared.closestRelays(
                toGeohash: cell,
                count: TransportConfig.nostrGeoRelayCount
            )
            guard !relays.isEmpty else {
                SecureLogger.warning("🌉 Bridge: no geo relays for cell \(cell); not publishing", category: .session)
                return
            }
            NostrRelayManager.shared.sendEvent(event, to: relays)
        }
        bridge.openSubscription = { cells in
            guard let cell = cells.first else { return }
            let relays = GeoRelayDirectory.shared.closestRelays(
                toGeohash: cell,
                count: TransportConfig.nostrGeoRelayCount
            )
            NostrRelayManager.shared.subscribe(
                filter: .bridgeRendezvous(cells, since: Date().addingTimeInterval(-BridgeService.Limits.maxEventAgeSeconds)),
                id: Self.bridgeSubscriptionID,
                relayUrls: relays.isEmpty ? nil : relays,
                handler: { event in
                    BridgeService.shared.handleRendezvousEvent(event)
                }
            )
        }
        bridge.closeSubscription = {
            NostrRelayManager.shared.unsubscribe(id: Self.bridgeSubscriptionID)
        }
        bridge.relaysConnected = { NostrRelayManager.shared.isConnected }
        bridge.locationCell = { [weak viewModel] in
            viewModel?.locationManager.availableChannels
                .first { $0.level == .neighborhood }?
                .geohash
        }
        bridge.requestLocationFix = { [weak viewModel] in
            viewModel?.locationManager.refreshChannels()
        }
        bridge.meshAdvertisedCell = { [weak bleService] in
            bleService?.advertisedBridgeGeohash()
        }
        bridge.sendToBridgePeer = { [weak bleService] payload, peer in
            bleService?.sendNostrCarrier(payload, to: peer) ?? false
        }
        bridge.availableBridgePeers = { [weak bleService] in
            bleService?.reachableBridgePeers() ?? []
        }
        bridge.broadcastToMesh = { [weak bleService] payload in
            bleService?.broadcastNostrCarrier(payload)
        }
        bridge.injectInbound = { [weak viewModel] inbound in
            viewModel?.handlePublicMessage(BitchatMessage(
                id: inbound.messageID,
                sender: inbound.senderNickname,
                content: inbound.content,
                timestamp: inbound.timestamp,
                isRelay: false,
                senderPeerID: PeerID(bridge: inbound.senderPubkey),
                isBridged: true
            ))
        }
        bridge.removeInjectedInbound = { [weak viewModel] messageID in
            viewModel?.removeBridgeInjectedPublicMessage(withID: messageID)
        }
        bridge.isInjectedInboundPresent = { [weak viewModel] messageID in
            viewModel?.bridgeInjectedPublicMessageIsPresent(withID: messageID) ?? false
        }
        bridge.isMessageSeenLocally = { [weak viewModel] messageID in
            viewModel?.publicConversationContainsMessage(withID: messageID, in: .mesh) ?? false
        }
        bridge.deriveIdentity = { cell in
            try idBridge.deriveIdentity(forBridgeRendezvous: cell)
        }
        bridge.myNickname = { [weak viewModel] in viewModel?.nickname ?? "" }

        // The `.bridge` capability + cell TLV advertise serving duty: "send
        // me deposits, and this is the island's cell". One switch: bridging
        // with a known cell is serving (deposits queue through connectivity
        // gaps, so the advertisement doesn't flap with the relays).
        let updateAdvertisement: @MainActor () -> Void = { [weak bleService] in
            let advertise = BridgeService.shared.isEnabled
                && BridgeService.shared.activeCell != nil
            bleService?.setLocalBridgeGeohash(advertise ? BridgeService.shared.activeCell : nil)
            bleService?.setLocalCapability(.bridge, enabled: advertise)
        }
        bridge.onEnabledChanged = { [weak viewModel] enabled in
            updateAdvertisement()
            // One switch collapses further: the bridge toggle also drives
            // the geohash-channel gateway — bridging with internet means
            // sharing it with the mesh around you, full stop.
            GatewayService.shared.setEnabled(enabled)
            // Flipping the switch is the user-initiated moment to ask for
            // location if it was never asked; otherwise the bridge sits
            // cell-less with only a settings caption explaining why.
            if enabled, viewModel?.locationManager.permissionState == .notDetermined {
                viewModel?.locationManager.enableLocationChannels()
            }
        }
        bridge.onActiveCellChanged = { _ in updateAdvertisement() }
        // Align a persisted split state (e.g. gateway enabled back when it
        // had its own toggle) to the single switch at launch.
        if GatewayService.shared.isEnabled != bridge.isEnabled {
            GatewayService.shared.setEnabled(bridge.isEnabled)
        }

        // Location fixes (or losing them) move the rendezvous cell.
        viewModel.locationManager.$availableChannels
            .receive(on: DispatchQueue.main)
            .sink { _ in BridgeService.shared.refreshRendezvous() }
            .store(in: &viewModel.cancellables)
        // The authorization callback lands asynchronously after launch; the
        // bootstrap-time location request races it and silently no-ops, so
        // re-enter when the permission state resolves (field bug: bridge
        // stayed cell-less for a whole session).
        viewModel.locationManager.$permissionState
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { _ in BridgeService.shared.refreshRendezvous() }
            .store(in: &viewModel.cancellables)

        // Apply the persisted toggle at launch.
        if bridge.isEnabled {
            bridge.refreshRendezvous()
            updateAdvertisement()
        }
    }

    /// Wires courier-over-bridge (`BridgeCourierService`) to the relay
    /// manager, the mesh transport's sealing/opening primitives, the courier
    /// store, and the message router's deposit path.
    func configureBridgeCourier() {
        guard let bleService = viewModel.meshService as? BLEService else { return }
        let courier = BridgeCourierService.shared

        courier.bridgeEnabled = { BridgeService.shared.isEnabled }
        // A geo/custom relay does not make a global courier drop durable.
        // Require an actually connected default (DM) relay so `sendEvent`
        // writes to at least one intended relay instead of only entering its
        // process-local pending queue.
        courier.relaysConnected = { NostrRelayManager.shared.isDMRelayConnected }
        courier.publishEvent = { event, completion in
            // Default (DM) relays: drops need the standing global relay set,
            // not geo relays — sender and recipient share no cell.
            // This confirmed path never falls back to the volatile relay
            // queue; bridge dedup is committed only after NIP-20 OK.
            NostrRelayManager.shared.sendEventImmediately(event, completion: completion)
        }
        courier.openSubscription = { tagsHex in
            NostrRelayManager.shared.unsubscribe(id: Self.courierDropSubscriptionID)
            NostrRelayManager.shared.subscribe(
                filter: .courierDrops(
                    recipientTagsHex: tagsHex,
                    since: Date().addingTimeInterval(-CourierEnvelope.maxLifetimeSeconds)
                ),
                id: Self.courierDropSubscriptionID,
                handler: { event in
                    BridgeCourierService.shared.handleDropEvent(event)
                }
            )
        }
        courier.closeSubscription = {
            NostrRelayManager.shared.unsubscribe(id: Self.courierDropSubscriptionID)
        }
        courier.myNoiseKey = { [weak bleService] in
            bleService?.myNoiseStaticPublicKey()
        }
        courier.localVerifiedPeers = { [weak bleService] in
            bleService?.verifiedPeersWithNoiseKeys() ?? []
        }
        courier.sealEnvelope = { [weak bleService] content, messageID, recipientKey in
            bleService?.sealBridgeCourierEnvelope(content, messageID: messageID, recipientNoiseKey: recipientKey)
        }
        courier.openEnvelope = { [weak bleService] envelope in
            bleService?.openBridgedCourierEnvelope(envelope) ?? false
        }
        courier.deliverToPeer = { [weak bleService] envelope, peerID in
            bleService?.deliverBridgedEnvelope(envelope, to: peerID) ?? false
        }
        courier.heldEnvelopes = { cooldown in
            CourierStore.shared.envelopesForBridgePublish(cooldown: cooldown)
        }
        courier.markHeldEnvelopePublished = { envelope in
            CourierStore.shared.markBridgePublished(envelope)
        }

        viewModel.messageRouter.bridgeCourierDeposit = { content, messageID, recipientKey, completion in
            BridgeCourierService.shared.depositDrop(
                content: content,
                messageID: messageID,
                recipientNoiseKey: recipientKey,
                completion: completion
            )
        }
        // The completion flows back only after a default relay accepts the
        // event, so a rejected or unacknowledged write never becomes carried.
        viewModel.messageRouter.startBridgeDepositSweep()
        bleService.onVerifiedPeerAnnounce = { _ in
            Task { @MainActor in
                BridgeCourierService.shared.refreshAfterVerifiedAnnounce()
            }
        }

        // Relay connectivity gates everything; refresh (re)opens or closes.
        // Deduped: refresh() resubscribes, and the raw publisher re-emits on
        // every relay state recompute (6x in 300ms in field logs).
        NostrRelayManager.shared.$isDMRelayConnected
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { _ in BridgeCourierService.shared.refresh() }
            .store(in: &viewModel.cancellables)
        // Toggle changes re-evaluate the watch set.
        BridgeService.shared.$isEnabled
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { _ in BridgeCourierService.shared.refresh() }
            .store(in: &viewModel.cancellables)

        courier.refresh()
    }

    private static let bridgeSubscriptionID = "bridge-rendezvous"
    private static let courierDropSubscriptionID = "bridge-courier-drops"

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
