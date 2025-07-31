import Foundation
import Network
import Combine

/// Manages WebSocket connections to Nostr relays
@MainActor
class NostrRelayManager: ObservableObject {
    static let shared = NostrRelayManager()
    
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
        "wss://relay.primal.net",
        "wss://offchain.pub",
        "wss://nostr21.com"
        // For local testing, you can add: "ws://localhost:8080"
    ]
    
    @Published private(set) var relays: [Relay] = []
    @Published private(set) var isConnected = false
    
    private var connections: [String: URLSessionWebSocketTask] = [:]
    private var subscriptions: [String: Set<String>] = [:] // relay URL -> subscription IDs
    private var messageHandlers: [String: (NostrEvent) -> Void] = [:]
    private var cancellables = Set<AnyCancellable>()
    
    // Message queue for reliability
    private var messageQueue: [(event: NostrEvent, relayUrls: [String])] = []
    private let messageQueueLock = NSLock()
    
    // Exponential backoff configuration
    private let initialBackoffInterval: TimeInterval = 1.0  // Start with 1 second
    private let maxBackoffInterval: TimeInterval = 300.0    // Max 5 minutes
    private let backoffMultiplier: Double = 2.0            // Double each time
    private let maxReconnectAttempts = 10                  // Stop after 10 attempts
    
    // Reconnection timer
    private var reconnectionTimer: Timer?
    
    init() {
        // Initialize with default relays
        self.relays = Self.defaultRelays.map { Relay(url: $0) }
    }
    
    /// Connect to all configured relays
    func connect() {
        for relay in relays {
            connectToRelay(relay.url)
        }
    }
    
    /// Disconnect from all relays
    func disconnect() {
        for (_, task) in connections {
            task.cancel(with: .goingAway, reason: nil)
        }
        connections.removeAll()
        updateConnectionStatus()
    }
    
    /// Send an event to specified relays (or all if none specified)
    func sendEvent(_ event: NostrEvent, to relayUrls: [String]? = nil) {
        let targetRelays = relayUrls ?? relays.map { $0.url }
        
        // Add to queue for reliability
        messageQueueLock.lock()
        messageQueue.append((event, targetRelays))
        messageQueueLock.unlock()
        
        // Attempt immediate send
        for relayUrl in targetRelays {
            if let connection = connections[relayUrl] {
                sendToRelay(event: event, connection: connection, relayUrl: relayUrl)
            }
        }
    }
    
    /// Subscribe to events matching a filter
    func subscribe(
        filter: NostrFilter,
        id: String = UUID().uuidString,
        handler: @escaping (NostrEvent) -> Void
    ) {
        messageHandlers[id] = handler
        
        let req = NostrRequest.subscribe(id: id, filters: [filter])
        
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys // For consistent output
            let message = try encoder.encode(req)
            guard let messageString = String(data: message, encoding: .utf8) else { 
                SecureLogger.log("❌ Failed to encode subscription request", category: SecureLogger.session, level: .error)
                return 
            }
            
            // Sending subscription to relays
            // Filter JSON prepared
            // Full filter JSON logged
            
            // Send subscription to all connected relays
            for (relayUrl, connection) in connections {
                connection.send(.string(messageString)) { error in
                    if let error = error {
                        SecureLogger.log("❌ Failed to send subscription to \(relayUrl): \(error)", 
                                        category: SecureLogger.session, level: .error)
                    } else {
                        // Subscription sent successfully
                        Task { @MainActor in
                            var subs = self.subscriptions[relayUrl] ?? Set<String>()
                            subs.insert(id)
                            self.subscriptions[relayUrl] = subs
                        }
                    }
                }
            }
            
            if connections.isEmpty {
                SecureLogger.log("⚠️ No relay connections available for subscription", 
                                category: SecureLogger.session, level: .warning)
            }
        } catch {
            SecureLogger.log("❌ Failed to encode subscription request: \(error)", 
                            category: SecureLogger.session, level: .error)
        }
    }
    
    /// Unsubscribe from a subscription
    func unsubscribe(id: String) {
        messageHandlers.removeValue(forKey: id)
        
        let req = NostrRequest.close(id: id)
        let message = try? JSONEncoder().encode(req)
        
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
        guard let url = URL(string: urlString) else { 
            SecureLogger.log("Invalid relay URL: \(urlString)", category: SecureLogger.session, level: .warning)
            return 
        }
        
        // Skip if we already have a connection object
        if connections[urlString] != nil {
            return
        }
        
        // Attempting to connect to Nostr relay
        
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        
        connections[urlString] = task
        task.resume()
        
        // Start receiving messages
        receiveMessage(from: task, relayUrl: urlString)
        
        // Send initial ping to verify connection
        task.sendPing { [weak self] error in
            DispatchQueue.main.async {
                if error == nil {
                    // Successfully connected to Nostr relay
                    self?.updateRelayStatus(urlString, isConnected: true)
                    SecureLogger.log("Successfully connected to Nostr relay \(urlString)", 
                                   category: SecureLogger.session, level: .info)
                } else {
                    SecureLogger.log("Failed to connect to Nostr relay \(urlString): \(error?.localizedDescription ?? "Unknown error")", 
                                   category: SecureLogger.session, level: .error)
                    self?.updateRelayStatus(urlString, isConnected: false, error: error)
                    // Trigger disconnection handler for proper backoff
                    self?.handleDisconnection(relayUrl: urlString, error: error ?? NSError(domain: "NostrRelay", code: -1, userInfo: nil))
                }
            }
        }
    }
    
    private func receiveMessage(from task: URLSessionWebSocketTask, relayUrl: String) {
        task.receive { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    Task { @MainActor in
                        self.handleMessage(text, from: relayUrl)
                    }
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        Task { @MainActor in
                        self.handleMessage(text, from: relayUrl)
                    }
                    }
                @unknown default:
                    break
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
    
    private func handleMessage(_ message: String, from relayUrl: String) {
        guard let data = message.data(using: .utf8) else { return }
        
        do {
            // Try to decode as an array first
            if let array = try JSONSerialization.jsonObject(with: data) as? [Any],
               array.count >= 2,
               let type = array[0] as? String {
                
                // Received message from relay
                
                switch type {
                case "EVENT":
                    if array.count >= 3,
                       let subId = array[1] as? String,
                       let eventDict = array[2] as? [String: Any] {
                        
                        let event = try NostrEvent(from: eventDict)
                        
                        // Processing event
                        
                        DispatchQueue.main.async {
                            // Update relay stats
                            if let index = self.relays.firstIndex(where: { $0.url == relayUrl }) {
                                self.relays[index].messagesReceived += 1
                            }
                            
                            // Call handler
                            if let handler = self.messageHandlers[subId] {
                                handler(event)
                            } else {
                                SecureLogger.log("⚠️ No handler for subscription \(subId)", 
                                                category: SecureLogger.session, level: .warning)
                            }
                        }
                    }
                    
                case "EOSE":
                    if array.count >= 2,
                       let _ = array[1] as? String {
                        // End of stored events
                    }
                    
                case "OK":
                    if array.count >= 3,
                       let eventId = array[1] as? String,
                       let success = array[2] as? Bool {
                        let reason = array.count >= 4 ? (array[3] as? String ?? "no reason given") : "no reason given"
                        if !success {
                            SecureLogger.log("📮 Event \(eventId) rejected by relay: \(reason)", 
                                            category: SecureLogger.session, level: .error)
                        }
                    }
                    
                case "NOTICE":
                    if array.count >= 2,
                       let notice = array[1] as? String {
                        SecureLogger.log("📢 Relay notice: \(notice)", 
                                        category: SecureLogger.session, level: .info)
                    }
                    
                default:
                    break // Unknown message type
                }
            }
        } catch {
            SecureLogger.log("Failed to parse Nostr message: \(error)", category: SecureLogger.session, level: .error)
        }
    }
    
    private func sendToRelay(event: NostrEvent, connection: URLSessionWebSocketTask, relayUrl: String) {
        let req = NostrRequest.event(event)
        
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let data = try encoder.encode(req)
            let message = String(data: data, encoding: .utf8) ?? ""
            
            // Sending event to relay
            // Event JSON prepared
            
            connection.send(.string(message)) { [weak self] error in
                DispatchQueue.main.async {
                    if let error = error {
                        SecureLogger.log("❌ Failed to send event to \(relayUrl): \(error)", 
                                        category: SecureLogger.session, level: .error)
                    } else {
                        // Update relay stats
                        if let index = self?.relays.firstIndex(where: { $0.url == relayUrl }) {
                            self?.relays[index].messagesSent += 1
                        }
                    }
                }
            }
        } catch {
            SecureLogger.log("Failed to encode event: \(error)", category: SecureLogger.session, level: .error)
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
    }
    
    private func updateConnectionStatus() {
        isConnected = relays.contains { $0.isConnected }
    }
    
    private func handleDisconnection(relayUrl: String, error: Error) {
        connections.removeValue(forKey: relayUrl)
        subscriptions.removeValue(forKey: relayUrl)
        updateRelayStatus(relayUrl, isConnected: false, error: error)
        
        // Check if this is a DNS error
        let errorDescription = error.localizedDescription.lowercased()
        if errorDescription.contains("hostname could not be found") || 
           errorDescription.contains("dns") {
            // Only log once for DNS failures
            if relays.first(where: { $0.url == relayUrl })?.lastError == nil {
                SecureLogger.log("Nostr relay DNS failure for \(relayUrl) - not retrying", category: SecureLogger.session, level: .warning)
            }
            // Mark relay as permanently failed
            if let index = relays.firstIndex(where: { $0.url == relayUrl }) {
                relays[index].lastError = error
            }
            return
        }
        
        // Implement exponential backoff for non-DNS errors
        guard let index = relays.firstIndex(where: { $0.url == relayUrl }) else { return }
        
        relays[index].reconnectAttempts += 1
        
        // Stop attempting after max attempts
        if relays[index].reconnectAttempts >= maxReconnectAttempts {
            SecureLogger.log("Max reconnection attempts (\(maxReconnectAttempts)) reached for \(relayUrl)", 
                           category: SecureLogger.session, level: .warning)
            return
        }
        
        // Calculate backoff interval
        let backoffInterval = min(
            initialBackoffInterval * pow(backoffMultiplier, Double(relays[index].reconnectAttempts - 1)),
            maxBackoffInterval
        )
        
        let nextReconnectTime = Date().addingTimeInterval(backoffInterval)
        relays[index].nextReconnectTime = nextReconnectTime
        
        SecureLogger.log("Scheduling reconnection to \(relayUrl) in \(Int(backoffInterval))s (attempt \(relays[index].reconnectAttempts))", 
                       category: SecureLogger.session, level: .info)
        
        // Schedule reconnection with exponential backoff
        DispatchQueue.main.asyncAfter(deadline: .now() + backoffInterval) { [weak self] in
            guard let self = self else { return }
            
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
        
        // Reset all relay states
        for index in relays.indices {
            relays[index].reconnectAttempts = 0
            relays[index].nextReconnectTime = nil
            relays[index].lastError = nil
        }
        
        // Reconnect
        connect()
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
        filter.limit = 100 // Add a reasonable limit
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
