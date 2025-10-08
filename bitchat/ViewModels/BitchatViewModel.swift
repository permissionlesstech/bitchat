//
// BitchatViewModel.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

///
/// # BitchatViewModel
///
/// The central business logic and state management component for BitChat.
/// Coordinates between the UI layer and the networking/encryption services.
///
/// ## Overview
/// BitchatViewModel implements the MVVM pattern, serving as the binding layer between
/// SwiftUI views and the underlying BitChat services. It manages:
/// - Message state and delivery
/// - Peer connections and presence
/// - Private chat sessions
/// - Command processing
/// - UI state like autocomplete and notifications
///
/// ## Architecture
/// The ViewModel acts as:
/// - **BitchatDelegate**: Receives messages and events from BLEService
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
/// let viewModel = BitchatViewModel()
/// viewModel.nickname = "Alice"
/// viewModel.startServices()
/// viewModel.sendMessage("Hello, mesh network!")
/// ```
///

import Foundation
import SwiftUI
import CryptoKit
import Combine
import CommonCrypto
import CoreBluetooth
#if os(iOS)
import UIKit
#endif

extension Notification: @unchecked @retroactive Sendable {}

/// Manages the application state and business logic for BitChat.
/// Acts as the primary coordinator between UI components and backend services,
/// implementing the BitchatDelegate protocol to handle network events.
class BitchatViewModel: ObservableObject, BitchatDelegate, @unchecked Sendable {
    // Precompiled regexes and detectors reused across formatting
    private enum Regexes {
        static let mention: NSRegularExpression = {
            try! NSRegularExpression(pattern: "@([\\p{L}0-9_]+(?:#[a-fA-F0-9]{4})?)", options: [])
        }()
        static let linkDetector: NSDataDetector? = {
            try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        }()
        static let simplifyHTTPURL: NSRegularExpression = {
            try! NSRegularExpression(pattern: "https?://[^\\s?#]+(?:[?#][^\\s]*)?", options: [.caseInsensitive])
        }()
    }

    // MARK: - Spam resilience: token buckets
    private struct TokenBucket {
        var capacity: Double
        var tokens: Double
        var refillPerSec: Double
        var lastRefill: Date

        mutating func allow(cost: Double = 1.0, now: Date = Date()) -> Bool {
            let dt = now.timeIntervalSince(lastRefill)
            if dt > 0 {
                tokens = min(capacity, tokens + dt * refillPerSec)
                lastRefill = now
            }
            if tokens >= cost {
                tokens -= cost
                return true
            }
            return false
        }
    }

    private var rateBucketsBySender: [String: TokenBucket] = [:]
    private var rateBucketsByContent: [String: TokenBucket] = [:]
    private let senderBucketCapacity: Double = TransportConfig.uiSenderRateBucketCapacity
    private let senderBucketRefill: Double = TransportConfig.uiSenderRateBucketRefillPerSec // tokens per second
    private let contentBucketCapacity: Double = TransportConfig.uiContentRateBucketCapacity
    private let contentBucketRefill: Double = TransportConfig.uiContentRateBucketRefillPerSec // tokens per second

    @MainActor
    private func normalizedSenderKey(for message: BitchatMessage) -> String {
        if let spid = message.senderPeerID {
            if spid.count == 16, let full = getNoiseKeyForShortID(spid)?.lowercased() {
                return "noise:" + full
            } else {
                return "mesh:" + spid.lowercased()
            }
        }
        return "name:" + message.sender.lowercased()
    }

    private func normalizedContentKey(_ content: String) -> String {
        // Lowercase, simplify URLs (strip query/fragment), collapse whitespace, bound length
        let lowered = content.lowercased()
        let ns = lowered as NSString
        let range = NSRange(location: 0, length: ns.length)
        var simplified = ""
        var last = 0
        for m in Regexes.simplifyHTTPURL.matches(in: lowered, options: [], range: range) {
            if m.range.location > last {
                simplified += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            }
            let url = ns.substring(with: m.range)
            if let q = url.firstIndex(where: { $0 == "?" || $0 == "#" }) {
                simplified += String(url[..<q])
            } else {
                simplified += url
            }
            last = m.range.location + m.range.length
        }
        if last < ns.length { simplified += ns.substring(with: NSRange(location: last, length: ns.length - last)) }
        let trimmed = simplified.trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = trimmed.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let prefix = String(collapsed.prefix(TransportConfig.contentKeyPrefixLength))
        // Fast djb2 hash
        let h = djb2(prefix)
        return String(format: "h:%016llx", h)
    }

    // Persistent recent content map (LRU) to speed near-duplicate checks
    private var contentLRUMap: [String: Date] = [:]
    private var contentLRUOrder: [String] = []
    private let contentLRUCap = TransportConfig.contentLRUCap
    private func recordContentKey(_ key: String, timestamp: Date) {
        if contentLRUMap[key] == nil { contentLRUOrder.append(key) }
        contentLRUMap[key] = timestamp
        if contentLRUOrder.count > contentLRUCap {
            let overflow = contentLRUOrder.count - contentLRUCap
            for _ in 0..<overflow {
                if let victim = contentLRUOrder.first {
                    contentLRUOrder.removeFirst()
                    contentLRUMap.removeValue(forKey: victim)
                }
            }
        }
    }
    // MARK: - Published Properties
    
    @Published var messages: [BitchatMessage] = []
    @Published var currentColorScheme: ColorScheme = .light
    private let maxMessages = TransportConfig.meshTimelineCap // Maximum messages before oldest are removed
    @Published var isConnected = false
    private var recentlySeenPeers: Set<String> = []
    
    @Published var nickname: String = "" {
        didSet {
            // Trim whitespace whenever nickname is set
            let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != nickname {
                nickname = trimmed
            }
            // Update mesh service nickname if it's initialized
            if meshService.myPeerID != "" {
                meshService.setNickname(nickname)
            }
        }
    }
    
    // MARK: - Service Delegates
    
    @MainActor private lazy var commandProcessor: CommandProcessor = CommandProcessor()
    @MainActor private lazy var messageRouter: MessageRouter =  MessageRouter(mesh: meshService, nostr: NostrTransport())
    private lazy var privateChatManager: PrivateChatManager = PrivateChatManager(meshService: meshService)
    @MainActor private lazy var unifiedPeerService: UnifiedPeerService = UnifiedPeerService(meshService: meshService)
    private let autocompleteService: AutocompleteService = AutocompleteService()
    
    // Computed properties for compatibility
    @MainActor
    var connectedPeers: Set<String> { unifiedPeerService.connectedPeerIDs }
    @Published var allPeers: [BitchatPeer] = []
    var privateChats: [String: [BitchatMessage]] { 
        get { privateChatManager.privateChats }
        set { privateChatManager.privateChats = newValue }
    }
    var selectedPrivateChatPeer: String? { 
        get { privateChatManager.selectedPeer }
        set { 
            if let peer = newValue {
                privateChatManager.startChat(with: peer)
            } else {
                privateChatManager.endChat()
            }
        }
    }
    var unreadPrivateMessages: Set<String> { 
        get { privateChatManager.unreadMessages }
        set { privateChatManager.unreadMessages = newValue }
    }
    
    /// Check if there are any unread messages (including from temporary Nostr peer IDs)
    var hasAnyUnreadMessages: Bool {
        !unreadPrivateMessages.isEmpty
    }

    /// Open the most relevant private chat when tapping the toolbar unread icon.
    /// Prefers the most recently active unread conversation, otherwise the most recent PM.
    @MainActor
    func openMostRelevantPrivateChat() {
        // Pick most recent unread by last message timestamp
        let unreadSorted = unreadPrivateMessages
            .map { ($0, privateChats[$0]?.last?.timestamp ?? Date.distantPast) }
            .sorted { $0.1 > $1.1 }
        if let target = unreadSorted.first?.0 {
            startPrivateChat(with: target)
            return
        }
        // Otherwise pick most recent private chat overall
        let recent = privateChats
            .map { (id: $0.key, ts: $0.value.last?.timestamp ?? Date.distantPast) }
            .sorted { $0.ts > $1.ts }
        if let target = recent.first?.id {
            startPrivateChat(with: target)
        }
    }
    
    //
    private var peerIDToPublicKeyFingerprint: [String: String] = [:]
    private var selectedPrivateChatFingerprint: String? = nil
    // Map stable short peer IDs (16-hex) to full Noise public key hex (64-hex) for session continuity
    private var shortIDToNoiseKey: [String: String] = [:]

    // Resolve full Noise key for a peer's short ID (used by UI header rendering)
    @MainActor
    func getNoiseKeyForShortID(_ shortPeerID: String) -> String? {
        if let mapped = shortIDToNoiseKey[shortPeerID] { return mapped }
        // Fallback: derive from active Noise session if available
        if shortPeerID.count == 16,
           let key = meshService.getNoiseService().getPeerPublicKeyData(shortPeerID) {
            let stable = key.hexEncodedString()
            shortIDToNoiseKey[shortPeerID] = stable
            return stable
        }
        return nil
    }

    // Resolve short mesh ID (16-hex) from a full Noise public key hex (64-hex)
    @MainActor
    func getShortIDForNoiseKey(_ fullNoiseKeyHex: String) -> String? {
        // Check known peers for a noise key match
        if let match = allPeers.first(where: { $0.noisePublicKey.hexEncodedString() == fullNoiseKeyHex }) {
            return match.id
        }
        // Also search cache mapping
        if let pair = shortIDToNoiseKey.first(where: { $0.value == fullNoiseKeyHex }) {
            return pair.key
        }
        return nil
    }
    private var peerIndex: [String: BitchatPeer] = [:]
    
    // MARK: - Autocomplete Properties
    
    @Published var autocompleteSuggestions: [String] = []
    @Published var showAutocomplete: Bool = false
    @Published var autocompleteRange: NSRange? = nil
    @Published var selectedAutocompleteIndex: Int = 0
    
    // Temporary property to fix compilation
    @Published var showPasswordPrompt = false
    
    // MARK: - Services and Storage
    
    lazy var meshService: Transport = BLEService()
    // PeerManager replaced by UnifiedPeerService
    private let userDefaults = UserDefaults(suiteName: "group.chat.bitchat").unsafelyUnwrapped
    private let nicknameKey = "bitchat.nickname"
    // MARK: - Caches
    
    // Caches for expensive computations
    private var encryptionStatusCache: [String: EncryptionStatus] = [:] // key: peerID
    
    // MARK: - Social Features (Delegated to PeerStateManager)
    
    @MainActor
    var favoritePeers: Set<String> { unifiedPeerService.favoritePeers }
    @MainActor
    var blockedUsers: Set<String> { unifiedPeerService.blockedUsers }
    
    // MARK: - Encryption and Security
    
    // Noise Protocol encryption status
    @Published var peerEncryptionStatus: [String: EncryptionStatus] = [:]  // peerID -> encryption status
    @Published var verifiedFingerprints: Set<String> = []  // Set of verified fingerprints
    @Published var showingFingerprintFor: String? = nil  // Currently showing fingerprint sheet for peer
    
    // Bluetooth state management
    @Published var showBluetoothAlert = false
    @Published var bluetoothAlertMessage = ""
    
    // Messages are naturally ephemeral - no persistent storage
    // Persist mesh public timeline across channel switches
    private var meshTimeline: [BitchatMessage] = []
    private let meshTimelineCap = TransportConfig.meshTimelineCap
    // Channel activity tracking for background nudges
    private var lastPublicActivityAt: [String: Date] = [:]   // channelKey -> last activity time
    
    // MARK: - Message Delivery Tracking
    
    // Delivery tracking
    private var cancellables = Set<AnyCancellable>()

    // MARK: - QR Verification (pending state)
    private struct PendingVerification {
        let noiseKeyHex: String
        let signKeyHex: String
        let nonceA: Data
        let startedAt: Date
        var sent: Bool
    }
    private var pendingQRVerifications: [String: PendingVerification] = [:] // peerID -> pending
    // Last handled challenge nonce per peer to avoid duplicate responses
    private var lastVerifyNonceByPeer: [String: Data] = [:]
    // Track when we last received a verify challenge from a peer (fingerprint-keyed)
    private var lastInboundVerifyChallengeAt: [String: Date] = [:] // key: fingerprint
    // Throttle mutual verification toasts per fingerprint
    private var lastMutualToastAt: [String: Date] = [:] // key: fingerprint

    // MARK: - Public message batching (UI perf)
    // Buffer incoming public messages and flush in small batches to reduce UI invalidations
    private var publicBuffer: [BitchatMessage] = []
    private var publicBufferTimer: Timer? = nil
    private let basePublicFlushInterval: TimeInterval = TransportConfig.basePublicFlushInterval
    private var dynamicPublicFlushInterval: TimeInterval = TransportConfig.basePublicFlushInterval
    private var recentBatchSizes: [Int] = []
    @Published private(set) var isBatchingPublic: Bool = false
    private let lateInsertThreshold: TimeInterval = TransportConfig.uiLateInsertThreshold
    
    // Track sent read receipts to avoid duplicates (persisted across launches)
    // Note: Persistence happens automatically in didSet, no lifecycle observers needed
    private var sentReadReceipts: Set<String> = [] {  // messageID set
        didSet {
            // Only persist if there are changes
            guard oldValue != sentReadReceipts else { return }
            
            // Persist to UserDefaults whenever it changes (no manual synchronize/verify re-read)
            if let data = try? JSONEncoder().encode(Array(sentReadReceipts)) {
                userDefaults.set(data, forKey: "sentReadReceipts")
            } else {
                SecureLogger.log("❌ Failed to encode read receipts for persistence",
                                category: SecureLogger.session, level: .error)
            }
        }
    }

    // Throttle verification response toasts per peer to avoid spam
    private var lastVerifyToastAt: [String: Date] = [:]
    
    // Track processed Nostr ACKs to avoid duplicate processing
    private var processedNostrAcks: Set<String> = []  // "messageId:ackType:senderPubkey" format
    
    // Track app startup phase to prevent marking old messages as unread
    private var isStartupPhase = true
    
    // MARK: - Initialization
    
    @MainActor
    func startServices() {
        VerificationService.shared.configure(with: meshService.getNoiseService())
        
        if meshService.delegate != nil {
            return
        }
        
        // Load persisted read receipts
        if let data = userDefaults.data(forKey: "sentReadReceipts"),
           let receipts = try? JSONDecoder().decode([String].self, from: data) {
            self.sentReadReceipts = Set(receipts)
            // Successfully loaded read receipts
        } else {
            // No persisted read receipts found
        }
        
        // Initialize services
        self.privateChatManager.messageRouter = self.messageRouter
        self.unifiedPeerService.messageRouter = self.messageRouter
        
        // Wire up dependencies
        self.commandProcessor.chatViewModel = self
        self.commandProcessor.meshService = meshService
        
        loadNickname()
        loadVerifiedFingerprints()
        meshService.delegate = self
        
        // Log startup info
        
        // Log fingerprint after a delay to ensure encryption service is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + TransportConfig.uiStartupInitialDelaySeconds) { [weak self] in
            if let self = self {
                _ = self.getMyFingerprint()
            }
        }
        
        // Set nickname before starting services
        meshService.setNickname(nickname)
        
        // Start mesh service immediately
        meshService.startServices()
        
        // Initialize Nostr services
        Task { @MainActor in
            // Small delay to ensure read receipts are fully loaded
            // This prevents race conditions where messages arrive before initialization completes
            try? await Task.sleep(nanoseconds: TransportConfig.uiStartupShortSleepNs) // 0.2 seconds
            
            // Attempt to flush any queued outbox after Nostr comes online
            messageRouter.flushAllOutbox()
            
            // End startup phase after 2 seconds
            // During startup phase, we:
            // 1. Skip cleanup of read receipts
            // 2. Only block OLD messages from being marked as unread
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(TransportConfig.uiStartupPhaseDurationSeconds * 1_000_000_000)) // 2 seconds
                self.isStartupPhase = false
            }
            
            // Bind unified peer service's peer list to our published property
            let cancellable = unifiedPeerService.$peers
                .receive(on: DispatchQueue.main)
                .sink { [weak self] peers in
                    guard let self = self else { return }
                    // Update peers directly; @Published drives UI updates
                    self.allPeers = peers
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
                    self.peerIndex = uniquePeers
                    // Schedule UI update if peers changed
                    if peers.count > 0 || self.allPeers.count > 0 {
                        // UI will update automatically
                    }
                    
                    // Update private chat peer ID if needed when peers change
                    if self.selectedPrivateChatFingerprint != nil {
                        self.updatePrivateChatPeerIfNeeded()
                    }
                }
            
            self.cancellables.insert(cancellable)
        }
        
        Task(priority: .low) {
            await NotificationService.shared.requestAuthorization()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self = self else { return }
                if self.connectedPeers.isEmpty && self.messages.isEmpty {
                    addPublicSystemMessage("Get people around you to download Meet and Eat to chat with them here!")
                }
            }
        }
        
        // Set up Noise encryption callbacks
        setupNoiseCallbacks()
        
        // Listen for favorite status changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFavoriteStatusChanged),
            name: .favoriteStatusChanged,
            object: nil
        )
        
        // When app becomes active, send read receipts for visible messages
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }
    
    // MARK: - Deinitialization
    
    deinit {
        // No need to force UserDefaults synchronization
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
        // Persist nickname; no need to force synchronize
        
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
    
    // MARK: - Blocked Users Management (Delegated to PeerStateManager)
    
    
    /// Check if a peer has unread messages, including messages stored under stable Noise keys and temporary Nostr peer IDs
    @MainActor
    func hasUnreadMessages(for peerID: String) -> Bool {
        // First check direct unread messages
        if unreadPrivateMessages.contains(peerID) {
            return true
        }
        
        // Check if messages are stored under the stable Noise key hex
        if let peer = unifiedPeerService.getPeer(by: peerID) {
            let noiseKeyHex = peer.noisePublicKey.hexEncodedString()
            if unreadPrivateMessages.contains(noiseKeyHex) {
                return true
            }
        }
        
        return false
    }
    
    @MainActor
    func toggleFavorite(peerID: String) {
        // Distinguish between ephemeral peer IDs (16 hex chars) and Noise public keys (64 hex chars)
        // Ephemeral peer IDs are 8 bytes = 16 hex characters
        // Noise public keys are 32 bytes = 64 hex characters
        
        if peerID.count == 64, let noisePublicKey = Data(hexString: peerID) {
            // This is a stable Noise key hex (used in private chats)
            // Find the ephemeral peer ID for this Noise key
            let ephemeralPeerID = unifiedPeerService.peers.first { peer in
                peer.noisePublicKey == noisePublicKey
            }?.id
            
            if let ephemeralID = ephemeralPeerID {
                // Found the ephemeral peer, use normal toggle
                unifiedPeerService.toggleFavorite(ephemeralID)
                // Also trigger UI update
                objectWillChange.send()
            } else {
                // No ephemeral peer found, directly toggle via FavoritesPersistenceService
                let currentStatus = FavoritesPersistenceService.shared.getFavoriteStatus(for: noisePublicKey)
                let wasFavorite = currentStatus?.isFavorite ?? false
                
                if wasFavorite {
                    // Remove favorite
                    FavoritesPersistenceService.shared.removeFavorite(peerNoisePublicKey: noisePublicKey)
                } else {
                    // Add favorite - get nickname from current status or from private chat messages
                    var nickname = currentStatus?.peerNickname
                    
                    // If no nickname in status, try to get from private chat messages
                    if nickname == nil, let messages = privateChats[peerID], !messages.isEmpty {
                        // Get the nickname from the first message where this peer was the sender
                        nickname = messages.first { $0.senderPeerID == peerID }?.sender
                    }
                    
                    let finalNickname = nickname ?? "Unknown"
                    let nostrKey = currentStatus?.peerNostrPublicKey ?? NostrIdentityBridge.getNostrPublicKey(for: noisePublicKey)
                    
                    FavoritesPersistenceService.shared.addFavorite(
                        peerNoisePublicKey: noisePublicKey,
                        peerNostrPublicKey: nostrKey,
                        peerNickname: finalNickname
                    )
                }
                
                // Trigger UI update
                objectWillChange.send()
                
                // Send favorite notification via Nostr if we're mutual favorites
                if !wasFavorite && currentStatus?.theyFavoritedUs == true {
                    // We just favorited them and they already favorite us - send via Nostr
                    sendFavoriteNotificationViaNostr(noisePublicKey: noisePublicKey, isFavorite: true)
                } else if wasFavorite {
                    // We're unfavoriting - send via Nostr if they still favorite us
                    sendFavoriteNotificationViaNostr(noisePublicKey: noisePublicKey, isFavorite: false)
                }
            }
        } else {
            // This is an ephemeral peer ID (16 hex chars), use normal toggle
            unifiedPeerService.toggleFavorite(peerID)
            // Trigger UI update
            objectWillChange.send()
        }
    }
    
    @MainActor
    func isFavorite(peerID: String) -> Bool {
        // Distinguish between ephemeral peer IDs (16 hex chars) and Noise public keys (64 hex chars)
        if peerID.count == 64, let noisePublicKey = Data(hexString: peerID) {
            // This is a Noise public key
            if let status = FavoritesPersistenceService.shared.getFavoriteStatus(for: noisePublicKey) {
                return status.isFavorite
            }
        } else {
            // This is an ephemeral peer ID - check with UnifiedPeerService
            if let peer = unifiedPeerService.getPeer(by: peerID) {
                return peer.isFavorite
            }
        }
        
        return false
    }
    
    // MARK: - Public Key and Identity Management
    @MainActor
    func isPeerBlocked(_ peerID: String) -> Bool {
        return unifiedPeerService.isBlocked(peerID)
    }
    
    // Helper method to find current peer ID for a fingerprint
    @MainActor
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
    @MainActor
    private func updatePrivateChatPeerIfNeeded() {
        guard let chatFingerprint = selectedPrivateChatFingerprint else { return }
        
        // Find current peer ID for the fingerprint
        if let currentPeerID = getCurrentPeerIDForFingerprint(chatFingerprint) {
            // Update the selected peer if it's different
            if let oldPeerID = selectedPrivateChatPeer, oldPeerID != currentPeerID {
                
                // Migrate messages from old peer ID to new peer ID
                if let oldMessages = privateChats[oldPeerID] {
                    var chats = privateChats
                    if chats[currentPeerID] == nil {
                        chats[currentPeerID] = []
                    }
                    chats[currentPeerID]?.append(contentsOf: oldMessages)
                    // Sort by timestamp
                    chats[currentPeerID]?.sort { $0.timestamp < $1.timestamp }
                    
                    // Remove duplicates
                    var seen = Set<String>()
                    chats[currentPeerID] = chats[currentPeerID]?.filter { msg in
                        if seen.contains(msg.id) {
                            return false
                        }
                        seen.insert(msg.id)
                        return true
                    }
                    
                    // Remove old peer ID
                    chats.removeValue(forKey: oldPeerID)
                    
                    // Update all at once
                    privateChats = chats  // Trigger setter
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
                    // UnifiedPeerService updates automatically via subscriptions
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
        // Ignore messages that are empty or whitespace-only to prevent blank lines
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
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
            // Parse mentions from the content (use original content for user intent)
            let mentions = parseMentions(from: content)
            
            // Add message to local display
            let displaySender = nickname
            let localSenderPeerID = meshService.myPeerID

            let message = BitchatMessage(
                sender: displaySender,
                content: trimmed,
                timestamp: Date(),
                isRelay: false,
                originalSender: nil,
                isPrivate: false,
                recipientNickname: nil,
                senderPeerID: localSenderPeerID,
                mentions: mentions.isEmpty ? nil : mentions
            )
            
            // Add to main messages immediately for user feedback
            messages.append(message)
            // Update content LRU for near-dup detection
            let ckey = normalizedContentKey(message.content)
            recordContentKey(ckey, timestamp: message.timestamp)
            // Persist to channel-specific timelines
            meshTimeline.append(message)
            trimMeshTimelineIfNeeded()
            trimMessagesIfNeeded()
            
            // Force immediate UI update for user's own messages
            objectWillChange.send()

            // Update channel activity time on send
            lastPublicActivityAt["mesh"] = Date()
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

        // Check if blocked
        if unifiedPeerService.isBlocked(peerID) {
            let nickname = meshService.peerNickname(peerID: peerID) ?? "user"
            addSystemMessage("cannot send message to \(nickname): user is blocked.")
            return
        }
        
        // Determine routing method and recipient nickname
        guard let noiseKey = Data(hexString: peerID) else { return }
        let isConnected = meshService.isPeerConnected(peerID)
        let isReachable = meshService.isPeerReachable(peerID)
        let favoriteStatus = FavoritesPersistenceService.shared.getFavoriteStatus(for: noiseKey)
        let isMutualFavorite = favoriteStatus?.isMutual ?? false
        let hasNostrKey = favoriteStatus?.peerNostrPublicKey != nil
        
        // Get nickname from various sources
        var recipientNickname = meshService.peerNickname(peerID: peerID)
        if recipientNickname == nil && favoriteStatus != nil {
            recipientNickname = favoriteStatus?.peerNickname
        }
        recipientNickname = recipientNickname ?? "user"
        
        // Generate message ID
        let messageID = UUID().uuidString
        
        // Create the message object
        let message = BitchatMessage(
            id: messageID,
            sender: nickname,
            content: content,
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: true,
            recipientNickname: recipientNickname,
            senderPeerID: meshService.myPeerID,
            mentions: nil,
            deliveryStatus: .sending
        )
        
        // Add to local chat
        if privateChats[peerID] == nil {
            privateChats[peerID] = []
        }
        privateChats[peerID]?.append(message)
        
        // Trigger UI update for sent message
        objectWillChange.send()
        
        // Send via appropriate transport (BLE if connected/reachable, else Nostr when possible)
        if isConnected || isReachable || (isMutualFavorite && hasNostrKey) {
            messageRouter.sendPrivate(content, to: peerID, recipientNickname: recipientNickname ?? "user", messageID: messageID)
            // Optimistically mark as sent for both transports; delivery/read will update subsequently
            if let idx = privateChats[peerID]?.firstIndex(where: { $0.id == messageID }) {
                privateChats[peerID]?[idx].deliveryStatus = .sent
            }
        } else {
            // Update delivery status to failed
            if let index = privateChats[peerID]?.firstIndex(where: { $0.id == messageID }) {
                privateChats[peerID]?[index].deliveryStatus = .failed(reason: "Peer not reachable")
            }
            addSystemMessage("Cannot send message to \(recipientNickname ?? "user") - peer is not reachable via mesh or Nostr.")
        }
    }

    /// Add a local system message to a private chat (no network send)
    @MainActor
    func addLocalPrivateSystemMessage(_ content: String, to peerID: String) {
        let systemMessage = BitchatMessage(
            sender: "system",
            content: content,
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: true,
            recipientNickname: meshService.peerNickname(peerID: peerID),
            senderPeerID: meshService.myPeerID
        )
        if privateChats[peerID] == nil { privateChats[peerID] = [] }
        privateChats[peerID]?.append(systemMessage)
        objectWillChange.send()
    }
    
    // MARK: - Bluetooth State Management
    
    /// Updates the Bluetooth state and shows appropriate alerts
    /// - Parameter state: The current Bluetooth manager state
//    @MainActor
    func updateBluetoothState(_ state: CBManagerState) {
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
            return
        }
        
        let peerNickname = meshService.peerNickname(peerID: peerID) ?? "unknown"
        
        // Check if the peer is blocked
        if unifiedPeerService.isBlocked(peerID) {
            addSystemMessage("cannot start chat with \(peerNickname): user is blocked.")
            return
        }
        
        // Check mutual favorites for offline messaging
        if let peer = unifiedPeerService.getPeer(by: peerID),
           peer.isFavorite && !peer.theyFavoritedUs && !peer.isConnected {
            addSystemMessage("cannot start chat with \(peerNickname): mutual favorite required for offline messaging.")
            return
        }
        
        // Consolidate messages from stable Noise key if needed
        // This ensures Nostr messages appear when opening a chat with an ephemeral peer ID
        if let peer = unifiedPeerService.getPeer(by: peerID) {
            let noiseKeyHex = peer.noisePublicKey.hexEncodedString()
            
            // If we have messages stored under the stable Noise key hex but not under the ephemeral ID,
            // or if we need to merge them, do so now
            if noiseKeyHex != peerID {
                if let nostrMessages = privateChats[noiseKeyHex], !nostrMessages.isEmpty {
                    // Check if there are ACTUALLY unread messages (not just the unread flag)
                    // Only transfer unread status if there are recent unread messages
                    var hasActualUnreadMessages = false
                    
                    // Merge messages from stable key into ephemeral peer ID storage
                    if privateChats[peerID] == nil {
                        privateChats[peerID] = []
                    }
                    
                    // Add any messages that aren't already in the ephemeral storage
                    let existingMessageIds = Set(privateChats[peerID]?.map { $0.id } ?? [])
                    for message in nostrMessages {
                        if !existingMessageIds.contains(message.id) {
                            // Create updated message with correct senderPeerID
                            // This is crucial for read receipts to work correctly
                            let updatedMessage = BitchatMessage(
                                id: message.id,
                                sender: message.sender,
                                content: message.content,
                                timestamp: message.timestamp,
                                isRelay: message.isRelay,
                                originalSender: message.originalSender,
                                isPrivate: message.isPrivate,
                                recipientNickname: message.recipientNickname,
                                senderPeerID: message.senderPeerID == meshService.myPeerID ? meshService.myPeerID : peerID,  // Update peer ID if it's from them
                                mentions: message.mentions,
                                deliveryStatus: message.deliveryStatus
                            )
                            privateChats[peerID]?.append(updatedMessage)
                            
                            // Check if this is an actually unread message
                            // Only mark as unread if:
                            // 1. Not a message we sent
                            // 2. Message is recent (< 60s old)
                            // Never mark old messages as unread during consolidation
                            if message.senderPeerID != meshService.myPeerID {
                                let messageAge = Date().timeIntervalSince(message.timestamp)
                                if messageAge < 60 && !sentReadReceipts.contains(message.id) {
                                    hasActualUnreadMessages = true
                                }
                            }
                        }
                    }
                    
                    // Sort by timestamp
                    privateChats[peerID]?.sort { $0.timestamp < $1.timestamp }
                    
                    // Only transfer unread status if there are actual recent unread messages
                    if hasActualUnreadMessages {
                        unreadPrivateMessages.insert(peerID)
                    } else if unreadPrivateMessages.contains(noiseKeyHex) {
                        // Remove incorrect unread status from stable key
                        unreadPrivateMessages.remove(noiseKeyHex)
                    }
                    
                    // Clean up the stable key storage to avoid duplication
                    privateChats.removeValue(forKey: noiseKeyHex)
                    
                    // Consolidated Nostr messages from stable key
                }
            }
        }

        
        // Trigger handshake if needed (mesh peers only). Skip for Nostr geohash conv keys.
        let sessionState = meshService.getNoiseSessionState(for: peerID)
        switch sessionState {
        case .none, .failed:
            meshService.triggerHandshake(with: peerID)
        default:
            break
        }
        
        // Delegate to private chat manager but add already-acked messages first
        // This prevents duplicate read receipts
        // IMPORTANT: Only add messages WE sent to sentReadReceipts, not messages we received
        if let messages = privateChats[peerID] {
            for message in messages {
                // Only track read receipts for messages WE sent (not received messages)
                if message.sender == nickname {
                    // Check if message has been read or delivered
                    if let status = message.deliveryStatus {
                        switch status {
                        case .read, .delivered:
                            sentReadReceipts.insert(message.id)
                            privateChatManager.sentReadReceipts.insert(message.id)
                        default:
                            break
                        }
                    }
                }
            }
        }
        
        privateChatManager.startChat(with: peerID)
        
        // Also mark messages as read for Nostr ACKs
        // This ensures read receipts are sent even for consolidated messages
        markPrivateMessagesAsRead(from: peerID)
    }
    
    func endPrivateChat() {
        selectedPrivateChatPeer = nil
        selectedPrivateChatFingerprint = nil
    }
    
    // MARK: - Nostr Message Handling
    
    @objc private func handleDeliveryAcknowledgment(_ notification: Notification) {
        guard let messageId = notification.userInfo?["messageId"] as? String else { return }
        
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
                        var chats = privateChats
                        chats[newPeerID] = messages
                        chats.removeValue(forKey: oldPeerID)
                        privateChats = chats  // Trigger setter
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
                        var chats = privateChats
                        chats[newPeerID] = messages
                        chats.removeValue(forKey: oldPeerID)
                        privateChats = chats  // Trigger setter
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
                if let nickname = meshService.peerNickname(peerID: peerID) {
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
            // UnifiedPeerService updates automatically via subscriptions
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
            DispatchQueue.main.asyncAfter(deadline: .now() + TransportConfig.uiAnimationMediumSeconds) {
                self.markPrivateMessagesAsRead(from: peerID)
            }
        }
    }
    
    @objc func applicationWillTerminate() {
        // Send leave message to all peers
        meshService.stopServices()
        
        // Force save any pending identity changes (verifications, favorites, etc)
        SecureIdentityStateManager.shared.forceSave()
        
        // Verify identity key is still there
        _ = KeychainManager.shared.verifyIdentityKeyExists()
        
        // No need to force synchronize here
        
        // Verify identity key after save
        _ = KeychainManager.shared.verifyIdentityKeyExists()
    }
    
    @MainActor
    private func sendReadReceipt(_ receipt: ReadReceipt, to peerID: String, originalTransport: String? = nil) {
        // First, try to resolve the current peer ID in case they reconnected with a new ID
        var actualPeerID = peerID
        
        // Check if this peer ID exists in current nicknames
        if meshService.peerNickname(peerID: peerID) == nil {
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
        
        // If this originated over Nostr, skip (handled by Nostr code paths)
        if originalTransport == "nostr" {
            return
        }
        // Use router to decide (mesh if reachable, else Nostr if available)
        messageRouter.sendReadReceipt(receipt, to: actualPeerID)
    }
    
    @MainActor
    func markPrivateMessagesAsRead(from peerID: String) {
        privateChatManager.markAsRead(from: peerID)
        
        // Get the peer's Noise key to check for Nostr messages
        var noiseKeyHex: String? = nil
        var peerNostrPubkey: String? = nil
        
        // First check if peerID is already a hex Noise key
        if let noiseKey = Data(hexString: peerID),
           let favoriteStatus = FavoritesPersistenceService.shared.getFavoriteStatus(for: noiseKey) {
            noiseKeyHex = peerID
            peerNostrPubkey = favoriteStatus.peerNostrPublicKey
        }
        // Otherwise get the Noise key from the peer info
        else if let peer = unifiedPeerService.getPeer(by: peerID) {
            noiseKeyHex = peer.noisePublicKey.hexEncodedString()
            let favoriteStatus = FavoritesPersistenceService.shared.getFavoriteStatus(for: peer.noisePublicKey)
            peerNostrPubkey = favoriteStatus?.peerNostrPublicKey
            
            // Also remove unread status from the stable Noise key if it exists
            if let keyHex = noiseKeyHex, unreadPrivateMessages.contains(keyHex) {
                unreadPrivateMessages.remove(keyHex)
            }
        }
        
        // Send Nostr read ACKs if peer has Nostr capability
        if peerNostrPubkey != nil {
            // Check messages under both ephemeral peer ID and stable Noise key
            let messagesToAck = getPrivateChatMessages(for: peerID)
            
            for message in messagesToAck {
                // Only send read ACKs for messages from the peer (not our own)
                // Check both the ephemeral peer ID and stable Noise key as sender
                if (message.senderPeerID == peerID || message.senderPeerID == noiseKeyHex) && !message.isRelay {
                    // Skip if we already sent an ACK for this message
                    if !sentReadReceipts.contains(message.id) {
                        // Use stable Noise key hex if available; else fall back to peerID
                        let recipPeer = (Data(hexString: peerID) != nil) ? peerID : (unifiedPeerService.getPeer(by: peerID)?.noisePublicKey.hexEncodedString() ?? peerID)
                        let receipt = ReadReceipt(originalMessageID: message.id, readerID: meshService.myPeerID, readerNickname: nickname)
                        messageRouter.sendReadReceipt(receipt, to: recipPeer)
                        sentReadReceipts.insert(message.id)
                    }
                }
            }
        }
    }
    
    @MainActor
    func getPrivateChatMessages(for peerID: String) -> [BitchatMessage] {
        var combined: [BitchatMessage] = []

        // Gather messages under the ephemeral peer ID
        if let ephemeralMessages = privateChats[peerID] {
            combined.append(contentsOf: ephemeralMessages)
        }

        // Also include messages stored under the stable Noise key (Nostr path)
        if let peer = unifiedPeerService.getPeer(by: peerID) {
            let noiseKeyHex = peer.noisePublicKey.hexEncodedString()
            if noiseKeyHex != peerID, let nostrMessages = privateChats[noiseKeyHex] {
                combined.append(contentsOf: nostrMessages)
            }
        }

        // De-duplicate by message ID: keep the item with the most advanced delivery status.
        // This prevents duplicate IDs causing LazyVStack warnings and blank rows, and ensures
        // we show the row whose status has already progressed to delivered/read.
        func statusRank(_ s: DeliveryStatus?) -> Int {
            guard let s = s else { return 0 }
            switch s {
            case .failed: return 1
            case .sending: return 2
            case .sent: return 3
            case .partiallyDelivered: return 4
            case .delivered: return 5
            case .read: return 6
            }
        }

        var bestByID: [String: BitchatMessage] = [:]
        for msg in combined {
            if let existing = bestByID[msg.id] {
                let lhs = statusRank(existing.deliveryStatus)
                let rhs = statusRank(msg.deliveryStatus)
                if rhs > lhs || (rhs == lhs && msg.timestamp > existing.timestamp) {
                    bestByID[msg.id] = msg
                }
            } else {
                bestByID[msg.id] = msg
            }
        }

        // Return chronologically sorted, de-duplicated list
        return bestByID.values.sorted { $0.timestamp < $1.timestamp }
    }
    
    @MainActor
    func getPeerIDForNickname(_ nickname: String) -> String? {
        // Fallback to mesh nickname resolution
        return unifiedPeerService.getPeerID(for: nickname)
    }
    
    
    // MARK: - Emergency Functions
    
    // PANIC: Emergency data clearing for activist safety
    @MainActor
    func panicClearAllData() {
        // Messages are processed immediately - nothing to flush
        
        // Clear all messages
        messages.removeAll()
        privateChatManager.privateChats.removeAll()
        privateChatManager.unreadMessages.removeAll()
        
        // Delete all keychain data (including Noise and Nostr keys)
        _ = KeychainManager.shared.deleteAllKeychainData()
        
        // Clear UserDefaults identity data
        userDefaults.removeObject(forKey: "bitchat.noiseIdentityKey")
        userDefaults.removeObject(forKey: "bitchat.messageRetentionKey")
        
        // Clear verified fingerprints
        verifiedFingerprints.removeAll()
        // Verified fingerprints are cleared when identity data is cleared below
        
        // Reset nickname to anonymous
        nickname = "anon\(Int.random(in: 1000...9999))"
        saveNickname()
        
        // Clear favorites and peer mappings
        // Clear through SecureIdentityStateManager instead of directly
        SecureIdentityStateManager.shared.clearAllIdentityData()
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
        processedNostrAcks.removeAll()
        
        // Clear all caches
        invalidateEncryptionCache()
        
        // Clear Nostr identity associations
        NostrIdentityBridge.clearAllAssociations()
        
        // Disconnect from all peers and clear persistent identity
        // This will force creation of a new identity (new fingerprint) on next launch
        meshService.emergencyDisconnectAll()
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
        // Build candidate list based on active channel
        let peerCandidates: [String] = {
            let values = meshService.getPeerNicknames().values
            return Array(values.filter { $0 != meshService.myNickname })
        }()

        let (suggestions, range) = autocompleteService.getSuggestions(
            for: text,
            peers: peerCandidates,
            cursorPosition: cursorPosition
        )
        
        if !suggestions.isEmpty {
            autocompleteSuggestions = suggestions
            autocompleteRange = range
            showAutocomplete = true
            selectedAutocompleteIndex = 0
        } else {
            autocompleteSuggestions = []
            autocompleteRange = nil
            showAutocomplete = false
            selectedAutocompleteIndex = 0
        }
    }
    
    func completeNickname(_ nickname: String, in text: inout String) -> Int {
        guard let range = autocompleteRange else { return text.count }
        
        text = autocompleteService.applySuggestion(nickname, to: text, range: range)
        
        // Hide autocomplete
        showAutocomplete = false
        autocompleteSuggestions = []
        autocompleteRange = nil
        selectedAutocompleteIndex = 0
        
        // Return new cursor position
        return range.location + nickname.count + (nickname.hasPrefix("@") ? 1 : 2)
    }
    
    // MARK: - Message Formatting
    @MainActor
    func formatMessageAsText(_ message: BitchatMessage, colorScheme: ColorScheme) -> AttributedString {
        // Determine if this message was sent by self (mesh, geo, or DM)
        let isSelf: Bool = {
            if let spid = message.senderPeerID {
                return spid == meshService.myPeerID
            }
            // Fallback by nickname
            if message.sender == nickname { return true }
            if message.sender.hasPrefix(nickname + "#") { return true }
            return false
        }()
        // Check cache first (key includes dark mode + self flag)
        let isDark = colorScheme == .dark
        if let cachedText = message.getCachedFormattedText(isDark: isDark, isSelf: isSelf) {
            return cachedText
        }
        
        // Not cached, format the message
        var result = AttributedString()
        
        let baseColor: Color = isSelf ? .orange : peerColor(for: message, isDark: isDark)
        
        if message.sender != "system" {
            // Sender (at the beginning) with light-gray suffix styling if present
            let (baseName, suffix) = splitSuffix(from: message.sender)
            var senderStyle = AttributeContainer()
            // Use consistent color for all senders
            senderStyle.foregroundColor = baseColor
            // Bold the user's own nickname
            let fontWeight: Font.Weight = isSelf ? .bold : .medium
            senderStyle.font = .system(size: 14, weight: fontWeight, design: .monospaced)
            // Make sender clickable: encode senderPeerID into a custom URL
            if let spid = message.senderPeerID, let url = URL(string: "bitchat://user/\(spid.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? spid)") {
                senderStyle.link = url
            }

            // Prefix "<@"
            result.append(AttributedString("<@").mergingAttributes(senderStyle))
            // Base name
            result.append(AttributedString(baseName).mergingAttributes(senderStyle))
            // Optional suffix in lighter variant of the base color (green or orange for self)
            if !suffix.isEmpty {
                var suffixStyle = senderStyle
                suffixStyle.foregroundColor = baseColor.opacity(0.6)
                result.append(AttributedString(suffix).mergingAttributes(suffixStyle))
            }
            // Suffix "> "
            result.append(AttributedString("> ").mergingAttributes(senderStyle))
            
            // Process content with mentions
            let content = message.content
            
            // For extremely long content, render as plain text to avoid heavy regex/layout work,
            // unless the content includes Cashu tokens we want to chip-render below
            // Compute NSString-backed length for regex/nsrange correctness with multi-byte characters
            let nsContent = content as NSString
            let nsLen = nsContent.length
            if (content.count > 4000 || content.hasVeryLongToken(threshold: 1024)) {
                var plainStyle = AttributeContainer()
                plainStyle.foregroundColor = baseColor
                plainStyle.font = isSelf
                    ? .system(size: 14, weight: .bold, design: .monospaced)
                    : .system(size: 14, design: .monospaced)
                result.append(AttributedString(content).mergingAttributes(plainStyle))
            } else {
            // Reuse compiled regexes and detector
            let mentionRegex = Regexes.mention
            let detector = Regexes.linkDetector
            let hasMentionsHint = content.contains("@")
            let hasURLHint = content.contains("://") || content.contains("www.") || content.contains("http")

            let mentionMatches = hasMentionsHint ? mentionRegex.matches(in: content, options: [], range: NSRange(location: 0, length: nsLen)) : []
            let urlMatches = hasURLHint ? (detector?.matches(in: content, options: [], range: NSRange(location: 0, length: nsLen)) ?? []) : []
            
            // Combine and sort matches, excluding URLs overlapping mentions
            let mentionRanges = mentionMatches.map { $0.range(at: 0) }
            func overlapsMention(_ r: NSRange) -> Bool {
                for mr in mentionRanges { if NSIntersectionRange(r, mr).length > 0 { return true } }
                return false
            }
            var allMatches: [(range: NSRange, type: String)] = []
            for match in mentionMatches {
                allMatches.append((match.range(at: 0), "mention"))
            }
            for match in urlMatches where !overlapsMention(match.range) {
                allMatches.append((match.range, "url"))
            }
            allMatches.sort { $0.range.location < $1.range.location }
            
            // Build content with styling
            var lastEnd = content.startIndex
            let isMentioned = message.mentions?.contains(nickname) ?? false
            
            for (range, type) in allMatches {
                // Add text before match
                if let nsRange = Range(range, in: content) {
                    if lastEnd < nsRange.lowerBound {
                        let beforeText = String(content[lastEnd..<nsRange.lowerBound])
                        if !beforeText.isEmpty {
                            var beforeStyle = AttributeContainer()
                            beforeStyle.foregroundColor = baseColor
                            beforeStyle.font = isSelf
                            ? .system(size: 14, weight: .bold, design: .monospaced)
                            : .system(size: 14, design: .monospaced)
                            if isMentioned {
                                beforeStyle.font = beforeStyle.font?.bold()
                            }
                            result.append(AttributedString(beforeText).mergingAttributes(beforeStyle))
                        }
                    }
                    
                    // Add styled match
                    let matchText = String(content[nsRange])
                    if type == "mention" {
                        // Split optional '#abcd' suffix and color suffix light grey
                        let (mBase, mSuffix) = splitSuffix(from: matchText.replacingOccurrences(of: "@", with: ""))
                        // Determine if this mention targets me (resolves with optional suffix per active channel)
                        let mySuffix: String? = {
                            return String(meshService.myPeerID.prefix(4))
                        }()
                        let isMentionToMe: Bool = {
                            if mBase == nickname {
                                if let suf = mySuffix, !mSuffix.isEmpty {
                                    return mSuffix == "#\(suf)"
                                }
                                return mSuffix.isEmpty
                            }
                            return false
                        }()
                        var mentionStyle = AttributeContainer()
                        mentionStyle.font = .system(size: 14, weight: isSelf ? .bold : .semibold, design: .monospaced)
                        let mentionColor: Color = isMentionToMe ? .orange : baseColor
                        mentionStyle.foregroundColor = mentionColor
                        // Emit '@'
                        result.append(AttributedString("@").mergingAttributes(mentionStyle))
                        // Base name
                        result.append(AttributedString(mBase).mergingAttributes(mentionStyle))
                        // Suffix in light grey
                        if !mSuffix.isEmpty {
                            var light = mentionStyle
                            light.foregroundColor = mentionColor.opacity(0.6)
                            result.append(AttributedString(mSuffix).mergingAttributes(light))
                        }
                    } else {
                        // Style non-mention matches
                        // Keep URL styling and make it tappable via .link attribute
                        var matchStyle = AttributeContainer()
                        matchStyle.font = .system(size: 14, weight: isSelf ? .bold : .semibold, design: .monospaced)
                        if type == "url" {
                            matchStyle.foregroundColor = isSelf ? .orange : .blue
                            matchStyle.underlineStyle = .single
                            if let url = URL(string: matchText) {
                                matchStyle.link = url
                            }
                        }
                        result.append(AttributedString(matchText).mergingAttributes(matchStyle))
                    }
                    // Advance lastEnd safely in case of overlaps
                    if lastEnd < nsRange.upperBound {
                        lastEnd = nsRange.upperBound
                    }
                }
            }
            
            // Add remaining text
            if lastEnd < content.endIndex {
                let remainingText = String(content[lastEnd...])
                var remainingStyle = AttributeContainer()
                remainingStyle.foregroundColor = baseColor
                remainingStyle.font = isSelf
                    ? .system(size: 14, weight: .bold, design: .monospaced)
                    : .system(size: 14, design: .monospaced)
                if isMentioned {
                    remainingStyle.font = remainingStyle.font?.bold()
                }
                result.append(AttributedString(remainingText).mergingAttributes(remainingStyle))
            }
            }
            
            // Add timestamp at the end (smaller, light grey)
            let timestamp = AttributedString(" [\(formatTimestamp(message.timestamp))]")
            var timestampStyle = AttributeContainer()
            timestampStyle.foregroundColor = Color.gray.opacity(0.7)
            timestampStyle.font = .system(size: 10, design: .monospaced)
            result.append(timestamp.mergingAttributes(timestampStyle))
        } else {
            // System message
            var contentStyle = AttributeContainer()
            contentStyle.foregroundColor = Color.gray
            let content = AttributedString("* \(message.content) *")
            contentStyle.font = .system(size: 12, design: .monospaced).italic()
            result.append(content.mergingAttributes(contentStyle))
            
            // Add timestamp at the end for system messages too
            let timestamp = AttributedString(" [\(formatTimestamp(message.timestamp))]")
            var timestampStyle = AttributeContainer()
            timestampStyle.foregroundColor = Color.gray.opacity(0.5)
            timestampStyle.font = .system(size: 10, design: .monospaced)
            result.append(timestamp.mergingAttributes(timestampStyle))
        }
        
        // Cache the formatted text
        message.setCachedFormattedText(result, isDark: isDark, isSelf: isSelf)
        
        return result
    }

    // Split a nickname into base and a '#abcd' suffix if present
    private func splitSuffix(from name: String) -> (String, String) {
        guard name.count >= 5 else { return (name, "") }
        let suffix = String(name.suffix(5))
        if suffix.first == "#", suffix.dropFirst().allSatisfy({ c in
            ("0"..."9").contains(String(c)) || ("a"..."f").contains(String(c)) || ("A"..."F").contains(String(c))
        }) {
            let base = String(name.dropLast(5))
            return (base, suffix)
        }
        return (name, "")
    }
    
    // MARK: - Noise Protocol Support
    
    @MainActor
    func updateEncryptionStatusForPeers() {
        for peerID in connectedPeers {
            updateEncryptionStatusForPeer(peerID)
        }
    }
    
    @MainActor
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
    
    @MainActor
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
        
        // Encryption status determined: \(status)
        
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
            messages = Array(messages.suffix(maxMessages))
        }
    }

    // MARK: - Per-Peer Colors
    private var peerColorCache: [String: Color] = [:]

    private func djb2(_ s: String) -> UInt64 {
        var hash: UInt64 = 5381
        for b in s.utf8 { hash = ((hash << 5) &+ hash) &+ UInt64(b) }
        return hash
    }

    @MainActor
    func colorForPeerSeed(_ seed: String, isDark: Bool) -> Color {
        let cacheKey = seed + (isDark ? "|dark" : "|light")
        if let cached = peerColorCache[cacheKey] { return cached }
        let h = djb2(seed)
        var hue = Double(h % 1000) / 1000.0
        let orange = 30.0 / 360.0
        if abs(hue - orange) < TransportConfig.uiColorHueAvoidanceDelta {
            hue = fmod(hue + TransportConfig.uiColorHueOffset, 1.0)
        }
        let sRand = Double((h >> 17) & 0x3FF) / 1023.0
        let bRand = Double((h >> 27) & 0x3FF) / 1023.0
        let sBase: Double = isDark ? 0.80 : 0.70
        let sRange: Double = 0.20
        let bBase: Double = isDark ? 0.75 : 0.45
        let bRange: Double = isDark ? 0.16 : 0.14
        let saturation = min(1.0, max(0.50, sBase + (sRand - 0.5) * sRange))
        let brightness = min(1.0, max(0.35, bBase + (bRand - 0.5) * bRange))
        let c = Color(hue: hue, saturation: saturation, brightness: brightness)
        peerColorCache[cacheKey] = c
        return c
    }

    @MainActor
    private func peerColor(for message: BitchatMessage, isDark: Bool) -> Color {
        if let spid = message.senderPeerID {
            if spid.count == 16 {
                // Mesh short ID
                return getPeerPaletteColor(for: spid, isDark: isDark)
            } else {
                return getPeerPaletteColor(for: spid.lowercased(), isDark: isDark)
            }
        }
        // Fallback when we only have a display name
        return colorForPeerSeed(message.sender.lowercased(), isDark: isDark)
    }

    @MainActor
    func colorForMeshPeer(id peerID: String, isDark: Bool) -> Color {
        return getPeerPaletteColor(for: peerID, isDark: isDark)
    }

    private func trimMeshTimelineIfNeeded() {
        if meshTimeline.count > meshTimelineCap {
            meshTimeline = Array(meshTimeline.suffix(meshTimelineCap))
        }
    }

    // MARK: - Peer List Minimal-Distance Palette
    private var peerPaletteLight: [String: (slot: Int, ring: Int, hue: Double)] = [:]
    private var peerPaletteDark: [String: (slot: Int, ring: Int, hue: Double)] = [:]
    private var peerPaletteSeeds: [String: String] = [:] // peerID -> seed used

    @MainActor
    private func meshSeed(for peerID: String) -> String {
        if let full = getNoiseKeyForShortID(peerID)?.lowercased() {
            return "noise:" + full
        }
        return peerID.lowercased()
    }

    @MainActor
    private func getPeerPaletteColor(for peerID: String, isDark: Bool) -> Color {
        // Ensure palette up to date for current peer set and seeds
        rebuildPeerPaletteIfNeeded()

        let entry = (isDark ? peerPaletteDark[peerID] : peerPaletteLight[peerID])
        let orange = Color.orange
        if peerID == meshService.myPeerID { return orange }
        let saturation: Double = isDark ? 0.80 : 0.70
        let baseBrightness: Double = isDark ? 0.75 : 0.45
        let ringDelta = isDark ? TransportConfig.uiPeerPaletteRingBrightnessDeltaDark : TransportConfig.uiPeerPaletteRingBrightnessDeltaLight
        if let e = entry {
            let brightness = min(1.0, max(0.0, baseBrightness + ringDelta * Double(e.ring)))
            return Color(hue: e.hue, saturation: saturation, brightness: brightness)
        }
        // Fallback to seed color if not in palette (e.g., transient)
        let seed = meshSeed(for: peerID)
        return colorForPeerSeed(seed, isDark: isDark)
    }

    @MainActor
    private func rebuildPeerPaletteIfNeeded() {
        // Build current peer->seed map (excluding self)
        let myID = meshService.myPeerID
        var currentSeeds: [String: String] = [:]
        for p in allPeers where p.id != myID {
            currentSeeds[p.id] = meshSeed(for: p.id)
        }
        // If seeds unchanged and palette exists for both themes, skip
        if currentSeeds == peerPaletteSeeds,
           peerPaletteLight.keys.count == currentSeeds.count,
           peerPaletteDark.keys.count == currentSeeds.count {
            return
        }
        peerPaletteSeeds = currentSeeds

        // Generate evenly spaced hue slots avoiding self-orange range
        let slotCount = max(8, TransportConfig.uiPeerPaletteSlots)
        let avoidCenter = 30.0 / 360.0
        let avoidDelta = TransportConfig.uiColorHueAvoidanceDelta
        var slots: [Double] = []
        for i in 0..<slotCount {
            let hue = Double(i) / Double(slotCount)
            if abs(hue - avoidCenter) < avoidDelta { continue }
            slots.append(hue)
        }
        if slots.isEmpty {
            // Safety: if avoidance consumed all (shouldn't happen), fall back to full slots
            for i in 0..<slotCount { slots.append(Double(i) / Double(slotCount)) }
        }

        // Helper to compute circular distance
        func circDist(_ a: Double, _ b: Double) -> Double {
            let d = abs(a - b)
            return d > 0.5 ? 1.0 - d : d
        }

        // Assign slots to peers to maximize minimal distance, deterministically
        let peers = currentSeeds.keys.sorted() // stable order
        // Preferred slot index by seed (wrapping to available slots)
        let prefIndex: [String: Int] = Dictionary(uniqueKeysWithValues: peers.map { id in
            let h = djb2(currentSeeds[id] ?? id)
            // Map to available slot range deterministically
            let idx = Int(h % UInt64(slots.count))
            return (id, idx)
        })

        func assign(for seeds: [String: String]) -> [String: (slot: Int, ring: Int, hue: Double)] {
            var mapping: [String: (slot: Int, ring: Int, hue: Double)] = [:]
            var usedSlots = Set<Int>()
            var usedHues: [Double] = []

            // Keep previous assignments if still valid to minimize churn
            let prev = peerPaletteLight.isEmpty ? peerPaletteDark : peerPaletteLight
            for (id, entry) in prev {
                if seeds.keys.contains(id), entry.slot < slots.count { // slot index still valid
                    mapping[id] = (entry.slot, entry.ring, slots[entry.slot])
                    usedSlots.insert(entry.slot)
                    usedHues.append(slots[entry.slot])
                }
            }

            // First ring assignment using free slots
            let unassigned = peers.filter { mapping[$0] == nil }
            for id in unassigned {
                // If a preferred slot free, take it
                let preferred = prefIndex[id] ?? 0
                if !usedSlots.contains(preferred) && preferred < slots.count {
                    mapping[id] = (preferred, 0, slots[preferred])
                    usedSlots.insert(preferred)
                    usedHues.append(slots[preferred])
                    continue
                }
                // Choose free slot maximizing minimal distance to used hues
                var bestSlot: Int? = nil
                var bestScore: Double = -1
                for sIdx in 0..<slots.count where !usedSlots.contains(sIdx) {
                    let hue = slots[sIdx]
                    let minDist = usedHues.isEmpty ? 1.0 : usedHues.map { circDist(hue, $0) }.min() ?? 1.0
                    // Bias toward preferred index for stability
                    let bias = 1.0 - (Double((abs(sIdx - (prefIndex[id] ?? 0)) % slots.count)) / Double(slots.count))
                    let score = minDist + 0.05 * bias
                    if score > bestScore { bestScore = score; bestSlot = sIdx }
                }
                if let s = bestSlot {
                    mapping[id] = (s, 0, slots[s])
                    usedSlots.insert(s)
                    usedHues.append(slots[s])
                }
            }

            // Overflow peers: assign additional rings by reusing slots with stable preference
            let stillUnassigned = peers.filter { mapping[$0] == nil }
            if !stillUnassigned.isEmpty {
                for (idx, id) in stillUnassigned.enumerated() {
                    let preferred = prefIndex[id] ?? 0
                    // Spread over slots by rotating from preferred with a golden-step
                    let goldenStep = 7 // small prime step for dispersion
                    let s = (preferred + idx * goldenStep) % slots.count
                    mapping[id] = (s, 1, slots[s])
                }
            }

            return mapping
        }

        let mapping = assign(for: currentSeeds)
        peerPaletteLight = mapping
        peerPaletteDark = mapping
    }

    // Clear the current public channel's timeline (visible + persistent buffer)
    @MainActor
    func clearCurrentPublicTimeline() {
        messages.removeAll()
        meshTimeline.removeAll()
    }
    
    // MARK: - Message Management
    
    private func addMessage(_ message: BitchatMessage) {
        // Check for duplicates
        guard !messages.contains(where: { $0.id == message.id }) else { return }
        messages.append(message)
        trimMessagesIfNeeded()
    }

    // Update encryption status in appropriate places, not during view updates
    @MainActor
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
    
    @MainActor
    func getFingerprint(for peerID: String) -> String? {
        return unifiedPeerService.getFingerprint(for: peerID)
    }
    
    //

    
    // Helper to resolve nickname for a peer ID through various sources
    @MainActor
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
        
        // Use anonymous with shortened peer ID
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
    
    @MainActor
    func verifyFingerprint(for peerID: String) {
        guard let fingerprint = getFingerprint(for: peerID) else { return }
        
        // Update secure storage with verified status
        SecureIdentityStateManager.shared.setVerified(fingerprint: fingerprint, verified: true)
        
        // Update local set for UI
        verifiedFingerprints.insert(fingerprint)
        
        // Update encryption status after verification
        updateEncryptionStatus(for: peerID)
    }

    @MainActor
    func unverifyFingerprint(for peerID: String) {
        guard let fingerprint = getFingerprint(for: peerID) else { return }
        SecureIdentityStateManager.shared.setVerified(fingerprint: fingerprint, verified: false)
        SecureIdentityStateManager.shared.forceSave()
        verifiedFingerprints.remove(fingerprint)
        updateEncryptionStatus(for: peerID)
    }
    
    @MainActor
    func loadVerifiedFingerprints() {
        // Load verified fingerprints directly from secure storage
        verifiedFingerprints = SecureIdentityStateManager.shared.getVerifiedFingerprints()
        // Log snapshot for debugging persistence
        let sample = verifiedFingerprints.prefix(TransportConfig.uiFingerprintSampleCount).map { $0.prefix(8) }.joined(separator: ", ")
        SecureLogger.log("🔐 Verified loaded: \(verifiedFingerprints.count) [\(sample)]", category: SecureLogger.security, level: .info)
        // Also log any offline favorites and whether we consider them verified
        let offlineFavorites = unifiedPeerService.favorites.filter { !$0.isConnected }
        for fav in offlineFavorites {
            let fp = unifiedPeerService.getFingerprint(for: fav.id)
            let isVer = fp.flatMap { verifiedFingerprints.contains($0) } ?? false
            let fpShort = fp?.prefix(8) ?? "nil"
            SecureLogger.log("⭐️ Favorite offline: \(fav.nickname) fp=\(fpShort) verified=\(isVer)", category: SecureLogger.security, level: .info)
        }
        // Invalidate cached encryption statuses so offline favorites can show verified badges immediately
        invalidateEncryptionCache()
        // Trigger UI refresh of peer list
        objectWillChange.send()
    }
    
    private func setupNoiseCallbacks() {
        let noiseService = meshService.getNoiseService()
        
        // Set up authentication callback
        noiseService.onPeerAuthenticated = { [weak self] peerID, fingerprint in
            guard let self = self else { return }
            
            DispatchQueue.main.async {

                SecureLogger.log("🔐 Authenticated: \(peerID)", category: SecureLogger.security, level: .debug)

                // Update encryption status
                if self.verifiedFingerprints.contains(fingerprint) {
                    self.peerEncryptionStatus[peerID] = .noiseVerified
                    // Encryption: noiseVerified
                } else {
                    self.peerEncryptionStatus[peerID] = .noiseSecured
                    // Encryption: noiseSecured
                }

                // Invalidate cache when encryption status changes
                self.invalidateEncryptionCache(for: peerID)

                // Cache shortID -> full Noise key mapping as soon as session authenticates
                if self.shortIDToNoiseKey[peerID] == nil,
                   let keyData = self.meshService.getNoiseService().getPeerPublicKeyData(peerID) {
                    let stable = keyData.hexEncodedString()
                    self.shortIDToNoiseKey[peerID] = stable
                    SecureLogger.log("🗺️ Mapped short peerID to Noise key for header continuity: \(peerID) -> \(stable.prefix(8))…",
                                    category: SecureLogger.session, level: .debug)
                }

                // If a QR verification is pending but not sent yet, send it now that session is authenticated
                if var pending = self.pendingQRVerifications[peerID], pending.sent == false {
                    self.meshService.sendVerifyChallenge(to: peerID, noiseKeyHex: pending.noiseKeyHex, nonceA: pending.nonceA)
                    pending.sent = true
                    self.pendingQRVerifications[peerID] = pending
                    SecureLogger.log("📤 Sent deferred verify challenge to \(peerID) after handshake", category: SecureLogger.security, level: .debug)
                }

                // Schedule UI update
                // UI will update automatically
            }
        }
        
        // Set up handshake required callback
        noiseService.onHandshakeRequired = { [weak self] peerID in
//            DispatchQueue.main.async {
                guard let self = self else { return }
                self.peerEncryptionStatus[peerID] = .noiseHandshaking
                
                // Invalidate cache when encryption status changes
                self.invalidateEncryptionCache(for: peerID)
//            }
        }
    }
    
    // MARK: - BitchatDelegate Methods
    
    // MARK: - Command Handling
    
    /// Processes IRC-style commands starting with '/'.
    /// - Parameter command: The full command string including the leading slash
    /// - Note: Supports commands like /nick, /msg, /who, /slap, /clear, /help
    @MainActor
    private func handleCommand(_ command: String) {
        let result = commandProcessor.process(command)
        
        switch result {
        case .success(let message):
            if let msg = message {
                addSystemMessage(msg)
            }
        case .error(let message):
            addSystemMessage(message)
        case .handled:
            // Command was handled, no message needed
            break
        }
    }
    
    // MARK: - Message Reception
    
    @MainActor func didReceiveMessage(_ message: BitchatMessage) {
        // Early validation
        guard !isMessageBlocked(message) else { return }
        guard !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || message.isPrivate else { return }
        
        // Route to appropriate handler
        if message.isPrivate {
            handlePrivateMessage(message)
        } else {
            handlePublicMessage(message)
        }
        
        // Post-processing
        checkForMentions(message)
        sendHapticFeedback(for: message)
    }

    // Low-level BLE events
    @MainActor func didReceiveNoisePayload(from peerID: String, type: NoisePayloadType, payload: Data, timestamp: Date) {
        switch type {
        case .privateMessage:
            guard let pm = PrivateMessagePacket.decode(from: payload) else { return }
            let senderName = unifiedPeerService.getPeer(by: peerID)?.nickname ?? "Unknown"
            let pmMentions = parseMentions(from: pm.content)
            let msg = BitchatMessage(
                id: pm.messageID,
                sender: senderName,
                content: pm.content,
                timestamp: timestamp,
                isRelay: false,
                originalSender: nil,
                isPrivate: true,
                recipientNickname: nickname,
                senderPeerID: peerID,
                mentions: pmMentions.isEmpty ? nil : pmMentions
            )
            handlePrivateMessage(msg)
            // Send delivery ACK back over BLE
            meshService.sendDeliveryAck(for: pm.messageID, to: peerID)
            
        case .delivered:
            guard let messageID = String(data: payload, encoding: .utf8) else { return }
            if let name = unifiedPeerService.getPeer(by: peerID)?.nickname {
                if let messages = privateChats[peerID], let idx = messages.firstIndex(where: { $0.id == messageID }) {
                    privateChats[peerID]?[idx].deliveryStatus = .delivered(to: name, at: Date())
                    objectWillChange.send()
                }
            }
            
        case .readReceipt:
            guard let messageID = String(data: payload, encoding: .utf8) else { return }
            if let name = unifiedPeerService.getPeer(by: peerID)?.nickname {
                if let messages = privateChats[peerID], let idx = messages.firstIndex(where: { $0.id == messageID }) {
                    privateChats[peerID]?[idx].deliveryStatus = .read(by: name, at: Date())
                    objectWillChange.send()
                }
            }
        case .verifyChallenge:
            // Parse and respond
            guard let tlv = VerificationService.shared.parseVerifyChallenge(payload) else { return }
            // Ensure intended for our noise key
            let myNoiseHex = meshService.getNoiseService().getStaticPublicKeyData().hexEncodedString().lowercased()
            guard tlv.noiseKeyHex.lowercased() == myNoiseHex else { return }
            // Deduplicate: ignore if we've already responded to this nonce for this peer
            if let last = lastVerifyNonceByPeer[peerID], last == tlv.nonceA { return }
            lastVerifyNonceByPeer[peerID] = tlv.nonceA
            // Record inbound challenge time keyed by stable fingerprint if available
            if let fp = getFingerprint(for: peerID) {
                lastInboundVerifyChallengeAt[fp] = Date()
                // If we've already verified this fingerprint locally, treat this as mutual and toast immediately (responder side)
                if verifiedFingerprints.contains(fp) {
                    let now = Date()
                    let last = lastMutualToastAt[fp] ?? .distantPast
                    if now.timeIntervalSince(last) > 60 { // 1-minute throttle
                        lastMutualToastAt[fp] = now
                        let name = unifiedPeerService.getPeer(by: peerID)?.nickname ?? resolveNickname(for: peerID)
                        NotificationService.shared.sendLocalNotification(
                            title: "Mutual verification",
                            body: "You and \(name) verified each other",
                            identifier: "verify-mutual-\(peerID)-\(UUID().uuidString)"
                        )
                    }
                }
            }
            meshService.sendVerifyResponse(to: peerID, noiseKeyHex: tlv.noiseKeyHex, nonceA: tlv.nonceA)
            // Silent response: no toast needed on responder
        case .verifyResponse:
            guard let resp = VerificationService.shared.parseVerifyResponse(payload) else { return }
            // Check pending for this peer
            guard let pending = pendingQRVerifications[peerID] else { return }
            guard resp.noiseKeyHex.lowercased() == pending.noiseKeyHex.lowercased(), resp.nonceA == pending.nonceA else { return }
            // Verify signature with expected sign key
            let ok = VerificationService.shared.verifyResponseSignature(noiseKeyHex: resp.noiseKeyHex, nonceA: resp.nonceA, signature: resp.signature, signerPublicKeyHex: pending.signKeyHex)
            if ok {
                pendingQRVerifications.removeValue(forKey: peerID)
                if let fp = getFingerprint(for: peerID) {
                    let short = fp.prefix(8)
                    SecureLogger.log("🔐 Marking verified fingerprint: \(short)", category: SecureLogger.security, level: .info)
                    SecureIdentityStateManager.shared.setVerified(fingerprint: fp, verified: true)
                    SecureIdentityStateManager.shared.forceSave()
                    verifiedFingerprints.insert(fp)
                    let name = unifiedPeerService.getPeer(by: peerID)?.nickname ?? resolveNickname(for: peerID)
                    NotificationService.shared.sendLocalNotification(
                        title: "Verified",
                        body: "You verified \(name)",
                        identifier: "verify-success-\(peerID)-\(UUID().uuidString)"
                    )
                    // If we also recently responded to their challenge, flag mutual and toast (initiator side)
                    if let t = lastInboundVerifyChallengeAt[fp], Date().timeIntervalSince(t) < 600 {
                        let now = Date()
                        let lastToast = lastMutualToastAt[fp] ?? .distantPast
                        if now.timeIntervalSince(lastToast) > 60 {
                            lastMutualToastAt[fp] = now
                            NotificationService.shared.sendLocalNotification(
                                title: "Mutual verification",
                                body: "You and \(name) verified each other",
                                identifier: "verify-mutual-\(peerID)-\(UUID().uuidString)"
                            )
                        }
                    }
                    updateEncryptionStatus(for: peerID)
                }
            }
        }
    }

    @MainActor func didReceivePublicMessage(from peerID: String, nickname: String, content: String, timestamp: Date) {
        let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let publicMentions = parseMentions(from: normalized)
        let msg = BitchatMessage(
            id: UUID().uuidString,
            sender: nickname,
            content: normalized,
            timestamp: timestamp,
            isRelay: false,
            originalSender: nil,
            isPrivate: false,
            recipientNickname: nil,
            senderPeerID: peerID,
            mentions: publicMentions.isEmpty ? nil : publicMentions
        )
        handlePublicMessage(msg)
        checkForMentions(msg)
        sendHapticFeedback(for: msg)
    }

    // MARK: - QR Verification API
    @MainActor
    func beginQRVerification(with qr: VerificationService.VerificationQR) -> Bool {
        // Find a matching peer by Noise key
        let targetNoise = qr.noiseKeyHex.lowercased()
        guard let peer = unifiedPeerService.peers.first(where: { $0.noisePublicKey.hexEncodedString().lowercased() == targetNoise }) else {
            return false
        }
        let peerID = peer.id
        // If we already have a pending verification with this peer, don't send another
        if pendingQRVerifications[peerID] != nil {
            return true
        }
        // Generate nonceA
        var nonce = Data(count: 16)
        _ = nonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        var pending = PendingVerification(noiseKeyHex: qr.noiseKeyHex, signKeyHex: qr.signKeyHex, nonceA: nonce, startedAt: Date(), sent: false)
        pendingQRVerifications[peerID] = pending
        // If Noise session is established, send immediately; otherwise trigger handshake and send on auth
        let noise = meshService.getNoiseService()
        if noise.hasEstablishedSession(with: peerID) {
            meshService.sendVerifyChallenge(to: peerID, noiseKeyHex: qr.noiseKeyHex, nonceA: nonce)
            pending.sent = true
            pendingQRVerifications[peerID] = pending
        } else {
            meshService.triggerHandshake(with: peerID)
        }
        return true
    }

    // Mention parsing moved from BLE – use the existing non-optional helper below
    // MARK: - Peer Connection Events
    
    @MainActor func didConnectToPeer(_ peerID: String) async {
        SecureLogger.log("🤝 Peer connected: \(peerID)", category: SecureLogger.session, level: .debug)
        isConnected = true
        
        // Register ephemeral session with identity manager
        SecureIdentityStateManager.shared.registerEphemeralSession(peerID: peerID)
        
        // Intentionally do not resend favorites on reconnect.
        // We only send our npub when a favorite is toggled on, or if our npub changes.
        
        // Force UI refresh
        objectWillChange.send()
        
        // Cache mapping to full Noise key for session continuity on disconnect
        if let peer = unifiedPeerService.getPeer(by: peerID) {
            let noiseKeyHex = peer.noisePublicKey.hexEncodedString()
            shortIDToNoiseKey[peerID] = noiseKeyHex
        }
        
        // Flush any queued messages for this peer via router
        messageRouter.flushOutbox(for: peerID)
    }
    
    func didDisconnectFromPeer(_ peerID: String) {
        SecureLogger.log("👋 Peer disconnected: \(peerID)", category: SecureLogger.session, level: .debug)
        
        // Remove ephemeral session from identity manager
        SecureIdentityStateManager.shared.removeEphemeralSession(peerID: peerID)

        // If the open PM is tied to this short peer ID, switch UI context to the full Noise key (offline favorite)
        var derivedStableKeyHex: String? = shortIDToNoiseKey[peerID]
        if derivedStableKeyHex == nil,
           let key = meshService.getNoiseService().getPeerPublicKeyData(peerID) {
            derivedStableKeyHex = key.hexEncodedString()
            shortIDToNoiseKey[peerID] = derivedStableKeyHex
        }

        if let current = selectedPrivateChatPeer, current == peerID,
           let stableKeyHex = derivedStableKeyHex {
            // Migrate messages view context to stable key so header shows favorite + Nostr globe
            if let messages = privateChats[peerID] {
                if privateChats[stableKeyHex] == nil { privateChats[stableKeyHex] = [] }
                let existing = Set(privateChats[stableKeyHex]!.map { $0.id })
                for msg in messages where !existing.contains(msg.id) {
                    let updated = BitchatMessage(
                        id: msg.id,
                        sender: msg.sender,
                        content: msg.content,
                        timestamp: msg.timestamp,
                        isRelay: msg.isRelay,
                        originalSender: msg.originalSender,
                        isPrivate: msg.isPrivate,
                        recipientNickname: msg.recipientNickname,
                        senderPeerID: (msg.senderPeerID == meshService.myPeerID) ? meshService.myPeerID : stableKeyHex,
                        mentions: msg.mentions,
                        deliveryStatus: msg.deliveryStatus
                    )
                    privateChats[stableKeyHex]?.append(updated)
                }
                privateChats[stableKeyHex]?.sort { $0.timestamp < $1.timestamp }
                privateChats.removeValue(forKey: peerID)
            }
            if unreadPrivateMessages.contains(peerID) {
                unreadPrivateMessages.remove(peerID)
                unreadPrivateMessages.insert(stableKeyHex)
            }
            selectedPrivateChatPeer = stableKeyHex
            objectWillChange.send()
        }
        
        // Update peer list immediately and force UI refresh
        DispatchQueue.main.async { [weak self] in
            // UnifiedPeerService updates automatically via subscriptions
            self?.objectWillChange.send()
        }
        
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
        
        //
    }
    
    @MainActor func didUpdatePeerList(_ peers: Dictionary<String, BLEService.PeerInfo>.Keys) {
        // UI updates must run on the main thread.
        // The delegate callback is not guaranteed to be on the main thread.
        
        // Update through peer manager
        // UnifiedPeerService updates automatically via subscriptions
        self.isConnected = !peers.isEmpty
        
        // Clean up stale unread peer IDs whenever peer list updates
        self.cleanupStaleUnreadPeerIDs()
        
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
    
    // MARK: - Helper Methods
    
    /// Clean up stale unread peer IDs that no longer exist in the peer list
    @MainActor
    private func cleanupStaleUnreadPeerIDs() {
        let currentPeerIDs = Set(unifiedPeerService.peers.map { $0.id })
        let staleIDs = unreadPrivateMessages.subtracting(currentPeerIDs)
        
        if !staleIDs.isEmpty {
            var idsToRemove: [String] = []
            for staleID in staleIDs {
                // Don't remove stable Noise key hexes (64 char hex strings) that have messages
                // These are used for Nostr messages when peer is offline
                if staleID.count == 64, staleID.allSatisfy({ $0.isHexDigit }) {
                    if let messages = privateChats[staleID], !messages.isEmpty {
                        // Keep this ID - it's a stable key with messages
                        continue
                    }
                }
                
                // Remove this stale ID
                idsToRemove.append(staleID)
                unreadPrivateMessages.remove(staleID)
            }
            
            if !idsToRemove.isEmpty {
                SecureLogger.log("🧹 Cleaned up \(idsToRemove.count) stale unread peer IDs", 
                                category: SecureLogger.session, level: .debug)
            }
        }
        
        // Also clean up old sentReadReceipts to prevent unlimited growth
        // Keep only receipts from messages we still have
        cleanupOldReadReceipts()
    }
    
    private func cleanupOldReadReceipts() {
        // Skip cleanup during startup phase or if privateChats is empty
        // This prevents removing valid receipts before messages are loaded
        if isStartupPhase || privateChats.isEmpty {
            return
        }
        
        // Build set of all message IDs we still have
        var validMessageIDs = Set<String>()
        for (_, messages) in privateChats {
            for message in messages {
                validMessageIDs.insert(message.id)
            }
        }
        
        // Remove receipts for messages we no longer have
        let oldCount = sentReadReceipts.count
        sentReadReceipts = sentReadReceipts.intersection(validMessageIDs)
        
        let removedCount = oldCount - sentReadReceipts.count
        if removedCount > 0 {
            SecureLogger.log("🧹 Cleaned up \(removedCount) old read receipts", 
                            category: SecureLogger.session, level: .debug)
        }
    }
    
    private func parseMentions(from content: String) -> [String] {
        // Allow optional disambiguation suffix '#abcd' for duplicate nicknames
        let pattern = "@([\\p{L}0-9_]+(?:#[a-fA-F0-9]{4})?)"
        let regex = try? NSRegularExpression(pattern: pattern, options: [])
        let nsContent = content as NSString
        let nsLen = nsContent.length
        let matches = regex?.matches(in: content, options: [], range: NSRange(location: 0, length: nsLen)) ?? []
        
        var mentions: [String] = []
        let peerNicknames = meshService.getPeerNicknames()
        // Compose the valid mention tokens based on current peers (already suffixed where needed)
        var validTokens = Set(peerNicknames.values)
        // Always allow mentioning self by base nickname and suffixed disambiguator
        validTokens.insert(nickname)
        let selfSuffixToken = nickname + "#" + String(meshService.myPeerID.prefix(4))
        validTokens.insert(selfSuffixToken)
        
        for match in matches {
            if let range = Range(match.range(at: 1), in: content) {
                let mentionedName = String(content[range])
                // Only include if it's a current valid token (base or suffixed)
                if validTokens.contains(mentionedName) {
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
        // UnifiedPeerService updates automatically via subscriptions
    }
    
    func isFavorite(fingerprint: String) -> Bool {
        return SecureIdentityStateManager.shared.isFavorite(fingerprint: fingerprint)
    }
    
    // MARK: - Delivery Tracking
    
    func didReceiveReadReceipt(_ receipt: ReadReceipt) {
        // Find the message and update its read status
        updateMessageDeliveryStatus(receipt.originalMessageID, status: .read(by: receipt.readerNickname, at: receipt.timestamp))
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
        for (peerID, chatMessages) in privateChats {
            guard let index = chatMessages.firstIndex(where: { $0.id == messageID }) else { continue }
            
            let currentStatus = chatMessages[index].deliveryStatus
            guard !shouldSkipUpdate(currentStatus: currentStatus, newStatus: status) else { continue }
            
            // Update delivery status directly (BitchatMessage is a class/reference type)
            privateChats[peerID]?[index].deliveryStatus = status
        }
        
        // Trigger UI update for delivery status change
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
        
    }
    
    // MARK: - Helper for System Messages
    private func addSystemMessage(_ content: String, timestamp: Date = Date()) {
        let systemMessage = BitchatMessage(
            sender: "system",
            content: content,
            timestamp: timestamp,
            isRelay: false
        )
        messages.append(systemMessage)
    }

    /// Add a system message to the mesh timeline only (never geohash).
    /// If mesh is currently active, also append to the visible `messages`.
    @MainActor
    private func addMeshOnlySystemMessage(_ content: String) {
        let systemMessage = BitchatMessage(
            sender: "system",
            content: content,
            timestamp: Date(),
            isRelay: false
        )
        // Persist to mesh timeline
        meshTimeline.append(systemMessage)
        trimMeshTimelineIfNeeded()
        // Only show inline if mesh is the active channel
        messages.append(systemMessage)
        objectWillChange.send()
    }
    
    /// Public helper to add a system message to the public chat timeline
    @MainActor
    func addPublicSystemMessage(_ content: String) {
        addSystemMessage(content)
        objectWillChange.send()
    }
    // Send a public message without adding a local user echo.
    // Used for emotes where we want a local system-style confirmation instead.
    @MainActor
    func sendPublicRaw(_ content: String) {
        // Default: send over mesh
        meshService.sendMessage(content, mentions: [])
    }

    // MARK: - Base64URL utils
    private static func base64URLDecode(_ s: String) -> Data? {
        var str = s.replacingOccurrences(of: "-", with: "+")
                    .replacingOccurrences(of: "_", with: "/")
        // Add padding if needed
        let rem = str.count % 4
        if rem > 0 { str.append(String(repeating: "=", count: 4 - rem)) }
        return Data(base64Encoded: str)
    }
    
    //
    
    @MainActor
    private func handleFavoriteNotificationFromMesh(_ content: String, from peerID: String, senderNickname: String) {
        // Parse the message format: "[FAVORITED]:npub..." or "[UNFAVORITED]:npub..."
        let isFavorite = content.hasPrefix("[FAVORITED]")
        let parts = content.split(separator: ":")
        
        // Extract Nostr public key if included
        var nostrPubkey: String? = nil
        if parts.count > 1 {
            nostrPubkey = String(parts[1])
            SecureLogger.log("📝 Received Nostr npub in favorite notification: \(nostrPubkey ?? "none")",
                            category: SecureLogger.session, level: .info)
        }
        
        // Get the noise public key for this peer
        // Try both ephemeral ID and if that fails, get from peer service
        var noiseKey: Data? = nil
        
        // First try as hex-encoded Noise key (64 chars)
        if peerID.count == 64 {
            noiseKey = Data(hexString: peerID)
        }
        
        // If not a hex key, get from peer service (ephemeral ID)
        if noiseKey == nil, let peer = unifiedPeerService.getPeer(by: peerID) {
            noiseKey = peer.noisePublicKey
        }
        
        guard let finalNoiseKey = noiseKey else {
            SecureLogger.log("⚠️ Cannot get Noise key for peer \(peerID)", 
                            category: SecureLogger.session, level: .warning)
            return
        }
        
        // Determine prior state to avoid duplicate system messages on repeated notifications
        let prior = FavoritesPersistenceService.shared.getFavoriteStatus(for: finalNoiseKey)?.theyFavoritedUs ?? false

        // Update the favorite relationship (idempotent storage)
        FavoritesPersistenceService.shared.updatePeerFavoritedUs(
            peerNoisePublicKey: finalNoiseKey,
            favorited: isFavorite,
            peerNickname: senderNickname,
            peerNostrPublicKey: nostrPubkey
        )
        
        // If they favorited us and provided their Nostr key, ensure it's stored
        if isFavorite && nostrPubkey != nil {
            SecureLogger.log("💾 Storing Nostr key association for \(senderNickname): \(nostrPubkey!.prefix(16))...",
                            category: SecureLogger.session, level: .info)
        }
        
        // Only show a system message when the state changes, and only in mesh
        if prior != isFavorite {
            let action = isFavorite ? "favorited" : "unfavorited"
            addMeshOnlySystemMessage("\(senderNickname) \(action) you")
        }
    }
    
    @MainActor
    private func findNoiseKey(for nostrPubkey: String) -> Data? {
        // Convert hex to npub if needed for comparison
        let npubToMatch: String
        if nostrPubkey.hasPrefix("npub") {
            npubToMatch = nostrPubkey
        } else {
            // Try to convert hex to npub
            guard let pubkeyData = Data(hexString: nostrPubkey) else { 
                SecureLogger.log("⚠️ Invalid hex public key format: \(nostrPubkey.prefix(16))...", 
                                category: SecureLogger.session, level: .warning)
                return nil 
            }
            
            do {
                npubToMatch = try Bech32.encode(hrp: "npub", data: pubkeyData)
            } catch {
                SecureLogger.log("⚠️ Failed to convert hex to npub: \(error)", 
                                category: SecureLogger.session, level: .warning)
                return nil
            }
        }
        
        // Search through favorites for matching Nostr pubkey
        for (noiseKey, relationship) in FavoritesPersistenceService.shared.favorites {
            if let storedNostrKey = relationship.peerNostrPublicKey {
                // Compare npub format
                if storedNostrKey == npubToMatch {
                    // SecureLogger.log("✅ Found Noise key for Nostr sender (npub match)", 
                    //                 category: SecureLogger.session, level: .debug)
                    return noiseKey
                }
                
                // Also try hex comparison if stored value is hex
                if !storedNostrKey.hasPrefix("npub") && storedNostrKey == nostrPubkey {
                    SecureLogger.log("✅ Found Noise key for Nostr sender (hex match)", 
                                    category: SecureLogger.session, level: .debug)
                    return noiseKey
                }
            }
        }
        
        SecureLogger.log("⚠️ No matching Noise key found for Nostr pubkey: \(nostrPubkey.prefix(16))... (tried npub: \(npubToMatch.prefix(16))...)", 
                        category: SecureLogger.session, level: .debug)
        return nil
    }
    
    @MainActor
    private func sendFavoriteNotificationViaNostr(noisePublicKey: Data, isFavorite: Bool) {
        let peerIDHex = noisePublicKey.hexEncodedString()
        messageRouter.sendFavoriteNotification(to: peerIDHex, isFavorite: isFavorite)
    }
    
    @MainActor
    func sendFavoriteNotification(to peerID: String, isFavorite: Bool) {
        // Handle both ephemeral peer IDs and Noise key hex strings
        var noiseKey: Data?
        
        // First check if peerID is a hex-encoded Noise key
        if let hexKey = Data(hexString: peerID) {
            noiseKey = hexKey
        } else {
            // It's an ephemeral peer ID, get the Noise key from UnifiedPeerService
            if let peer = unifiedPeerService.getPeer(by: peerID) {
                noiseKey = peer.noisePublicKey
            }
        }
        
        // Try mesh first for connected peers
        if meshService.isPeerConnected(peerID) {
            messageRouter.sendFavoriteNotification(to: peerID, isFavorite: isFavorite)
            SecureLogger.log("📤 Sent favorite notification via BLE to \(peerID)", category: SecureLogger.session, level: .debug)
        } else if let key = noiseKey {
            // Send via Nostr for offline peers (using router)
            let recipientPeerID = key.hexEncodedString()
            messageRouter.sendFavoriteNotification(to: recipientPeerID, isFavorite: isFavorite)
        } else {
            SecureLogger.log("⚠️ Cannot send favorite notification - peer not connected and no Nostr pubkey", category: SecureLogger.session, level: .warning)
        }
    }
    
    // MARK: - Message Processing Helpers
    
    /// Check if a message should be blocked based on sender
    @MainActor
    private func isMessageBlocked(_ message: BitchatMessage) -> Bool {
        if let peerID = message.senderPeerID ?? getPeerIDForNickname(message.sender) {
            // Check mesh/known peers first
            if isPeerBlocked(peerID) { return true }
            return false
        }
        return false
    }
    
    /// Process action messages (hugs, slaps) into system messages
    private func processActionMessage(_ message: BitchatMessage) -> BitchatMessage {
        let isActionMessage = message.content.hasPrefix("* ") && message.content.hasSuffix(" *") &&
                              (message.content.contains("🫂") || message.content.contains("🐟"))
        
        if isActionMessage {
            return BitchatMessage(
                id: message.id,
                sender: "system",
                content: String(message.content.dropFirst(2).dropLast(2)), // Remove * * wrapper
                timestamp: message.timestamp,
                isRelay: message.isRelay,
                originalSender: message.originalSender,
                isPrivate: message.isPrivate,
                recipientNickname: message.recipientNickname,
                senderPeerID: message.senderPeerID,
                mentions: message.mentions,
                deliveryStatus: message.deliveryStatus
            )
        }
        return message
    }
    
    /// Migrate private chats when peer reconnects with new ID
    @MainActor
    private func migratePrivateChatsIfNeeded(for peerID: String, senderNickname: String) {
        let currentFingerprint = getFingerprint(for: peerID)
        
        if privateChats[peerID] == nil || privateChats[peerID]?.isEmpty == true {
            var migratedMessages: [BitchatMessage] = []
            var oldPeerIDsToRemove: [String] = []
            
            // Only migrate messages from the last 24 hours to prevent old messages from flooding
            let cutoffTime = Date().addingTimeInterval(-TransportConfig.uiMigrationCutoffSeconds)
            
            for (oldPeerID, messages) in privateChats {
                if oldPeerID != peerID {
                    let oldFingerprint = peerIDToPublicKeyFingerprint[oldPeerID]
                    
                    // Filter messages to only recent ones
                    let recentMessages = messages.filter { $0.timestamp > cutoffTime }
                    
                    // Skip if no recent messages
                    guard !recentMessages.isEmpty else { continue }
                    
                    // Check fingerprint match first (most reliable)
                    if let currentFp = currentFingerprint,
                       let oldFp = oldFingerprint,
                       currentFp == oldFp {
                        migratedMessages.append(contentsOf: recentMessages)
                        
                        // Only remove old peer ID if we migrated ALL its messages
                        if recentMessages.count == messages.count {
                            oldPeerIDsToRemove.append(oldPeerID)
                        } else {
                            // Keep old messages in original location but don't show in UI
                            SecureLogger.log("📦 Partially migrating \(recentMessages.count) of \(messages.count) messages from \(oldPeerID)", 
                                            category: SecureLogger.session, level: .info)
                        }
                        
                        SecureLogger.log("📦 Migrating \(recentMessages.count) recent messages from old peer ID \(oldPeerID) to \(peerID) (fingerprint match)", 
                                        category: SecureLogger.session, level: .info)
                    } else if currentFingerprint == nil || oldFingerprint == nil {
                        // Check if this chat contains messages with this sender by nickname
                        let isRelevantChat = recentMessages.contains { msg in
                            (msg.sender == senderNickname && msg.sender != nickname) ||
                            (msg.sender == nickname && msg.recipientNickname == senderNickname)
                        }
                        
                        if isRelevantChat {
                            migratedMessages.append(contentsOf: recentMessages)
                            
                            // Only remove if all messages were migrated
                            if recentMessages.count == messages.count {
                                oldPeerIDsToRemove.append(oldPeerID)
                            }
                            
                            SecureLogger.log("📦 Migrating \(recentMessages.count) recent messages from old peer ID \(oldPeerID) to \(peerID) (nickname match)", 
                                            category: SecureLogger.session, level: .warning)
                        }
                    }
                }
            }
            
            // Remove old peer ID entries
            if !oldPeerIDsToRemove.isEmpty {
                // Track if we need to update selectedPrivateChatPeer
                let needsSelectedUpdate = oldPeerIDsToRemove.contains { selectedPrivateChatPeer == $0 }
                
                // Directly modify privateChats to minimize UI disruption
                for oldPeerID in oldPeerIDsToRemove {
                    privateChats.removeValue(forKey: oldPeerID)
                    unreadPrivateMessages.remove(oldPeerID)
                }
                
                // Add or update messages for the new peer ID
                if var existingMessages = privateChats[peerID] {
                    // Merge with existing messages, replace-by-id semantics
                    for msg in migratedMessages {
                        if let i = existingMessages.firstIndex(where: { $0.id == msg.id }) {
                            existingMessages[i] = msg
                        } else {
                            existingMessages.append(msg)
                        }
                    }
                    existingMessages.sort { $0.timestamp < $1.timestamp }
                    privateChats[peerID] = existingMessages
                } else {
                    // Initialize with migrated messages
                    privateChats[peerID] = migratedMessages
                }
                privateChatManager.sanitizeChat(for: peerID)
                
                // Update selectedPrivateChatPeer if it was pointing to an old ID
                if needsSelectedUpdate {
                    selectedPrivateChatPeer = peerID
                    SecureLogger.log("📱 Updated selectedPrivateChatPeer from old ID to \(peerID) during migration", 
                                    category: SecureLogger.session, level: .info)
                }
            }
        }
    }
    
    /// Handle incoming private message
    @MainActor
    private func handlePrivateMessage(_ message: BitchatMessage) {
        SecureLogger.log("📥 handlePrivateMessage called for message from \(message.sender)", category: SecureLogger.session, level: .debug)
        let senderPeerID = message.senderPeerID ?? getPeerIDForNickname(message.sender)
        
        guard let peerID = senderPeerID else { 
            SecureLogger.log("⚠️ Could not get peer ID for sender \(message.sender)", category: SecureLogger.session, level: .warning)
            return 
        }
        
        // Check if this is a favorite/unfavorite notification
        if message.content.hasPrefix("[FAVORITED]") || message.content.hasPrefix("[UNFAVORITED]") {
            handleFavoriteNotificationFromMesh(message.content, from: peerID, senderNickname: message.sender)
            return  // Don't store as a regular message
        }
        
        // Migrate chats if needed
        migratePrivateChatsIfNeeded(for: peerID, senderNickname: message.sender)
        
        // IMPORTANT: Also consolidate messages from stable Noise key if this is an ephemeral peer
        // This ensures Nostr messages appear in BLE chats
        if peerID.count == 16 {  // This is an ephemeral peer ID (8 bytes = 16 hex chars)
            if let peer = unifiedPeerService.getPeer(by: peerID) {
                let stableKeyHex = peer.noisePublicKey.hexEncodedString()
                
                // If we have messages stored under the stable key, merge them
                if stableKeyHex != peerID, let nostrMessages = privateChats[stableKeyHex], !nostrMessages.isEmpty {
                    // Merge messages from stable key into ephemeral peer ID storage
                    if privateChats[peerID] == nil {
                        privateChats[peerID] = []
                    }
                    
                    // Add any messages that aren't already in the ephemeral storage
                    let existingMessageIds = Set(privateChats[peerID]?.map { $0.id } ?? [])
                    for nostrMessage in nostrMessages {
                        if !existingMessageIds.contains(nostrMessage.id) {
                            privateChats[peerID]?.append(nostrMessage)
                        }
                    }
                    
                    // Sort by timestamp
                    privateChats[peerID]?.sort { $0.timestamp < $1.timestamp }
                    
                    // Clean up the stable key storage to avoid duplication
                    privateChats.removeValue(forKey: stableKeyHex)
                    
                    SecureLogger.log("📥 Consolidated \(nostrMessages.count) Nostr messages from stable key to ephemeral peer \(peerID)", 
                                    category: SecureLogger.session, level: .info)
                }
            }
        }
        
        // Initialize chat if needed
        if privateChats[peerID] == nil {
            var chats = privateChats
            chats[peerID] = []
            privateChats = chats
        }
        
        // Fix delivery status for incoming messages
        var messageToStore = message
        if message.sender != nickname {
            if messageToStore.deliveryStatus == nil || messageToStore.deliveryStatus == .sending {
                messageToStore.deliveryStatus = .delivered(to: nickname, at: Date())
            }
        }
        
        // Process action messages
        messageToStore = processActionMessage(messageToStore)
        
        // Store message
        var chats = privateChats
        chats[peerID]?.append(messageToStore)
        privateChats = chats
        
        // UI updates via @Published reassignment above
        
        // Handle fingerprint-based chat updates
        if let chatFingerprint = selectedPrivateChatFingerprint,
           let senderFingerprint = peerIDToPublicKeyFingerprint[peerID],
           chatFingerprint == senderFingerprint && selectedPrivateChatPeer != peerID {
            selectedPrivateChatPeer = peerID
        }
        
        updatePrivateChatPeerIfNeeded()
        
        // Handle notifications and read receipts
        // Check if we should send notification (only for truly unread and recent messages)
        if selectedPrivateChatPeer != peerID || UIApplication.shared.applicationState != .active {
            unreadPrivateMessages.insert(peerID)
            // Avoid notifying for messages that have been marked read already (resubscribe/dup cases)
            if !sentReadReceipts.contains(message.id) {
                NotificationService.shared.sendPrivateMessageNotification(
                    from: message.sender,
                    message: message.content,
                    peerID: peerID
                )
            }
        } else {
            let feedback = UINotificationFeedbackGenerator()
            feedback.prepare()
            // User is viewing this chat - no notification needed
            unreadPrivateMessages.remove(peerID)
            
            // Also clean up any old peer IDs from unread set that no longer exist
            // This prevents stale unread indicators
            cleanupStaleUnreadPeerIDs()
            
            // Send read receipt if needed
            if !sentReadReceipts.contains(message.id) {
                let receipt = ReadReceipt(
                    originalMessageID: message.id,
                    readerID: meshService.myPeerID,
                    readerNickname: nickname
                )
                
                
                let recipientID = message.senderPeerID ?? peerID
                
                Task { @MainActor in
                    feedback.notificationOccurred(.success)
                    var originalTransport: String? = nil
                    if let noiseKey = Data(hexString: recipientID),
                       let favoriteStatus = FavoritesPersistenceService.shared.getFavoriteStatus(for: noiseKey),
                       favoriteStatus.peerNostrPublicKey != nil,
                       self.meshService.peerNickname(peerID: recipientID) == nil {
                        originalTransport = "nostr"
                    }
                    
                    self.sendReadReceipt(receipt, to: recipientID, originalTransport: originalTransport)
                }
                sentReadReceipts.insert(message.id)
            }
            
            // Mark other messages as read
            DispatchQueue.main.asyncAfter(deadline: .now() + TransportConfig.uiReadReceiptRetryShortSeconds) { [weak self] in
                self?.markPrivateMessagesAsRead(from: peerID)
            }
        }
    }
    
    /// Handle incoming public message
    @MainActor
    private func handlePublicMessage(_ message: BitchatMessage) {
        let finalMessage = processActionMessage(message)

        // Drop if sender is blocked
        if isMessageBlocked(finalMessage) { return }

        // Apply per-sender and per-content rate limits (drop if exceeded)
        if finalMessage.sender != "system" {
            let senderKey = normalizedSenderKey(for: finalMessage)
            let contentKey = normalizedContentKey(finalMessage.content)
            let now = Date()
            var sBucket = rateBucketsBySender[senderKey] ?? TokenBucket(capacity: senderBucketCapacity, tokens: senderBucketCapacity, refillPerSec: senderBucketRefill, lastRefill: now)
            let senderAllowed = sBucket.allow(now: now)
            rateBucketsBySender[senderKey] = sBucket
            var cBucket = rateBucketsByContent[contentKey] ?? TokenBucket(capacity: contentBucketCapacity, tokens: contentBucketCapacity, refillPerSec: contentBucketRefill, lastRefill: now)
            let contentAllowed = cBucket.allow(now: now)
            rateBucketsByContent[contentKey] = cBucket
            if !(senderAllowed && contentAllowed) { return }
        }

        // Size cap: drop extremely large public messages early
        if finalMessage.sender != "system" && finalMessage.content.count > 16000 { return }

        // Persist mesh messages to mesh timeline always
        if finalMessage.sender != "system" {
            meshTimeline.append(finalMessage)
            trimMeshTimelineIfNeeded()
        }
        // Removed background nudge notification for generic "new chats!"

        // Append via batching buffer (skip empty content) with simple dedup by ID
        if !finalMessage.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !messages.contains(where: { $0.id == finalMessage.id }) {
                enqueuePublic(finalMessage)
            }
        }
    }

    // MARK: - Public message batching helpers
    @MainActor
    private func enqueuePublic(_ message: BitchatMessage) {
        publicBuffer.append(message)
        schedulePublicFlush()
    }

    @MainActor
    private func schedulePublicFlush() {
        if publicBufferTimer != nil { return }
        publicBufferTimer = Timer.scheduledTimer(timeInterval: dynamicPublicFlushInterval,
                                                 target: self,
                                                 selector: #selector(flushPublicBuffer(_:)),
                                                 userInfo: nil,
                                                 repeats: false)
    }

    @objc @MainActor
    private func flushPublicBuffer(_ timer: Timer) {
        publicBufferTimer?.invalidate()
        publicBufferTimer = nil
        guard !publicBuffer.isEmpty else { return }

        // Dedup against existing by id and near-duplicate messages by content (within ~1s), across senders
        var seenIDs = Set(messages.map { $0.id })
        var added: [BitchatMessage] = []
        var batchContentLatest: [String: Date] = [:]
        for m in publicBuffer {
            if seenIDs.contains(m.id) { continue }
            let ckey = normalizedContentKey(m.content)
            if let ts = contentLRUMap[ckey], abs(ts.timeIntervalSince(m.timestamp)) < 1.0 { continue }
            if let ts = batchContentLatest[ckey], abs(ts.timeIntervalSince(m.timestamp)) < 1.0 { continue }
            seenIDs.insert(m.id)
            added.append(m)
            batchContentLatest[ckey] = m.timestamp
        }
        publicBuffer.removeAll(keepingCapacity: true)
        guard !added.isEmpty else { return }

        // Indicate batching for conditional UI animations
        isBatchingPublic = true
        // Rough chronological order: sort the batch by timestamp before inserting
        added.sort { $0.timestamp < $1.timestamp }
        // Insert late arrivals into approximate position; append recent ones
        let lastTs = messages.last?.timestamp ?? .distantPast
        for m in added {
            if m.timestamp < lastTs.addingTimeInterval(-lateInsertThreshold) {
                let idx = insertionIndexByTimestamp(m.timestamp)
                if idx >= messages.count { messages.append(m) } else { messages.insert(m, at: idx) }
            } else {
                messages.append(m)
            }
            // Record content key for LRU
            let ckey = normalizedContentKey(m.content)
            recordContentKey(ckey, timestamp: m.timestamp)
        }
        trimMessagesIfNeeded()
        // Update batch size stats and adjust interval
        recentBatchSizes.append(added.count)
        if recentBatchSizes.count > 10 { recentBatchSizes.removeFirst(recentBatchSizes.count - 10) }
        let avg = recentBatchSizes.isEmpty ? 0.0 : Double(recentBatchSizes.reduce(0, +)) / Double(recentBatchSizes.count)
        dynamicPublicFlushInterval = avg > 100.0 ? 0.12 : basePublicFlushInterval
        // Prewarm formatting cache for current UI color scheme only
        for m in added {
            _ = self.formatMessageAsText(m, colorScheme: currentColorScheme)
        }
        // Reset batching flag (already on main actor)
        isBatchingPublic = false
        // If new items arrived during this flush, coalesce by flushing once more next tick
        if !publicBuffer.isEmpty { schedulePublicFlush() }
    }
    
    @MainActor
    private func insertionIndexByTimestamp(_ ts: Date) -> Int {
        var low = 0
        var high = messages.count
        while low < high {
            let mid = (low + high) / 2
            if messages[mid].timestamp < ts {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
    
    /// Check for mentions and send notifications
    
    @MainActor private func checkForMentions(_ message: BitchatMessage) {
        // Determine our acceptable mention token. If any connected peer shares our nickname,
        // require the disambiguated form '<nickname>#<peerIDprefix>' to trigger.
        var myTokens: Set<String> = [nickname]
        let meshPeers = meshService.getPeerNicknames()
        let collisions = meshPeers.values.filter { $0.hasPrefix(nickname + "#") }
        if !collisions.isEmpty {
            let suffix = "#" + String(meshService.myPeerID.prefix(4))
            myTokens = [nickname + suffix]
        }
        let isMentioned = (message.mentions?.contains { myTokens.contains($0) } ?? false)
        
        if isMentioned && message.sender != nickname {
            SecureLogger.log("🔔 Mention from \(message.sender)",
                             category: SecureLogger.session, level: .info)
            NotificationService.shared.sendMentionNotification(from: message.sender, message: message.content)
        }
    }

/// Send haptic feedback for special messages (iOS only)
    @MainActor private func sendHapticFeedback(for message: BitchatMessage) {
        #if os(iOS)
        guard UIApplication.shared.applicationState == .active else { return }
        
        // Build acceptable target tokens: base nickname and, if in a location channel, nickname with '#abcd'
        let tokens: [String] = [nickname]

        let hugsMe = tokens.contains { message.content.contains("hugs \($0)") } || message.content.contains("hugs you")
        let slapsMe = tokens.contains { message.content.contains("slaps \($0) around") } || message.content.contains("slaps you around")

        let isHugForMe = message.content.contains("🫂") && hugsMe
        let isSlapForMe = message.content.contains("🐟") && slapsMe
        
        if isHugForMe && message.sender != nickname {
            // Long warm haptic for hugs
            let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
            impactFeedback.prepare()
            
            for i in 0..<8 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * TransportConfig.uiBatchDispatchStaggerSeconds) {
                    impactFeedback.impactOccurred()
                }
            }
        } else if isSlapForMe && message.sender != nickname {
            // Sharp haptic for slaps
            let impactFeedback = UIImpactFeedbackGenerator(style: .heavy)
            impactFeedback.prepare()
            impactFeedback.impactOccurred()
        }
        #endif
    }
}
// End of BitchatViewModel class
