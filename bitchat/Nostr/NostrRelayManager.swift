import BitLogger
import Foundation
import Network
import Combine
import Tor

protocol NostrRelayConnectionProtocol: AnyObject {
    func resume()
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping (Error?) -> Void)
    func receive(completionHandler: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void)
    func sendPing(pongReceiveHandler: @escaping (Error?) -> Void)
}

protocol NostrRelaySessionProtocol {
    func webSocketTask(with url: URL) -> NostrRelayConnectionProtocol
}

private final class URLSessionWebSocketTaskAdapter: NostrRelayConnectionProtocol {
    private let base: URLSessionWebSocketTask

    init(base: URLSessionWebSocketTask) {
        self.base = base
    }

    func resume() {
        base.resume()
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        base.cancel(with: closeCode, reason: reason)
    }

    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping (Error?) -> Void) {
        base.send(message, completionHandler: completionHandler)
    }

    func receive(completionHandler: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        base.receive(completionHandler: completionHandler)
    }

    func sendPing(pongReceiveHandler: @escaping (Error?) -> Void) {
        base.sendPing(pongReceiveHandler: pongReceiveHandler)
    }
}

private struct URLSessionAdapter: NostrRelaySessionProtocol {
    let base: URLSession

    func webSocketTask(with url: URL) -> NostrRelayConnectionProtocol {
        URLSessionWebSocketTaskAdapter(base: base.webSocketTask(with: url))
    }
}

struct NostrRelayManagerDependencies {
    var activationAllowed: () -> Bool
    var userTorEnabled: () -> Bool
    var hasMutualFavorites: () -> Bool
    var hasLocationPermission: () -> Bool
    var mutualFavoritesPublisher: AnyPublisher<Set<Data>, Never>
    var locationPermissionPublisher: AnyPublisher<LocationChannelManager.PermissionState, Never>
    var torEnforced: () -> Bool
    var torIsReady: () -> Bool
    var torIsForeground: () -> Bool
    var awaitTorReady: (@escaping (Bool) -> Void) -> Void
    var makeSession: () -> NostrRelaySessionProtocol
    var scheduleAfter: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void
    var now: () -> Date
    /// Uniform random value in [0, 1) used to jitter reconnect backoff.
    /// Injectable so tests can pin or sweep the jitter deterministically.
    var jitterUnit: () -> Double
}

private extension NostrRelayManagerDependencies {
    @MainActor
    static func live() -> Self {
        Self(
            activationAllowed: { NetworkActivationService.shared.activationAllowed },
            userTorEnabled: { NetworkActivationService.shared.userTorEnabled },
            hasMutualFavorites: { !FavoritesPersistenceService.shared.mutualFavorites.isEmpty },
            hasLocationPermission: { LocationChannelManager.shared.permissionState == .authorized },
            mutualFavoritesPublisher: FavoritesPersistenceService.shared.$mutualFavorites.eraseToAnyPublisher(),
            locationPermissionPublisher: LocationChannelManager.shared.$permissionState.eraseToAnyPublisher(),
            torEnforced: { TorManager.shared.torEnforced },
            torIsReady: { TorManager.shared.isReady },
            torIsForeground: { TorManager.shared.isForeground() },
            awaitTorReady: { completion in
                Task.detached {
                    let ready = await TorManager.shared.awaitReady()
                    await MainActor.run {
                        completion(ready)
                    }
                }
            },
            makeSession: { URLSessionAdapter(base: TorURLSession.shared.session) },
            scheduleAfter: { delay, action in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
            },
            now: Date.init,
            jitterUnit: { Double.random(in: 0..<1) }
        )
    }
}

/// Manages WebSocket connections to Nostr relays
@MainActor
final class NostrRelayManager: ObservableObject {
    static let shared = NostrRelayManager()
    // Track gift-wraps (kind 1059) we initiated so we can log OK acks at info
    private(set) static var pendingGiftWrapIDs = Set<String>()
    static func registerPendingGiftWrap(id: String) {
        pendingGiftWrapIDs.insert(id)
    }
    
    struct Relay: Identifiable {
        let id = UUID()
        let url: String
        var isConnected: Bool = false
        var lastError: Error?
        var messagesSent: Int = 0
        var messagesReceived: Int = 0
        var reconnectAttempts: Int = 0
        var lastDisconnectedAt: Date?
        var nextReconnectTime: Date?
    }
    
    // Default relays carry NIP-17 gift wraps, so avoid relays known to reject kind 1059.
    private static let defaultRelays = [
        "wss://relay.damus.io",
        "wss://nos.lol",
        "wss://relay.primal.net",
        "wss://offchain.pub"
        // For local testing, you can add: "ws://localhost:8080"
    ]
    private static let defaultRelaySet = Set(defaultRelays.compactMap { NostrRelayURL.normalized($0) })
    
    @Published private(set) var relays: [Relay] = []
    @Published private(set) var isConnected = false
    /// Whether a relay that carries private messages is connected. DMs
    /// target the default (gift-wrap-capable) relay set, so a connected
    /// geohash/custom relay alone must not count — sends would still queue.
    @Published private(set) var isDMRelayConnected = false
    
    private let dependencies: NostrRelayManagerDependencies
    private var allowDefaultRelays: Bool = false
    private var hasMutualFavorites: Bool = false
    private var hasLocationPermission: Bool = false
    private var connections: [String: NostrRelayConnectionProtocol] = [:]
    private var subscriptions: [String: Set<String>] = [:] // relay URL -> active subscription IDs
    // Not-yet-flushed REQs per relay, bounded by a per-relay cap (oldest by
    // insertion order evicted) and an age sweep on connect attempts. Dicts are
    // unordered, so each entry carries an insertion sequence and queue time.
    private struct PendingSubscription {
        let messageString: String // encoded REQ JSON
        let queuedAt: Date
        let sequence: UInt64
    }
    private var pendingSubscriptions: [String: [String: PendingSubscription]] = [:] // relay URL -> (subscription id -> pending REQ)
    private var pendingSubscriptionSequence: UInt64 = 0
    private var messageHandlers: [String: (NostrEvent) -> Void] = [:]
    private struct InboundEventKey: Hashable {
        let subscriptionID: String
        let eventID: String
    }
    private let recentInboundEventKeyLimit = TransportConfig.nostrInboundEventDedupCap
    private let recentInboundEventKeyTrimTarget = TransportConfig.nostrInboundEventDedupTrimTarget
    private var recentInboundEventKeys = Set<InboundEventKey>()
    private var recentInboundEventKeyOrder: [InboundEventKey] = []
    private var duplicateInboundEventDropCount = 0
    private var duplicateInboundEventDropCountBySubscription: [String: Int] = [:]
    private var inboundEventLogCount = 0
    // Coalesce duplicate subscribe requests for the same id within a short window.
    private let subscribeCoalesceInterval: TimeInterval = 1.0
    private var subscribeCoalesce: [String: Date] = [:]
    private var pendingTorConnectionURLs = Set<String>()
    private var awaitingTorForConnections = false
    private var torReadyWaitAttempts = 0
    private var cancellables = Set<AnyCancellable>()

    private struct SubscriptionRequestState: Equatable {
        let messageString: String
        let relayURLs: Set<String>
    }
    private var subscriptionRequestState: [String: SubscriptionRequestState] = [:]

    // Track EOSE per subscription to signal when initial stored events are
    // done. Completion is scoped to relays the REQ actually reached: targets
    // still mid-connect must not hold the callback hostage until the fallback
    // timer (a dead relay of five used to pin "loading" for the full 10s).
    private struct EOSETracker {
        /// Targets the REQ has not been delivered to yet (still connecting).
        var awaitingSend: Set<String>
        /// Relays that received the REQ and have not sent EOSE yet.
        var awaitingEOSE: Set<String>
        /// True once any relay received the REQ (or answered with EOSE) —
        /// completion with zero sends would mean "done" without ever asking.
        var didSend = false
        var callback: () -> Void
        let epoch: Int

        /// Done when every relay that got the REQ has resolved, provided at
        /// least one did — or when every target dropped out entirely.
        var isComplete: Bool {
            (didSend && awaitingEOSE.isEmpty) || (awaitingSend.isEmpty && awaitingEOSE.isEmpty)
        }
    }
    private var eoseTrackers: [String: EOSETracker] = [:]
    private var eoseTrackerEpoch = 0
    private var pendingEOSECallbacks: [String: () -> Void] = [:]
    
    // Message queue for reliability
    // Pending sends held only for relays that are not yet connected.
    private struct PendingSend {
        var event: NostrEvent
        var pendingRelays: Set<String>
    }
    private var messageQueue: [PendingSend] = []
    private let messageQueueLock = NSLock()
    /// Non-queued sends whose callers require relay durability. A WebSocket
    /// write only proves bytes left this process; NIP-20 OK is the relay's
    /// accept/reject acknowledgment.
    private struct ConfirmedSendState {
        let token: UUID
        var awaitingRelays: Set<String>
        let completion: (Bool) -> Void
    }
    private var confirmedSends: [String: ConfirmedSendState] = [:]
    // Total pending sends dropped at the queue cap; drives the sampled
    // overflow warning (first + every Nth drop).
    private var pendingSendDropCount = 0
    private let encoder = JSONEncoder()
    private var shouldUseTor: Bool { dependencies.userTorEnabled() }
    
    // Exponential backoff configuration
    private let initialBackoffInterval: TimeInterval = TransportConfig.nostrRelayInitialBackoffSeconds
    private let maxBackoffInterval: TimeInterval = TransportConfig.nostrRelayMaxBackoffSeconds
    private let backoffMultiplier: Double = TransportConfig.nostrRelayBackoffMultiplier
    private let maxReconnectAttempts = TransportConfig.nostrRelayMaxReconnectAttempts
    
    // Bump generation to invalidate scheduled reconnects when we reset/disconnect
    private var connectionGeneration: Int = 0
    
    init() {
        self.dependencies = .live()
        hasMutualFavorites = dependencies.hasMutualFavorites()
        hasLocationPermission = dependencies.hasLocationPermission()
        applyDefaultRelayPolicy(force: true)
        // Deterministic JSON shape for outbound requests
        self.encoder.outputFormatting = .sortedKeys
        dependencies.mutualFavoritesPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] favorites in
                guard let self = self else { return }
                self.hasMutualFavorites = !favorites.isEmpty
                self.applyDefaultRelayPolicy()
            }
            .store(in: &cancellables)
        dependencies.locationPermissionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self else { return }
                let authorized = (state == .authorized)
                if authorized == self.hasLocationPermission { return }
                self.hasLocationPermission = authorized
                self.applyDefaultRelayPolicy()
            }
            .store(in: &cancellables)
    }

    internal init(dependencies: NostrRelayManagerDependencies) {
        self.dependencies = dependencies
        hasMutualFavorites = dependencies.hasMutualFavorites()
        hasLocationPermission = dependencies.hasLocationPermission()
        applyDefaultRelayPolicy(force: true)
        // Deterministic JSON shape for outbound requests
        self.encoder.outputFormatting = .sortedKeys
        dependencies.mutualFavoritesPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] favorites in
                guard let self = self else { return }
                self.hasMutualFavorites = !favorites.isEmpty
                self.applyDefaultRelayPolicy()
            }
            .store(in: &cancellables)
        dependencies.locationPermissionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self else { return }
                let authorized = (state == .authorized)
                if authorized == self.hasLocationPermission { return }
                self.hasLocationPermission = authorized
                self.applyDefaultRelayPolicy()
            }
            .store(in: &cancellables)
    }
    
    /// Connect to all configured relays
    func connect() {
        // Global network policy gate
        guard dependencies.activationAllowed() else { return }
        connectToRelays(relays.map(\.url), shouldLog: true)
    }
    
    /// Disconnect from all relays
    func disconnect() {
        connectionGeneration &+= 1
        for (_, task) in connections {
            task.cancel(with: .goingAway, reason: nil)
        }
        connections.removeAll()
        markRelaySocketsClosed(resetState: false)
        // Sockets are gone, so per-relay subscription state is cleared — but
        // durable intent (subscriptionRequestState, messageHandlers, parked
        // EOSE callbacks) is kept so REQs replay when relays reconnect
        // (e.g. background → foreground).
        subscriptions.removeAll()
        pendingSubscriptions.removeAll()
        // Settle in-flight initial loads instead of leaving callers hanging.
        let trackers = eoseTrackers
        eoseTrackers.removeAll()
        for (_, tracker) in trackers {
            tracker.callback()
        }
        let confirmed = confirmedSends.values.map(\.completion)
        confirmedSends.removeAll()
        confirmed.forEach { $0(false) }
        pendingTorConnectionURLs.removeAll()
        awaitingTorForConnections = false
        torReadyWaitAttempts = 0
        updateConnectionStatus()
    }

    /// Panic wipe reset: close sockets and drop every user/session-specific
    /// relay intent without invoking old callbacks. Unlike `disconnect()`, this
    /// must not preserve subscription replay state because geohash DM handlers
    /// can capture pre-wipe Nostr private keys.
    func resetForPanicWipe() {
        connectionGeneration &+= 1
        for (_, task) in connections {
            task.cancel(with: .goingAway, reason: nil)
        }
        connections.removeAll()
        markRelaySocketsClosed(resetState: true)
        subscriptions.removeAll()
        pendingSubscriptions.removeAll()
        messageHandlers.removeAll()
        subscriptionRequestState.removeAll()
        subscribeCoalesce.removeAll()
        eoseTrackers.removeAll()
        pendingEOSECallbacks.removeAll()
        pendingTorConnectionURLs.removeAll()
        awaitingTorForConnections = false
        torReadyWaitAttempts = 0
        recentInboundEventKeys.removeAll()
        recentInboundEventKeyOrder.removeAll()
        duplicateInboundEventDropCount = 0
        duplicateInboundEventDropCountBySubscription.removeAll()
        inboundEventLogCount = 0
        Self.pendingGiftWrapIDs.removeAll()
        confirmedSends.removeAll()

        messageQueueLock.lock()
        messageQueue.removeAll()
        pendingSendDropCount = 0
        messageQueueLock.unlock()

        updateConnectionStatus()
    }

    private func markRelaySocketsClosed(resetState: Bool) {
        let now = dependencies.now()
        for index in relays.indices {
            relays[index].isConnected = false
            relays[index].nextReconnectTime = nil
            if resetState {
                relays[index].lastError = nil
                relays[index].lastDisconnectedAt = nil
                relays[index].messagesSent = 0
                relays[index].messagesReceived = 0
                relays[index].reconnectAttempts = 0
            } else {
                relays[index].lastDisconnectedAt = now
            }
        }
    }
    
    /// Ensure connections exist to the given relay URLs (idempotent).
    func ensureConnections(to relayUrls: [String]) {
        // Global network policy gate
        guard dependencies.activationAllowed() else { return }
        let targets = allowedRelayList(from: relayUrls)
        guard !targets.isEmpty else { return }
        var existing = Set(relays.map { $0.url })
        for url in targets where !existing.contains(url) {
            relays.append(Relay(url: url))
            existing.insert(url)
        }
        connectToRelays(targets)
    }

    /// Send an event to specified relays (or all if none specified)
    func sendEvent(_ event: NostrEvent, to relayUrls: [String]? = nil) {
        // Global network policy gate
        guard dependencies.activationAllowed() else { return }
        if shouldUseTor && dependencies.torEnforced() && !dependencies.torIsReady() {
            // Fail-closed: nothing touches the network until Tor is up. Queue the
            // event locally so it survives a slow bootstrap (queued sends flush
            // when relays connect), then kick off connection setup, which itself
            // waits for Tor readiness.
            let targetRelays = allowedRelayList(from: relayUrls ?? Self.defaultRelays)
            guard !targetRelays.isEmpty else { return }
            enqueuePendingSend(event, pendingRelays: Set(targetRelays))
            ensureConnections(to: targetRelays)
            return
        }
        let requestedRelays = relayUrls ?? Self.defaultRelays
        let targetRelays = allowedRelayList(from: requestedRelays)
        guard !targetRelays.isEmpty else { return }
        ensureConnections(to: targetRelays)

        // Attempt immediate send to relays with active connections; queue the rest
        var stillPending = Set<String>()
        for relayUrl in targetRelays {
            if let connection = connectedConnection(for: relayUrl) {
                sendToRelay(event: event, connection: connection, relayUrl: relayUrl)
            } else {
                stillPending.insert(relayUrl)
            }
        }
        if !stillPending.isEmpty {
            enqueuePendingSend(event, pendingRelays: stillPending)
        }
    }

    /// Attempts an event only on currently connected target relays and
    /// reports whether at least one relay explicitly accepted it via NIP-20
    /// OK. A successful WebSocket write alone is not durable acceptance.
    /// Unlike `sendEvent`, this never enters the process-local pending queue;
    /// callers use it when success unlocks durable state or user-visible
    /// delivery progress.
    func sendEventImmediately(
        _ event: NostrEvent,
        to relayUrls: [String]? = nil,
        completion: @escaping (Bool) -> Void
    ) {
        guard dependencies.activationAllowed() else {
            completion(false)
            return
        }
        guard !(shouldUseTor && dependencies.torEnforced() && !dependencies.torIsReady()) else {
            completion(false)
            return
        }

        let requestedRelays = relayUrls ?? Self.defaultRelays
        let targetRelays = allowedRelayList(from: requestedRelays)
        let connectedTargets = targetRelays.compactMap { relayUrl -> (String, NostrRelayConnectionProtocol)? in
            guard let connection = connectedConnection(for: relayUrl) else { return nil }
            return (relayUrl, connection)
        }
        guard !connectedTargets.isEmpty else {
            completion(false)
            return
        }

        let token = UUID()
        let eventID = event.id
        if let replaced = confirmedSends.removeValue(forKey: eventID) {
            replaced.completion(false)
        }
        confirmedSends[eventID] = ConfirmedSendState(
            token: token,
            awaitingRelays: Set(connectedTargets.map(\.0)),
            completion: completion
        )
        dependencies.scheduleAfter(TransportConfig.nostrConfirmedSendAckTimeoutSeconds) { [weak self] in
            Task { @MainActor [weak self] in
                self?.timeoutConfirmedSend(eventID: eventID, token: token)
            }
        }

        for (relayUrl, connection) in connectedTargets {
            sendToRelay(event: event, connection: connection, relayUrl: relayUrl) { [weak self] succeeded in
                guard let self else { return }
                // Success only means the bytes reached the socket; wait for
                // the matching relay OK. A failed write settles this target
                // as rejected because no OK can arrive for it.
                if !succeeded {
                    self.resolveConfirmedSend(
                        eventID: eventID,
                        relayURL: relayUrl,
                        accepted: false,
                        token: token
                    )
                }
            }
        }
    }

    private func resolveConfirmedSend(
        eventID: String,
        relayURL: String,
        accepted: Bool,
        token: UUID? = nil
    ) {
        guard var state = confirmedSends[eventID],
              token == nil || state.token == token,
              state.awaitingRelays.remove(relayURL) != nil else { return }
        if accepted {
            confirmedSends.removeValue(forKey: eventID)
            state.completion(true)
        } else if state.awaitingRelays.isEmpty {
            confirmedSends.removeValue(forKey: eventID)
            state.completion(false)
        } else {
            confirmedSends[eventID] = state
        }
    }

    private func timeoutConfirmedSend(eventID: String, token: UUID) {
        guard let state = confirmedSends[eventID], state.token == token else { return }
        confirmedSends.removeValue(forKey: eventID)
        state.completion(false)
    }

    private func enqueuePendingSend(_ event: NostrEvent, pendingRelays: Set<String>) {
        messageQueueLock.lock()
        messageQueue.append(PendingSend(event: event, pendingRelays: pendingRelays))
        let overflow = messageQueue.count - TransportConfig.nostrPendingSendQueueCap
        if overflow > 0 {
            messageQueue.removeFirst(overflow)
        }
        messageQueueLock.unlock()
        guard overflow > 0 else { return }
        // Dropped events are ephemeral (presence/geo), so no status surfacing
        // is needed — but the drops should be visible. Sampled so a sustained
        // relay stall can't flood the log.
        pendingSendDropCount += overflow
        if pendingSendDropCount == 1 ||
            pendingSendDropCount.isMultiple(of: TransportConfig.nostrPendingSendDropLogInterval) {
            SecureLogger.warning(
                "📤 Relay send queue full — dropped \(pendingSendDropCount) oldest event(s)",
                category: .session
            )
        }
    }

    /// Try to flush any queued messages for relays that are now connected.
    private func flushMessageQueue(for relayUrl: String? = nil) {
        messageQueueLock.lock()
        defer { messageQueueLock.unlock() }
        guard !messageQueue.isEmpty else { return }
        if let target = relayUrl {
            // Flush only for a specific relay
            for i in (0..<messageQueue.count).reversed() {
                var item = messageQueue[i]
                if item.pendingRelays.contains(target), let conn = connectedConnection(for: target) {
                    sendToRelay(event: item.event, connection: conn, relayUrl: target)
                    item.pendingRelays.remove(target)
                    if item.pendingRelays.isEmpty {
                        messageQueue.remove(at: i)
                    } else {
                        messageQueue[i] = item
                    }
                }
            }
        } else {
            // Flush for any relays that now have connections
            for i in (0..<messageQueue.count).reversed() {
                var item = messageQueue[i]
                for url in item.pendingRelays {
                    if let conn = connectedConnection(for: url) {
                        sendToRelay(event: item.event, connection: conn, relayUrl: url)
                        item.pendingRelays.remove(url)
                    }
                }
                if item.pendingRelays.isEmpty {
                    messageQueue.remove(at: i)
                } else {
                    messageQueue[i] = item
                }
            }
        }
    }

    private func connectedConnection(for relayUrl: String) -> NostrRelayConnectionProtocol? {
        guard let connection = connections[relayUrl],
              relays.first(where: { $0.url == relayUrl })?.isConnected == true else {
            return nil
        }
        return connection
    }
    
    /// Subscribe to events matching a filter. If `relayUrls` provided, targets only those relays.
    func subscribe(
        filter: NostrFilter,
        id: String = UUID().uuidString,
        relayUrls: [String]? = nil,
        handler: @escaping (NostrEvent) -> Void,
        onEOSE: (() -> Void)? = nil
    ) {
        // Global network policy gate
        guard dependencies.activationAllowed() else { return }
        // Coalesce rapid duplicate subscribe requests even while Tor readiness is pending.
        let now = dependencies.now()
        if let last = subscribeCoalesce[id], now.timeIntervalSince(last) < subscribeCoalesceInterval {
            return
        }
        subscribeCoalesce[id] = now
        messageHandlers[id] = handler
        
        let req = NostrRequest.subscribe(id: id, filters: [filter])
        
        do {
            let message = try encoder.encode(req)
            guard let messageString = String(data: message, encoding: .utf8) else { 
                SecureLogger.error("❌ Failed to encode subscription request", category: .session)
                return 
            }
            
            // SecureLogger.debug("📋 Subscription filter JSON: \(messageString.prefix(200))...", category: .session)
            
            // Target specific relays if provided; else default. Filter permanently failed relays.
            let baseUrls = relayUrls ?? Self.defaultRelays
            let urls = allowedRelayList(from: baseUrls).filter { !isPermanentlyFailed($0) }
            let requestState = SubscriptionRequestState(messageString: messageString, relayURLs: Set(urls))
            if subscriptionRequestState[id] == requestState, subscriptionStateExists(id: id, requestState: requestState) {
                return
            }
            subscriptionRequestState[id] = requestState

            // Always queue subscriptions; sending happens when a relay reports connected
            var existingSet = Set(relays.map { $0.url })
            for url in urls where !existingSet.contains(url) {
                relays.append(Relay(url: url))
                existingSet.insert(url)
            }
            for url in urls {
                queuePendingSubscription(id: id, messageString: messageString, for: url)
            }
            // Initialize EOSE tracking if requested
            if let onEOSE = onEOSE {
                if urls.isEmpty {
                    onEOSE()
                } else if shouldWaitForTorBeforeConnecting {
                    parkEOSECallbackUntilTorReady(id: id, callback: onEOSE)
                } else {
                    startEOSETracking(id: id, relayURLs: Set(urls), callback: onEOSE)
                }
            }
            SecureLogger.debug("📋 Queued subscription id=\(id) for \(urls.count) relay(s)", category: .session)
            // Ensure we actually have sockets opening to these relays so queued REQs can flush
            ensureConnections(to: urls)
            // If some targets are already connected, flush immediately for them
            for url in urls {
                if let r = relays.first(where: { $0.url == url }), r.isConnected {
                    flushPendingSubscriptions(for: url)
                }
            }
        } catch {
            SecureLogger.error("❌ Failed to encode subscription request: \(error)", category: .session)
        }
    }

    private func applyDefaultRelayPolicy(force: Bool = false) {
        let shouldAllow = hasMutualFavorites || hasLocationPermission
        if !force && shouldAllow == allowDefaultRelays { return }
        allowDefaultRelays = shouldAllow
        if shouldAllow {
            var existing = Set(relays.map { $0.url })
            for url in Self.defaultRelays where !existing.contains(url) {
                relays.append(Relay(url: url))
                existing.insert(url)
            }
            if dependencies.activationAllowed() {
                ensureConnections(to: Self.defaultRelays)
            }
        } else {
            for url in Self.defaultRelays {
                if let connection = connections[url] {
                    connection.cancel(with: .goingAway, reason: nil)
                }
                connections.removeValue(forKey: url)
                subscriptions.removeValue(forKey: url)
                pendingSubscriptions.removeValue(forKey: url)
            }
            messageQueueLock.lock()
            for index in (0..<messageQueue.count).reversed() {
                var item = messageQueue[index]
                item.pendingRelays.subtract(Self.defaultRelaySet)
                if item.pendingRelays.isEmpty {
                    messageQueue.remove(at: index)
                } else {
                    messageQueue[index] = item
                }
            }
            messageQueueLock.unlock()
            relays.removeAll { Self.defaultRelaySet.contains($0.url) }
            updateConnectionStatus()
        }
    }

    private func allowedRelayList(from urls: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for rawURL in urls {
            guard let url = NostrRelayURL.normalized(rawURL) else { continue }
            if !allowDefaultRelays && Self.defaultRelaySet.contains(url) { continue }
            if seen.insert(url).inserted {
                result.append(url)
            }
        }
        return result
    }
    
    /// Unsubscribe from a subscription
    func unsubscribe(id: String) {
        messageHandlers.removeValue(forKey: id)
        removeRecentInboundEvents(forSubscriptionID: id)
        duplicateInboundEventDropCountBySubscription.removeValue(forKey: id)
        // Allow immediate re-subscription by clearing coalescer timestamp
        subscribeCoalesce.removeValue(forKey: id)
        subscriptionRequestState.removeValue(forKey: id)
        pendingEOSECallbacks.removeValue(forKey: id)
        eoseTrackers.removeValue(forKey: id)
        for url in Array(pendingSubscriptions.keys) {
            pendingSubscriptions[url]?.removeValue(forKey: id)
        }
        
        let req = NostrRequest.close(id: id)
        let message = try? encoder.encode(req)
        
        guard let messageData = message,
              let messageString = String(data: messageData, encoding: .utf8) else { return }
        
        // Send unsubscribe to all relays
        for (relayUrl, connection) in connections {
            if subscriptions[relayUrl]?.contains(id) == true {
                subscriptions[relayUrl]?.remove(id)
                connection.send(.string(messageString)) { _ in
                    // Local state is cleared before sending so callers can re-subscribe immediately.
                }
            }
        }
    }
    
    // MARK: - Private Methods

    private var shouldWaitForTorBeforeConnecting: Bool {
        shouldUseTor && !dependencies.torIsReady()
    }

    private func connectToRelays(_ relayUrls: [String], shouldLog: Bool = false) {
        guard dependencies.activationAllowed() else { return }
        sweepStalePendingSubscriptions()
        let targets = allowedRelayList(from: relayUrls).filter {
            connections[$0] == nil && !isPermanentlyFailed($0)
        }
        guard !targets.isEmpty else { return }

        if shouldWaitForTorBeforeConnecting {
            queueConnectionsUntilTorReady(targets)
            return
        }

        if shouldLog {
            let route = shouldUseTor ? "via Tor" : "direct"
            SecureLogger.debug("🌐 Connecting to \(targets.count) Nostr relay(s) (\(route))", category: .session)
        }

        for url in targets {
            connectToRelay(url)
        }
    }

    private func queueConnectionsUntilTorReady(_ relayUrls: [String]) {
        let targets = allowedRelayList(from: relayUrls).filter {
            connections[$0] == nil && !isPermanentlyFailed($0)
        }
        guard !targets.isEmpty else { return }

        pendingTorConnectionURLs.formUnion(targets)
        guard !awaitingTorForConnections else { return }

        awaitingTorForConnections = true
        let generation = connectionGeneration
        dependencies.awaitTorReady { [weak self] ready in
            guard let self else { return }
            guard generation == self.connectionGeneration else { return }

            let pending = Array(self.pendingTorConnectionURLs)
            self.pendingTorConnectionURLs.removeAll()
            self.awaitingTorForConnections = false

            guard ready else {
                self.torReadyWaitAttempts += 1
                if self.torReadyWaitAttempts < TransportConfig.nostrTorReadyMaxWaitAttempts {
                    SecureLogger.warning("Tor not ready; re-queueing \(pending.count) relay connection(s) (attempt \(self.torReadyWaitAttempts))", category: .session)
                    self.queueConnectionsUntilTorReady(pending)
                } else {
                    // Still fail-closed (no network), but unblock any callers
                    // waiting on EOSE so the UI doesn't hang indefinitely.
                    // Queued subscriptions/sends are kept and flush if a later
                    // trigger (e.g. app foreground) brings Tor up.
                    SecureLogger.error("❌ Tor not ready after \(self.torReadyWaitAttempts) wait(s); aborting relay connections (fail-closed)", category: .session)
                    self.torReadyWaitAttempts = 0
                    self.unblockPendingEOSECallbacks(reason: "tor-unavailable")
                }
                return
            }

            self.torReadyWaitAttempts = 0
            self.connectToRelays(pending, shouldLog: true)
        }
    }

    /// Park an EOSE callback while Tor is not yet ready, and schedule the same
    /// fallback timeout `startEOSETracking` uses. Without it, a parked callback
    /// would only be unblocked by Tor-readiness retry exhaustion (several
    /// awaitReady timeouts, i.e. minutes), leaving callers hanging far past the
    /// normal EOSE fallback. If Tor recovers first the callback is promoted to
    /// a real EOSE tracker (`startPendingEOSETrackingIfNeeded`), and if retry
    /// exhaustion fires first it is drained by `unblockPendingEOSECallbacks`;
    /// either way it leaves `pendingEOSECallbacks` and this timer is a no-op.
    private func parkEOSECallbackUntilTorReady(id: String, callback: @escaping () -> Void) {
        pendingEOSECallbacks[id] = callback
        let generation = connectionGeneration
        dependencies.scheduleAfter(TransportConfig.nostrSubscriptionEOSEFallbackSeconds) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Stale timers from a previous connection generation are void.
                guard generation == self.connectionGeneration else { return }
                // Already fired (unsubscribe, retry-exhaustion unblock) or
                // promoted to a real EOSE tracker: nothing to do.
                guard let callback = self.pendingEOSECallbacks.removeValue(forKey: id) else { return }
                SecureLogger.warning("Unblocking Tor-parked EOSE callback for \(id) after fallback timeout", category: .session)
                callback()
            }
        }
    }

    /// Fire and clear all EOSE callbacks that are parked waiting for Tor.
    /// Callers treat EOSE as "initial fetch finished"; firing with no data is
    /// safe and prevents indefinite hangs when Tor cannot bootstrap.
    private func unblockPendingEOSECallbacks(reason: String) {
        guard !pendingEOSECallbacks.isEmpty else { return }
        let callbacks = pendingEOSECallbacks
        pendingEOSECallbacks.removeAll()
        SecureLogger.warning("Unblocking \(callbacks.count) pending EOSE callback(s) without data (\(reason))", category: .session)
        for (_, callback) in callbacks {
            callback()
        }
    }

    private func subscriptionStateExists(id: String, requestState: SubscriptionRequestState) -> Bool {
        guard !requestState.relayURLs.isEmpty else { return true }
        return requestState.relayURLs.allSatisfy { url in
            pendingSubscriptions[url]?[id]?.messageString == requestState.messageString ||
                subscriptions[url]?.contains(id) == true
        }
    }

    private func queuePendingSubscription(id: String, messageString: String, for url: String) {
        var map = pendingSubscriptions[url] ?? [:]
        pendingSubscriptionSequence &+= 1
        map[id] = PendingSubscription(
            messageString: messageString,
            queuedAt: dependencies.now(),
            sequence: pendingSubscriptionSequence
        )
        // Bound per-relay pending REQs; evict oldest by insertion order. The
        // durable intent stays in subscriptionRequestState, so an evicted REQ
        // is still replayed if its subscription is active when the relay
        // (re)connects.
        var evictedCount = 0
        while map.count > TransportConfig.nostrPendingSubscriptionsPerRelayCap,
              let oldest = map.min(by: { $0.value.sequence < $1.value.sequence }) {
            map.removeValue(forKey: oldest.key)
            evictedCount += 1
        }
        if evictedCount > 0 {
            // Bounds proof: the cap eviction actually removed entries.
            SecureLogger.warning(
                "📋 Evicted \(evictedCount) pending sub(s) over cap for \(url)",
                category: .session
            )
        }
        pendingSubscriptions[url] = map
    }

    /// Drop pending REQs older than the TTL. Runs on connect attempts (the
    /// natural maintenance path: connect/ensureConnections/reconnects all
    /// funnel through connectToRelays) so stale entries for relays that never
    /// come up cannot accumulate without bound.
    private func sweepStalePendingSubscriptions() {
        let now = dependencies.now()
        for (url, map) in pendingSubscriptions {
            let fresh = map.filter {
                now.timeIntervalSince($0.value.queuedAt) <= TransportConfig.nostrPendingSubscriptionTTLSeconds
            }
            guard fresh.count != map.count else { continue }
            // Bounds proof: the age sweep actually removed entries. Warning
            // (not debug) — stale pending REQs mean a relay never came up.
            SecureLogger.warning(
                "📋 Swept \(map.count - fresh.count) stale pending sub(s) for \(url)",
                category: .session
            )
            pendingSubscriptions[url] = fresh.isEmpty ? nil : fresh
        }
    }

    private func startEOSETracking(id: String, relayURLs: Set<String>, callback: @escaping () -> Void) {
        eoseTrackerEpoch += 1
        let epoch = eoseTrackerEpoch
        eoseTrackers[id] = EOSETracker(awaitingSend: relayURLs, awaitingEOSE: [], callback: callback, epoch: epoch)
        // Fallback timeout to avoid hanging if a relay never sends EOSE.
        dependencies.scheduleAfter(TransportConfig.nostrSubscriptionEOSEFallbackSeconds) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let tracker = self.eoseTrackers[id], tracker.epoch == epoch else { return }
                self.eoseTrackers.removeValue(forKey: id)
                tracker.callback()
            }
        }
    }

    private func startPendingEOSETrackingIfNeeded(id: String) {
        guard eoseTrackers[id] == nil,
              let callback = pendingEOSECallbacks.removeValue(forKey: id),
              let requestState = subscriptionRequestState[id]
        else {
            return
        }

        if requestState.relayURLs.isEmpty {
            callback()
        } else {
            startEOSETracking(id: id, relayURLs: requestState.relayURLs, callback: callback)
        }
    }

    private func shouldDeliverInboundEvent(subscriptionID: String, eventID: String) -> Bool {
        guard !eventID.isEmpty else { return true }
        let key = InboundEventKey(subscriptionID: subscriptionID, eventID: eventID)
        guard recentInboundEventKeys.insert(key).inserted else {
            recordDuplicateInboundEventDrop(subscriptionID: subscriptionID)
            return false
        }
        recentInboundEventKeyOrder.append(key)

        if recentInboundEventKeyOrder.count > recentInboundEventKeyLimit {
            let removeCount = recentInboundEventKeyOrder.count - recentInboundEventKeyTrimTarget
            for staleKey in recentInboundEventKeyOrder.prefix(removeCount) {
                recentInboundEventKeys.remove(staleKey)
            }
            recentInboundEventKeyOrder.removeFirst(removeCount)
        }
        return true
    }

    private func recordDuplicateInboundEventDrop(subscriptionID: String) {
        duplicateInboundEventDropCount += 1
        let subscriptionCount = (duplicateInboundEventDropCountBySubscription[subscriptionID] ?? 0) + 1
        duplicateInboundEventDropCountBySubscription[subscriptionID] = subscriptionCount

        if duplicateInboundEventDropCount == 1 ||
            duplicateInboundEventDropCount.isMultiple(of: TransportConfig.nostrDuplicateEventLogInterval) {
            SecureLogger.debug(
                "Dropped duplicate Nostr event deliveries total=\(duplicateInboundEventDropCount) sub=\(subscriptionID) sub_total=\(subscriptionCount)",
                category: .session
            )
        }
    }

    private func removeRecentInboundEvents(forSubscriptionID subscriptionID: String) {
        guard !recentInboundEventKeyOrder.isEmpty else { return }
        var retainedKeys: [InboundEventKey] = []
        retainedKeys.reserveCapacity(recentInboundEventKeyOrder.count)
        for key in recentInboundEventKeyOrder {
            if key.subscriptionID == subscriptionID {
                recentInboundEventKeys.remove(key)
            } else {
                retainedKeys.append(key)
            }
        }
        recentInboundEventKeyOrder = retainedKeys
    }
    
    private func connectToRelay(_ urlString: String) {
        // Global network policy gate
        guard dependencies.activationAllowed() else { return }
        guard let url = URL(string: urlString) else { 
            SecureLogger.warning("Invalid relay URL: \(urlString)", category: .session)
            return 
        }

        // Avoid initiating connections while app is backgrounded; we'll reconnect on foreground
        if shouldUseTor && dependencies.torEnforced() && !dependencies.torIsForeground() {
            return
        }
        
        // Skip if we already have a connection object
        if connections[urlString] != nil {
            return
        }
        if isPermanentlyFailed(urlString) {
            return
        }
        
        // Attempting to connect to Nostr relay via the proxied session
        
        // If Tor is enforced but not ready, delay connection until it is.
        if shouldWaitForTorBeforeConnecting {
            queueConnectionsUntilTorReady([urlString])
            return
        }
        
        let session = dependencies.makeSession()
        let task = session.webSocketTask(with: url)
        
        connections[urlString] = task
        task.resume()
        
        // Start receiving messages
        receiveMessage(from: task, relayUrl: urlString)
        
        // Send initial ping to verify connection
        task.sendPing { [weak self] error in
            DispatchQueue.main.async {
                guard self?.connections[urlString] === task else { return }
                if error == nil {
                    SecureLogger.debug("✅ Connected to Nostr relay: \(urlString)", category: .session)
                    self?.updateRelayStatus(urlString, isConnected: true)
                    // Flush any pending subscriptions for this relay
                    self?.flushPendingSubscriptions(for: urlString)
                } else {
                    SecureLogger.error("❌ Failed to connect to Nostr relay \(urlString): \(error?.localizedDescription ?? "Unknown error")", category: .session)
                    self?.updateRelayStatus(urlString, isConnected: false, error: error)
                    // Trigger disconnection handler for proper backoff
                    self?.handleDisconnection(
                        relayUrl: urlString,
                        error: error ?? NSError(domain: "NostrRelay", code: -1, userInfo: nil),
                        connection: task
                    )
                }
            }
        }
    }

    /// Send queued subscriptions and replay durable ones for a relay that just
    /// (re)connected. Relays drop subscriptions with the socket, so every
    /// active subscription targeting this relay must be re-sent.
    private func flushPendingSubscriptions(for relayUrl: String) {
        guard let connection = connections[relayUrl] else { return }
        var toSend = (pendingSubscriptions[relayUrl] ?? [:]).mapValues(\.messageString)
        for (id, state) in subscriptionRequestState where state.relayURLs.contains(relayUrl) && toSend[id] == nil {
            toSend[id] = state.messageString
        }
        for (id, messageString) in toSend {
            if self.subscriptions[relayUrl]?.contains(id) == true {
                // Already subscribed on this relay (e.g. a tracker promoted
                // after an earlier flush): its EOSE is coming, count it.
                markEOSESubscribed(id: id, relayUrl: relayUrl)
                continue
            }
            startPendingEOSETrackingIfNeeded(id: id)
            // Mark at send *initiation*, not in the async completion: a fast
            // relay's EOSE could otherwise complete the tracker while this
            // relay — REQ already on the wire — still sat in awaitingSend.
            // If the send fails the socket is going down with it, and the
            // disconnect settle (or the fallback timer) releases the wait.
            markEOSESubscribed(id: id, relayUrl: relayUrl)
            connection.send(.string(messageString)) { [weak self, weak connection] error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let error = error {
                        // Keep the pending entry; the next (re)connect retries it.
                        SecureLogger.error("❌ Failed to send pending subscription to \(relayUrl): \(error)", category: .session)
                    } else {
                        // A stale completion from a socket that has since been
                        // replaced must not mark the subscription active, or
                        // the next connection would skip replaying it.
                        guard let connection, self.connections[relayUrl] === connection else { return }
                        self.subscriptions[relayUrl, default: []].insert(id)
                        self.pendingSubscriptions[relayUrl]?.removeValue(forKey: id)
                    }
                }
            }
        }
    }
    
    private func receiveMessage(from task: NostrRelayConnectionProtocol, relayUrl: String) {
        task.receive { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(let message):
                // Parse off-main to reduce UI jank, then hop back for state updates
                Task.detached(priority: .utility) {
                    guard let parsed = ParsedInbound(message) else { return }
                    await MainActor.run {
                        guard self.connections[relayUrl] === task else { return }
                        self.handleParsedMessage(parsed, from: relayUrl)
                    }
                }
                
                // Continue receiving
                Task { @MainActor in
                    guard self.connections[relayUrl] === task else { return }
                    self.receiveMessage(from: task, relayUrl: relayUrl)
                }
                
            case .failure(let error):
                DispatchQueue.main.async {
                    self.handleDisconnection(relayUrl: relayUrl, error: error, connection: task)
                }
            }
        }
    }
    
    // Parsed inbound message type (off-main)
    // Note: declared at file scope below to avoid MainActor isolation inside this class
    // and keep parsing off the main actor.

    // Handle parsed message on MainActor (state updates and handlers)
    private func handleParsedMessage(_ parsed: ParsedInbound, from relayUrl: String) {
        switch parsed {
        case .event(let subId, let event):
            if let index = self.relays.firstIndex(where: { $0.url == relayUrl }) {
                self.relays[index].messagesReceived += 1
            }
            guard event.isValidSignature() else {
                SecureLogger.warning(
                    "⚠️ Dropped invalid Nostr event id=\(event.id.prefix(16))… sub=\(subId) relay=\(relayUrl)",
                    category: .session
                )
                return
            }
            guard shouldDeliverInboundEvent(subscriptionID: subId, eventID: event.id) else {
                return
            }
            if event.kind != 1059 {
                // Per-event logging floods dev builds in busy geohashes; sample it.
                inboundEventLogCount += 1
                if inboundEventLogCount == 1 || inboundEventLogCount.isMultiple(of: TransportConfig.nostrInboundEventLogInterval) {
                    SecureLogger.debug("📥 Event #\(inboundEventLogCount) kind=\(event.kind) id=\(event.id.prefix(16))… relay=\(relayUrl)", category: .session)
                }
            }
            if let handler = self.messageHandlers[subId] {
                handler(event)
            } else {
                SecureLogger.warning("⚠️ No handler for subscription \(subId)", category: .session)
            }
        case .eose(let subId):
            if var tracker = eoseTrackers[subId] {
                // An EOSE proves the relay received the REQ even if the local
                // send completion hasn't run yet.
                tracker.awaitingSend.remove(relayUrl)
                tracker.awaitingEOSE.remove(relayUrl)
                tracker.didSend = true
                if tracker.isComplete {
                    eoseTrackers.removeValue(forKey: subId)
                    tracker.callback()
                } else {
                    eoseTrackers[subId] = tracker
                }
            }
        case .ok(let eventId, let success, let reason):
            resolveConfirmedSend(eventID: eventId, relayURL: relayUrl, accepted: success)
            if success {
                _ = Self.pendingGiftWrapIDs.remove(eventId)
                SecureLogger.debug("✅ Accepted id=\(eventId.prefix(16))… relay=\(relayUrl)", category: .session)
            } else {
                let isGiftWrap = Self.pendingGiftWrapIDs.remove(eventId) != nil
                if isGiftWrap {
                    SecureLogger.warning("📮 Rejected id=\(eventId.prefix(16))… relay=\(relayUrl) reason=\(reason)", category: .session)
                } else {
                    SecureLogger.error("📮 Rejected id=\(eventId.prefix(16))… relay=\(relayUrl) reason=\(reason)", category: .session)
                }
            }
        case .notice:
            break
        }
    }
    
    private func sendToRelay(
        event: NostrEvent,
        connection: NostrRelayConnectionProtocol,
        relayUrl: String,
        completion: ((Bool) -> Void)? = nil
    ) {
        let req = NostrRequest.event(event)
        
        do {
            let data = try encoder.encode(req)
            let message = String(data: data, encoding: .utf8) ?? ""
            
            SecureLogger.debug("📤 Send kind=\(event.kind) id=\(event.id.prefix(16))… relay=\(relayUrl)", category: .session)
            
            connection.send(.string(message)) { [weak self] error in
                DispatchQueue.main.async {
                    if let error = error {
                        SecureLogger.error("❌ Failed to send event to \(relayUrl): \(error)", category: .session)
                        completion?(false)
                    } else {
                        // SecureLogger.debug("✅ Event sent to relay: \(relayUrl)", category: .session)
                        // Update relay stats
                        if let index = self?.relays.firstIndex(where: { $0.url == relayUrl }) {
                            self?.relays[index].messagesSent += 1
                        }
                        completion?(true)
                    }
                }
            }
        } catch {
            SecureLogger.error("Failed to encode event: \(error)", category: .session)
            completion?(false)
        }
    }
    
    private func updateRelayStatus(_ url: String, isConnected: Bool, error: Error? = nil) {
        if let index = relays.firstIndex(where: { $0.url == url }) {
            relays[index].isConnected = isConnected
            relays[index].lastError = error
            if isConnected {
                relays[index].reconnectAttempts = 0  // Reset on successful connection
                relays[index].nextReconnectTime = nil
            } else {
                relays[index].lastDisconnectedAt = dependencies.now()
            }
        }
        updateConnectionStatus()
        // If we just connected to this relay, flush any queued sends targeting it
        if isConnected {
            flushMessageQueue(for: url)
        }
    }
    
    private func updateConnectionStatus() {
        isConnected = relays.contains { $0.isConnected }
        // Relay URLs are normalized before entries are created, so direct
        // set membership is sound.
        isDMRelayConnected = relays.contains { $0.isConnected && Self.defaultRelaySet.contains($0.url) }
    }
    
    /// A relay that drops before sending EOSE must not stall initial-load
    /// callbacks; treat it as done and let the remaining relays (or the
    /// fallback timeout) drive completion.
    private func settleEOSETrackers(droppingRelay relayUrl: String) {
        for (id, var tracker) in eoseTrackers
        where tracker.awaitingSend.contains(relayUrl) || tracker.awaitingEOSE.contains(relayUrl) {
            tracker.awaitingSend.remove(relayUrl)
            tracker.awaitingEOSE.remove(relayUrl)
            if tracker.isComplete {
                eoseTrackers.removeValue(forKey: id)
                tracker.callback()
            } else {
                eoseTrackers[id] = tracker
            }
        }
    }

    /// Whether any of `relayUrls` currently holds a live connection. Lets
    /// subscribers distinguish "loaded, empty" from "never reached a relay"
    /// when an EOSE fallback fires.
    func isAnyRelayConnected(among relayUrls: [String]) -> Bool {
        let targets = Set(relayUrls)
        return relays.contains { targets.contains($0.url) && $0.isConnected }
    }

    /// Marks the REQ as delivered to `relayUrl`: EOSE completion now waits on
    /// this relay instead of the never-connected remainder.
    private func markEOSESubscribed(id: String, relayUrl: String) {
        guard var tracker = eoseTrackers[id],
              tracker.awaitingSend.remove(relayUrl) != nil else { return }
        tracker.awaitingEOSE.insert(relayUrl)
        tracker.didSend = true
        eoseTrackers[id] = tracker
    }

    private func handleDisconnection(
        relayUrl: String,
        error: Error,
        connection: NostrRelayConnectionProtocol? = nil
    ) {
        if let connection, connections[relayUrl] !== connection { return }
        connections.removeValue(forKey: relayUrl)
        subscriptions.removeValue(forKey: relayUrl)
        let awaitingConfirmation = confirmedSends.compactMap { eventID, state in
            state.awaitingRelays.contains(relayUrl) ? eventID : nil
        }
        for eventID in awaitingConfirmation {
            resolveConfirmedSend(eventID: eventID, relayURL: relayUrl, accepted: false)
        }
        updateRelayStatus(relayUrl, isConnected: false, error: error)
        settleEOSETrackers(droppingRelay: relayUrl)
        // If networking is disallowed, do not schedule reconnection
        if !dependencies.activationAllowed() {
            return
        }
        
        // Check if this is a DNS or handshake error; treat as permanent
        let errorDescription = error.localizedDescription.lowercased()
        let ns = error as NSError
        if errorDescription.contains("hostname could not be found") || 
           errorDescription.contains("dns") ||
           (ns.domain == NSURLErrorDomain && ns.code == NSURLErrorBadServerResponse) {
            if relays.first(where: { $0.url == relayUrl })?.lastError == nil {
                SecureLogger.warning("Nostr relay permanent failure for \(relayUrl) - not retrying (code=\(ns.code))", category: .session)
            }
            if let index = relays.firstIndex(where: { $0.url == relayUrl }) {
                relays[index].lastError = error
                relays[index].reconnectAttempts = maxReconnectAttempts
                relays[index].nextReconnectTime = nil
            }
            pendingSubscriptions[relayUrl] = nil
            return
        }
        
        // Implement exponential backoff for non-DNS errors
        guard let index = relays.firstIndex(where: { $0.url == relayUrl }) else { return }
        
        relays[index].reconnectAttempts += 1
        
        // Stop attempting after max attempts
        if relays[index].reconnectAttempts >= maxReconnectAttempts {
            SecureLogger.warning("Max reconnection attempts (\(maxReconnectAttempts)) reached for \(relayUrl)", category: .session)
            return
        }
        
        // Calculate backoff interval with ±jitterRatio random jitter so relays
        // that dropped together don't all reconnect at the same instant.
        let baseBackoffInterval = min(
            initialBackoffInterval * pow(backoffMultiplier, Double(relays[index].reconnectAttempts - 1)),
            maxBackoffInterval
        )
        let jitterRatio = TransportConfig.nostrRelayBackoffJitterRatio
        let jitterFactor = 1.0 + (dependencies.jitterUnit() * 2.0 - 1.0) * jitterRatio
        let backoffInterval = baseBackoffInterval * jitterFactor

        let nextReconnectTime = dependencies.now().addingTimeInterval(backoffInterval)
        relays[index].nextReconnectTime = nextReconnectTime

        // Reconnects are bounded by maxReconnectAttempts and exponentially
        // backed off, so this is low-frequency: plain debug, no sampling.
        SecureLogger.debug(
            "🔄 Reconnect \(relayUrl) in \(String(format: "%.1f", backoffInterval))s (base \(String(format: "%.1f", baseBackoffInterval))s, attempt \(relays[index].reconnectAttempts)/\(maxReconnectAttempts))",
            category: .session
        )

        // Schedule reconnection with exponential backoff
        let gen = connectionGeneration
        dependencies.scheduleAfter(backoffInterval) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                // Ignore stale scheduled reconnects from a previous generation
                guard gen == self.connectionGeneration else { return }
                // Check if we should still reconnect (relay might have been removed)
                if self.relays.contains(where: { $0.url == relayUrl }) {
                    self.connectToRelay(relayUrl)
                }
            }
        }
    }
    
    // MARK: - Public Utility Methods
    
    /// Manually retry connection to a specific relay
    func retryConnection(to relayUrl: String) {
        let normalizedRelayUrl = NostrRelayURL.normalized(relayUrl) ?? relayUrl
        guard let index = relays.firstIndex(where: { $0.url == normalizedRelayUrl }) else { return }
        
        // Reset reconnection attempts
        relays[index].reconnectAttempts = 0
        relays[index].nextReconnectTime = nil
        relays[index].lastError = nil
        
        // Disconnect if connected
        if let connection = connections[normalizedRelayUrl] {
            connection.cancel(with: .goingAway, reason: nil)
            connections.removeValue(forKey: normalizedRelayUrl)
        }
        
        // Attempt immediate reconnection
        connectToRelay(normalizedRelayUrl)
    }
    
    /// Get detailed status for all relays
    func getRelayStatuses() -> [(url: String, isConnected: Bool, reconnectAttempts: Int, nextReconnectTime: Date?)] {
        return relays.map { relay in
            (url: relay.url, 
             isConnected: relay.isConnected, 
             reconnectAttempts: relay.reconnectAttempts,
             nextReconnectTime: relay.nextReconnectTime)
        }
    }

    var debugPendingMessageQueueCount: Int {
        messageQueueLock.lock()
        defer { messageQueueLock.unlock() }
        return messageQueue.count
    }

    func debugPendingSubscriptionCount(for relayUrl: String) -> Int {
        pendingSubscriptions[relayUrl]?.count ?? 0
    }

    func debugPendingSubscriptionIDs(for relayUrl: String) -> Set<String> {
        guard let map = pendingSubscriptions[relayUrl] else { return [] }
        return Set(map.keys)
    }

    var debugMessageHandlerCount: Int {
        messageHandlers.count
    }

    var debugSubscriptionRequestCount: Int {
        subscriptionRequestState.count
    }

    var debugPendingEOSECallbackCount: Int {
        pendingEOSECallbacks.count
    }

    var debugDuplicateInboundEventDropCount: Int {
        duplicateInboundEventDropCount
    }

    func debugDuplicateInboundEventDropCount(forSubscriptionID subscriptionID: String) -> Int {
        duplicateInboundEventDropCountBySubscription[subscriptionID] ?? 0
    }

    func debugFlushMessageQueue() {
        flushMessageQueue(for: nil)
    }
    
    /// Reset all relay connections
    func resetAllConnections() {
        disconnect()
        // New generation begins now
        connectionGeneration &+= 1
        
        // Reset all relay states
        for index in relays.indices {
            relays[index].reconnectAttempts = 0
            relays[index].nextReconnectTime = nil
            relays[index].lastError = nil
        }
        
        // Reconnect
        connect()
    }

    // MARK: - Failure classification
    private func isPermanentlyFailed(_ url: String) -> Bool {
        guard let r = relays.first(where: { $0.url == url }) else { return false }
        // Failures decay: after a cooldown the relay gets another chance, so a
        // long network outage or transient relay trouble can't blacklist it
        // for the rest of the process lifetime.
        if let lastDisconnect = r.lastDisconnectedAt,
           dependencies.now().timeIntervalSince(lastDisconnect) >= TransportConfig.nostrRelayFailureCooldownSeconds {
            return false
        }
        if r.reconnectAttempts >= maxReconnectAttempts { return true }
        if let ns = r.lastError as NSError?, ns.domain == NSURLErrorDomain {
            if ns.code == NSURLErrorBadServerResponse || ns.code == NSURLErrorCannotFindHost {
                return true
            }
        }
        return false
    }
}

// MARK: - Off-main inbound parsing helpers (file scope, non-isolated)

private enum ParsedInbound {
    case event(subId: String, event: NostrEvent)
    case ok(eventId: String, success: Bool, reason: String)
    case eose(subscriptionId: String)
    case notice(String)
    
    init?(_ message: URLSessionWebSocketTask.Message) {
        guard let data = message.data,
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
              array.count >= 2,
              let type = array[0] as? String else {
            return nil
        }

        switch type {
        case "EVENT":
            if array.count >= 3,
               let subId = array[1] as? String,
               let eventDict = array[2] as? [String: Any],
               let event = try? NostrEvent(from: eventDict) {
                self = .event(subId: subId, event: event)
                return
            }
            return nil
        case "EOSE":
            if let subId = array[1] as? String {
                self = .eose(subscriptionId: subId)
                return
            }
            return nil
        case "OK":
            if array.count >= 3,
               let eventId = array[1] as? String,
               let success = array[2] as? Bool {
                let reason = array.count >= 4 ? (array[3] as? String ?? "no reason given") : "no reason given"
                self = .ok(eventId: eventId, success: success, reason: reason)
                return
            }
            return nil
        case "NOTICE":
            if array.count >= 2, let msg = array[1] as? String {
                self = .notice(msg)
                return
            }
            return nil
        default:
            return nil
        }
    }
}

private extension URLSessionWebSocketTask.Message {
    var data: Data? {
        switch self {
        case .string(let text): text.data(using: .utf8)
        case .data(let data):   data
        @unknown default:       nil
        }
    }
}

// MARK: - Nostr Protocol Types

enum NostrRequest: Encodable {
    case event(NostrEvent)
    case subscribe(id: String, filters: [NostrFilter])
    case close(id: String)
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        
        switch self {
        case .event(let event):
            try container.encode("EVENT")
            try container.encode(event)
            
        case .subscribe(let id, let filters):
            try container.encode("REQ")
            try container.encode(id)
            for filter in filters {
                try container.encode(filter)
            }
            
        case .close(let id):
            try container.encode("CLOSE")
            try container.encode(id)
        }
    }
}

struct NostrFilter: Encodable {
    var ids: [String]?
    var authors: [String]?
    var kinds: [Int]?
    var since: Int?
    var until: Int?
    var limit: Int?
    
    // Tag filters - stored internally but encoded specially
    fileprivate var tagFilters: [String: [String]]?
    
    init() {
        // Default initializer
    }
    
    // Custom encoding to handle tag filters properly
    enum CodingKeys: String, CodingKey {
        case ids, authors, kinds, since, until, limit
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        
        // Encode standard fields
        if let ids = ids { try container.encode(ids, forKey: DynamicCodingKey(stringValue: "ids")) }
        if let authors = authors { try container.encode(authors, forKey: DynamicCodingKey(stringValue: "authors")) }
        if let kinds = kinds { try container.encode(kinds, forKey: DynamicCodingKey(stringValue: "kinds")) }
        if let since = since { try container.encode(since, forKey: DynamicCodingKey(stringValue: "since")) }
        if let until = until { try container.encode(until, forKey: DynamicCodingKey(stringValue: "until")) }
        if let limit = limit { try container.encode(limit, forKey: DynamicCodingKey(stringValue: "limit")) }
        
        // Encode tag filters with # prefix
        if let tagFilters = tagFilters {
            for (tag, values) in tagFilters {
                try container.encode(values, forKey: DynamicCodingKey(stringValue: "#\(tag)"))
            }
        }
    }
    
    // For NIP-17 gift wraps
    static func giftWrapsFor(pubkey: String, since: Date? = nil) -> NostrFilter {
        var filter = NostrFilter()
        filter.kinds = [1059] // Gift wrap kind
        filter.since = since?.timeIntervalSince1970.toInt()
        filter.tagFilters = ["p": [pubkey]]
        filter.limit = TransportConfig.nostrRelayDefaultFetchLimit // reasonable limit
        return filter
    }

    // For location channels: geohash-scoped ephemeral events (kind 20000) and presence (kind 20001)
    static func geohashEphemeral(_ geohash: String, since: Date? = nil, limit: Int = 1000) -> NostrFilter {
        var filter = NostrFilter()
        filter.kinds = [20000, 20001]
        filter.since = since?.timeIntervalSince1970.toInt()
        filter.tagFilters = ["g": [geohash]]
        filter.limit = limit
        return filter
    }

    // For location notes: persistent text notes (kind 1) tagged with geohash
    static func geohashNotes(_ geohash: String, since: Date? = nil, limit: Int = 200) -> NostrFilter {
        var filter = NostrFilter()
        filter.kinds = [1]
        filter.since = since?.timeIntervalSince1970.toInt()
        filter.tagFilters = ["g": [geohash]]
        filter.limit = limit
        return filter
    }

    // For location notes with neighbors: subscribe to multiple geohashes (center + neighbors)
    static func geohashNotes(_ geohashes: [String], since: Date? = nil, limit: Int = 200) -> NostrFilter {
        var filter = NostrFilter()
        filter.kinds = [1]
        filter.since = since?.timeIntervalSince1970.toInt()
        filter.tagFilters = ["g": geohashes]
        filter.limit = limit
        return filter
    }

    // For the mesh bridge: rendezvous messages (kind 20000) and presence
    // (kind 20001) tagged `#r` with one or more cells (own + neighbors).
    static func bridgeRendezvous(_ cells: [String], since: Date? = nil, limit: Int = 200) -> NostrFilter {
        var filter = NostrFilter()
        filter.kinds = [20000, 20001]
        filter.since = since?.timeIntervalSince1970.toInt()
        filter.tagFilters = ["r": cells]
        filter.limit = limit
        return filter
    }

    // For courier drops: sealed envelopes (kind 1401) parked under rotating
    // recipient tags (`#x`, hex). Callers pass every candidate tag (adjacent
    // UTC days x recipients) in one filter.
    static func courierDrops(recipientTagsHex: [String], since: Date? = nil, limit: Int = 100) -> NostrFilter {
        var filter = NostrFilter()
        filter.kinds = [NostrProtocol.EventKind.courierDrop.rawValue]
        filter.since = since?.timeIntervalSince1970.toInt()
        filter.tagFilters = ["x": recipientTagsHex]
        filter.limit = limit
        return filter
    }
}

// Dynamic coding key for tag filters
private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    
    init(stringValue: String) {
        self.stringValue = stringValue
    }
    
    init?(intValue: Int) {
        return nil
    }
}

private extension TimeInterval {
    func toInt() -> Int {
        return Int(self)
    }
}
