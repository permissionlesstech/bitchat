import BitLogger
import Foundation
import Network
import Combine

public protocol NostrRelayConnectionProtocol: AnyObject {
    func resume()
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping (Error?) -> Void)
    func receive(completionHandler: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void)
    func sendPing(pongReceiveHandler: @escaping (Error?) -> Void)
}

public protocol NostrRelaySessionProtocol {
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

public enum LocationPermissionState: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
}

public struct NostrRelayManagerDependencies {
    public var activationAllowed: () -> Bool
    public var userTorEnabled: () -> Bool
    public var hasMutualFavorites: () -> Bool
    public var hasLocationPermission: () -> Bool
    public var mutualFavoritesPublisher: AnyPublisher<Set<Data>, Never>
    public var locationPermissionPublisher: AnyPublisher<LocationPermissionState, Never>
    public var torEnforced: () -> Bool
    public var torIsReady: () -> Bool
    public var torIsForeground: () -> Bool
    public var awaitTorReady: (@escaping (Bool) -> Void) -> Void
    public var makeSession: () -> NostrRelaySessionProtocol
    public var scheduleAfter: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void
    public var now: () -> Date

    public init(
        activationAllowed: @escaping () -> Bool,
        userTorEnabled: @escaping () -> Bool,
        hasMutualFavorites: @escaping () -> Bool,
        hasLocationPermission: @escaping () -> Bool,
        mutualFavoritesPublisher: AnyPublisher<Set<Data>, Never>,
        locationPermissionPublisher: AnyPublisher<LocationPermissionState, Never>,
        torEnforced: @escaping () -> Bool,
        torIsReady: @escaping () -> Bool,
        torIsForeground: @escaping () -> Bool,
        awaitTorReady: @escaping (@escaping (Bool) -> Void) -> Void,
        makeSession: @escaping () -> NostrRelaySessionProtocol,
        scheduleAfter: @Sendable @escaping (TimeInterval, @escaping @Sendable () -> Void) -> Void,
        now: @escaping () -> Date
    ) {
        self.activationAllowed = activationAllowed
        self.userTorEnabled = userTorEnabled
        self.hasMutualFavorites = hasMutualFavorites
        self.hasLocationPermission = hasLocationPermission
        self.mutualFavoritesPublisher = mutualFavoritesPublisher
        self.locationPermissionPublisher = locationPermissionPublisher
        self.torEnforced = torEnforced
        self.torIsReady = torIsReady
        self.torIsForeground = torIsForeground
        self.awaitTorReady = awaitTorReady
        self.makeSession = makeSession
        self.scheduleAfter = scheduleAfter
        self.now = now
    }
}

/// Manages WebSocket connections to Nostr relays
@MainActor
public final class NostrRelayManager: ObservableObject {
    nonisolated(unsafe) public static var shared: NostrRelayManager!

    public static func setupShared(dependencies: NostrRelayManagerDependencies) {
        shared = NostrRelayManager(dependencies: dependencies)
    }

    /// Wraps a URLSession into a NostrRelaySessionProtocol for use in live dependencies.
    public static func makeURLSession(_ session: URLSession) -> NostrRelaySessionProtocol {
        URLSessionAdapter(base: session)
    }

    // Track gift-wraps (kind 1059) we initiated so we can log OK acks at info
    private(set) public static var pendingGiftWrapIDs = Set<String>()
    public static func registerPendingGiftWrap(id: String) {
        pendingGiftWrapIDs.insert(id)
    }

    public struct Relay: Identifiable {
        public let id = UUID()
        public let url: String
        public var isConnected: Bool = false
        public var lastError: Error?
        public var lastConnectedAt: Date?
        public var messagesSent: Int = 0
        public var messagesReceived: Int = 0
        public var reconnectAttempts: Int = 0
        public var lastDisconnectedAt: Date?
        public var nextReconnectTime: Date?
    }

    // Default relay list (can be customized)
    private static let defaultRelays = [
        "wss://relay.damus.io",
        "wss://nos.lol",
        "wss://relay.primal.net",
        "wss://offchain.pub",
        "wss://nostr21.com"
    ]
    private static let defaultRelaySet = Set(defaultRelays)

    @Published private(set) public var relays: [Relay] = []
    @Published private(set) public var isConnected = false

    private let dependencies: NostrRelayManagerDependencies
    private var allowDefaultRelays: Bool = false
    private var hasMutualFavorites: Bool = false
    private var hasLocationPermission: Bool = false
    private var connections: [String: NostrRelayConnectionProtocol] = [:]
    private var subscriptions: [String: Set<String>] = [:]
    private var pendingSubscriptions: [String: [String: String]] = [:]
    private var messageHandlers: [String: (NostrEvent) -> Void] = [:]
    private var subscribeCoalesce: [String: Date] = [:]
    private var cancellables = Set<AnyCancellable>()

    private struct EOSETracker {
        var pendingRelays: Set<String>
        var callback: () -> Void
        var timer: Timer?
    }
    private var eoseTrackers: [String: EOSETracker] = [:]

    private struct PendingSend {
        var event: NostrEvent
        var pendingRelays: Set<String>
    }
    private var messageQueue: [PendingSend] = []
    private let messageQueueLock = NSLock()
    private let encoder = JSONEncoder()
    private var shouldUseTor: Bool { dependencies.userTorEnabled() }

    // Exponential backoff configuration (matches TransportConfig values)
    private let initialBackoffInterval: TimeInterval = 1.0
    private let maxBackoffInterval: TimeInterval = 300.0
    private let backoffMultiplier: Double = 2.0
    private let maxReconnectAttempts = 10

    private var connectionGeneration: Int = 0

    public init(dependencies: NostrRelayManagerDependencies) {
        self.dependencies = dependencies
        hasMutualFavorites = dependencies.hasMutualFavorites()
        hasLocationPermission = dependencies.hasLocationPermission()
        applyDefaultRelayPolicy(force: true)
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
    public func connect() {
        guard dependencies.activationAllowed() else { return }
        if shouldUseTor {
            dependencies.awaitTorReady { [weak self] ready in
                guard let self = self else { return }
                if !ready {
                    SecureLogger.error("❌ Tor not ready; aborting relay connections (fail-closed)", category: .session)
                    return
                }
                SecureLogger.debug("🌐 Connecting to \(self.relays.count) Nostr relays (via Tor)", category: .session)
                for relay in self.relays {
                    self.connectToRelay(relay.url)
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
    public func disconnect() {
        connectionGeneration &+= 1

        for (_, task) in connections {
            task.cancel(with: .goingAway, reason: nil)
        }
        connections.removeAll()
        subscriptions.removeAll()
        pendingSubscriptions.removeAll()
        updateConnectionStatus()
    }

    /// Ensure connections exist to the given relay URLs (idempotent).
    public func ensureConnections(to relayUrls: [String]) {
        guard dependencies.activationAllowed() else { return }
        let targets = allowedRelayList(from: relayUrls)
        guard !targets.isEmpty else { return }
        if shouldUseTor && dependencies.torEnforced() && !dependencies.torIsReady() {
            dependencies.awaitTorReady { [weak self] ready in
                guard let self = self else { return }
                if ready { self.ensureConnections(to: relayUrls) }
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
    public func sendEvent(_ event: NostrEvent, to relayUrls: [String]? = nil) {
        guard dependencies.activationAllowed() else { return }
        if shouldUseTor && dependencies.torEnforced() && !dependencies.torIsReady() {
            dependencies.awaitTorReady { [weak self] ready in
                guard let self = self else { return }
                if ready { self.sendEvent(event, to: relayUrls) }
            }
            return
        }
        let requestedRelays = relayUrls ?? Self.defaultRelays
        let targetRelays = allowedRelayList(from: requestedRelays)
        guard !targetRelays.isEmpty else { return }
        ensureConnections(to: targetRelays)

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

    private func flushMessageQueue(for relayUrl: String? = nil) {
        messageQueueLock.lock()
        defer { messageQueueLock.unlock() }
        guard !messageQueue.isEmpty else { return }
        if let target = relayUrl {
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
    public func subscribe(
        filter: NostrFilter,
        id: String = UUID().uuidString,
        relayUrls: [String]? = nil,
        handler: @escaping (NostrEvent) -> Void,
        onEOSE: (() -> Void)? = nil
    ) {
        guard dependencies.activationAllowed() else { return }
        let now = dependencies.now()
        if messageHandlers[id] != nil {
            if let last = subscribeCoalesce[id], now.timeIntervalSince(last) < 1.0 {
                return
            }
        }
        subscribeCoalesce[id] = now
        if shouldUseTor && dependencies.torEnforced() && !dependencies.torIsReady() {
            dependencies.awaitTorReady { [weak self] ready in
                guard let self = self else { return }
                if ready {
                    self.subscribe(filter: filter, id: id, relayUrls: relayUrls, handler: handler, onEOSE: onEOSE)
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

            let baseUrls = relayUrls ?? Self.defaultRelays
            let candidateUrls = baseUrls.filter { !isPermanentlyFailed($0) }
            let urls = allowedRelayList(from: candidateUrls)
            let existingSet = Set(relays.map { $0.url })
            for url in urls where !existingSet.contains(url) {
                relays.append(Relay(url: url))
            }
            for url in urls {
                var map = self.pendingSubscriptions[url] ?? [:]
                map[id] = messageString
                self.pendingSubscriptions[url] = map
            }
            if let onEOSE = onEOSE {
                if urls.isEmpty {
                    onEOSE()
                } else {
                    var tracker = EOSETracker(pendingRelays: Set(urls), callback: onEOSE, timer: nil)
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
            ensureConnections(to: urls)
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
        for url in urls {
            if !allowDefaultRelays && Self.defaultRelaySet.contains(url) { continue }
            if seen.insert(url).inserted {
                result.append(url)
            }
        }
        return result
    }

    /// Unsubscribe from a subscription
    public func unsubscribe(id: String) {
        messageHandlers.removeValue(forKey: id)
        subscribeCoalesce.removeValue(forKey: id)

        let req = NostrRequest.close(id: id)
        let message = try? encoder.encode(req)

        guard let messageData = message,
              let messageString = String(data: messageData, encoding: .utf8) else { return }

        for (relayUrl, connection) in connections {
            if subscriptions[relayUrl]?.contains(id) == true {
                subscriptions[relayUrl]?.remove(id)
                connection.send(.string(messageString)) { _ in }
            }
        }
    }

    // MARK: - Private Methods

    private func connectToRelay(_ urlString: String) {
        guard dependencies.activationAllowed() else { return }
        guard let url = URL(string: urlString) else {
            SecureLogger.warning("Invalid relay URL: \(urlString)", category: .session)
            return
        }

        if shouldUseTor && dependencies.torEnforced() && !dependencies.torIsForeground() {
            return
        }

        if connections[urlString] != nil {
            return
        }
        if isPermanentlyFailed(urlString) {
            return
        }

        if shouldUseTor && dependencies.torEnforced() && !dependencies.torIsReady() {
            dependencies.awaitTorReady { [weak self] ready in
                guard let self = self else { return }
                if ready { self.connectToRelay(urlString) }
                else { SecureLogger.error("❌ Tor not ready; skipping connection to \(urlString)", category: .session) }
            }
            return
        }

        let session = dependencies.makeSession()
        let task = session.webSocketTask(with: url)

        connections[urlString] = task
        task.resume()

        receiveMessage(from: task, relayUrl: urlString)

        task.sendPing { [weak self] error in
            DispatchQueue.main.async {
                if error == nil {
                    SecureLogger.debug("✅ Connected to Nostr relay: \(urlString)", category: .session)
                    self?.updateRelayStatus(urlString, isConnected: true)
                    self?.flushPendingSubscriptions(for: urlString)
                } else {
                    SecureLogger.error("❌ Failed to connect to Nostr relay \(urlString): \(error?.localizedDescription ?? "Unknown error")", category: .session)
                    self?.updateRelayStatus(urlString, isConnected: false, error: error)
                    self?.handleDisconnection(relayUrl: urlString, error: error ?? NSError(domain: "NostrRelay", code: -1, userInfo: nil))
                }
            }
        }
    }

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

    private func receiveMessage(from task: NostrRelayConnectionProtocol, relayUrl: String) {
        task.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let message):
                Task.detached(priority: .utility) {
                    guard let parsed = ParsedInbound(message) else { return }
                    await MainActor.run {
                        self.handleParsedMessage(parsed, from: relayUrl)
                    }
                }

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

    private func sendToRelay(event: NostrEvent, connection: NostrRelayConnectionProtocol, relayUrl: String) {
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
                relays[index].lastConnectedAt = dependencies.now()
                relays[index].reconnectAttempts = 0
                relays[index].nextReconnectTime = nil
            } else {
                relays[index].lastDisconnectedAt = dependencies.now()
            }
        }
        updateConnectionStatus()
        if isConnected {
            flushMessageQueue(for: url)
        }
    }

    private func updateConnectionStatus() {
        isConnected = relays.contains { $0.isConnected }
    }

    private func handleDisconnection(relayUrl: String, error: Error) {
        if !dependencies.activationAllowed() {
            connections.removeValue(forKey: relayUrl)
            subscriptions.removeValue(forKey: relayUrl)
            updateRelayStatus(relayUrl, isConnected: false, error: error)
            return
        }
        connections.removeValue(forKey: relayUrl)
        subscriptions.removeValue(forKey: relayUrl)
        updateRelayStatus(relayUrl, isConnected: false, error: error)

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

        guard let index = relays.firstIndex(where: { $0.url == relayUrl }) else { return }

        relays[index].reconnectAttempts += 1

        if relays[index].reconnectAttempts >= maxReconnectAttempts {
            SecureLogger.warning("Max reconnection attempts (\(maxReconnectAttempts)) reached for \(relayUrl)", category: .session)
            return
        }

        let backoffInterval = min(
            initialBackoffInterval * pow(backoffMultiplier, Double(relays[index].reconnectAttempts - 1)),
            maxBackoffInterval
        )

        let nextReconnectTime = dependencies.now().addingTimeInterval(backoffInterval)
        relays[index].nextReconnectTime = nextReconnectTime

        let gen = connectionGeneration
        dependencies.scheduleAfter(backoffInterval) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard gen == self.connectionGeneration else { return }
                if self.relays.contains(where: { $0.url == relayUrl }) {
                    self.connectToRelay(relayUrl)
                }
            }
        }
    }

    // MARK: - Public Utility Methods

    public func retryConnection(to relayUrl: String) {
        guard let index = relays.firstIndex(where: { $0.url == relayUrl }) else { return }

        relays[index].reconnectAttempts = 0
        relays[index].nextReconnectTime = nil
        relays[index].lastError = nil

        if let connection = connections[relayUrl] {
            connection.cancel(with: .goingAway, reason: nil)
            connections.removeValue(forKey: relayUrl)
        }

        connectToRelay(relayUrl)
    }

    public func getRelayStatuses() -> [(url: String, isConnected: Bool, reconnectAttempts: Int, nextReconnectTime: Date?)] {
        return relays.map { relay in
            (url: relay.url,
             isConnected: relay.isConnected,
             reconnectAttempts: relay.reconnectAttempts,
             nextReconnectTime: relay.nextReconnectTime)
        }
    }

    public var debugPendingMessageQueueCount: Int {
        messageQueueLock.lock()
        defer { messageQueueLock.unlock() }
        return messageQueue.count
    }

    public func debugPendingSubscriptionCount(for relayUrl: String) -> Int {
        pendingSubscriptions[relayUrl]?.count ?? 0
    }

    public func debugFlushMessageQueue() {
        flushMessageQueue(for: nil)
    }

    /// Reset all relay connections
    public func resetAllConnections() {
        disconnect()
        connectionGeneration &+= 1

        for index in relays.indices {
            relays[index].reconnectAttempts = 0
            relays[index].nextReconnectTime = nil
            relays[index].lastError = nil
        }

        connect()
    }

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

public enum NostrRequest: Encodable {
    case event(NostrEvent)
    case subscribe(id: String, filters: [NostrFilter])
    case close(id: String)

    public func encode(to encoder: Encoder) throws {
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

public struct NostrFilter: Encodable {
    public var ids: [String]?
    public var authors: [String]?
    public var kinds: [Int]?
    public var since: Int?
    public var until: Int?
    public var limit: Int?

    fileprivate var tagFilters: [String: [String]]?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case ids, authors, kinds, since, until, limit
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)

        if let ids = ids { try container.encode(ids, forKey: DynamicCodingKey(stringValue: "ids")) }
        if let authors = authors { try container.encode(authors, forKey: DynamicCodingKey(stringValue: "authors")) }
        if let kinds = kinds { try container.encode(kinds, forKey: DynamicCodingKey(stringValue: "kinds")) }
        if let since = since { try container.encode(since, forKey: DynamicCodingKey(stringValue: "since")) }
        if let until = until { try container.encode(until, forKey: DynamicCodingKey(stringValue: "until")) }
        if let limit = limit { try container.encode(limit, forKey: DynamicCodingKey(stringValue: "limit")) }

        if let tagFilters = tagFilters {
            for (tag, values) in tagFilters {
                try container.encode(values, forKey: DynamicCodingKey(stringValue: "#\(tag)"))
            }
        }
    }

    // For NIP-17 gift wraps (limit matches TransportConfig.nostrRelayDefaultFetchLimit)
    public static func giftWrapsFor(pubkey: String, since: Date? = nil) -> NostrFilter {
        var filter = NostrFilter()
        filter.kinds = [1059]
        filter.since = since?.timeIntervalSince1970.toInt()
        filter.tagFilters = ["p": [pubkey]]
        filter.limit = 100
        return filter
    }

    // For location channels: geohash-scoped ephemeral events (kind 20000) and presence (kind 20001)
    public static func geohashEphemeral(_ geohash: String, since: Date? = nil, limit: Int = 1000) -> NostrFilter {
        var filter = NostrFilter()
        filter.kinds = [20000, 20001]
        filter.since = since?.timeIntervalSince1970.toInt()
        filter.tagFilters = ["g": [geohash]]
        filter.limit = limit
        return filter
    }

    // For location notes: persistent text notes (kind 1) tagged with geohash
    public static func geohashNotes(_ geohash: String, since: Date? = nil, limit: Int = 200) -> NostrFilter {
        var filter = NostrFilter()
        filter.kinds = [1]
        filter.since = since?.timeIntervalSince1970.toInt()
        filter.tagFilters = ["g": [geohash]]
        filter.limit = limit
        return filter
    }

    // For location notes with neighbors: subscribe to multiple geohashes (center + neighbors)
    public static func geohashNotes(_ geohashes: [String], since: Date? = nil, limit: Int = 200) -> NostrFilter {
        var filter = NostrFilter()
        filter.kinds = [1]
        filter.since = since?.timeIntervalSince1970.toInt()
        filter.tagFilters = ["g": geohashes]
        filter.limit = limit
        return filter
    }
}

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
