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
    
    public enum MessageUrgency {
        case low
        case normal
        case high
        case urgent
    }
    
    struct RoutedMessage {
        let id: String
        let content: String
        let recipientNoisePublicKey: Data
        var transport: Transport
        let timestamp: Date
        var status: DeliveryStatus
    }
    
    @Published private(set) var pendingMessages: [String: RoutedMessage] = [:]
    
    internal let meshService: BluetoothMeshService
    private let nostrRelay: NostrRelayManager
    private let favoritesService: FavoritesPersistenceService
    
    // Computed properties for voice extensions
    internal var myPeerID: String { meshService.myPeerID }
    private let processedMessagesService = ProcessedMessagesService.shared
    
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
    
    /// Send a message to a peer with intelligent transport fallback
    func sendMessage(
        _ content: String,
        to recipientNoisePublicKey: Data,
        preferredTransport: Transport? = nil,
        messageId: String? = nil,
        urgency: MessageUrgency = .normal
    ) async throws {
        
        let finalMessageId = messageId ?? UUID().uuidString
        let recipientHexID = recipientNoisePublicKey.hexEncodedString()
        
        // Check transport availability
        let peerAvailableOnMesh = meshService.isPeerConnected(recipientHexID)
        let isMutualFavorite = favoritesService.isMutualFavorite(recipientNoisePublicKey)
        
        // Determine transport strategy with fallback
        let primaryTransport: Transport
        let fallbackTransport: Transport?
        
        if let preferred = preferredTransport {
            primaryTransport = preferred
            fallbackTransport = determineFallbackTransport(primary: preferred, peerOnMesh: peerAvailableOnMesh, isFavorite: isMutualFavorite)
        } else if peerAvailableOnMesh {
            primaryTransport = .bluetoothMesh
            fallbackTransport = isMutualFavorite ? .nostr : nil
        } else if isMutualFavorite {
            primaryTransport = .nostr
            fallbackTransport = nil // Nostr is our last resort
        } else {
            throw MessageRouterError.peerNotReachable
        }
        
        // Create routed message
        let routedMessage = RoutedMessage(
            id: finalMessageId,
            content: content,
            recipientNoisePublicKey: recipientNoisePublicKey,
            transport: primaryTransport,
            timestamp: Date(),
            status: .pending
        )
        
        pendingMessages[finalMessageId] = routedMessage
        
        // Try primary transport with intelligent fallback
        do {
            try await sendWithFallback(
                routedMessage, 
                primaryTransport: primaryTransport,
                fallbackTransport: fallbackTransport,
                urgency: urgency
            )
        } catch {
            // Update final failure status
            pendingMessages[finalMessageId]?.status = .failed(error)
            throw error
        }
    }
    
    /// Intelligent fallback transport determination
    private func determineFallbackTransport(
        primary: Transport, 
        peerOnMesh: Bool, 
        isFavorite: Bool
    ) -> Transport? {
        switch primary {
        case .bluetoothMesh:
            return isFavorite ? .nostr : nil
        case .nostr:
            return peerOnMesh ? .bluetoothMesh : nil
        }
    }
    
    /// Send message with intelligent fallback and retry logic
    private func sendWithFallback(
        _ message: RoutedMessage,
        primaryTransport: Transport,
        fallbackTransport: Transport?,
        urgency: MessageUrgency
    ) async throws {
        let timeout: TimeInterval = urgency == .urgent ? 15 : 30 // Shorter timeout for urgent messages
        let maxRetries = urgency == .urgent ? 1 : 2
        
        // Try primary transport
        do {
            try await withTimeout(timeout) {
                try await self.sendViaTransport(message, transport: primaryTransport)
            }
            SecureLogger.log("✅ Message \(message.id) sent via primary transport: \(primaryTransport)", 
                           category: SecureLogger.routing, level: .info)
            return
        } catch {
            SecureLogger.log("❌ Primary transport \(primaryTransport) failed for message \(message.id): \(error)", 
                           category: SecureLogger.routing, level: .warning)
            
            // Update message transport status
            pendingMessages[message.id]?.status = .failed(error)
        }
        
        // Try fallback transport if available
        guard let fallback = fallbackTransport else {
            throw MessageRouterError.transportFailed
        }
        
        SecureLogger.log("🔄 Attempting fallback transport \(fallback) for message \(message.id)", 
                       category: SecureLogger.routing, level: .info)
        
        // Update message to use fallback transport
        var fallbackMessage = message
        fallbackMessage.transport = fallback
        pendingMessages[message.id] = fallbackMessage
        
        // Try fallback with retry
        for attempt in 1...maxRetries {
            do {
                try await withTimeout(timeout) {
                    try await self.sendViaTransport(fallbackMessage, transport: fallback)
                }
                SecureLogger.log("✅ Message \(message.id) sent via fallback transport: \(fallback) (attempt \(attempt))", 
                               category: SecureLogger.routing, level: .info)
                return
            } catch {
                SecureLogger.log("❌ Fallback attempt \(attempt) failed for message \(message.id): \(error)", 
                               category: SecureLogger.routing, level: .warning)
                
                if attempt < maxRetries {
                    // Wait before retry (exponential backoff)
                    let delay = TimeInterval(attempt) * 2.0
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
        
        throw MessageRouterError.transportFailed
    }
    
    /// Send via specific transport (unified interface)
    private func sendViaTransport(_ message: RoutedMessage, transport: Transport) async throws {
        switch transport {
        case .bluetoothMesh:
            try await sendViaMesh(message)
        case .nostr:
            try await sendViaNostr(message)
        }
    }
    
    /// Timeout wrapper for async operations
    private func withTimeout<T>(_ timeout: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw MessageRouterError.timeout
            }
            
            guard let result = try await group.next() else {
                throw MessageRouterError.timeout
            }
            
            group.cancelAll()
            return result
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
        
        
        // Try mesh first
        if meshService.getPeerNicknames()[recipientHexID] != nil {
            
            // Send via mesh as a system message
            meshService.sendFavoriteNotification(to: recipientHexID, isFavorite: isFavorite)
            
        } else if let favoriteStatus = favoritesService.getFavoriteStatus(for: recipientNoisePublicKey),
                  let recipientNostrPubkey = favoriteStatus.peerNostrPublicKey {
            
            
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
        
        // Looking up Nostr key for recipient
        
        if favoriteStatus != nil {
            // Found favorite relationship
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
        
        // Create NIP-17 encrypted message with structured content
        let structuredContent = "MSG:\(message.id):\(message.content)"
        let event = try NostrProtocol.createPrivateMessage(
            content: structuredContent,
            recipientPubkey: recipientNostrPubkey,
            senderIdentity: senderIdentity
        )
        
        // Created gift wrap event
        
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
        
        // Listen for app becoming active to check for messages
        NotificationCenter.default.publisher(for: .appDidBecomeActive)
            .sink { [weak self] _ in
                self?.checkForNostrMessages()
            }
            .store(in: &cancellables)
    }
    
    private func setupNostrMessageHandling() {
        guard (try? NostrIdentityBridge.getCurrentNostrIdentity()) != nil else { 
            SecureLogger.log("⚠️ No Nostr identity available for initial setup", category: SecureLogger.session, level: .warning)
            return 
        }
        
        
        // Connect to relays if not already connected
        if !nostrRelay.isConnected {
            nostrRelay.connect()
            
            // Wait for connections to establish before subscribing
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.subscribeToNostrMessages()
            }
        } else {
            // Already connected, subscribe immediately
            subscribeToNostrMessages()
        }
    }
    
    /// Check for Nostr messages when app becomes active
    func checkForNostrMessages() {
        // Checking for Nostr messages
        
        guard (try? NostrIdentityBridge.getCurrentNostrIdentity()) != nil else { 
            SecureLogger.log("⚠️ No Nostr identity available for message check", category: SecureLogger.session, level: .warning)
            return 
        }
        
        // Ensure we're connected to relays first
        if !nostrRelay.isConnected {
            // Connecting to Nostr relays
            nostrRelay.connect()
            
            // Wait a bit for connections to establish before subscribing
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.subscribeToNostrMessages()
            }
        } else {
            // Already connected, subscribe immediately
            subscribeToNostrMessages()
        }
    }
    
    private func subscribeToNostrMessages() {
        guard let currentIdentity = try? NostrIdentityBridge.getCurrentNostrIdentity() else { return }
        
        // Subscribing to Nostr messages
        // Full pubkey recorded
        // Pubkey length verified
        
        // Unsubscribe existing subscription to refresh
        nostrRelay.unsubscribe(id: "router-messages")
        
        // Create a new subscription for recent messages
        let sinceDate = processedMessagesService.getSubscriptionSinceDate()
        let filter = NostrFilter.giftWrapsFor(
            pubkey: currentIdentity.publicKeyHex,
            since: sinceDate
        )
        
        // Subscribing to messages since date
        
        // Subscribing to gift wraps
        
        nostrRelay.subscribe(filter: filter, id: "router-messages") { [weak self] event in
            // Received Nostr event
            self?.handleNostrMessage(event)
        }
    }
    
    private func handleNostrMessage(_ giftWrap: NostrEvent) {
        // Check if we've already processed this event
        if processedMessagesService.isMessageProcessed(giftWrap.id) {
            // Skipping already processed event
            return
        }
        
        // Attempting to decrypt gift wrap
        // Full event ID recorded
        // Event timestamp recorded
        // Event tags recorded
        
        // Decrypt the message
        guard let currentIdentity = try? NostrIdentityBridge.getCurrentNostrIdentity() else {
            SecureLogger.log("❌ No current Nostr identity available", 
                            category: SecureLogger.session, level: .error)
            return
        }
        
        // Check if this event is actually tagged for us
        let ourPubkey = currentIdentity.publicKeyHex
        let isTaggedForUs = giftWrap.tags.contains { tag in
            tag.count >= 2 && tag[0] == "p" && tag[1] == ourPubkey
        }
        
        if !isTaggedForUs {
            SecureLogger.log("⚠️ Gift wrap not tagged for us! Our pubkey: \(ourPubkey.prefix(8))..., Event tags: \(giftWrap.tags)", 
                            category: SecureLogger.session, level: .warning)
            return
        }
        
        do {
            let (content, senderPubkey) = try NostrProtocol.decryptPrivateMessage(
                giftWrap: giftWrap,
                recipientIdentity: currentIdentity
            )
            
        
            // Mark this event as processed to avoid duplicates on app restart
            let eventTimestamp = Date(timeIntervalSince1970: TimeInterval(giftWrap.created_at))
            processedMessagesService.markMessageAsProcessed(giftWrap.id, timestamp: eventTimestamp)
        
            // Check for deduplication within current session
            let messageHash = "\(senderPubkey)-\(content)-\(giftWrap.created_at)"
            if messageDeduplication.get(messageHash) != nil {
                return // Already processed in this session
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
        
        // Handle delivery acknowledgments
        if content.hasPrefix("DELIVERED:") {
            let parts = content.split(separator: ":")
            if parts.count > 1 {
                let messageId = String(parts[1])
                handleDeliveryAcknowledgment(messageId: messageId, from: senderPubkey)
            }
            return
        }
        
        // Handle read receipts
        if content.hasPrefix("READ:") {
            let parts = content.split(separator: ":", maxSplits: 1)
            if parts.count > 1 {
                let receiptDataString = String(parts[1])
                if let receiptData = Data(base64Encoded: receiptDataString),
                   let receipt = ReadReceipt.fromBinaryData(receiptData) {
                    handleReadReceipt(receipt, from: senderPubkey)
                }
            }
            return
        }
        
        // Find the sender's Noise public key
        guard let senderNoiseKey = findNoisePublicKey(for: senderPubkey) else { return }
        
        // Parse structured message content
        var messageId = UUID().uuidString
        var messageContent = content
        
        if content.hasPrefix("MSG:") {
            let parts = content.split(separator: ":", maxSplits: 2)
            if parts.count >= 3 {
                messageId = String(parts[1])
                messageContent = String(parts[2])
            }
        }
        
        // Create a BitchatMessage and inject into the stream
        let chatMessage = BitchatMessage(
            id: messageId,
            sender: favoritesService.getFavoriteStatus(for: senderNoiseKey)?.peerNickname ?? "Unknown",
            content: messageContent,
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
            
            // Send delivery acknowledgment back to sender
            sendDeliveryAcknowledgment(for: chatMessage.id, to: senderPubkey)
            
        } catch {
            SecureLogger.log("❌ Failed to decrypt gift wrap: \(error)", 
                            category: SecureLogger.session, level: .error)
        }
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
    
    private func handleDeliveryAcknowledgment(messageId: String, from senderPubkey: String) {
        
        // Find the sender's Noise public key
        guard let senderNoiseKey = findNoisePublicKey(for: senderPubkey) else { return }
        
        // Post notification for ChatViewModel to update delivery status
        NotificationCenter.default.post(
            name: .messageDeliveryAcknowledged,
            object: nil,
            userInfo: [
                "messageId": messageId,
                "senderNoiseKey": senderNoiseKey
            ]
        )
    }
    
    private func handleReadReceipt(_ receipt: ReadReceipt, from senderPubkey: String) {
        
        // Find the sender's Noise public key
        guard let senderNoiseKey = findNoisePublicKey(for: senderPubkey) else { return }
        let senderHexID = senderNoiseKey.hexEncodedString()
        
        // Update the receipt with the correct sender ID
        var updatedReceipt = receipt
        updatedReceipt.readerID = senderHexID
        
        // Post notification for ChatViewModel to process
        NotificationCenter.default.post(
            name: .readReceiptReceived,
            object: nil,
            userInfo: ["receipt": updatedReceipt]
        )
    }
    
    func sendReadReceipt(
        for originalMessageID: String,
        to recipientNoisePublicKey: Data,
        preferredTransport: Transport? = nil
    ) async throws {
        
        // Get nickname from delegate or use default
        let nickname = (meshService.delegate as? ChatViewModel)?.nickname ?? "Anonymous"
        
        // Create read receipt
        let receipt = ReadReceipt(
            originalMessageID: originalMessageID,
            readerID: meshService.myPeerID,
            readerNickname: nickname
        )
        
        // Encode receipt
        let receiptData = receipt.toBinaryData()
        let content = "READ:\(receiptData.base64EncodedString())"
        
        // Check if peer is connected via mesh (mesh takes precedence)
        let recipientHexID = recipientNoisePublicKey.hexEncodedString()
        
        // First check if the peer is currently connected with the given ID
        var actualRecipientHexID = recipientHexID
        var actualRecipientNoiseKey = recipientNoisePublicKey
        
        // Always check if they reconnected with a new ID, even if preferredTransport is specified
        if let favoriteStatus = favoritesService.getFavoriteStatus(for: recipientNoisePublicKey) {
            let peerNickname = favoriteStatus.peerNickname
            
            // Search through all current peers to find one with the same nickname
            for (currentPeerID, currentNickname) in meshService.getPeerNicknames() {
                if currentNickname == peerNickname,
                   currentPeerID != recipientHexID,
                   let currentNoiseKey = Data(hexString: currentPeerID) {
                    SecureLogger.log("🔄 Found updated peer ID for \(peerNickname): \(recipientHexID) -> \(currentPeerID)", 
                                    category: SecureLogger.session, level: .info)
                    actualRecipientHexID = currentPeerID
                    actualRecipientNoiseKey = currentNoiseKey
                    break
                }
            }
            
            // If still not found in connected peers, check all favorites for the current key
            if meshService.getPeerNicknames()[actualRecipientHexID] == nil {
                // Search through all favorites to find the current noise key for this nickname
                for (noiseKey, relationship) in favoritesService.favorites {
                    if relationship.peerNickname == peerNickname && relationship.peerNostrPublicKey != nil {
                        SecureLogger.log("🔄 Using current favorite key for \(peerNickname): \(recipientHexID) -> \(noiseKey.hexEncodedString())", 
                                        category: SecureLogger.session, level: .info)
                        actualRecipientHexID = noiseKey.hexEncodedString()
                        actualRecipientNoiseKey = noiseKey
                        break
                    }
                }
            }
        }
        
        let isConnectedOnMesh = meshService.isPeerConnected(actualRecipientHexID)
        
        if isConnectedOnMesh && preferredTransport != .nostr {
            // Send via mesh
            SecureLogger.log("📡 Sending read receipt via mesh to \(actualRecipientHexID)", 
                            category: SecureLogger.session, level: .debug)
            meshService.sendReadReceipt(receipt, to: actualRecipientHexID)
        } else {
            // Send via Nostr
            SecureLogger.log("🌐 Sending read receipt via Nostr to \(actualRecipientHexID)", 
                            category: SecureLogger.session, level: .debug)
            
            // Get recipient's Nostr public key using the actual current noise key
            let favoriteStatus = favoritesService.getFavoriteStatus(for: actualRecipientNoiseKey)
            guard let recipientNostrPubkey = favoriteStatus?.peerNostrPublicKey else {
                SecureLogger.log("❌ Cannot send read receipt - no Nostr key for recipient", 
                                category: SecureLogger.session, level: .error)
                throw MessageRouterError.noNostrKey
            }
            
            guard let senderIdentity = try? NostrIdentityBridge.getCurrentNostrIdentity() else {
                SecureLogger.log("⚠️ No Nostr identity available for read receipt", 
                                category: SecureLogger.session, level: .warning)
                throw MessageRouterError.noIdentity
            }
            
            // Create read receipt message
            guard let event = try? NostrProtocol.createPrivateMessage(
                content: content,
                recipientPubkey: recipientNostrPubkey,
                senderIdentity: senderIdentity
            ) else {
                SecureLogger.log("❌ Failed to create read receipt", 
                                category: SecureLogger.session, level: .error)
                throw MessageRouterError.encryptionFailed
            }
            
            // Send via relay
            nostrRelay.sendEvent(event)
        }
    }
    
    private func sendDeliveryAcknowledgment(for messageId: String, to recipientNostrPubkey: String) {
        SecureLogger.log("📤 Sending delivery acknowledgment for message \(messageId)", 
                        category: SecureLogger.session, level: .debug)
        
        guard let senderIdentity = try? NostrIdentityBridge.getCurrentNostrIdentity() else {
            SecureLogger.log("⚠️ No Nostr identity available for acknowledgment", 
                            category: SecureLogger.session, level: .warning)
            return
        }
        
        // Create acknowledgment message
        let content = "DELIVERED:\(messageId)"
        guard let event = try? NostrProtocol.createPrivateMessage(
            content: content,
            recipientPubkey: recipientNostrPubkey,
            senderIdentity: senderIdentity
        ) else {
            SecureLogger.log("❌ Failed to create delivery acknowledgment", 
                            category: SecureLogger.session, level: .error)
            return
        }
        
        // Send via relay
        nostrRelay.sendEvent(event)
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
    case noNostrKey
    case noIdentity
    case encryptionFailed
    case timeout
    
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
        case .noNostrKey:
            return "No Nostr key available for recipient"
        case .noIdentity:
            return "No identity available"
        case .encryptionFailed:
            return "Failed to encrypt message"
        case .timeout:
            return "Message sending timed out"
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let nostrMessageReceived = Notification.Name("NostrMessageReceived")
    static let messageDeliveryAcknowledged = Notification.Name("MessageDeliveryAcknowledged")
    static let readReceiptReceived = Notification.Name("ReadReceiptReceived")
    static let appDidBecomeActive = Notification.Name("AppDidBecomeActive")
}

