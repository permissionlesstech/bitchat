//
// ChatViewModel.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

///
/// # ChatViewModel
///
/// The central business logic and state management component for BitChat.
/// Coordinates between the UI layer and the networking/encryption services.
///
/// ## Overview
/// ChatViewModel implements the MVVM pattern, serving as the binding layer between
/// SwiftUI views and the underlying BitChat services. It manages:
/// - Message state and delivery
/// - Peer connections and presence
/// - Private chat sessions
/// - Command processing
/// - UI state like autocomplete and notifications
///
/// ## Architecture
/// The ViewModel acts as:
/// - **BitchatDelegate**: Receives messages and events from BluetoothMeshService
/// - **State Manager**: Maintains all UI-relevant state with @Published properties
/// - **Command Processor**: Handles IRC-style commands (/msg, /who, etc.)
/// - **Message Router**: Directs messages to appropriate chats (public/private)
///
/// ## Key Features
///
/// ### Message Management
/// - Efficient message handling with duplicate detection
/// - Maintains separate public and private message queues
/// - Limits message history to prevent memory issues (1337 messages)
/// - Tracks delivery and read receipts
///
/// ### Privacy Features
/// - Ephemeral by design - no persistent message storage
/// - Supports verified fingerprints for secure communication
/// - Blocks messages from blocked users
/// - Emergency wipe capability (triple-tap)
///
/// ### User Experience
/// - Smart autocomplete for mentions and commands
/// - Unread message indicators
/// - Connection status tracking
/// - Favorite peers management
///
/// ## Command System
/// Supports IRC-style commands:
/// - `/nick <name>`: Change nickname
/// - `/msg <user> <message>`: Send private message
/// - `/who`: List connected peers
/// - `/slap <user>`: Fun interaction
/// - `/clear`: Clear message history
/// - `/help`: Show available commands
///
/// ## Performance Optimizations
/// - SwiftUI automatically optimizes UI updates
/// - Caches expensive computations (encryption status)
/// - Debounces autocomplete suggestions
/// - Efficient peer list management
///
/// ## Thread Safety
/// - All @Published properties trigger UI updates on main thread
/// - Background operations use proper queue management
/// - Atomic operations for critical state updates
///
/// ## Usage Example
/// ```swift
/// let viewModel = ChatViewModel()
/// viewModel.nickname = "Alice"
/// viewModel.startServices()
/// viewModel.sendMessage("Hello, mesh network!")
/// ```
///

import Foundation
import SwiftUI
import Combine
import CryptoKit
import CommonCrypto
import CoreBluetooth
#if os(iOS)
import UIKit
#endif

/// Manages the application state and business logic for BitChat.
/// Acts as the primary coordinator between UI components and backend services,
/// implementing the BitchatDelegate protocol to handle network events.
class ChatViewModel: ObservableObject, BitchatDelegate {
    // MARK: - Published Properties
    
    @Published var messages: [BitchatMessage] = []
    private let maxMessages = 1337 // Maximum messages before oldest are removed
    @Published var connectedPeers: [String] = []
    @Published var allPeers: [BitchatPeer] = []  // Unified peer list including favorites
    private var peerIndex: [String: BitchatPeer] = [:] // Quick lookup by peer ID
    
    // MARK: - Properties
    @Published var nickname: String = "" {
        didSet {
            // Trim whitespace whenever nickname is set
            let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != nickname {
                nickname = trimmed
            }
        }
    }
    @Published var isConnected = false
    @Published var privateChats: [String: [BitchatMessage]] = [:] // peerID -> messages
    @Published var selectedPrivateChatPeer: String? = nil
    private var selectedPrivateChatFingerprint: String? = nil  // Track by fingerprint for persistence across reconnections
    @Published var unreadPrivateMessages: Set<String> = []
    @Published var autocompleteSuggestions: [String] = []
    @Published var showAutocomplete: Bool = false
    @Published var autocompleteRange: NSRange? = nil
    @Published var selectedAutocompleteIndex: Int = 0
    
    // MARK: - Autocomplete Properties
    
    // Autocomplete optimization
    private let mentionRegex = try? NSRegularExpression(pattern: "@([a-zA-Z0-9_]*)$", options: [])
    private var cachedNicknames: [String] = []
    private var lastNicknameUpdate: Date = .distantPast
    
    // Temporary property to fix compilation
    @Published var showPasswordPrompt = false
    
    // MARK: - Services and Storage
    
    var meshService = BluetoothMeshService()
    private var nostrRelayManager: NostrRelayManager?
    private var messageRouter: MessageRouter?
    private var peerManager: PeerManager?
    private let userDefaults = UserDefaults.standard
    private let nicknameKey = "bitchat.nickname"
    
    // MARK: - Caches
    
    // Caches for expensive computations
    private var encryptionStatusCache: [String: EncryptionStatus] = [:] // key: peerID
    
    // MARK: - Social Features
    
    @Published var favoritePeers: Set<String> = []  // Now stores public key fingerprints instead of peer IDs
    private var peerIDToPublicKeyFingerprint: [String: String] = [:]  // Maps ephemeral peer IDs to persistent fingerprints
    private var blockedUsers: Set<String> = []  // Stores public key fingerprints of blocked users
    
    // MARK: - Encryption and Security
    
    // Noise Protocol encryption status
    @Published var peerEncryptionStatus: [String: EncryptionStatus] = [:]  // peerID -> encryption status
    @Published var verifiedFingerprints: Set<String> = []  // Set of verified fingerprints
    @Published var showingFingerprintFor: String? = nil  // Currently showing fingerprint sheet for peer
    
    // Bluetooth state management
    @Published var showBluetoothAlert = false
    @Published var bluetoothAlertMessage = ""
    @Published var bluetoothState: CBManagerState = .unknown
    
    // Messages are naturally ephemeral - no persistent storage
    
    // MARK: - Message Delivery Tracking
    
    // Delivery tracking
    private var deliveryTrackerCancellable: AnyCancellable?
    private var cancellables = Set<AnyCancellable>()
    
    // Track sent read receipts to avoid duplicates
    private var sentReadReceipts: Set<String> = []  // messageID set
    
    // Track Nostr pubkey mappings for unknown senders
    private var nostrKeyMapping: [String: String] = [:]  // senderPeerID -> nostrPubkey
    
    // MARK: - Initialization
    
    init() {
        loadNickname()
        loadFavorites()
        loadBlockedUsers()
        loadVerifiedFingerprints()
        meshService.delegate = self
        
        // Log startup info
        
        // Log fingerprint after a delay to ensure encryption service is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            if let self = self {
                _ = self.getMyFingerprint()
            }
        }
        
        // Start mesh service immediately
        meshService.startServices()
        
        // Set up message retry service
        MessageRetryService.shared.meshService = meshService
        
        // Initialize Nostr services
        Task { @MainActor in
            nostrRelayManager = NostrRelayManager.shared
            nostrRelayManager?.connect()
            
            messageRouter = MessageRouter(
                meshService: meshService,
                nostrRelay: nostrRelayManager!
            )
            
            // Initialize peer manager
            peerManager = PeerManager(meshService: meshService)
            peerManager?.updatePeers()
            
            // Bind peer manager's peer list to our published property
            let cancellable = peerManager?.$peers
                .receive(on: DispatchQueue.main)
                .sink { [weak self] peers in
                    SecureLogger.log("📱 UI: Received \(peers.count) peers from PeerManager", 
                                    category: SecureLogger.session, level: .info)
                    for peer in peers {
                        SecureLogger.log("  - \(peer.displayName): connected=\(peer.isConnected), state=\(peer.connectionState)", 
                                        category: SecureLogger.session, level: .debug)
                    }
                    // Update peers directly
                    self?.allPeers = peers
                    // Update peer index for O(1) lookups
                    // Deduplicate peers by ID to prevent crash from duplicate keys
                    var uniquePeers: [String: BitchatPeer] = [:]
                    for peer in peers {
                        // Keep the first occurrence of each peer ID
                        if uniquePeers[peer.id] == nil {
                            uniquePeers[peer.id] = peer
                        } else {
                            SecureLogger.log("⚠️ Duplicate peer ID detected: \(peer.id) (\(peer.displayName))", 
                                           category: SecureLogger.session, level: .warning)
                        }
                    }
                    self?.peerIndex = uniquePeers
                    // Schedule UI update if peers changed
                    if peers.count > 0 || self?.allPeers.count ?? 0 > 0 {
                        // UI will update automatically
                    }
                    
                    // Update private chat peer ID if needed when peers change
                    if self?.selectedPrivateChatFingerprint != nil {
                        self?.updatePrivateChatPeerIfNeeded()
                    }
                }
            
            if let cancellable = cancellable {
                self.cancellables.insert(cancellable)
            }
        }
        
        // Set up Noise encryption callbacks
        setupNoiseCallbacks()
        
        // Request notification permission
        NotificationService.shared.requestAuthorization()
        
        // Subscribe to delivery status updates
        deliveryTrackerCancellable = DeliveryTracker.shared.deliveryStatusUpdated
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (messageID, status) in
                self?.updateMessageDeliveryStatus(messageID, status: status)
            }
        
        // Listen for retry notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRetryMessage),
            name: Notification.Name("bitchat.retryMessage"),
            object: nil
        )
        
        // Listen for Nostr messages
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleNostrMessage),
            name: .nostrMessageReceived,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleNostrReadReceipt),
            name: .readReceiptReceived,
            object: nil
        )
        
        // Listen for favorite status changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFavoriteStatusChanged),
            name: .favoriteStatusChanged,
            object: nil
        )
        
        // Listen for peer status updates to refresh UI
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePeerStatusUpdate),
            name: Notification.Name("peerStatusUpdated"),
            object: nil
        )
        
        // Listen for delivery acknowledgments
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDeliveryAcknowledgment),
            name: .messageDeliveryAcknowledged,
            object: nil
        )
                
        // When app becomes active, send read receipts for visible messages
        #if os(macOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        
        // Add app lifecycle observers to save data
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillResignActive),
            name: NSApplication.willResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
        #else
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        
        // Add screenshot detection for iOS
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userDidTakeScreenshot),
            name: UIApplication.userDidTakeScreenshotNotification,
            object: nil
        )
        
        // Add app lifecycle observers to save data
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillTerminate),
            name: UIApplication.willTerminateNotification,
            object: nil
        )
        #endif
    }
    
    // MARK: - Deinitialization
    
    deinit {
        // Force immediate save
        userDefaults.synchronize()
    }
    
    // MARK: - Nickname Management
    
    private func loadNickname() {
        if let savedNickname = userDefaults.string(forKey: nicknameKey) {
            // Trim whitespace when loading
            nickname = savedNickname.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            nickname = "anon\(Int.random(in: 1000...9999))"
            saveNickname()
        }
    }
    
    func saveNickname() {
        userDefaults.set(nickname, forKey: nicknameKey)
        userDefaults.synchronize() // Force immediate save
        
        // Send announce with new nickname to all peers
        meshService.sendBroadcastAnnounce()
    }
    
    func validateAndSaveNickname() {
        // Trim whitespace from nickname
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Check if nickname is empty after trimming
        if trimmed.isEmpty {
            nickname = "anon\(Int.random(in: 1000...9999))"
        } else {
            nickname = trimmed
        }
        saveNickname()
    }
    
    // MARK: - Favorites Management
    
    private func loadFavorites() {
        // Load favorites from secure storage
        favoritePeers = SecureIdentityStateManager.shared.getFavorites()
    }
    
    private func saveFavorites() {
        // Favorites are now saved automatically in SecureIdentityStateManager
        // This method is kept for compatibility
    }
    
    // MARK: - Blocked Users Management
    
    private func loadBlockedUsers() {
        // Load blocked users from secure storage
        let allIdentities = SecureIdentityStateManager.shared.getAllSocialIdentities()
        blockedUsers = Set(allIdentities.filter { $0.isBlocked }.map { $0.fingerprint })
    }
    
    private func saveBlockedUsers() {
        // Blocked users are now saved automatically in SecureIdentityStateManager
        // This method is kept for compatibility
    }
    
    
    func toggleFavorite(peerID: String) {
        
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            
            // Try to find the favorite relationship first by Noise key, then by Nostr key
            var noisePublicKey: Data?
            var currentStatus: FavoritesPersistenceService.FavoriteRelationship?
            
            // First try as Noise key
            if let noiseKey = Data(hexString: peerID) {
                currentStatus = FavoritesPersistenceService.shared.getFavoriteStatus(for: noiseKey)
                noisePublicKey = noiseKey
            }
            
            // getFavoriteStatusByNostrKey not implemented
            // If not found, try as Nostr key
            // if currentStatus == nil {
            //     currentStatus = FavoritesPersistenceService.shared.getFavoriteStatusByNostrKey(peerID)
            //     noisePublicKey = currentStatus?.peerNoisePublicKey
            // }
            
            // If still no noise key, we can't proceed
            guard let finalNoiseKey = noisePublicKey else {
                SecureLogger.log("❌ Could not find noise key for peer: \(peerID)", category: SecureLogger.session, level: .error)
                return
            }
            
            let isFavorite = currentStatus?.isFavorite ?? false
            
            SecureLogger.log("📊 Current favorite status for \(peerID): isFavorite=\(isFavorite), isMutual=\(currentStatus?.isMutual ?? false)", 
                            category: SecureLogger.session, level: .info)
            
            if isFavorite {
                // Remove from favorites
                FavoritesPersistenceService.shared.removeFavorite(peerNoisePublicKey: finalNoiseKey)
                
                // Send unfavorite notification via mesh or Nostr
                Task {
                    try? await self.messageRouter?.sendFavoriteNotification(to: finalNoiseKey, isFavorite: false)
                }
            } else {
                // Add to favorites
                let peers = self.allPeers
                let nickname = self.meshService.getPeerNicknames()[peerID] ?? peers.first(where: { $0.id == peerID })?.displayName ?? "Unknown"
                let nostrPublicKey = peers.first(where: { $0.id == peerID })?.nostrPublicKey
                
                // Ensure we have a Nostr identity created
                if (try? NostrIdentityBridge.getCurrentNostrIdentity()) != nil {
                }
                
                FavoritesPersistenceService.shared.addFavorite(
                    peerNoisePublicKey: finalNoiseKey,
                    peerNostrPublicKey: nostrPublicKey ?? currentStatus?.peerNostrPublicKey,
                    peerNickname: nickname
                )
                
                // Send favorite notification via mesh or Nostr
                Task {
                    try? await self.messageRouter?.sendFavoriteNotification(to: finalNoiseKey, isFavorite: true)
                }
            }
            
            // Update the peer list to reflect the change
            self.peerManager?.updatePeers()
            
            // Check if we now have a mutual favorite relationship
            if let updatedStatus = FavoritesPersistenceService.shared.getFavoriteStatus(for: finalNoiseKey),
               updatedStatus.isMutual {
            }
        }
    }
    
    @MainActor
    func isFavorite(peerID: String) -> Bool {
        // First try as Noise public key
        if let noisePublicKey = Data(hexString: peerID) {
            if let status = FavoritesPersistenceService.shared.getFavoriteStatus(for: noisePublicKey) {
                return status.isFavorite
            }
        }
        
        // getFavoriteStatusByNostrKey not implemented
        // If not found, try as Nostr public key
        // if let status = FavoritesPersistenceService.shared.getFavoriteStatusByNostrKey(peerID) {
        //     return status.isFavorite
        // }
        
        return false
    }
    
    // MARK: - Public Key and Identity Management
    
    // Called when we receive a peer's public key
    func registerPeerPublicKey(peerID: String, publicKeyData: Data) {
        // Create a fingerprint from the public key (full SHA256, not truncated)
        let fingerprintStr = SHA256.hash(data: publicKeyData)
            .compactMap { String(format: "%02x", $0) }
            .joined()
        
        // Only register if not already registered
        if peerIDToPublicKeyFingerprint[peerID] != fingerprintStr {
            peerIDToPublicKeyFingerprint[peerID] = fingerprintStr
        }
        
        // Update identity state manager with handshake completion
        SecureIdentityStateManager.shared.updateHandshakeState(peerID: peerID, state: .completed(fingerprint: fingerprintStr))
        
        // Update encryption status now that we have the fingerprint
        updateEncryptionStatus(for: peerID)
        
        // Check if we have a claimed nickname for this peer
        let peerNicknames = meshService.getPeerNicknames()
        if let nickname = peerNicknames[peerID], nickname != "Unknown" && nickname != "anon\(peerID.prefix(4))" {
            // Update or create social identity with the claimed nickname
            if var identity = SecureIdentityStateManager.shared.getSocialIdentity(for: fingerprintStr) {
                identity.claimedNickname = nickname
                SecureIdentityStateManager.shared.updateSocialIdentity(identity)
            } else {
                let newIdentity = SocialIdentity(
                    fingerprint: fingerprintStr,
                    localPetname: nil,
                    claimedNickname: nickname,
                    trustLevel: .casual,
                    isFavorite: false,
                    isBlocked: false,
                    notes: nil
                )
                SecureIdentityStateManager.shared.updateSocialIdentity(newIdentity)
            }
        }
        
        // Check if this peer is the one we're in a private chat with
        updatePrivateChatPeerIfNeeded()
        
        // If we're in a private chat with this peer (by fingerprint), send pending read receipts
        if let chatFingerprint = selectedPrivateChatFingerprint,
           chatFingerprint == fingerprintStr {
            // Send read receipts for any unread messages from this peer
            // Use a small delay to ensure the connection is fully established
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.markPrivateMessagesAsRead(from: peerID)
            }
        }
    }
    
    private func isPeerBlocked(_ peerID: String) -> Bool {
        // Check if we have the public key fingerprint for this peer
        if let fingerprint = peerIDToPublicKeyFingerprint[peerID] {
            return SecureIdentityStateManager.shared.isBlocked(fingerprint: fingerprint)
        }
        
        // Try to get fingerprint from mesh service
        if let fingerprint = meshService.getPeerFingerprint(peerID) {
            return SecureIdentityStateManager.shared.isBlocked(fingerprint: fingerprint)
        }
        
        return false
    }
    
    // Helper method to find current peer ID for a fingerprint
    private func getCurrentPeerIDForFingerprint(_ fingerprint: String) -> String? {
        // Search through all connected peers to find the one with matching fingerprint
        for peerID in connectedPeers {
            if let mappedFingerprint = peerIDToPublicKeyFingerprint[peerID],
               mappedFingerprint == fingerprint {
                return peerID
            }
        }
        return nil
    }
    
    // Helper method to update selectedPrivateChatPeer if fingerprint matches
    private func updatePrivateChatPeerIfNeeded() {
        guard let chatFingerprint = selectedPrivateChatFingerprint else { return }
        
        // Find current peer ID for the fingerprint
        if let currentPeerID = getCurrentPeerIDForFingerprint(chatFingerprint) {
            // Update the selected peer if it's different
            if let oldPeerID = selectedPrivateChatPeer, oldPeerID != currentPeerID {
                SecureLogger.log("📱 Updating private chat peer from \(oldPeerID) to \(currentPeerID)", 
                                category: SecureLogger.session, level: .debug)
                
                // Migrate messages from old peer ID to new peer ID
                if let oldMessages = privateChats[oldPeerID] {
                    if privateChats[currentPeerID] == nil {
                        privateChats[currentPeerID] = []
                    }
                    privateChats[currentPeerID]?.append(contentsOf: oldMessages)
                    // Sort by timestamp
                    privateChats[currentPeerID]?.sort { $0.timestamp < $1.timestamp }
                    // Remove duplicates
                    var seen = Set<String>()
                    privateChats[currentPeerID] = privateChats[currentPeerID]?.filter { msg in
                        if seen.contains(msg.id) {
                            return false
                        }
                        seen.insert(msg.id)
                        return true
                    }
                    trimPrivateChatMessagesIfNeeded(for: currentPeerID)
                    privateChats.removeValue(forKey: oldPeerID)
                }
                
                // Migrate unread status
                if unreadPrivateMessages.contains(oldPeerID) {
                    unreadPrivateMessages.remove(oldPeerID)
                    unreadPrivateMessages.insert(currentPeerID)
                }
                
                selectedPrivateChatPeer = currentPeerID
                
                // Schedule UI update for encryption status change
                // UI will update automatically
                
                // Also refresh the peer list to update encryption status
                Task { @MainActor in
                    peerManager?.updatePeers()
                }
            } else if selectedPrivateChatPeer == nil {
                // Just set the peer ID if we don't have one
                selectedPrivateChatPeer = currentPeerID
                // UI will update automatically
            }
            
            // Clear unread messages for the current peer ID
            unreadPrivateMessages.remove(currentPeerID)
        }
    }
    
    // MARK: - Message Sending
    
    /// Sends a message through the BitChat network.
    /// - Parameter content: The message content to send
    /// - Note: Automatically handles command processing if content starts with '/'
    ///         Routes to private chat if one is selected, otherwise broadcasts
    @MainActor
    func sendMessage(_ content: String) {
        guard !content.isEmpty else { return }
        
        // Check for commands
        if content.hasPrefix("/") {
            Task { @MainActor in
                handleCommand(content)
            }
            return
        }
        
        if selectedPrivateChatPeer != nil {
            // Update peer ID in case it changed due to reconnection
            updatePrivateChatPeerIfNeeded()
            
            if let selectedPeer = selectedPrivateChatPeer {
                // Send as private message
                sendPrivateMessage(content, to: selectedPeer)
            } else {
            }
        } else {
            // Parse mentions from the content
            let mentions = parseMentions(from: content)
            
            // Add message to local display
            let message = BitchatMessage(
                sender: nickname,
                content: content,
                timestamp: Date(),
                isRelay: false,
                originalSender: nil,
                isPrivate: false,
                recipientNickname: nil,
                senderPeerID: meshService.myPeerID,
                mentions: mentions.isEmpty ? nil : mentions
            )
            
            // Add to main messages immediately for user feedback
            messages.append(message)
            trimMessagesIfNeeded()
            
            // Force immediate UI update for user's own messages
            objectWillChange.send()
            
            // Send via mesh with mentions
            meshService.sendMessage(content, mentions: mentions)
        }
    }
    
    /// Sends an encrypted private message to a specific peer.
    /// - Parameters:
    ///   - content: The message content to encrypt and send
    ///   - peerID: The recipient's peer ID
    /// - Note: Automatically establishes Noise encryption if not already active
    @MainActor
    func sendPrivateMessage(_ content: String, to peerID: String) {
        guard !content.isEmpty else { return }
        
        // Check if peer is available on mesh (actually connected, not just known)
        let meshPeers = meshService.getPeerNicknames()
        let peerAvailableOnMesh = meshService.isPeerConnected(peerID)
        let recipientNickname: String
        
        if let meshNickname = meshPeers[peerID] {
            recipientNickname = meshNickname
        } else {
            // Try to get from favorites
            guard let noiseKey = Data(hexString: peerID),
                  let favoriteStatus = FavoritesPersistenceService.shared.getFavoriteStatus(for: noiseKey) else {
                return
            }
            recipientNickname = favoriteStatus.peerNickname
        }
        
        // Check if the recipient is blocked
        if isPeerBlocked(peerID) {
            let systemMessage = BitchatMessage(
                sender: "system",
                content: "cannot send message to \(recipientNickname): user is blocked.",
                timestamp: Date(),
                isRelay: false
            )
            messages.append(systemMessage)
            return
        }
        
        // IMPORTANT: When sending a message, it means we're viewing this chat
        // Send read receipts for any delivered messages from this peer
        markPrivateMessagesAsRead(from: peerID)
        
        // Create the message locally
        let message = BitchatMessage(
            sender: nickname,
            content: content,
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: true,
            recipientNickname: recipientNickname,
            senderPeerID: meshService.myPeerID,
            deliveryStatus: .sending
        )
        
        // Add to our private chat history
        if privateChats[peerID] == nil {
            privateChats[peerID] = []
        }
        privateChats[peerID]?.append(message)
        trimPrivateChatMessagesIfNeeded(for: peerID)
        
        // Track the message for delivery confirmation
        let isFavorite = isFavorite(peerID: peerID)
        DeliveryTracker.shared.trackMessage(message, recipientID: peerID, recipientNickname: recipientNickname, isFavorite: isFavorite)
        
        // Immediate UI update for user's own messages
        objectWillChange.send()
        
        // Determine how to send the message
        guard let noiseKey = Data(hexString: peerID) else { return }
        
        if peerAvailableOnMesh {
            // Send via mesh with the same message ID
            meshService.sendPrivateMessage(content, to: peerID, recipientNickname: recipientNickname, messageID: message.id)
        } else if let favoriteStatus = FavoritesPersistenceService.shared.getFavoriteStatus(for: noiseKey),
                  favoriteStatus.isMutual {
            // Mutual favorite offline - send via Nostr
            SecureLogger.log("🌐 Sending private message to offline mutual favorite \(recipientNickname) via Nostr", 
                            category: SecureLogger.session, level: .info)
            
            Task {
                do {
                    try await messageRouter?.sendMessage(content, to: noiseKey, messageId: message.id)
                } catch {
                    SecureLogger.log("Failed to send message via Nostr: \(error)", 
                                    category: SecureLogger.session, level: .error)
                    // DeliveryTracker will handle timeout automatically
                }
            }
        } else {
            // Not reachable - show error to user
            SecureLogger.log("⚠️ Cannot send message to \(recipientNickname) - not available on mesh or Nostr", 
                            category: SecureLogger.session, level: .warning)
            
            // Add system message to inform user
            let systemMessage = BitchatMessage(
                sender: "system",
                content: "Cannot send message to \(recipientNickname) - peer is not reachable via mesh or Nostr.",
                timestamp: Date(),
                isRelay: false
            )
            addMessage(systemMessage)
        }
    }
    
    // MARK: - Bluetooth State Management
    
    /// Updates the Bluetooth state and shows appropriate alerts
    /// - Parameter state: The current Bluetooth manager state
    @MainActor
    func updateBluetoothState(_ state: CBManagerState) {
        bluetoothState = state
        
        switch state {
        case .poweredOff:
            bluetoothAlertMessage = "Bluetooth is turned off. Please turn on Bluetooth in Settings to use BitChat."
            showBluetoothAlert = true
        case .unauthorized:
            bluetoothAlertMessage = "BitChat needs Bluetooth permission to connect with nearby devices. Please enable Bluetooth access in Settings."
            showBluetoothAlert = true
        case .unsupported:
            bluetoothAlertMessage = "This device does not support Bluetooth. BitChat requires Bluetooth to function."
            showBluetoothAlert = true
        case .poweredOn:
            // Hide alert when Bluetooth is powered on
            showBluetoothAlert = false
            bluetoothAlertMessage = ""
        case .unknown, .resetting:
            // Don't show alerts for transient states
            showBluetoothAlert = false
        @unknown default:
            showBluetoothAlert = false
        }
    }
    
    // MARK: - Private Chat Management
    
    /// Initiates a private chat session with a peer.
    /// - Parameter peerID: The peer's ID to start chatting with
    /// - Note: Switches the UI to private chat mode and loads message history
    @MainActor
    func startPrivateChat(with peerID: String) {
        // Safety check: Don't allow starting chat with ourselves
        if peerID == meshService.myPeerID {
            SecureLogger.log("⚠️ Attempted to start private chat with self, ignoring", 
                            category: SecureLogger.session, level: .warning)
            return
        }
        
        // Try to get nickname from mesh first, then from peer list
        let peerNickname = meshService.getPeerNicknames()[peerID] ?? 
                          peerIndex[peerID]?.displayName ?? 
                          "unknown"
        
        // Check if the peer is blocked
        if isPeerBlocked(peerID) {
            let systemMessage = BitchatMessage(
                sender: "system",
                content: "cannot start chat with \(peerNickname): user is blocked.",
                timestamp: Date(),
                isRelay: false
            )
            messages.append(systemMessage)
            return
        }
        
        // Check if this is a moon peer (we favorite them but they don't favorite us) AND they're offline
        // Only require mutual favorites for offline Nostr messaging
        if let peer = peerIndex[peerID],
           peer.isFavorite && !peer.theyFavoritedUs && !peer.isConnected && !peer.isRelayConnected {
            let systemMessage = BitchatMessage(
                sender: "system",
                content: "cannot start chat with \(peerNickname): mutual favorite required for offline messaging.",
                timestamp: Date(),
                isRelay: false
            )
            messages.append(systemMessage)
            return
        }
        
        // Trigger handshake if we don't have a session yet
        let sessionState = meshService.getNoiseSessionState(for: peerID)
        switch sessionState {
        case .none, .failed:
            // Initiate handshake when opening PM
            meshService.triggerHandshake(with: peerID)
        default:
            break
        }
        
        selectedPrivateChatPeer = peerID
        // Also track by fingerprint for persistence across reconnections
        selectedPrivateChatFingerprint = peerIDToPublicKeyFingerprint[peerID]
        unreadPrivateMessages.remove(peerID)
        
        // Check if we need to migrate messages from an old peer ID
        // This happens when peer IDs change between sessions
        if privateChats[peerID] == nil || privateChats[peerID]?.isEmpty == true {
            
            // Get the fingerprint for this peer
            let currentFingerprint = getFingerprint(for: peerID)
            
            // Look for messages under other peer IDs with the same fingerprint
            var migratedMessages: [BitchatMessage] = []
            var oldPeerIDsToRemove: [String] = []
            
            for (oldPeerID, messages) in privateChats {
                if oldPeerID != peerID {
                    // Check if this old peer ID has the same fingerprint (same actual peer)
                    let oldFingerprint = peerIDToPublicKeyFingerprint[oldPeerID]
                    
                    if let currentFp = currentFingerprint,
                       let oldFp = oldFingerprint,
                       currentFp == oldFp {
                        // Same peer with different ID - migrate all messages
                        migratedMessages.append(contentsOf: messages)
                        oldPeerIDsToRemove.append(oldPeerID)
                        
                        SecureLogger.log("📦 Migrating \(messages.count) messages from old peer ID \(oldPeerID) to \(peerID) based on fingerprint match", 
                                        category: SecureLogger.session, level: .info)
                    } else if currentFingerprint == nil || oldFingerprint == nil {
                        // Fallback: use nickname matching only if we don't have fingerprints
                        // This is less reliable but handles legacy data
                        let messagesWithPeer = messages.filter { msg in
                            // Message is FROM the peer to us
                            (msg.sender == peerNickname && msg.sender != nickname) ||
                            // OR message is FROM us TO the peer
                            (msg.sender == nickname && (msg.recipientNickname == peerNickname || 
                             // Also check if this was a private message in a chat that only has us and one other person
                             (msg.isPrivate && messages.allSatisfy { m in 
                                 m.sender == nickname || m.sender == peerNickname 
                             })))
                        }
                        
                        if !messagesWithPeer.isEmpty {
                            // Check if ALL messages in this chat are between us and this peer
                            let allMessagesAreWithPeer = messages.allSatisfy { msg in
                                (msg.sender == peerNickname || msg.sender == nickname) &&
                                (msg.recipientNickname == nil || msg.recipientNickname == peerNickname || msg.recipientNickname == nickname)
                            }
                            
                            if allMessagesAreWithPeer {
                                // This entire chat history likely belongs to this peer, migrate it all
                                migratedMessages.append(contentsOf: messages)
                                oldPeerIDsToRemove.append(oldPeerID)
                                
                                SecureLogger.log("📦 Migrating \(messages.count) messages from old peer ID \(oldPeerID) to \(peerID) based on nickname match (no fingerprints available)", 
                                                category: SecureLogger.session, level: .warning)
                            }
                        }
                    }
                }
            }
            
            // Remove old peer ID entries that were fully migrated
            for oldPeerID in oldPeerIDsToRemove {
                privateChats.removeValue(forKey: oldPeerID)
                unreadPrivateMessages.remove(oldPeerID)
            }
            
            // Initialize chat history with migrated messages if any
            if !migratedMessages.isEmpty {
                privateChats[peerID] = migratedMessages.sorted { $0.timestamp < $1.timestamp }
                trimPrivateChatMessagesIfNeeded(for: peerID)
            } else {
                privateChats[peerID] = []
            }
        }
        
        _ = privateChats[peerID] ?? []
        
        // Send read receipts for unread messages from this peer
        // Add a small delay to ensure UI has updated
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.markPrivateMessagesAsRead(from: peerID)
        }
        
        // Also try immediately in case messages are already there
        markPrivateMessagesAsRead(from: peerID)
    }
    
    func endPrivateChat() {
        selectedPrivateChatPeer = nil
        selectedPrivateChatFingerprint = nil
    }
    
    // MARK: - Message Retry Handling
    
    @objc private func handleRetryMessage(_ notification: Notification) {
        guard let messageID = notification.userInfo?["messageID"] as? String else { return }
        
        // Find the message to retry
        if let message = messages.first(where: { $0.id == messageID }) {
            SecureLogger.log("Retrying message \(messageID) to \(message.recipientNickname ?? "unknown")", 
                           category: SecureLogger.session, level: .info)
            
            // Resend the message through mesh service
            if message.isPrivate,
               let peerID = getPeerIDForNickname(message.recipientNickname ?? "") {
                // Update status to sending
                updateMessageDeliveryStatus(messageID, status: .sending)
                
                // Resend via mesh service
                meshService.sendMessage(message.content, 
                                      mentions: message.mentions ?? [], 
                                      to: peerID,
                                      messageID: messageID,
                                      timestamp: message.timestamp)
            }
        }
    }
    
    // MARK: - Nostr Message Handling
    
    @objc private func handleNostrMessage(_ notification: Notification) {
        guard let message = notification.userInfo?["message"] as? BitchatMessage else { return }
        
        // Store the Nostr pubkey if provided (for messages from unknown senders)
        if let nostrPubkey = notification.userInfo?["nostrPubkey"] as? String,
           let senderPeerID = message.senderPeerID {
            // Store mapping for read receipts
            nostrKeyMapping[senderPeerID] = nostrPubkey
        }
        
        // Process the Nostr message through the same flow as Bluetooth messages
        didReceiveMessage(message)
    }
    
    @objc private func handleDeliveryAcknowledgment(_ notification: Notification) {
        guard let messageId = notification.userInfo?["messageId"] as? String,
              let senderNoiseKey = notification.userInfo?["senderNoiseKey"] as? Data else { return }
        
        let senderHexId = senderNoiseKey.hexEncodedString()
        
        SecureLogger.log("✅ Handling delivery acknowledgment for message \(messageId) from \(senderHexId)", 
                        category: SecureLogger.session, level: .info)
        
        // Update the delivery status for the message
        if let index = messages.firstIndex(where: { $0.id == messageId }) {
            // Update delivery status to delivered
            messages[index].deliveryStatus = DeliveryStatus.delivered(to: "nostr", at: Date())
            
            // Schedule UI update for delivery status
            // UI will update automatically
        }
        
        // Also update in private chats if it's a private message
        for (peerID, chatMessages) in privateChats {
            if let index = chatMessages.firstIndex(where: { $0.id == messageId }) {
                privateChats[peerID]?[index].deliveryStatus = DeliveryStatus.delivered(to: "nostr", at: Date())
                // UI will update automatically
                break
            }
        }
    }
    
    @objc private func handleNostrReadReceipt(_ notification: Notification) {
        guard let receipt = notification.userInfo?["receipt"] as? ReadReceipt else { return }
        
        SecureLogger.log("📖 Handling read receipt for message \(receipt.originalMessageID) from Nostr", 
                        category: SecureLogger.session, level: .info)
        
        // Process the read receipt through the same flow as Bluetooth read receipts
        didReceiveReadReceipt(receipt)
    }
    
    @objc private func handlePeerStatusUpdate(_ notification: Notification) {
        // Update private chat peer if needed when peer status changes
        updatePrivateChatPeerIfNeeded()
    }
    
    @objc private func handleFavoriteStatusChanged(_ notification: Notification) {
        guard let peerPublicKey = notification.userInfo?["peerPublicKey"] as? Data else { return }
        
        Task { @MainActor in
            // Handle noise key updates
            if let isKeyUpdate = notification.userInfo?["isKeyUpdate"] as? Bool,
               isKeyUpdate,
               let oldKey = notification.userInfo?["oldPeerPublicKey"] as? Data {
                let oldPeerID = oldKey.hexEncodedString()
                let newPeerID = peerPublicKey.hexEncodedString()
                
                // If we have a private chat open with the old peer ID, update it to the new one
                if selectedPrivateChatPeer == oldPeerID {
                    SecureLogger.log("📱 Updating private chat peer ID due to key change: \(oldPeerID) -> \(newPeerID)", 
                                    category: SecureLogger.session, level: .info)
                    
                    // Transfer private chat messages to new peer ID
                    if let messages = privateChats[oldPeerID] {
                        privateChats[newPeerID] = messages
                        privateChats.removeValue(forKey: oldPeerID)
                    }
                    
                    // Transfer unread status
                    if unreadPrivateMessages.contains(oldPeerID) {
                        unreadPrivateMessages.remove(oldPeerID)
                        unreadPrivateMessages.insert(newPeerID)
                    }
                    
                    // Update selected peer
                    selectedPrivateChatPeer = newPeerID
                    
                    // Update fingerprint tracking if needed
                    if let fingerprint = peerIDToPublicKeyFingerprint[oldPeerID] {
                        peerIDToPublicKeyFingerprint.removeValue(forKey: oldPeerID)
                        peerIDToPublicKeyFingerprint[newPeerID] = fingerprint
                        selectedPrivateChatFingerprint = fingerprint
                    }
                    
                    // Schedule UI refresh
                    // UI will update automatically
                } else {
                    // Even if the chat isn't open, migrate any existing private chat data
                    if let messages = privateChats[oldPeerID] {
                        SecureLogger.log("📱 Migrating private chat messages from \(oldPeerID) to \(newPeerID)", 
                                        category: SecureLogger.session, level: .debug)
                        privateChats[newPeerID] = messages
                        privateChats.removeValue(forKey: oldPeerID)
                    }
                    
                    // Transfer unread status
                    if unreadPrivateMessages.contains(oldPeerID) {
                        unreadPrivateMessages.remove(oldPeerID)
                        unreadPrivateMessages.insert(newPeerID)
                    }
                    
                    // Update fingerprint mapping
                    if let fingerprint = peerIDToPublicKeyFingerprint[oldPeerID] {
                        peerIDToPublicKeyFingerprint.removeValue(forKey: oldPeerID)
                        peerIDToPublicKeyFingerprint[newPeerID] = fingerprint
                    }
                }
            }
            
            // First check if this is a peer ID update for our current chat
            updatePrivateChatPeerIfNeeded()
            
            // Then handle favorite/unfavorite messages if applicable
            if let isFavorite = notification.userInfo?["isFavorite"] as? Bool {
                let peerID = peerPublicKey.hexEncodedString()
                let action = isFavorite ? "favorited" : "unfavorited"
                
                // Find peer nickname
                let peerNickname: String
                if let nickname = meshService.getPeerNicknames()[peerID] {
                    peerNickname = nickname
                } else if let favorite = FavoritesPersistenceService.shared.getFavoriteStatus(for: peerPublicKey) {
                    peerNickname = favorite.peerNickname
                } else {
                    peerNickname = "Unknown"
                }
                
                // Create system message
                let systemMessage = BitchatMessage(
                    id: UUID().uuidString,
                sender: "System",
                content: "\(peerNickname) \(action) you",
                timestamp: Date(),
                isRelay: false,
                originalSender: nil,
                isPrivate: false,
                recipientNickname: nil,
                senderPeerID: nil,
                mentions: nil
            )
            
            // Add to message stream
            addMessage(systemMessage)
            
            // Update peer manager to refresh UI
            peerManager?.updatePeers()
            }
        }
    }
    
    // MARK: - App Lifecycle
    
    @MainActor
    @objc private func appDidBecomeActive() {
        // When app becomes active, send read receipts for visible private chat
        if let peerID = selectedPrivateChatPeer {
            // Try immediately
            self.markPrivateMessagesAsRead(from: peerID)
            // And again with a delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.markPrivateMessagesAsRead(from: peerID)
            }
        }
    }
    
    @objc private func userDidTakeScreenshot() {
        // Send screenshot notification based on current context
        let screenshotMessage = "* \(nickname) took a screenshot *"
        
        if let peerID = selectedPrivateChatPeer {
            // In private chat - send to the other person
            if let peerNickname = meshService.getPeerNicknames()[peerID] {
                // Only send screenshot notification if we have an established session
                // This prevents triggering handshake requests for screenshot notifications
                let sessionState = meshService.getNoiseSessionState(for: peerID)
                switch sessionState {
                case .established:
                    // Send the message directly without going through sendPrivateMessage to avoid local echo
                    meshService.sendPrivateMessage(screenshotMessage, to: peerID, recipientNickname: peerNickname)
                default:
                    // Don't send screenshot notification if no session exists
                    SecureLogger.log("Skipping screenshot notification to \(peerID) - no established session", category: SecureLogger.security, level: .debug)
                }
            }
            
            // Show local notification immediately as system message
            let localNotification = BitchatMessage(
                sender: "system",
                content: "you took a screenshot",
                timestamp: Date(),
                isRelay: false,
                originalSender: nil,
                isPrivate: true,
                recipientNickname: meshService.getPeerNicknames()[peerID],
                senderPeerID: meshService.myPeerID
            )
            if privateChats[peerID] == nil {
                privateChats[peerID] = []
            }
            privateChats[peerID]?.append(localNotification)
            trimPrivateChatMessagesIfNeeded(for: peerID)
            
        } else {
            // In public chat - send to everyone
            meshService.sendMessage(screenshotMessage, mentions: [])
            
            // Show local notification immediately as system message
            let localNotification = BitchatMessage(
                sender: "system",
                content: "you took a screenshot",
                timestamp: Date(),
                isRelay: false
            )
            // Add system message
            addMessage(localNotification)
        }
    }
    
    @objc private func appWillResignActive() {
        userDefaults.synchronize()
    }
    
    @objc func applicationWillTerminate() {
        
        // Force save any pending identity changes (verifications, favorites, etc)
        SecureIdentityStateManager.shared.forceSave()
        
        // Verify identity key is still there
        _ = KeychainManager.shared.verifyIdentityKeyExists()
        
        userDefaults.synchronize()
        
        // Verify identity key after save
        _ = KeychainManager.shared.verifyIdentityKeyExists()
    }
    
    @objc private func appWillTerminate() {
        
        userDefaults.synchronize()
    }
    
    @MainActor
    private func sendReadReceipt(_ receipt: ReadReceipt, to peerID: String, originalTransport: String? = nil) {
        // First, try to resolve the current peer ID in case they reconnected with a new ID
        var actualPeerID = peerID
        
        // Check if this peer ID exists in current nicknames
        if meshService.getPeerNicknames()[peerID] == nil {
            // Peer not found with this ID, try to find by fingerprint or nickname
            if let oldNoiseKey = Data(hexString: peerID),
               let favoriteStatus = FavoritesPersistenceService.shared.getFavoriteStatus(for: oldNoiseKey) {
                let peerNickname = favoriteStatus.peerNickname
                
                // Search for the current peer ID with the same nickname
                for (currentPeerID, currentNickname) in meshService.getPeerNicknames() {
                    if currentNickname == peerNickname {
                        SecureLogger.log("📖 Resolved updated peer ID for read receipt: \(peerID) -> \(currentPeerID)", 
                                        category: SecureLogger.session, level: .info)
                        actualPeerID = currentPeerID
                        break
                    }
                }
            }
        }
        
        // If we know the original transport, use it for the read receipt
        if originalTransport == "nostr" {
            // Message was received via Nostr, send read receipt via Nostr
            if let noiseKey = Data(hexString: actualPeerID) {
                Task { @MainActor in
                    try? await messageRouter?.sendReadReceipt(for: receipt.originalMessageID, to: noiseKey, preferredTransport: .nostr)
                }
            } else if let nostrPubkey = nostrKeyMapping[actualPeerID] {
                // This is a Nostr-only peer we haven't mapped to a Noise key yet
                Task { @MainActor in
                    if let tempNoiseKey = Data(hexString: nostrPubkey) {
                        try? await messageRouter?.sendReadReceipt(for: receipt.originalMessageID, to: tempNoiseKey, preferredTransport: .nostr)
                    }
                }
            }
        } else if meshService.getPeerNicknames()[actualPeerID] != nil {
            // Use mesh for connected peers (default behavior)
            meshService.sendReadReceipt(receipt, to: actualPeerID)
        } else {
            // Try Nostr for offline peers
            if let noiseKey = Data(hexString: actualPeerID) {
                Task { @MainActor in
                    try? await messageRouter?.sendReadReceipt(for: receipt.originalMessageID, to: noiseKey)
                }
            } else if let nostrPubkey = nostrKeyMapping[actualPeerID] {
                // This is a Nostr-only peer we haven't mapped to a Noise key yet
                Task { @MainActor in
                    if let tempNoiseKey = Data(hexString: nostrPubkey) {
                        try? await messageRouter?.sendReadReceipt(for: receipt.originalMessageID, to: tempNoiseKey)
                    }
                }
            }
        }
    }
    
    @MainActor
    func markPrivateMessagesAsRead(from peerID: String) {
        // Get the nickname for this peer
        let peerNickname = meshService.getPeerNicknames()[peerID] ?? ""
        
        // First ensure we have the latest messages (in case of migration)
        if let messages = privateChats[peerID], !messages.isEmpty {
        } else {
            
            // Look through ALL private chats to find messages from this nickname
            for (_, chatMessages) in privateChats {
                let relevantMessages = chatMessages.filter { msg in
                    msg.sender == peerNickname && msg.sender != nickname
                }
                if !relevantMessages.isEmpty {
                }
            }
        }
        
        guard let messages = privateChats[peerID], !messages.isEmpty else { 
            return 
        }
        
        
        // Find messages from the peer that haven't been read yet
        var readReceiptsSent = 0
        for (_, message) in messages.enumerated() {
            // Only send read receipts for messages from the other peer (not our own)
            // Check multiple conditions to ensure we catch all messages from the peer
            let isOurMessage = message.sender == nickname
            let isFromPeerByNickname = !peerNickname.isEmpty && message.sender == peerNickname
            
            // Check if message is from this peer by comparing IDs
            // Handle both Noise and Nostr keys
            var isFromPeerByID = false
            if let msgSenderID = message.senderPeerID {
                // Direct match
                isFromPeerByID = msgSenderID == peerID
                
                // If no direct match, check if we're comparing Nostr keys
                if !isFromPeerByID {
                    // Check if the peerID has a favorite entry with a Nostr key that matches
                    if let noiseKey = Data(hexString: peerID),
                       let favoriteStatus = FavoritesPersistenceService.shared.getFavoriteStatus(for: noiseKey),
                       let nostrKey = favoriteStatus.peerNostrPublicKey {
                        isFromPeerByID = msgSenderID == nostrKey
                    }
                    
                    // getFavoriteStatusByNostrKey not implemented
                    // Or check if the message sender ID maps to this peer's Noise key
                    // if !isFromPeerByID,
                    //    let senderFavorite = FavoritesPersistenceService.shared.getFavoriteStatusByNostrKey(msgSenderID),
                    //    senderFavorite.peerNoisePublicKey.hexEncodedString() == peerID {
                    //     isFromPeerByID = true
                    // }
                }
            }
            
            let isPrivateToUs = message.isPrivate && message.recipientNickname == nickname
            
            // This is a message FROM the peer if it's not from us AND (matches nickname OR peer ID OR is private to us)
            let isFromPeer = !isOurMessage && (isFromPeerByNickname || isFromPeerByID || isPrivateToUs)
            
            if message.id == message.id { // Always true, for debugging
            }
            
            if isFromPeer {
                if let status = message.deliveryStatus {
                    switch status {
                    case .sent, .delivered:
                        // Create and send read receipt for sent or delivered messages
                        // Check if we've already sent a receipt for this message
                        if !sentReadReceipts.contains(message.id) {
                            let receipt = ReadReceipt(
                                originalMessageID: message.id,
                                readerID: meshService.myPeerID,
                                readerNickname: nickname
                            )
                            
                            // Send read receipt to the message sender
                            // Use the message's senderPeerID if available (for Nostr messages)
                            // Otherwise use the current peerID
                            let recipientID = message.senderPeerID ?? peerID
                            
                            // Check if message was delivered via Nostr
                            var originalTransport: String? = nil
                            if let status = message.deliveryStatus {
                                switch status {
                                case .delivered(let transport, _):
                                    originalTransport = transport
                                default:
                                    break
                                }
                            }
                            
                            sendReadReceipt(receipt, to: recipientID, originalTransport: originalTransport)
                            sentReadReceipts.insert(message.id)
                            readReceiptsSent += 1
                        } else {
                        }
                    case .read:
                        // Already read, no need to send another receipt
                        break
                    default:
                        // Message not yet delivered, can't mark as read
                        break
                    }
                } else {
                    // No delivery status - this might be an older message
                    // Send read receipt anyway for backwards compatibility
                    if !sentReadReceipts.contains(message.id) {
                        let receipt = ReadReceipt(
                            originalMessageID: message.id,
                            readerID: meshService.myPeerID,
                            readerNickname: nickname
                        )
                        // Use the message's senderPeerID if available (for Nostr messages)
                        let recipientID = message.senderPeerID ?? peerID
                        
                        // For backwards compatibility, check if this might be a Nostr message
                        // by checking if the sender has a Nostr key
                        let receiptToSend = receipt
                        let recipientToSend = recipientID
                        Task { @MainActor in
                            var originalTransport: String? = nil
                            if let noiseKey = Data(hexString: recipientToSend),
                               let favoriteStatus = FavoritesPersistenceService.shared.getFavoriteStatus(for: noiseKey),
                               favoriteStatus.peerNostrPublicKey != nil,
                               self.meshService.getPeerNicknames()[recipientToSend] == nil {
                                // Peer has Nostr key and is not on mesh, likely received via Nostr
                                originalTransport = "nostr"
                            }
                            
                            self.sendReadReceipt(receiptToSend, to: recipientToSend, originalTransport: originalTransport)
                        }
                        sentReadReceipts.insert(message.id)
                        readReceiptsSent += 1
                    } else {
                    }
                }
            } else {
            }
        }
        
    }
    
    func getPrivateChatMessages(for peerID: String) -> [BitchatMessage] {
        let messages = privateChats[peerID] ?? []
        if !messages.isEmpty {
        }
        return messages
    }
    
    func getPeerIDForNickname(_ nickname: String) -> String? {
        let nicknames = meshService.getPeerNicknames()
        return nicknames.first(where: { $0.value == nickname })?.key
    }
    
    
    // MARK: - Emergency Functions
    
    // PANIC: Emergency data clearing for activist safety
    @MainActor
    func panicClearAllData() {
        // Messages are processed immediately - nothing to flush
        
        // Clear all messages
        messages.removeAll()
        privateChats.removeAll()
        unreadPrivateMessages.removeAll()
        
        // First run aggressive cleanup to get rid of all legacy items
        _ = KeychainManager.shared.aggressiveCleanupLegacyItems()
        
        // Then delete all current keychain data
        _ = KeychainManager.shared.deleteAllKeychainData()
        
        // Clear UserDefaults identity fallbacks
        userDefaults.removeObject(forKey: "bitchat.noiseIdentityKey")
        userDefaults.removeObject(forKey: "bitchat.messageRetentionKey")
        
        // Clear verified fingerprints
        verifiedFingerprints.removeAll()
        // Verified fingerprints are cleared when identity data is cleared below
        
        // Clear message retry queue
        MessageRetryService.shared.clearRetryQueue()
        
        
        // Reset nickname to anonymous
        nickname = "anon\(Int.random(in: 1000...9999))"
        saveNickname()
        
        // Clear favorites
        favoritePeers.removeAll()
        peerIDToPublicKeyFingerprint.removeAll()
        
        // Clear persistent favorites from keychain
        FavoritesPersistenceService.shared.clearAllFavorites()
        
        // Clear identity data from secure storage
        SecureIdentityStateManager.shared.clearAllIdentityData()
        
        // Clear autocomplete state
        autocompleteSuggestions.removeAll()
        showAutocomplete = false
        autocompleteRange = nil
        selectedAutocompleteIndex = 0
        
        // Clear selected private chat
        selectedPrivateChatPeer = nil
        selectedPrivateChatFingerprint = nil
        
        // Clear read receipt tracking
        sentReadReceipts.removeAll()
        
        // Clear all caches
        invalidateEncryptionCache()
        
        // Disconnect from all peers and clear persistent identity
        // This will force creation of a new identity (new fingerprint) on next launch
        meshService.emergencyDisconnectAll()
        
        // Force immediate UserDefaults synchronization
        userDefaults.synchronize()
        
        // Force immediate UI update for panic mode
        // UI updates immediately - no flushing needed
        
    }
    
    
    
    // MARK: - Formatting Helpers
    
    func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
    
    
    // MARK: - Autocomplete
    
    func updateAutocomplete(for text: String, cursorPosition: Int) {
        // Quick early exit for empty text
        guard cursorPosition > 0 else {
            if showAutocomplete {
                showAutocomplete = false
                autocompleteSuggestions = []
                autocompleteRange = nil
            }
            return
        }
        
        // Find @ symbol before cursor
        let beforeCursor = String(text.prefix(cursorPosition))
        
        // Use cached regex
        guard let regex = mentionRegex,
              let match = regex.firstMatch(in: beforeCursor, options: [], range: NSRange(location: 0, length: beforeCursor.count)) else {
            if showAutocomplete {
                showAutocomplete = false
                autocompleteSuggestions = []
                autocompleteRange = nil
            }
            return
        }
        
        // Extract the partial nickname
        let partialRange = match.range(at: 1)
        guard let range = Range(partialRange, in: beforeCursor) else {
            if showAutocomplete {
                showAutocomplete = false
                autocompleteSuggestions = []
                autocompleteRange = nil
            }
            return
        }
        
        let partial = String(beforeCursor[range]).lowercased()
        
        // Update cached nicknames only if peer list changed (check every 1 second max)
        let now = Date()
        if now.timeIntervalSince(lastNicknameUpdate) > 1.0 || cachedNicknames.isEmpty {
            let peerNicknames = meshService.getPeerNicknames()
            cachedNicknames = Array(peerNicknames.values).sorted()
            lastNicknameUpdate = now
        }
        
        // Filter suggestions using cached nicknames
        let suggestions = cachedNicknames.filter { nick in
            nick.lowercased().hasPrefix(partial)
        }
        
        // UI will update automatically
        if !suggestions.isEmpty {
            // Only update if suggestions changed
            if autocompleteSuggestions != suggestions {
                autocompleteSuggestions = suggestions
            }
            if !showAutocomplete {
                showAutocomplete = true
            }
            if autocompleteRange != match.range(at: 0) {
                autocompleteRange = match.range(at: 0)
            }
            selectedAutocompleteIndex = 0
        } else {
            if showAutocomplete {
                showAutocomplete = false
                autocompleteSuggestions = []
                autocompleteRange = nil
                selectedAutocompleteIndex = 0
            }
        }
    }
    
    func completeNickname(_ nickname: String, in text: inout String) -> Int {
        guard let range = autocompleteRange else { return text.count }
        
        // Replace the @partial with @nickname
        let nsText = text as NSString
        let newText = nsText.replacingCharacters(in: range, with: "@\(nickname) ")
        text = newText
        
        // Hide autocomplete
        showAutocomplete = false
        autocompleteSuggestions = []
        autocompleteRange = nil
        selectedAutocompleteIndex = 0
        
        // Return new cursor position (after the space)
        return range.location + nickname.count + 2
    }
    
    // MARK: - Message Formatting
    
    func getSenderColor(for message: BitchatMessage, colorScheme: ColorScheme) -> Color {
        let isDark = colorScheme == .dark
        let primaryColor = isDark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
        
        return primaryColor
    }
    
    
    func formatMessageContent(_ message: BitchatMessage, colorScheme: ColorScheme) -> AttributedString {
        let isDark = colorScheme == .dark
        let contentText = message.content
        var processedContent = AttributedString()
        
        // Regular expressions for mentions and hashtags
        let mentionPattern = "@([a-zA-Z0-9_]+)"
        let hashtagPattern = "#([a-zA-Z0-9_]+)"
        
        let mentionRegex = try? NSRegularExpression(pattern: mentionPattern, options: [])
        let hashtagRegex = try? NSRegularExpression(pattern: hashtagPattern, options: [])
        
        let mentionMatches = mentionRegex?.matches(in: contentText, options: [], range: NSRange(location: 0, length: contentText.count)) ?? []
        let hashtagMatches = hashtagRegex?.matches(in: contentText, options: [], range: NSRange(location: 0, length: contentText.count)) ?? []
        
        // Combine and sort all matches
        var allMatches: [(range: NSRange, type: String)] = []
        for match in mentionMatches {
            allMatches.append((match.range(at: 0), "mention"))
        }
        for match in hashtagMatches {
            allMatches.append((match.range(at: 0), "hashtag"))
        }
        allMatches.sort { $0.range.location < $1.range.location }
        
        var lastEndIndex = contentText.startIndex
        
        for (matchRange, matchType) in allMatches {
            // Add text before the match
            if let range = Range(matchRange, in: contentText) {
                let beforeText = String(contentText[lastEndIndex..<range.lowerBound])
                if !beforeText.isEmpty {
                    var normalStyle = AttributeContainer()
                    normalStyle.font = .system(size: 14, design: .monospaced)
                    normalStyle.foregroundColor = isDark ? Color.white : Color.black
                    processedContent.append(AttributedString(beforeText).mergingAttributes(normalStyle))
                }
                
                // Add the match with appropriate styling
                let matchText = String(contentText[range])
                var matchStyle = AttributeContainer()
                matchStyle.font = .system(size: 14, weight: .semibold, design: .monospaced)
                
                if matchType == "mention" {
                    matchStyle.foregroundColor = Color.orange
                } else {
                    // Hashtag
                    matchStyle.foregroundColor = Color.blue
                    matchStyle.underlineStyle = .single
                }
                
                processedContent.append(AttributedString(matchText).mergingAttributes(matchStyle))
                
                lastEndIndex = range.upperBound
            }
        }
        
        // Add any remaining text
        if lastEndIndex < contentText.endIndex {
            let remainingText = String(contentText[lastEndIndex...])
            var normalStyle = AttributeContainer()
            normalStyle.font = .system(size: 14, design: .monospaced)
            normalStyle.foregroundColor = isDark ? Color.white : Color.black
            processedContent.append(AttributedString(remainingText).mergingAttributes(normalStyle))
        }
        
        return processedContent
    }
    
    func formatMessageAsText(_ message: BitchatMessage, colorScheme: ColorScheme) -> AttributedString {
        // Check cache first
        let isDark = colorScheme == .dark
        if let cachedText = message.getCachedFormattedText(isDark: isDark) {
            return cachedText
        }
        
        // Not cached, format the message
        var result = AttributedString()
        
        let primaryColor = isDark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
        let secondaryColor = primaryColor.opacity(0.7)
        
        // Timestamp
        let timestamp = AttributedString("[\(formatTimestamp(message.timestamp))] ")
        var timestampStyle = AttributeContainer()
        timestampStyle.foregroundColor = message.sender == "system" ? Color.gray : secondaryColor
        timestampStyle.font = .system(size: 12, design: .monospaced)
        result.append(timestamp.mergingAttributes(timestampStyle))
        
        if message.sender != "system" {
            // Sender
            let sender = AttributedString("<@\(message.sender)> ")
            var senderStyle = AttributeContainer()
            
            // Use consistent color for all senders
            senderStyle.foregroundColor = primaryColor
            // Bold the user's own nickname
            let fontWeight: Font.Weight = message.sender == nickname ? .bold : .medium
            senderStyle.font = .system(size: 14, weight: fontWeight, design: .monospaced)
            result.append(sender.mergingAttributes(senderStyle))
            
            // Process content with hashtags and mentions
            let content = message.content
            
            let hashtagPattern = "#([a-zA-Z0-9_]+)"
            let mentionPattern = "@([a-zA-Z0-9_]+)"
            
            let hashtagRegex = try? NSRegularExpression(pattern: hashtagPattern, options: [])
            let mentionRegex = try? NSRegularExpression(pattern: mentionPattern, options: [])
            
            // Use NSDataDetector for URL detection
            let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
            
            let hashtagMatches = hashtagRegex?.matches(in: content, options: [], range: NSRange(location: 0, length: content.count)) ?? []
            let mentionMatches = mentionRegex?.matches(in: content, options: [], range: NSRange(location: 0, length: content.count)) ?? []
            let urlMatches = detector?.matches(in: content, options: [], range: NSRange(location: 0, length: content.count)) ?? []
            
            // Combine and sort matches
            var allMatches: [(range: NSRange, type: String)] = []
            for match in hashtagMatches {
                allMatches.append((match.range(at: 0), "hashtag"))
            }
            for match in mentionMatches {
                allMatches.append((match.range(at: 0), "mention"))
            }
            for match in urlMatches {
                allMatches.append((match.range, "url"))
            }
            allMatches.sort { $0.range.location < $1.range.location }
            
            // Build content with styling
            var lastEnd = content.startIndex
            let isMentioned = message.mentions?.contains(nickname) ?? false
            
            for (range, type) in allMatches {
                // Add text before match
                if let nsRange = Range(range, in: content) {
                    let beforeText = String(content[lastEnd..<nsRange.lowerBound])
                    if !beforeText.isEmpty {
                        var beforeStyle = AttributeContainer()
                        beforeStyle.foregroundColor = primaryColor
                        beforeStyle.font = .system(size: 14, design: .monospaced)
                        if isMentioned {
                            beforeStyle.font = beforeStyle.font?.bold()
                        }
                        result.append(AttributedString(beforeText).mergingAttributes(beforeStyle))
                    }
                    
                    // Add styled match
                    let matchText = String(content[nsRange])
                    var matchStyle = AttributeContainer()
                    matchStyle.font = .system(size: 14, weight: .semibold, design: .monospaced)
                    
                    if type == "hashtag" {
                        matchStyle.foregroundColor = Color.blue
                        matchStyle.underlineStyle = .single
                    } else if type == "mention" {
                        matchStyle.foregroundColor = Color.orange
                    } else if type == "url" {
                        matchStyle.foregroundColor = Color.blue
                        matchStyle.underlineStyle = .single
                    }
                    
                    result.append(AttributedString(matchText).mergingAttributes(matchStyle))
                    lastEnd = nsRange.upperBound
                }
            }
            
            // Add remaining text
            if lastEnd < content.endIndex {
                let remainingText = String(content[lastEnd...])
                var remainingStyle = AttributeContainer()
                remainingStyle.foregroundColor = primaryColor
                remainingStyle.font = .system(size: 14, design: .monospaced)
                if isMentioned {
                    remainingStyle.font = remainingStyle.font?.bold()
                }
                result.append(AttributedString(remainingText).mergingAttributes(remainingStyle))
            }
        } else {
            // System message
            var contentStyle = AttributeContainer()
            contentStyle.foregroundColor = Color.gray
            let content = AttributedString("* \(message.content) *")
            contentStyle.font = .system(size: 12, design: .monospaced).italic()
            result.append(content.mergingAttributes(contentStyle))
        }
        
        // Cache the formatted text
        message.setCachedFormattedText(result, isDark: isDark)
        
        return result
    }
    
    func formatMessage(_ message: BitchatMessage, colorScheme: ColorScheme) -> AttributedString {
        var result = AttributedString()
        
        let isDark = colorScheme == .dark
        let primaryColor = isDark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
        let secondaryColor = primaryColor.opacity(0.7)
        
        let timestamp = AttributedString("[\(formatTimestamp(message.timestamp))] ")
        var timestampStyle = AttributeContainer()
        timestampStyle.foregroundColor = message.sender == "system" ? Color.gray : secondaryColor
        timestampStyle.font = .system(size: 12, design: .monospaced)
        result.append(timestamp.mergingAttributes(timestampStyle))
        
        if message.sender == "system" {
            let content = AttributedString("* \(message.content) *")
            var contentStyle = AttributeContainer()
            contentStyle.foregroundColor = Color.gray
            contentStyle.font = .system(size: 12, design: .monospaced).italic()
            result.append(content.mergingAttributes(contentStyle))
        } else {
            let sender = AttributedString("<\(message.sender)> ")
            var senderStyle = AttributeContainer()
            
            // Use consistent color for all senders
            senderStyle.foregroundColor = primaryColor
            // Bold the user's own nickname
            let fontWeight: Font.Weight = message.sender == nickname ? .bold : .medium
            senderStyle.font = .system(size: 12, weight: fontWeight, design: .monospaced)
            result.append(sender.mergingAttributes(senderStyle))
            
            
            // Process content to highlight mentions
            let contentText = message.content
            var processedContent = AttributedString()
            
            // Regular expression to find @mentions
            let pattern = "@([a-zA-Z0-9_]+)"
            let regex = try? NSRegularExpression(pattern: pattern, options: [])
            let matches = regex?.matches(in: contentText, options: [], range: NSRange(location: 0, length: contentText.count)) ?? []
            
            var lastEndIndex = contentText.startIndex
            
            for match in matches {
                // Add text before the mention
                if let range = Range(match.range(at: 0), in: contentText) {
                    let beforeText = String(contentText[lastEndIndex..<range.lowerBound])
                    if !beforeText.isEmpty {
                        var normalStyle = AttributeContainer()
                        normalStyle.font = .system(size: 14, design: .monospaced)
                        normalStyle.foregroundColor = isDark ? Color.white : Color.black
                        processedContent.append(AttributedString(beforeText).mergingAttributes(normalStyle))
                    }
                    
                    // Add the mention with highlight
                    let mentionText = String(contentText[range])
                    var mentionStyle = AttributeContainer()
                    mentionStyle.font = .system(size: 14, weight: .semibold, design: .monospaced)
                    mentionStyle.foregroundColor = Color.orange
                    processedContent.append(AttributedString(mentionText).mergingAttributes(mentionStyle))
                    
                    lastEndIndex = range.upperBound
                }
            }
            
            // Add any remaining text
            if lastEndIndex < contentText.endIndex {
                let remainingText = String(contentText[lastEndIndex...])
                var normalStyle = AttributeContainer()
                normalStyle.font = .system(size: 14, design: .monospaced)
                normalStyle.foregroundColor = isDark ? Color.white : Color.black
                processedContent.append(AttributedString(remainingText).mergingAttributes(normalStyle))
            }
            
            result.append(processedContent)
            
            if message.isRelay, let originalSender = message.originalSender {
                let relay = AttributedString(" (via \(originalSender))")
                var relayStyle = AttributeContainer()
                relayStyle.foregroundColor = secondaryColor
                relayStyle.font = .system(size: 11, design: .monospaced)
                result.append(relay.mergingAttributes(relayStyle))
            }
        }
        
        return result
    }
    
    // MARK: - Noise Protocol Support
    
    func updateEncryptionStatusForPeers() {
        for peerID in connectedPeers {
            updateEncryptionStatusForPeer(peerID)
        }
    }
    
    func updateEncryptionStatusForPeer(_ peerID: String) {
        let noiseService = meshService.getNoiseService()
        
        if noiseService.hasEstablishedSession(with: peerID) {
            // Check if fingerprint is verified using our persisted data
            if let fingerprint = getFingerprint(for: peerID),
               verifiedFingerprints.contains(fingerprint) {
                peerEncryptionStatus[peerID] = .noiseVerified
            } else {
                peerEncryptionStatus[peerID] = .noiseSecured
            }
        } else if noiseService.hasSession(with: peerID) {
            // Session exists but not established - handshaking
            peerEncryptionStatus[peerID] = .noiseHandshaking
        } else {
            // No session at all
            peerEncryptionStatus[peerID] = Optional.none
        }
        
        // Invalidate cache when encryption status changes
        invalidateEncryptionCache(for: peerID)
        
        // UI will update automatically via @Published properties
    }
    
    func getEncryptionStatus(for peerID: String) -> EncryptionStatus {
        // Check cache first
        if let cachedStatus = encryptionStatusCache[peerID] {
            return cachedStatus
        }
        
        // This must be a pure function - no state mutations allowed
        // to avoid SwiftUI update loops
        
        // Check if we've ever established a session by looking for a fingerprint
        let hasEverEstablishedSession = getFingerprint(for: peerID) != nil
        
        let sessionState = meshService.getNoiseSessionState(for: peerID)
        let storedStatus = peerEncryptionStatus[peerID]
        
        let status: EncryptionStatus
        
        // Determine status based on session state
        switch sessionState {
        case .established:
            // We have encryption, now check if it's verified
            if let fingerprint = getFingerprint(for: peerID) {
                if verifiedFingerprints.contains(fingerprint) {
                    status = .noiseVerified
                } else {
                    status = .noiseSecured
                }
            } else {
                // We have a session but no fingerprint yet - still secured
                status = .noiseSecured
            }
        case .handshaking, .handshakeQueued:
            // If we've ever established a session, show secured instead of handshaking
            if hasEverEstablishedSession {
                // Check if it was verified before
                if let fingerprint = getFingerprint(for: peerID),
                   verifiedFingerprints.contains(fingerprint) {
                    status = .noiseVerified
                } else {
                    status = .noiseSecured
                }
            } else {
                // First time establishing - show handshaking
                status = .noiseHandshaking
            }
        case .none:
            // If we've ever established a session, show secured instead of no handshake
            if hasEverEstablishedSession {
                // Check if it was verified before
                if let fingerprint = getFingerprint(for: peerID),
                   verifiedFingerprints.contains(fingerprint) {
                    status = .noiseVerified
                } else {
                    status = .noiseSecured
                }
            } else {
                // Never established - show no handshake
                status = .noHandshake
            }
        case .failed:
            // If we've ever established a session, show secured instead of failed
            if hasEverEstablishedSession {
                // Check if it was verified before
                if let fingerprint = getFingerprint(for: peerID),
                   verifiedFingerprints.contains(fingerprint) {
                    status = .noiseVerified
                } else {
                    status = .noiseSecured
                }
            } else {
                // Never established - show failed
                status = .none
            }
        }
        
        // Cache the result
        encryptionStatusCache[peerID] = status
        
        // Only log occasionally to avoid spam
        if Int.random(in: 0..<100) == 0 {
            SecureLogger.log("getEncryptionStatus for \(peerID): sessionState=\(sessionState), stored=\(String(describing: storedStatus)), hasEverEstablished=\(hasEverEstablishedSession), final=\(status)", category: SecureLogger.security, level: .debug)
        }
        
        return status
    }
    
    // Clear caches when data changes
    private func invalidateEncryptionCache(for peerID: String? = nil) {
        if let peerID = peerID {
            encryptionStatusCache.removeValue(forKey: peerID)
        } else {
            encryptionStatusCache.removeAll()
        }
    }
    
    
    // MARK: - Message Handling
    
    private func trimMessagesIfNeeded() {
        if messages.count > maxMessages {
            let removeCount = messages.count - maxMessages
            messages.removeFirst(removeCount)
        }
    }
    
    private func trimPrivateChatMessagesIfNeeded(for peerID: String) {
        if let count = privateChats[peerID]?.count, count > maxMessages {
            let removeCount = count - maxMessages
            privateChats[peerID]?.removeFirst(removeCount)
        }
    }
    
    // MARK: - Message Management
    
    private func addMessage(_ message: BitchatMessage) {
        // Check for duplicates
        guard !messages.contains(where: { $0.id == message.id }) else { return }
        
        messages.append(message)
        messages.sort { $0.timestamp < $1.timestamp }
        trimMessagesIfNeeded()
    }
    
    private func addPrivateMessage(_ message: BitchatMessage, for peerID: String) {
        if privateChats[peerID] == nil {
            privateChats[peerID] = []
        }
        
        // Check for duplicates
        guard !(privateChats[peerID]?.contains(where: { $0.id == message.id }) ?? false) else { return }
        
        privateChats[peerID]?.append(message)
        privateChats[peerID]?.sort { $0.timestamp < $1.timestamp }
        trimPrivateChatMessagesIfNeeded(for: peerID)
    }
    
    // Update encryption status in appropriate places, not during view updates
    private func updateEncryptionStatus(for peerID: String) {
        let noiseService = meshService.getNoiseService()
        
        if noiseService.hasEstablishedSession(with: peerID) {
            if let fingerprint = getFingerprint(for: peerID) {
                if verifiedFingerprints.contains(fingerprint) {
                    peerEncryptionStatus[peerID] = .noiseVerified
                } else {
                    peerEncryptionStatus[peerID] = .noiseSecured
                }
            } else {
                // Session established but no fingerprint yet
                peerEncryptionStatus[peerID] = .noiseSecured
            }
        } else if noiseService.hasSession(with: peerID) {
            peerEncryptionStatus[peerID] = .noiseHandshaking
        } else {
            peerEncryptionStatus[peerID] = Optional.none
        }
        
        // Invalidate cache when encryption status changes
        invalidateEncryptionCache(for: peerID)
        
        // UI will update automatically via @Published properties
    }
    
    // MARK: - Fingerprint Management
    
    func showFingerprint(for peerID: String) {
        showingFingerprintFor = peerID
    }
    
    // MARK: - Peer Lookup Helpers
    
    func getPeer(byID peerID: String) -> BitchatPeer? {
        return peerIndex[peerID]
    }
    
    func getFingerprint(for peerID: String) -> String? {
        // Remove debug logging to prevent console spam during view updates
        
        // First try to get fingerprint from mesh service's peer ID rotation mapping
        if let fingerprint = meshService.getFingerprint(for: peerID) {
            return fingerprint
        }
        
        // Fallback to noise service (direct Noise session fingerprint)
        if let fingerprint = meshService.getNoiseService().getPeerFingerprint(peerID) {
            return fingerprint
        }
        
        // Last resort: check local mapping
        if let fingerprint = peerIDToPublicKeyFingerprint[peerID] {
            return fingerprint
        }
        
        return nil
    }
    
    // Helper to resolve nickname for a peer ID through various sources
    func resolveNickname(for peerID: String) -> String {
        // Guard against empty or very short peer IDs
        guard !peerID.isEmpty else {
            return "unknown"
        }
        
        // Check if this might already be a nickname (not a hex peer ID)
        // Peer IDs are hex strings, so they only contain 0-9 and a-f
        let isHexID = peerID.allSatisfy { $0.isHexDigit }
        if !isHexID {
            // If it's already a nickname, just return it
            return peerID
        }
        
        // First try direct peer nicknames from mesh service
        let peerNicknames = meshService.getPeerNicknames()
        if let nickname = peerNicknames[peerID] {
            return nickname
        }
        
        // Try to resolve through fingerprint and social identity
        if let fingerprint = getFingerprint(for: peerID) {
            if let identity = SecureIdentityStateManager.shared.getSocialIdentity(for: fingerprint) {
                // Prefer local petname if set
                if let petname = identity.localPetname {
                    return petname
                }
                // Otherwise use their claimed nickname
                return identity.claimedNickname
            }
        }
        
        // Fallback to anonymous with shortened peer ID
        // Ensure we have at least 4 characters for the prefix
        let prefixLength = min(4, peerID.count)
        let prefix = String(peerID.prefix(prefixLength))
        
        // Avoid "anonanon" by checking if ID already starts with "anon"
        if prefix.starts(with: "anon") {
            return "peer\(prefix)"
        }
        return "anon\(prefix)"
    }
    
    func getMyFingerprint() -> String {
        let fingerprint = meshService.getNoiseService().getIdentityFingerprint()
        return fingerprint
    }
    
    func verifyFingerprint(for peerID: String) {
        guard let fingerprint = getFingerprint(for: peerID) else { return }
        
        // Update secure storage with verified status
        SecureIdentityStateManager.shared.setVerified(fingerprint: fingerprint, verified: true)
        
        // Update local set for UI
        verifiedFingerprints.insert(fingerprint)
        
        // Update encryption status after verification
        updateEncryptionStatus(for: peerID)
    }
    
    func loadVerifiedFingerprints() {
        // Load verified fingerprints directly from secure storage
        verifiedFingerprints = SecureIdentityStateManager.shared.getVerifiedFingerprints()
    }
    
    private func setupNoiseCallbacks() {
        let noiseService = meshService.getNoiseService()
        
        // Set up authentication callback
        noiseService.onPeerAuthenticated = { [weak self] peerID, fingerprint in
            DispatchQueue.main.async {
                guard let self = self else { return }
                
                SecureLogger.log("ChatViewModel: Peer authenticated - \(peerID), fingerprint: \(fingerprint)", category: SecureLogger.security, level: .info)
                
                // Update encryption status
                if self.verifiedFingerprints.contains(fingerprint) {
                    self.peerEncryptionStatus[peerID] = .noiseVerified
                    SecureLogger.log("ChatViewModel: Setting encryption status to noiseVerified for \(peerID)", category: SecureLogger.security, level: .info)
                } else {
                    self.peerEncryptionStatus[peerID] = .noiseSecured
                    SecureLogger.log("ChatViewModel: Setting encryption status to noiseSecured for \(peerID)", category: SecureLogger.security, level: .info)
                }
                
                // Invalidate cache when encryption status changes
                self.invalidateEncryptionCache(for: peerID)
                
                // Schedule UI update
                // UI will update automatically
            }
        }
        
        // Set up handshake required callback
        noiseService.onHandshakeRequired = { [weak self] peerID in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.peerEncryptionStatus[peerID] = .noiseHandshaking
                
                // Invalidate cache when encryption status changes
                self.invalidateEncryptionCache(for: peerID)
                
                // Schedule UI update
                // UI will update automatically
            }
        }
    }
    
    // MARK: - BitchatDelegate Methods
    
    // MARK: - Command Handling
    
    /// Processes IRC-style commands starting with '/'.
    /// - Parameter command: The full command string including the leading slash
    /// - Note: Supports commands like /nick, /msg, /who, /slap, /clear, /help
    @MainActor
    private func handleCommand(_ command: String) {
        let parts = command.split(separator: " ")
        guard let cmd = parts.first else { return }
        
        switch cmd {
        case "/m", "/msg":
            if parts.count > 1 {
                let targetName = String(parts[1])
                // Remove @ if present
                let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName
                
                // Find peer ID for this nickname
                if let peerID = getPeerIDForNickname(nickname) {
                    startPrivateChat(with: peerID)
                    
                    // If there's a message after the nickname, send it
                    if parts.count > 2 {
                        let messageContent = parts[2...].joined(separator: " ")
                        sendPrivateMessage(messageContent, to: peerID)
                    } else {
                        let systemMessage = BitchatMessage(
                            sender: "system",
                            content: "started private chat with \(nickname)",
                            timestamp: Date(),
                            isRelay: false
                        )
                        messages.append(systemMessage)
                    }
                } else {
                    let systemMessage = BitchatMessage(
                        sender: "system",
                        content: "user '\(nickname)' not found. they may be offline or using a different nickname.",
                        timestamp: Date(),
                        isRelay: false
                    )
                    messages.append(systemMessage)
                }
            } else {
                let systemMessage = BitchatMessage(
                    sender: "system",
                    content: "usage: /m @nickname [message] or /m nickname [message]",
                    timestamp: Date(),
                    isRelay: false
                )
                messages.append(systemMessage)
            }
        case "/w":
            let peerNicknames = meshService.getPeerNicknames()
            if connectedPeers.isEmpty {
                let systemMessage = BitchatMessage(
                    sender: "system",
                    content: "no one else is online right now.",
                    timestamp: Date(),
                    isRelay: false
                )
                messages.append(systemMessage)
            } else {
                let onlineList = connectedPeers.compactMap { peerID in
                    peerNicknames[peerID]
                }.sorted().joined(separator: ", ")
                
                let systemMessage = BitchatMessage(
                    sender: "system",
                    content: "online users: \(onlineList)",
                    timestamp: Date(),
                    isRelay: false
                )
                messages.append(systemMessage)
            }
        case "/clear":
            // Clear messages based on current context
            if let peerID = selectedPrivateChatPeer {
                // Clear private chat
                privateChats[peerID]?.removeAll()
            } else {
                // Clear main messages
                messages.removeAll()
            }
        case "/hug":
            if parts.count > 1 {
                let targetName = String(parts[1])
                // Remove @ if present
                let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName
                
                // Check if target exists in connected peers
                if let targetPeerID = getPeerIDForNickname(nickname) {
                    // Create hug message
                    let hugMessage = BitchatMessage(
                        sender: "system",
                        content: "🫂 \(self.nickname) hugs \(nickname)",
                        timestamp: Date(),
                        isRelay: false,
                        isPrivate: false,
                        recipientNickname: nickname,
                        senderPeerID: meshService.myPeerID
                    )
                    
                    // Send as a regular message but it will be displayed as system message due to content
                    let hugContent = "* 🫂 \(self.nickname) hugs \(nickname) *"
                    if selectedPrivateChatPeer != nil {
                        // In private chat, send as private message
                        if let peerNickname = meshService.getPeerNicknames()[targetPeerID] {
                            meshService.sendPrivateMessage("* 🫂 \(self.nickname) hugs you *", to: targetPeerID, recipientNickname: peerNickname)
                        }
                    } else {
                        // In public chat
                        meshService.sendMessage(hugContent)
                        messages.append(hugMessage)
                    }
                } else {
                    let errorMessage = BitchatMessage(
                        sender: "system",
                        content: "cannot hug \(nickname): user not found.",
                        timestamp: Date(),
                        isRelay: false
                    )
                    messages.append(errorMessage)
                }
            } else {
                let usageMessage = BitchatMessage(
                    sender: "system",
                    content: "usage: /hug <nickname>",
                    timestamp: Date(),
                    isRelay: false
                )
                messages.append(usageMessage)
            }
            
        case "/slap":
            if parts.count > 1 {
                let targetName = String(parts[1])
                // Remove @ if present
                let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName
                
                // Check if target exists in connected peers
                if let targetPeerID = getPeerIDForNickname(nickname) {
                    // Create slap message
                    let slapMessage = BitchatMessage(
                        sender: "system",
                        content: "🐟 \(self.nickname) slaps \(nickname) around a bit with a large trout",
                        timestamp: Date(),
                        isRelay: false,
                        isPrivate: false,
                        recipientNickname: nickname,
                        senderPeerID: meshService.myPeerID
                    )
                    
                    // Send as a regular message but it will be displayed as system message due to content
                    let slapContent = "* 🐟 \(self.nickname) slaps \(nickname) around a bit with a large trout *"
                    if selectedPrivateChatPeer != nil {
                        // In private chat, send as private message
                        if let peerNickname = meshService.getPeerNicknames()[targetPeerID] {
                            meshService.sendPrivateMessage("* 🐟 \(self.nickname) slaps you around a bit with a large trout *", to: targetPeerID, recipientNickname: peerNickname)
                        }
                    } else {
                        // In public chat
                        meshService.sendMessage(slapContent)
                        messages.append(slapMessage)
                    }
                } else {
                    let errorMessage = BitchatMessage(
                        sender: "system",
                        content: "cannot slap \(nickname): user not found.",
                        timestamp: Date(),
                        isRelay: false
                    )
                    messages.append(errorMessage)
                }
            } else {
                let usageMessage = BitchatMessage(
                    sender: "system",
                    content: "usage: /slap <nickname>",
                    timestamp: Date(),
                    isRelay: false
                )
                messages.append(usageMessage)
            }
            
        case "/block":
            if parts.count > 1 {
                let targetName = String(parts[1])
                // Remove @ if present
                let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName
                
                // Find peer ID for this nickname
                if let peerID = getPeerIDForNickname(nickname) {
                    // Get fingerprint for persistent blocking
                    if let fingerprintStr = meshService.getPeerFingerprint(peerID) {
                        
                        if SecureIdentityStateManager.shared.isBlocked(fingerprint: fingerprintStr) {
                            let systemMessage = BitchatMessage(
                                sender: "system",
                                content: "\(nickname) is already blocked.",
                                timestamp: Date(),
                                isRelay: false
                            )
                            messages.append(systemMessage)
                        } else {
                            // Update or create social identity with blocked status
                            if var identity = SecureIdentityStateManager.shared.getSocialIdentity(for: fingerprintStr) {
                                identity.isBlocked = true
                                identity.isFavorite = false  // Remove from favorites if blocked
                                SecureIdentityStateManager.shared.updateSocialIdentity(identity)
                            } else {
                                let blockedIdentity = SocialIdentity(
                                    fingerprint: fingerprintStr,
                                    localPetname: nil,
                                    claimedNickname: nickname,
                                    trustLevel: .unknown,
                                    isFavorite: false,
                                    isBlocked: true,
                                    notes: nil
                                )
                                SecureIdentityStateManager.shared.updateSocialIdentity(blockedIdentity)
                            }
                            
                            // Update local sets for UI
                            blockedUsers.insert(fingerprintStr)
                            favoritePeers.remove(fingerprintStr)
                            
                            let systemMessage = BitchatMessage(
                                sender: "system",
                                content: "blocked \(nickname). you will no longer receive messages from them.",
                                timestamp: Date(),
                                isRelay: false
                            )
                            messages.append(systemMessage)
                        }
                    } else {
                        let systemMessage = BitchatMessage(
                            sender: "system",
                            content: "cannot block \(nickname): unable to verify identity.",
                            timestamp: Date(),
                            isRelay: false
                        )
                        messages.append(systemMessage)
                    }
                } else {
                    let systemMessage = BitchatMessage(
                        sender: "system",
                        content: "cannot block \(nickname): user not found.",
                        timestamp: Date(),
                        isRelay: false
                    )
                    messages.append(systemMessage)
                }
            } else {
                // List blocked users
                if blockedUsers.isEmpty {
                    let systemMessage = BitchatMessage(
                        sender: "system",
                        content: "no blocked peers.",
                        timestamp: Date(),
                        isRelay: false
                    )
                    messages.append(systemMessage)
                } else {
                    // Find nicknames for blocked users
                    var blockedNicknames: [String] = []
                    for (peerID, _) in meshService.getPeerNicknames() {
                        if let fingerprintStr = meshService.getPeerFingerprint(peerID) {
                            if blockedUsers.contains(fingerprintStr) {
                                if let nickname = meshService.getPeerNicknames()[peerID] {
                                    blockedNicknames.append(nickname)
                                }
                            }
                        }
                    }
                    
                    let blockedList = blockedNicknames.isEmpty ? "blocked peers (not currently online)" : blockedNicknames.sorted().joined(separator: ", ")
                    let systemMessage = BitchatMessage(
                        sender: "system",
                        content: "blocked peers: \(blockedList)",
                        timestamp: Date(),
                        isRelay: false
                    )
                    messages.append(systemMessage)
                }
            }
            
        case "/unblock":
            if parts.count > 1 {
                let targetName = String(parts[1])
                // Remove @ if present
                let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName
                
                // Find peer ID for this nickname
                if let peerID = getPeerIDForNickname(nickname) {
                    // Get fingerprint
                    if let fingerprintStr = meshService.getPeerFingerprint(peerID) {
                        
                        if SecureIdentityStateManager.shared.isBlocked(fingerprint: fingerprintStr) {
                            // Update social identity to unblock
                            SecureIdentityStateManager.shared.setBlocked(fingerprintStr, isBlocked: false)
                            
                            // Update local set for UI
                            blockedUsers.remove(fingerprintStr)
                            
                            let systemMessage = BitchatMessage(
                                sender: "system",
                                content: "unblocked \(nickname).",
                                timestamp: Date(),
                                isRelay: false
                            )
                            messages.append(systemMessage)
                        } else {
                            let systemMessage = BitchatMessage(
                                sender: "system",
                                content: "\(nickname) is not blocked.",
                                timestamp: Date(),
                                isRelay: false
                            )
                            messages.append(systemMessage)
                        }
                    } else {
                        let systemMessage = BitchatMessage(
                            sender: "system",
                            content: "cannot unblock \(nickname): unable to verify identity.",
                            timestamp: Date(),
                            isRelay: false
                        )
                        messages.append(systemMessage)
                    }
                } else {
                    let systemMessage = BitchatMessage(
                        sender: "system",
                        content: "cannot unblock \(nickname): user not found.",
                        timestamp: Date(),
                        isRelay: false
                    )
                    messages.append(systemMessage)
                }
            } else {
                let systemMessage = BitchatMessage(
                    sender: "system",
                    content: "usage: /unblock <nickname>",
                    timestamp: Date(),
                    isRelay: false
                )
                messages.append(systemMessage)
            }
            
        case "/fav":
            if parts.count > 1 {
                let targetName = String(parts[1])
                // Remove @ if present
                let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName
                
                // Find peer ID for this nickname
                if let peerID = getPeerIDForNickname(nickname) {
                    // Add to favorites using the Nostr integration
                    if let noisePublicKey = Data(hexString: peerID) {
                        // Get or set Nostr public key
                        let existingFavorite = FavoritesPersistenceService.shared.getFavoriteStatus(for: noisePublicKey)
                        FavoritesPersistenceService.shared.addFavorite(
                            peerNoisePublicKey: noisePublicKey,
                            peerNostrPublicKey: existingFavorite?.peerNostrPublicKey,
                            peerNickname: nickname
                        )
                        
                        // Toggle favorite in identity manager for UI
                        toggleFavorite(peerID: peerID)
                        
                        // Send favorite notification
                        Task { [weak self] in
                            try? await self?.messageRouter?.sendFavoriteNotification(to: noisePublicKey, isFavorite: true)
                        }
                        
                        let systemMessage = BitchatMessage(
                            sender: "system",
                            content: "added \(nickname) to favorites.",
                            timestamp: Date(),
                            isRelay: false
                        )
                        messages.append(systemMessage)
                    }
                } else {
                    let systemMessage = BitchatMessage(
                        sender: "system",
                        content: "can't find peer: \(nickname)",
                        timestamp: Date(),
                        isRelay: false
                    )
                    messages.append(systemMessage)
                }
            } else {
                let systemMessage = BitchatMessage(
                    sender: "system",
                    content: "usage: /fav <nickname>",
                    timestamp: Date(),
                    isRelay: false
                )
                messages.append(systemMessage)
            }
            
        case "/unfav":
            if parts.count > 1 {
                let targetName = String(parts[1])
                // Remove @ if present
                let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName
                
                // Find peer ID for this nickname
                if let peerID = getPeerIDForNickname(nickname) {
                    // Remove from favorites
                    if let noisePublicKey = Data(hexString: peerID) {
                        FavoritesPersistenceService.shared.removeFavorite(peerNoisePublicKey: noisePublicKey)
                        
                        // Toggle favorite in identity manager for UI
                        toggleFavorite(peerID: peerID)
                        
                        // Send unfavorite notification
                        Task { [weak self] in
                            try? await self?.messageRouter?.sendFavoriteNotification(to: noisePublicKey, isFavorite: false)
                        }
                        
                        let systemMessage = BitchatMessage(
                            sender: "system",
                            content: "removed \(nickname) from favorites.",
                            timestamp: Date(),
                            isRelay: false
                        )
                        messages.append(systemMessage)
                    }
                } else {
                    let systemMessage = BitchatMessage(
                        sender: "system",
                        content: "can't find peer: \(nickname)",
                        timestamp: Date(),
                        isRelay: false
                    )
                    messages.append(systemMessage)
                }
            } else {
                let systemMessage = BitchatMessage(
                    sender: "system",
                    content: "usage: /unfav <nickname>",
                    timestamp: Date(),
                    isRelay: false
                )
                messages.append(systemMessage)
            }
            
        case "/testnostr":
            let systemMessage = BitchatMessage(
                sender: "system",
                content: "testing nostr relay connectivity...",
                timestamp: Date(),
                isRelay: false
            )
            messages.append(systemMessage)
            
            Task { @MainActor in
                if let relayManager = self.nostrRelayManager {
                    // Simple connectivity test
                    relayManager.connect()
                    
                    // Wait a moment for connections
                    try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                    
                    let statusMessage = if relayManager.isConnected {
                        "nostr relays connected successfully!"
                    } else {
                        "failed to connect to nostr relays - check console for details"
                    }
                    
                    let completeMessage = BitchatMessage(
                        sender: "system",
                        content: statusMessage,
                        timestamp: Date(),
                        isRelay: false
                    )
                    self.messages.append(completeMessage)
                } else {
                    let errorMessage = BitchatMessage(
                        sender: "system",
                        content: "nostr relay manager not initialized",
                        timestamp: Date(),
                        isRelay: false
                    )
                    self.messages.append(errorMessage)
                }
            }
            
        default:
            // Unknown command
            let systemMessage = BitchatMessage(
                sender: "system",
                content: "unknown command: \(cmd).",
                timestamp: Date(),
                isRelay: false
            )
            messages.append(systemMessage)
        }
    }
    
    // MARK: - Message Reception
    
    func handleHandshakeRequest(from peerID: String, nickname: String, pendingCount: UInt8) {
        // Create a notification message
        let notificationMessage = BitchatMessage(
            sender: "system",
            content: "📨 \(nickname) wants to send you \(pendingCount) message\(pendingCount == 1 ? "" : "s"). Open the conversation to receive.",
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: false,
            recipientNickname: nil,
            senderPeerID: "system",
            mentions: nil
        )
        
        // Add to messages
        messages.append(notificationMessage)
        trimMessagesIfNeeded()
        
        // Show system notification
        if let fingerprint = getFingerprint(for: peerID) {
            let isFavorite = favoritePeers.contains(fingerprint)
            if isFavorite {
                // Send favorite notification
                NotificationService.shared.sendPrivateMessageNotification(
                    from: nickname,
                    message: "\(pendingCount) message\(pendingCount == 1 ? "" : "s") pending",
                    peerID: peerID
                )
            } else {
                // Send regular notification
                NotificationService.shared.sendMentionNotification(
                    from: nickname,
                    message: "\(pendingCount) message\(pendingCount == 1 ? "" : "s") pending. Open conversation to receive."
                )
            }
        }
    }
    
    func didReceiveMessage(_ message: BitchatMessage) {
        
        
        // Check if sender is blocked (for both private and public messages)
        if let senderPeerID = message.senderPeerID {
            if isPeerBlocked(senderPeerID) {
                // Silently ignore messages from blocked users
                return
            }
        } else if let peerID = getPeerIDForNickname(message.sender) {
            if isPeerBlocked(peerID) {
                // Silently ignore messages from blocked users
                return
            }
        }
        
        if message.isPrivate {
            // Handle private message
            
            // Use the senderPeerID from the message if available
            let senderPeerID = message.senderPeerID ?? getPeerIDForNickname(message.sender)
            
            if let peerID = senderPeerID {
                // Message from someone else
                
                // First check if we need to migrate existing messages from this sender
                let senderNickname = message.sender
                let currentFingerprint = getFingerprint(for: peerID)
                
                if privateChats[peerID] == nil || privateChats[peerID]?.isEmpty == true {
                    // Check if we have messages under a different peer ID with same fingerprint
                    var migratedMessages: [BitchatMessage] = []
                    var oldPeerIDsToRemove: [String] = []
                    
                    for (oldPeerID, messages) in privateChats {
                        if oldPeerID != peerID {
                            // Check fingerprint match first (most reliable)
                            let oldFingerprint = peerIDToPublicKeyFingerprint[oldPeerID]
                            
                            if let currentFp = currentFingerprint,
                               let oldFp = oldFingerprint,
                               currentFp == oldFp {
                                // Same peer with different ID - migrate all messages
                                migratedMessages.append(contentsOf: messages)
                                oldPeerIDsToRemove.append(oldPeerID)
                                
                                SecureLogger.log("📦 Migrating \(messages.count) messages from old peer ID \(oldPeerID) to \(peerID) for incoming message (fingerprint match)", 
                                                category: SecureLogger.session, level: .info)
                            } else if currentFingerprint == nil || oldFingerprint == nil {
                                // Fallback: Check if this chat contains messages with this sender by nickname
                                let isRelevantChat = messages.contains { msg in
                                    (msg.sender == senderNickname && msg.sender != nickname) ||
                                    (msg.sender == nickname && msg.recipientNickname == senderNickname)
                                }
                                
                                if isRelevantChat {
                                    migratedMessages.append(contentsOf: messages)
                                    oldPeerIDsToRemove.append(oldPeerID)
                                    
                                    SecureLogger.log("📦 Migrating \(messages.count) messages from old peer ID \(oldPeerID) to \(peerID) for incoming message (nickname match)", 
                                                    category: SecureLogger.session, level: .warning)
                                }
                            }
                        }
                    }
                    
                    // Remove old peer ID entries
                    for oldPeerID in oldPeerIDsToRemove {
                        privateChats.removeValue(forKey: oldPeerID)
                        unreadPrivateMessages.remove(oldPeerID)
                    }
                    
                    // Initialize with migrated messages
                    privateChats[peerID] = migratedMessages
                    trimPrivateChatMessagesIfNeeded(for: peerID)
                }
                
                if privateChats[peerID] == nil {
                    privateChats[peerID] = []
                }
                
                // Fix delivery status for incoming messages
                var messageToStore = message
                if message.sender != nickname {
                    // This is an incoming message - it should NOT have "sending" status
                    if messageToStore.deliveryStatus == nil || messageToStore.deliveryStatus == .sending {
                        // Mark it as delivered since we received it
                        messageToStore.deliveryStatus = .delivered(to: nickname, at: Date())
                    }
                }
                
                // Check if this is an action that should be converted to system message
                let isActionMessage = messageToStore.content.hasPrefix("* ") && messageToStore.content.hasSuffix(" *") &&
                                      (messageToStore.content.contains("🫂") || messageToStore.content.contains("🐟") || 
                                       messageToStore.content.contains("took a screenshot"))
                
                if isActionMessage {
                    // Convert to system message
                    messageToStore = BitchatMessage(
                        id: messageToStore.id,
                        sender: "system",
                        content: String(messageToStore.content.dropFirst(2).dropLast(2)), // Remove * * wrapper
                        timestamp: messageToStore.timestamp,
                        isRelay: messageToStore.isRelay,
                        originalSender: messageToStore.originalSender,
                        isPrivate: messageToStore.isPrivate,
                        recipientNickname: messageToStore.recipientNickname,
                        senderPeerID: messageToStore.senderPeerID,
                        mentions: messageToStore.mentions,
                        deliveryStatus: messageToStore.deliveryStatus
                    )
                }
                
                // Add private message directly
                addPrivateMessage(messageToStore, for: peerID)
                
                // Debug logging
                
                // Check if we're in a private chat with this peer's fingerprint
                // This handles reconnections with new peer IDs
                if let chatFingerprint = selectedPrivateChatFingerprint,
                   let senderFingerprint = peerIDToPublicKeyFingerprint[peerID],
                   chatFingerprint == senderFingerprint && selectedPrivateChatPeer != peerID {
                    // Update our private chat peer to the new ID
                    selectedPrivateChatPeer = peerID
                    // Schedule UI update when peer ID changes
                    // UI will update automatically
                }
                
                // Also check if we need to update the private chat peer for any reason
                updatePrivateChatPeerIfNeeded()
                
                // No special handling needed - messages are added immediately
                
                // Mark as unread if not currently viewing this chat
                if selectedPrivateChatPeer != peerID {
                    unreadPrivateMessages.insert(peerID)
                    
                } else {
                    // We're viewing this chat, make sure unread is cleared
                    unreadPrivateMessages.remove(peerID)
                    
                    // Send read receipt immediately since we're viewing the chat
                    if !sentReadReceipts.contains(message.id) {
                        let receipt = ReadReceipt(
                            originalMessageID: message.id,
                            readerID: meshService.myPeerID,
                            readerNickname: nickname
                        )
                        // Use the message's senderPeerID if available (for Nostr messages)
                        let recipientID = message.senderPeerID ?? peerID
                        
                        // For backwards compatibility, check if this might be a Nostr message
                        // by checking if the sender has a Nostr key
                        let receiptToSend = receipt
                        let recipientToSend = recipientID
                        Task { @MainActor in
                            var originalTransport: String? = nil
                            if let noiseKey = Data(hexString: recipientToSend),
                               let favoriteStatus = FavoritesPersistenceService.shared.getFavoriteStatus(for: noiseKey),
                               favoriteStatus.peerNostrPublicKey != nil,
                               self.meshService.getPeerNicknames()[recipientToSend] == nil {
                                // Peer has Nostr key and is not on mesh, likely received via Nostr
                                originalTransport = "nostr"
                            }
                            
                            self.sendReadReceipt(receiptToSend, to: recipientToSend, originalTransport: originalTransport)
                        }
                        sentReadReceipts.insert(message.id)
                    }
                    
                    // Also check if there are other unread messages from this peer
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.markPrivateMessagesAsRead(from: peerID)
                    }
                }
            } else if message.sender == nickname {
                // Our own message that was echoed back - ignore it since we already added it locally
            }
        } else {
            // Regular public message (main chat)
            
            // Check if this is an action that should be converted to system message
            let isActionMessage = message.content.hasPrefix("* ") && message.content.hasSuffix(" *") &&
                                  (message.content.contains("🫂") || message.content.contains("🐟") || 
                                   message.content.contains("took a screenshot"))
            
            let finalMessage: BitchatMessage
            if isActionMessage {
                // Convert to system message
                finalMessage = BitchatMessage(
                    sender: "system",
                    content: String(message.content.dropFirst(2).dropLast(2)), // Remove * * wrapper
                    timestamp: message.timestamp,
                    isRelay: message.isRelay,
                    originalSender: message.originalSender,
                    isPrivate: false,
                    recipientNickname: message.recipientNickname,
                    senderPeerID: message.senderPeerID,
                    mentions: message.mentions
                )
            } else {
                finalMessage = message
            }
            
            // Check if this is our own message being echoed back
            if finalMessage.sender != nickname && finalMessage.sender != "system" {
                // Skip empty or whitespace-only messages
                if !finalMessage.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    addMessage(finalMessage)
                }
            } else if finalMessage.sender != "system" {
                // Our own message - check if we already have it (by ID and content)
                let messageExists = messages.contains { existingMsg in
                    // Check by ID first
                    if existingMsg.id == finalMessage.id {
                        return true
                    }
                    // Check by content and sender with time window (within 1 second)
                    if existingMsg.content == finalMessage.content && 
                       existingMsg.sender == finalMessage.sender {
                        let timeDiff = abs(existingMsg.timestamp.timeIntervalSince(finalMessage.timestamp))
                        return timeDiff < 1.0
                    }
                    return false
                }
                if !messageExists {
                    // This is a message we sent from another device or it's missing locally
                    // Skip empty or whitespace-only messages
                    if !finalMessage.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        addMessage(finalMessage)
                    }
                }
            } else {
                // System message - check for empty content before adding
                if !finalMessage.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    addMessage(finalMessage)
                }
            }
        }
        
        // Check if we're mentioned
        let isMentioned = message.mentions?.contains(nickname) ?? false
        
        // Send notifications for mentions and private messages when app is in background
        if isMentioned && message.sender != nickname {
            NotificationService.shared.sendMentionNotification(from: message.sender, message: message.content)
        } else if message.isPrivate && message.sender != nickname {
            // Only send notification if the private chat is not currently open
            if selectedPrivateChatPeer != message.senderPeerID {
                NotificationService.shared.sendPrivateMessageNotification(from: message.sender, message: message.content, peerID: message.senderPeerID ?? "")
            }
        }
        
        #if os(iOS)
        // Haptic feedback for iOS only
        guard UIApplication.shared.applicationState == .active else {
            return
        }
        // Check if this is a hug message directed at the user
        let isHugForMe = message.content.contains("🫂") && 
                         (message.content.contains("hugs \(nickname)") ||
                          message.content.contains("hugs you"))
        
        // Check if this is a slap message directed at the user
        let isSlapForMe = message.content.contains("🐟") && 
                          (message.content.contains("slaps \(nickname) around") ||
                           message.content.contains("slaps you around"))
        
        if isHugForMe && message.sender != nickname {
            // Long warm haptic for hugs - continuous gentle vibration
            let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
            impactFeedback.prepare()
            
            // Create a warm, sustained haptic pattern
            for i in 0..<8 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.15) {
                    impactFeedback.impactOccurred()
                }
            }
            
            // Add a final stronger pulse
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                let strongFeedback = UIImpactFeedbackGenerator(style: .heavy)
                strongFeedback.prepare()
                strongFeedback.impactOccurred()
            }
        } else if isSlapForMe && message.sender != nickname {
            // Very harsh, fast, strong haptic for slaps - multiple sharp impacts
            let impactFeedback = UIImpactFeedbackGenerator(style: .heavy)
            impactFeedback.prepare()
            
            // Rapid-fire heavy impacts to simulate a hard slap
            impactFeedback.impactOccurred()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                impactFeedback.impactOccurred()
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                impactFeedback.impactOccurred()
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
                impactFeedback.impactOccurred()
            }
            
            // Final extra heavy impact
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                let finalImpact = UIImpactFeedbackGenerator(style: .heavy)
                finalImpact.prepare()
                finalImpact.impactOccurred()
            }
        } else if isMentioned && message.sender != nickname {
            // Very prominent haptic for @mentions - triple tap with heavy impact
            let impactFeedback = UIImpactFeedbackGenerator(style: .heavy)
            impactFeedback.prepare()
            impactFeedback.impactOccurred()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                impactFeedback.impactOccurred()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                impactFeedback.impactOccurred()
            }
        } else if message.isPrivate && message.sender != nickname {
            // Heavy haptic for private messages - more pronounced
            let impactFeedback = UIImpactFeedbackGenerator(style: .heavy)
            impactFeedback.prepare()
            impactFeedback.impactOccurred()
            
            // Double tap for extra emphasis
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                impactFeedback.impactOccurred()
            }
        } else if message.sender != nickname {
            // Light haptic for public messages from others
            let impactFeedback = UIImpactFeedbackGenerator(style: .light)
            impactFeedback.impactOccurred()
        }
        #endif
    }
    
    // MARK: - Peer Connection Events
    
    func didConnectToPeer(_ peerID: String) {
        isConnected = true
        
        // Register ephemeral session with identity manager
        SecureIdentityStateManager.shared.registerEphemeralSession(peerID: peerID)
        
        // Connection messages removed to reduce chat noise
    }
    
    func didDisconnectFromPeer(_ peerID: String) {
        // Remove ephemeral session from identity manager
        SecureIdentityStateManager.shared.removeEphemeralSession(peerID: peerID)
        
        // Clear sent read receipts for this peer since they'll need to be resent after reconnection
        // Only clear receipts for messages from this specific peer
        if let messages = privateChats[peerID] {
            for message in messages {
                // Remove read receipts for messages FROM this peer (not TO this peer)
                if message.senderPeerID == peerID {
                    sentReadReceipts.remove(message.id)
                }
            }
        }
        
        // Disconnection messages removed to reduce chat noise
    }
    
    func didUpdatePeerList(_ peers: [String]) {
        // UI updates must run on the main thread.
        // The delegate callback is not guaranteed to be on the main thread.
        DispatchQueue.main.async {
            self.connectedPeers = peers
            self.isConnected = !peers.isEmpty
            
            self.peerManager?.updatePeers()
            
            // Register ephemeral sessions for all connected peers
            for peerID in peers {
                SecureIdentityStateManager.shared.registerEphemeralSession(peerID: peerID)
            }
            
            // Schedule UI refresh to ensure offline favorites are shown
            // UI will update automatically
            
            // Update encryption status for all peers
            self.updateEncryptionStatusForPeers()

            // Schedule UI update for peer list change
            // UI will update automatically
            
            // Check if we need to update private chat peer after reconnection
            if self.selectedPrivateChatFingerprint != nil {
                self.updatePrivateChatPeerIfNeeded()
            }
            
            // Don't end private chat when peer temporarily disconnects
            // The fingerprint tracking will allow us to reconnect when they come back
        }
    }
    
    // MARK: - Helper Methods
    
    private func parseMentions(from content: String) -> [String] {
        let pattern = "@([a-zA-Z0-9_]+)"
        let regex = try? NSRegularExpression(pattern: pattern, options: [])
        let matches = regex?.matches(in: content, options: [], range: NSRange(location: 0, length: content.count)) ?? []
        
        var mentions: [String] = []
        let peerNicknames = meshService.getPeerNicknames()
        let allNicknames = Set(peerNicknames.values).union([nickname]) // Include self
        
        for match in matches {
            if let range = Range(match.range(at: 1), in: content) {
                let mentionedName = String(content[range])
                // Only include if it's a valid nickname
                if allNicknames.contains(mentionedName) {
                    mentions.append(mentionedName)
                }
            }
        }
        
        return Array(Set(mentions)) // Remove duplicates
    }
    
    @MainActor
    func handlePeerFavoritedUs(peerID: String, favorited: Bool, nickname: String, nostrNpub: String? = nil) {
        // Get peer's noise public key
        guard let noisePublicKey = Data(hexString: peerID) else { return }
        
        // Decode npub to hex if provided
        var nostrPublicKey: String? = nil
        if let npub = nostrNpub {
            do {
                let (hrp, data) = try Bech32.decode(npub)
                if hrp == "npub" {
                    nostrPublicKey = data.hexEncodedString()
                }
            } catch {
                SecureLogger.log("Failed to decode Nostr npub: \(error)", category: SecureLogger.session, level: .error)
            }
        }
        
        // Update favorite status in persistence service
        FavoritesPersistenceService.shared.updatePeerFavoritedUs(
            peerNoisePublicKey: noisePublicKey,
            favorited: favorited,
            peerNickname: nickname,
            peerNostrPublicKey: nostrPublicKey
        )
        
        // Update peer list to reflect the change
        peerManager?.updatePeers()
    }
    
    func isFavorite(fingerprint: String) -> Bool {
        return SecureIdentityStateManager.shared.isFavorite(fingerprint: fingerprint)
    }
    
    // MARK: - Delivery Tracking
    
    func didReceiveDeliveryAck(_ ack: DeliveryAck) {
        // Find the message and update its delivery status
        updateMessageDeliveryStatus(ack.originalMessageID, status: .delivered(to: ack.recipientNickname, at: ack.timestamp))
    }
    
    func didReceiveReadReceipt(_ receipt: ReadReceipt) {
        // Find the message and update its read status
        updateMessageDeliveryStatus(receipt.originalMessageID, status: .read(by: receipt.readerNickname, at: receipt.timestamp))
        
        // Clear delivery tracking since the message has been read
        // This prevents the timeout from marking it as failed
        DeliveryTracker.shared.clearDeliveryStatus(for: receipt.originalMessageID)
    }
    
    func didUpdateMessageDeliveryStatus(_ messageID: String, status: DeliveryStatus) {
        updateMessageDeliveryStatus(messageID, status: status)
    }
    
    private func updateMessageDeliveryStatus(_ messageID: String, status: DeliveryStatus) {
        
        // Helper function to check if we should skip this update
        func shouldSkipUpdate(currentStatus: DeliveryStatus?, newStatus: DeliveryStatus) -> Bool {
            guard let current = currentStatus else { return false }
            
            // Don't downgrade from read to delivered
            switch (current, newStatus) {
            case (.read, .delivered):
                return true
            case (.read, .sent):
                return true
            default:
                return false
            }
        }
        
        // Update in main messages
        if let index = messages.firstIndex(where: { $0.id == messageID }) {
            let currentStatus = messages[index].deliveryStatus
            if !shouldSkipUpdate(currentStatus: currentStatus, newStatus: status) {
                messages[index].deliveryStatus = status
            }
        }
        
        // Update in private chats
        var updatedPrivateChats = privateChats
        for (peerID, chatMessages) in updatedPrivateChats {
            if let index = chatMessages.firstIndex(where: { $0.id == messageID }) {
                let currentStatus = chatMessages[index].deliveryStatus
                if !shouldSkipUpdate(currentStatus: currentStatus, newStatus: status) {
                    chatMessages[index].deliveryStatus = status
                    updatedPrivateChats[peerID] = chatMessages
                }
            }
        }
        
        // Force complete reassignment to trigger SwiftUI update
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.privateChats = updatedPrivateChats
            // UI will update automatically
        }
        
    }
    
}  // End of ChatViewModel class
