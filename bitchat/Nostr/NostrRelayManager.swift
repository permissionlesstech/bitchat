import BitLogger
import Foundation
import Network
import Combine
import Tor

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
        var lastConnectedAt: Date?
        var messagesSent: Int = 0
        var messagesReceived: Int = 0
        var reconnectAttempts: Int = 0
        var lastDisconnectedAt: Date?
        var nextReconnectTime: Date?
    }
    
    // Default relay list (can be customized)
    private static let defaultRelays = [
        "wss://relay.damus.io",
        "wss://nos.lol",
        "wss://relay.primal.net",
        "wss://offchain.pub",
        "wss://nostr21.com"
        // For local testing, you can add: "ws://localhost:8080"
    ]
    private static let defaultRelaySet = Set(defaultRelays)
    
    @Published private(set) var relays: [Relay] = []
    @Published private(set) var isConnected = false
    
    private var allowDefaultRelays: Bool = false
    private var hasMutualFavorites: Bool = false
    private var hasLocationPermission: Bool = false
    private var connections: [String: URLSessionWebSocketTask] = [:]
    private var subscriptions: [String: Set<String>] = [:] // relay URL -> active subscription IDs
    private var pendingSubscriptions: [String: [String: String]] = [:] // relay URL -> (subscription id -> encoded REQ JSON)
    private var messageHandlers: [String: (NostrEvent) -> Void] = [:]
    // Coalesce duplicate subscribe requests for the same id within a short window
    private var subscribeCoalesce: [String: Date] = [:]
    private var cancellables = Set<AnyCancellable>()

    // Track EOSE per subscription to signal when initial stored events are done
    private struct EOSETracker {
        var pendingRelays: Set<String>
        var callback: () -> Void
        var timer: Timer?
    }
    private var eoseTrackers: [String: EOSETracker] = [:]
    
    // Message queue for reliability
    // Pending sends held only for relays that are not yet connected.
    private struct PendingSend {
        var event: NostrEvent
        var pendingRelays: Set<String>
    }
    private var messageQueue: [PendingSend] = []
    private let messageQueueLock = NSLock()
    private let encoder = JSONEncoder()
    private var networkService: NetworkActivationService { NetworkActivationService.shared }
    private var shouldUseTor: Bool { networkService.userTorEnabled }
    
    // Exponential backoff configuration
    private let initialBackoffInterval: TimeInterval = TransportConfig.nostrRelayInitialBackoffSeconds
    private let maxBackoffInterval: TimeInterval = TransportConfig.nostrRelayMaxBackoffSeconds
    private let backoffMultiplier: Double = TransportConfig.nostrRelayBackoffMultiplier
    private let maxReconnectAttempts = TransportConfig.nostrRelayMaxReconnectAttempts
    
    // Bump generation to invalidate scheduled reconnects when we reset/disconnect
    private var connectionGeneration: Int = 0
    
    init() {
        hasMutualFavorites = !FavoritesPersistenceService.shared.mutualFavorites.isEmpty
        hasLocationPermission = LocationChannelManager.shared.permissionState == .authorized
        applyDefaultRelayPolicy(force: true)
        // Deterministic JSON shape for outbound requests
        self.encoder.outputFormatting = .sortedKeys
        FavoritesPersistenceService.shared.$mutualFavorites
            .receive(on: DispatchQueue.main)
            .sink { [weak self] favorites in
                guard let self = self else { return }
                self.hasMutualFavorites = !favorites.isEmpty
                self.applyDefaultRelayPolicy()
            }
            .store(in: &cancellables)
        LocationChannelManager.shared.$permissionState
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
        guard networkService.activationAllowed else { return }
        if shouldUseTor {
            // Ensure Tor is started early and wait for readiness off-main; then hop back to connect.
            Task.detached {
                let ready = await TorManager.shared.awaitReady()
                await MainActor.run {
                    if !ready {
                        SecureLogger.error("❌ Tor not ready; aborting relay connections (fail-closed)", category: .session)
                        return
                    }
                    SecureLogger.debug("🌐 Connecting to \(self.relays.count) Nostr relays (via Tor)", category: .session)
                    for relay in self.relays {
                        self.connectToRelay(relay.url)
                    }
                }
            }
        } else {
            SecureLogger.debug("🌐 Connecting to \(self.relays.count) Nostr relays (direct)", category: .session)
            for relay in self.relays {
                connectToRelay(relay.url)
            }
        }
    }
    
    /// Disconnect from all relays
    func disconnect() {
        connectionGeneration &+= 1
        for (_, task) in connections {
            task.cancel(with: .goingAway, reason: nil)
        }
        connections.removeAll()
        // Clear known subscriptions and any queued subs since connections are gone
        subscriptions.removeAll()
        pendingSubscriptions.removeAll()
        updateConnectionStatus()
    }
    
    /// Ensure connections exist to the given relay URLs (idempotent).
    func ensureConnections(to relayUrls: [String]) {
        // Global network policy gate
        guard networkService.activationAllowed else { return }
        let targets = allowedRelayList(from: relayUrls)
        guard !targets.isEmpty else { return }
        if shouldUseTor && TorManager.shared.torEnforced && !TorManager.shared.isReady {
            // Defer until Tor is fully ready; avoid queuing connection attempts early
            Task.detached { [weak self] in
                guard let self = self else { return }
                let ready = await TorManager.shared.awaitReady()
                await MainActor.run { if ready { self.ensureConnections(to: relayUrls) } }
            }
            return
        }
        var existing = Set(relays.map { $0.url })
        for url in targets where !existing.contains(url) {
            relays.append(Relay(url: url))
            existing.insert(url)
        }
        for url in targets where connections[url] == nil {
            connectToRelay(url)
        }
    }

    /// Send an event to specified relays (or all if none specified)
    func sendEvent(_ event: NostrEvent, to relayUrls: [String]? = nil) {
        // Global network policy gate
        guard networkService.activationAllowed else { return }
        if shouldUseTor && TorManager.shared.torEnforced && !TorManager.shared.isReady {
            // Defer sends until Tor is ready to avoid premature queueing
            Task.detached { [weak self] in
                guard let self = self else { return }
                let ready = await TorManager.shared.awaitReady()
                await MainActor.run { if ready { self.sendEvent(event, to: relayUrls) } }
            }
            return
        }
        let requestedRelays = relayUrls ?? Self.defaultRelays
        let targetRelays = allowedRelayList(from: requestedRelays)
        guard !targetRelays.isEmpty else { return }
        ensureConnections(to: targetRelays)

        // Attempt immediate send to relays with active connections; queue the rest
        var stillPending = Set<String>()
        for relayUrl in targetRelays {
            if let connection = connections[relayUrl] {
                sendToRelay(event: event, connection: connection, relayUrl: relayUrl)
            } else {
                stillPending.insert(relayUrl)
            }
        }
        if !stillPending.isEmpty {
            messageQueueLock.lock()
            messageQueue.append(PendingSend(event: event, pendingRelays: stillPending))
            messageQueueLock.unlock()
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
                if item.pendingRelays.contains(target), let conn = connections[target] {
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
                    if let conn = connections[url] {
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
    
    /// Subscribe to events matching a filter. If `relayUrls` provided, targets only those relays.
    func subscribe(
        filter: NostrFilter,
        id: String = UUID().uuidString,
        relayUrls: [String]? = nil,
        handler: @escaping (NostrEvent) -> Void,
        onEOSE: (() -> Void)? = nil
    ) {
        // Global network policy gate
        guard networkService.activationAllowed else { return }
        // Coalesce rapid duplicate subscribe requests only if a handler already exists
        let now = Date()
        if messageHandlers[id] != nil {
            if let last = subscribeCoalesce[id], now.timeIntervalSince(last) < 1.0 {
                return
            }
        }
        subscribeCoalesce[id] = now
        if shouldUseTor && TorManager.shared.torEnforced && !TorManager.shared.isReady {
            // Defer subscription setup until Tor is ready; avoid queuing subs early
            Task.detached { [weak self] in
                guard let self = self else { return }
                let ready = await TorManager.shared.awaitReady()
                await MainActor.run {
                    if ready {
                        self.subscribe(filter: filter, id: id, relayUrls: relayUrls, handler: handler)
                    }
                }
            }
            return
        }
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
            let candidateUrls = baseUrls.filter { !isPermanentlyFailed($0) }
            let urls = allowedRelayList(from: candidateUrls)
            // Always queue subscriptions; sending happens when a relay reports connected
            let existingSet = Set(relays.map { $0.url })
            for url in urls where !existingSet.contains(url) {
                relays.append(Relay(url: url))
            }
            for url in candidateUrls {
                var map = self.pendingSubscriptions[url] ?? [:]
                map[id] = messageString
                self.pendingSubscriptions[url] = map
            }
            // Initialize EOSE tracking if requested
            if let onEOSE = onEOSE {
                if urls.isEmpty {
                    onEOSE()
                } else {
                    var tracker = EOSETracker(pendingRelays: Set(urls), callback: onEOSE, timer: nil)
                    // Fallback timeout to avoid hanging if a relay never sends EOSE
                    tracker.timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                        Task { @MainActor in
                            guard let self = self else { return }
                            if let t = self.eoseTrackers[id] {
                                t.timer?.invalidate()
                                self.eoseTrackers.removeValue(forKey: id)
                                onEOSE()
                            }
                        }
                    }
                    eoseTrackers[id] = tracker
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
            if networkService.activationAllowed {
                ensureConnections(to: Self.defaultRelays)
            }
        } else {
            for url in Self.defaultRelays {
                if let connection = connections[url] {
                    connection.cancel(with: .goingAway, reason: nil)
                }
                connections.removeValue(forKey: url)
                subscriptions.removeValue(forKey: url)
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
        for url in urls {
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
        // Allow immediate re-subscription by clearing coalescer timestamp
        subscribeCoalesce.removeValue(forKey: id)
        
        let req = NostrRequest.close(id: id)
        let message = try? encoder.encode(req)
        
        guard let messageData = message,
              let messageString = String(data: messageData, encoding: .utf8) else { return }
        
        // Send unsubscribe to all relays
        for (relayUrl, connection) in connections {
            if subscriptions[relayUrl]?.contains(id) == true {
                connection.send(.string(messageString)) { _ in
                    Task { @MainActor in
                        self.subscriptions[relayUrl]?.remove(id)
                    }
                }
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func connectToRelay(_ urlString: String) {
        // Global network policy gate
        guard networkService.activationAllowed else { return }
        guard let url = URL(string: urlString) else { 
            SecureLogger.warning("Invalid relay URL: \(urlString)", category: .session)
            return 
        }

        // Avoid initiating connections while app is backgrounded; we'll reconnect on foreground
        if shouldUseTor && TorManager.shared.torEnforced && !TorManager.shared.isForeground() {
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
        if shouldUseTor && TorManager.shared.torEnforced && !TorManager.shared.isReady {
            Task.detached { [weak self] in
                guard let self = self else { return }
                let ready = await TorManager.shared.awaitReady()
                await MainActor.run {
                    if ready { self.connectToRelay(urlString) }
                    else { SecureLogger.error("❌ Tor not ready; skipping connection to \(urlString)", category: .session) }
                }
            }
            return
        }
        
        let session = TorURLSession.shared.session
        let task = session.webSocketTask(with: url)
        
        connections[urlString] = task
        task.resume()
        
        // Start receiving messages
        receiveMessage(from: task, relayUrl: urlString)
        
        // Send initial ping to verify connection
        task.sendPing { [weak self] error in
            DispatchQueue.main.async {
                if error == nil {
                    SecureLogger.debug("✅ Connected to Nostr relay: \(urlString)", category: .session)
                    self?.updateRelayStatus(urlString, isConnected: true)
                    // Flush any pending subscriptions for this relay
                    self?.flushPendingSubscriptions(for: urlString)
                } else {
                    SecureLogger.error("❌ Failed to connect to Nostr relay \(urlString): \(error?.localizedDescription ?? "Unknown error")", category: .session)
                    self?.updateRelayStatus(urlString, isConnected: false, error: error)
                    // Trigger disconnection handler for proper backoff
                    self?.handleDisconnection(relayUrl: urlString, error: error ?? NSError(domain: "NostrRelay", code: -1, userInfo: nil))
                }
            }
        }
    }

    /// Send any queued subscriptions for a relay that just connected.
    private func flushPendingSubscriptions(for relayUrl: String) {
        guard let map = pendingSubscriptions[relayUrl], !map.isEmpty else { return }
        guard let connection = connections[relayUrl] else { return }
        for (id, messageString) in map {
            if self.subscriptions[relayUrl]?.contains(id) == true { continue }
            connection.send(.string(messageString)) { error in
                if let error = error {
                    SecureLogger.error("❌ Failed to send pending subscription to \(relayUrl): \(error)", category: .session)
                } else {
                    Task { @MainActor in
                        var subs = self.subscriptions[relayUrl] ?? Set<String>()
                        subs.insert(id)
                        self.subscriptions[relayUrl] = subs
                    }
                }
            }
        }
        pendingSubscriptions[relayUrl] = nil
    }
    
    private func receiveMessage(from task: URLSessionWebSocketTask, relayUrl: String) {
        task.receive { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(let message):
                // Parse off-main to reduce UI jank, then hop back for state updates
                Task.detached(priority: .utility) {
                    guard let parsed = ParsedInbound(message) else { return }
                    await MainActor.run {
                        NostrRelayManager.shared.handleParsedMessage(parsed, from: relayUrl)
                    }
                }
                
                // Continue receiving
                Task { @MainActor in
                    self.receiveMessage(from: task, relayUrl: relayUrl)
                }
                
            case .failure(let error):
                DispatchQueue.main.async {
                    self.handleDisconnection(relayUrl: relayUrl, error: error)
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
            if event.kind != 1059 {
                SecureLogger.debug("📥 Event kind=\(event.kind) id=\(event.id.prefix(16))… relay=\(relayUrl)", category: .session)
            }
            if let index = self.relays.firstIndex(where: { $0.url == relayUrl }) {
                self.relays[index].messagesReceived += 1
            }
            if let handler = self.messageHandlers[subId] {
                handler(event)
            } else {
                SecureLogger.warning("⚠️ No handler for subscription \(subId)", category: .session)
            }
        case .eose(let subId):
            if var tracker = eoseTrackers[subId] {
                tracker.pendingRelays.remove(relayUrl)
                if tracker.pendingRelays.isEmpty {
                    tracker.timer?.invalidate()
                    eoseTrackers.removeValue(forKey: subId)
                    tracker.callback()
                } else {
                    eoseTrackers[subId] = tracker
                }
            }
        case .ok(let eventId, let success, let reason):
            if success {
                _ = Self.pendingGiftWrapIDs.remove(eventId)
                SecureLogger.debug("✅ Accepted id=\(eventId.prefix(16))… relay=\(relayUrl)", category: .session)
            } else {
                let isGiftWrap = Self.pendingGiftWrapIDs.remove(eventId) != nil
                if isGiftWrap {
                    SecureLogger.warning("📮 Rejected id=\(eventId.prefix(16))… reason=\(reason)", category: .session)
                } else {
                    SecureLogger.error("📮 Rejected id=\(eventId.prefix(16))… reason=\(reason)", category: .session)
                }
            }
        case .notice:
            break
        }
    }
    
    private func sendToRelay(event: NostrEvent, connection: URLSessionWebSocketTask, relayUrl: String) {
        let req = NostrRequest.event(event)
        
        do {
            let data = try encoder.encode(req)
            let message = String(data: data, encoding: .utf8) ?? ""
            
            SecureLogger.debug("📤 Send kind=\(event.kind) id=\(event.id.prefix(16))… relay=\(relayUrl)", category: .session)
            
            connection.send(.string(message)) { [weak self] error in
                DispatchQueue.main.async {
                    if let error = error {
                        SecureLogger.error("❌ Failed to send event to \(relayUrl): \(error)", category: .session)
                    } else {
                        // SecureLogger.debug("✅ Event sent to relay: \(relayUrl)", category: .session)
                        // Update relay stats
                        if let index = self?.relays.firstIndex(where: { $0.url == relayUrl }) {
                            self?.relays[index].messagesSent += 1
                        }
                    }
                }
            }
        } catch {
            SecureLogger.error("Failed to encode event: \(error)", category: .session)
        }
    }
    
    private func updateRelayStatus(_ url: String, isConnected: Bool, error: Error? = nil) {
        if let index = relays.firstIndex(where: { $0.url == url }) {
            relays[index].isConnected = isConnected
            relays[index].lastError = error
            if isConnected {
                relays[index].lastConnectedAt = Date()
                relays[index].reconnectAttempts = 0  // Reset on successful connection
                relays[index].nextReconnectTime = nil
            } else {
                relays[index].lastDisconnectedAt = Date()
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
    }
    
    private func handleDisconnection(relayUrl: String, error: Error) {
        // If networking is disallowed, do not schedule reconnection
        if !networkService.activationAllowed {
            connections.removeValue(forKey: relayUrl)
            subscriptions.removeValue(forKey: relayUrl)
            updateRelayStatus(relayUrl, isConnected: false, error: error)
            return
        }
        connections.removeValue(forKey: relayUrl)
        subscriptions.removeValue(forKey: relayUrl)
        updateRelayStatus(relayUrl, isConnected: false, error: error)
        
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
        
        // Calculate backoff interval
        let backoffInterval = min(
            initialBackoffInterval * pow(backoffMultiplier, Double(relays[index].reconnectAttempts - 1)),
            maxBackoffInterval
        )
        
        let nextReconnectTime = Date().addingTimeInterval(backoffInterval)
        relays[index].nextReconnectTime = nextReconnectTime
        
        
        // Schedule reconnection with exponential backoff
        let gen = connectionGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + backoffInterval) { [weak self] in
            guard let self = self else { return }
            // Ignore stale scheduled reconnects from a previous generation
            guard gen == self.connectionGeneration else { return }
            // Check if we should still reconnect (relay might have been removed)
            if self.relays.contains(where: { $0.url == relayUrl }) {
                self.connectToRelay(relayUrl)
            }
        }
    }
    
    // MARK: - Public Utility Methods
    
    /// Manually retry connection to a specific relay
    func retryConnection(to relayUrl: String) {
        guard let index = relays.firstIndex(where: { $0.url == relayUrl }) else { return }
        
        // Reset reconnection attempts
        relays[index].reconnectAttempts = 0
        relays[index].nextReconnectTime = nil
        
        // Disconnect if connected
        if let connection = connections[relayUrl] {
            connection.cancel(with: .goingAway, reason: nil)
            connections.removeValue(forKey: relayUrl)
        }
        
        // Attempt immediate reconnection
        connectToRelay(relayUrl)
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
               let event = try? NostrEvent(from: eventDict),
               event.isValidSignature() {
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
