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
    }
    
    // Default relay list (can be customized)
    private static let defaultRelays = [
        "wss://relay.damus.io",
        "wss://nos.lol",
        "wss://relay.primal.net",
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
        let message = try? JSONEncoder().encode(req)
        
        guard let messageData = message,
              let messageString = String(data: messageData, encoding: .utf8) else { return }
        
        // Send subscription to all connected relays
        for (relayUrl, connection) in connections {
            connection.send(.string(messageString)) { error in
                if error == nil {
                    Task { @MainActor in
                        var subs = self.subscriptions[relayUrl] ?? Set<String>()
                        subs.insert(id)
                        self.subscriptions[relayUrl] = subs
                    }
                }
            }
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
        
        SecureLogger.log("Attempting to connect to Nostr relay: \(urlString)", category: SecureLogger.session, level: .info)
        
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
                    SecureLogger.log("Successfully connected to Nostr relay: \(urlString)", category: SecureLogger.session, level: .info)
                    self?.updateRelayStatus(urlString, isConnected: true)
                } else {
                    SecureLogger.log("Failed to connect to Nostr relay \(urlString): \(error?.localizedDescription ?? "Unknown error")", category: SecureLogger.session, level: .error)
                    self?.updateRelayStatus(urlString, isConnected: false, error: error)
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
            // Try to decode as an event first
            if let array = try JSONSerialization.jsonObject(with: data) as? [Any],
               array.count >= 3,
               let type = array[0] as? String,
               type == "EVENT",
               let subId = array[1] as? String,
               let eventDict = array[2] as? [String: Any] {
                
                let event = try NostrEvent(from: eventDict)
                
                DispatchQueue.main.async {
                    // Update relay stats
                    if let index = self.relays.firstIndex(where: { $0.url == relayUrl }) {
                        self.relays[index].messagesReceived += 1
                    }
                    
                    // Call handler
                    if let handler = self.messageHandlers[subId] {
                        handler(event)
                    }
                }
            }
        } catch {
            SecureLogger.log("Failed to parse Nostr message: \(error)", category: SecureLogger.session, level: .error)
        }
    }
    
    private func sendToRelay(event: NostrEvent, connection: URLSessionWebSocketTask, relayUrl: String) {
        let req = NostrRequest.event(event)
        
        do {
            let data = try JSONEncoder().encode(req)
            let message = String(data: data, encoding: .utf8) ?? ""
            
            connection.send(.string(message)) { [weak self] error in
                DispatchQueue.main.async {
                    if error == nil {
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
        
        // Attempt reconnection after delay for non-DNS errors
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.connectToRelay(relayUrl)
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
    var tags: [String: [String]]?
    
    // For NIP-17 gift wraps
    static func giftWrapsFor(pubkey: String, since: Date? = nil) -> NostrFilter {
        return NostrFilter(
            kinds: [1059], // Gift wrap kind
            since: since?.timeIntervalSince1970.toInt(),
            tags: ["p": [pubkey]]
        )
    }
}

private extension TimeInterval {
    func toInt() -> Int {
        return Int(self)
    }
}
