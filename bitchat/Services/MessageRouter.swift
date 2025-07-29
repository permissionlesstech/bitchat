import Foundation
import Combine

/// Routes messages through the appropriate transport (Bluetooth mesh or Nostr)
@MainActor
class MessageRouter: ObservableObject {
    
    enum Transport {
        case bluetoothMesh
        case nostr
    }
    
    enum DeliveryStatus {
        case pending
        case sent
        case delivered
        case failed(Error)
    }
    
    struct RoutedMessage {
        let id: String
        let content: String
        let recipientNoisePublicKey: Data
        let transport: Transport
        let timestamp: Date
        var status: DeliveryStatus
    }
    
    @Published private(set) var pendingMessages: [String: RoutedMessage] = [:]
    
    private let meshService: BluetoothMeshService
    private let nostrRelay: NostrRelayManager
    private let favoritesService: FavoritesPersistenceService
    
    private var cancellables = Set<AnyCancellable>()
    private let messageDeduplication = LRUCache<String, Date>(maxSize: 1000)
    
    init(
        meshService: BluetoothMeshService,
        nostrRelay: NostrRelayManager
    ) {
        self.meshService = meshService
        self.nostrRelay = nostrRelay
        self.favoritesService = FavoritesPersistenceService.shared
        
        setupBindings()
    }
    
    /// Send a message to a peer, automatically selecting the best transport
    func sendMessage(
        _ content: String,
        to recipientNoisePublicKey: Data,
        preferredTransport: Transport? = nil
    ) async throws {
        
        let messageId = UUID().uuidString
        
        // Check if peer is available on mesh
        let recipientHexID = recipientNoisePublicKey.hexEncodedString()
        let peerAvailableOnMesh = meshService.getPeerNicknames()[recipientHexID] != nil
        
        // Check if this is a mutual favorite
        let isMutualFavorite = favoritesService.isMutualFavorite(recipientNoisePublicKey)
        
        // Determine transport
        let transport: Transport
        if let preferred = preferredTransport {
            transport = preferred
        } else if peerAvailableOnMesh {
            // Always prefer mesh when available
            transport = .bluetoothMesh
        } else if isMutualFavorite {
            // Use Nostr for mutual favorites when not on mesh
            transport = .nostr
        } else {
            throw MessageRouterError.peerNotReachable
        }
        
        // Create routed message
        let routedMessage = RoutedMessage(
            id: messageId,
            content: content,
            recipientNoisePublicKey: recipientNoisePublicKey,
            transport: transport,
            timestamp: Date(),
            status: .pending
        )
        
        pendingMessages[messageId] = routedMessage
        
        // Route based on transport
        switch transport {
        case .bluetoothMesh:
            try await sendViaMesh(routedMessage)
            
        case .nostr:
            try await sendViaNostr(routedMessage)
        }
    }
    
    /// Send a favorite/unfavorite notification
    func sendFavoriteNotification(
        to recipientNoisePublicKey: Data,
        isFavorite: Bool
    ) async throws {
        
        // messageType is used for logging below
        // let messageType: MessageType = isFavorite ? .favorited : .unfavorited
        let recipientHexID = recipientNoisePublicKey.hexEncodedString()
        let action = isFavorite ? "favorite" : "unfavorite"
        
        SecureLogger.log("📤 Sending \(action) notification to \(recipientHexID)", 
                        category: SecureLogger.session, level: .info)
        
        // Try mesh first
        if meshService.getPeerNicknames()[recipientHexID] != nil {
            SecureLogger.log("📡 Sending \(action) notification via Bluetooth mesh", 
                            category: SecureLogger.session, level: .info)
            
            // Send via mesh as a system message
            meshService.sendFavoriteNotification(to: recipientHexID, isFavorite: isFavorite)
            
        } else if let favoriteStatus = favoritesService.getFavoriteStatus(for: recipientNoisePublicKey),
                  let recipientNostrPubkey = favoriteStatus.peerNostrPublicKey {
            
            SecureLogger.log("🌐 Sending \(action) notification via Nostr to \(favoriteStatus.peerNickname)", 
                            category: SecureLogger.session, level: .info)
            
            // Send via Nostr as a special message
            guard let senderIdentity = try? NostrIdentityBridge.getCurrentNostrIdentity() else {
                throw MessageRouterError.noNostrIdentity
            }
            
            // Include our npub in the content
            let content = isFavorite ? "FAVORITED:\(senderIdentity.npub)" : "UNFAVORITED:\(senderIdentity.npub)"
            let event = try NostrProtocol.createPrivateMessage(
                content: content,
                recipientPubkey: recipientNostrPubkey,
                senderIdentity: senderIdentity
            )
            
            nostrRelay.sendEvent(event)
        } else {
            SecureLogger.log("⚠️ Cannot send \(action) notification - peer not reachable via mesh or Nostr", 
                            category: SecureLogger.session, level: .warning)
        }
    }
    
    // MARK: - Private Methods
    
    private func sendViaMesh(_ message: RoutedMessage) async throws {
        // Send the message through mesh - using sendPrivateMessage for now
        let recipientHexID = message.recipientNoisePublicKey.hexEncodedString()
        if let recipientNickname = meshService.getPeerNicknames()[recipientHexID] {
            meshService.sendPrivateMessage(message.content, to: recipientHexID, recipientNickname: recipientNickname, messageID: message.id)
        }
        
        // Update status
        pendingMessages[message.id]?.status = .sent
    }
    
    private func sendViaNostr(_ message: RoutedMessage) async throws {
        // Get recipient's Nostr public key
        let favoriteStatus = favoritesService.getFavoriteStatus(for: message.recipientNoisePublicKey)
        
        SecureLogger.log("🔍 Looking up Nostr key for noise key: \(message.recipientNoisePublicKey.hexEncodedString())", 
                        category: SecureLogger.session, level: .debug)
        
        if let status = favoriteStatus {
            SecureLogger.log("📋 Found favorite: '\(status.peerNickname)', Nostr key: \(status.peerNostrPublicKey ?? "nil")", 
                            category: SecureLogger.session, level: .info)
        } else {
            SecureLogger.log("❌ No favorite relationship found", 
                            category: SecureLogger.session, level: .error)
        }
        
        guard let favoriteStatus = favoriteStatus,
              let recipientNostrPubkey = favoriteStatus.peerNostrPublicKey else {
            throw MessageRouterError.noNostrPublicKey
        }
        
        // Get sender's Nostr identity
        guard let senderIdentity = try NostrIdentityBridge.getCurrentNostrIdentity() else {
            throw MessageRouterError.noNostrIdentity
        }
        
        // Create NIP-17 encrypted message
        let event = try NostrProtocol.createPrivateMessage(
            content: message.content,
            recipientPubkey: recipientNostrPubkey,
            senderIdentity: senderIdentity
        )
        
        // Send via relay
        nostrRelay.sendEvent(event)
        
        // Update status
        pendingMessages[message.id]?.status = .sent
    }
    
    private func setupBindings() {
        // Monitor Nostr messages
        setupNostrMessageHandling()
        
        // Clean up old pending messages periodically
        Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.cleanupOldMessages()
            }
            .store(in: &cancellables)
    }
    
    private func setupNostrMessageHandling() {
        guard let currentIdentity = try? NostrIdentityBridge.getCurrentNostrIdentity() else { return }
        
        // Subscribe to gift wraps for our pubkey
        let filter = NostrFilter.giftWrapsFor(
            pubkey: currentIdentity.publicKeyHex,
            since: Date().addingTimeInterval(-86400) // Last 24 hours
        )
        
        nostrRelay.subscribe(filter: filter, id: "router-messages") { [weak self] event in
            self?.handleNostrMessage(event)
        }
    }
    
    private func handleNostrMessage(_ giftWrap: NostrEvent) {
        // Decrypt the message
        guard let currentIdentity = try? NostrIdentityBridge.getCurrentNostrIdentity(),
              let (content, senderPubkey) = try? NostrProtocol.decryptPrivateMessage(
                giftWrap: giftWrap,
                recipientIdentity: currentIdentity
              ) else { return }
        
        // Check for deduplication
        let messageHash = "\(senderPubkey)-\(content)-\(giftWrap.created_at)"
        if messageDeduplication.get(messageHash) != nil {
            return // Already processed
        }
        messageDeduplication.set(messageHash, value: Date())
        
        // Handle special messages
        if content.hasPrefix("FAVORITED") || content.hasPrefix("UNFAVORITED") {
            let parts = content.split(separator: ":")
            let isFavorite = parts.first == "FAVORITED"
            let nostrNpub = parts.count > 1 ? String(parts[1]) : nil
            handleFavoriteNotification(from: senderPubkey, isFavorite: isFavorite, nostrNpub: nostrNpub)
            return
        }
        
        // Find the sender's Noise public key
        guard let senderNoiseKey = findNoisePublicKey(for: senderPubkey) else { return }
        
        // Create a BitchatMessage and inject into the stream
        let chatMessage = BitchatMessage(
            id: UUID().uuidString,
            sender: favoritesService.getFavoriteStatus(for: senderNoiseKey)?.peerNickname ?? "Unknown",
            content: content,
            timestamp: Date(timeIntervalSince1970: TimeInterval(giftWrap.created_at)),
            isRelay: false,
            originalSender: nil,
            isPrivate: true,
            recipientNickname: nil,
            senderPeerID: senderNoiseKey.hexEncodedString(),
            mentions: nil,
            deliveryStatus: .delivered(to: "nostr", at: Date())
        )
        
        // Post notification for ChatViewModel to handle
        NotificationCenter.default.post(
            name: .nostrMessageReceived,
            object: nil,
            userInfo: ["message": chatMessage]
        )
    }
    
    private func handleFavoriteNotification(from nostrPubkey: String, isFavorite: Bool, nostrNpub: String? = nil) {
        // Find the sender's Noise public key
        guard let senderNoiseKey = findNoisePublicKey(for: nostrPubkey) else { return }
        
        // Update favorites service - nostrPubkey is already the hex public key
        favoritesService.updatePeerFavoritedUs(
            peerNoisePublicKey: senderNoiseKey,
            favorited: isFavorite,
            peerNostrPublicKey: nostrPubkey
        )
        
        // Post notification for UI update
        NotificationCenter.default.post(
            name: .favoriteStatusChanged,
            object: nil,
            userInfo: [
                "peerPublicKey": senderNoiseKey,
                "isFavorite": isFavorite
            ]
        )
    }
    
    private func findNoisePublicKey(for nostrPubkey: String) -> Data? {
        // Search through favorites for matching Nostr pubkey
        for (noiseKey, relationship) in favoritesService.favorites {
            if relationship.peerNostrPublicKey == nostrPubkey {
                return noiseKey
            }
        }
        return nil
    }
    
    private func cleanupOldMessages() {
        let cutoff = Date().addingTimeInterval(-300) // 5 minutes
        pendingMessages = pendingMessages.filter { $0.value.timestamp > cutoff }
    }
}

// MARK: - Errors

enum MessageRouterError: LocalizedError {
    case peerNotReachable
    case noNostrPublicKey
    case noNostrIdentity
    case transportFailed
    
    var errorDescription: String? {
        switch self {
        case .peerNotReachable:
            return "Peer is not reachable via mesh or Nostr"
        case .noNostrPublicKey:
            return "Peer's Nostr public key is unknown"
        case .noNostrIdentity:
            return "No Nostr identity available"
        case .transportFailed:
            return "Failed to send message"
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let nostrMessageReceived = Notification.Name("NostrMessageReceived")
}

