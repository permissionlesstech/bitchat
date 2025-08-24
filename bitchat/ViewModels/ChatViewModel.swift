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
/// let viewModel = ChatViewModel()
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

/// Manages the application state and business logic for BitChat.
/// Acts as the primary coordinator between UI components and backend services,
/// implementing the BitchatDelegate protocol to handle network events.
class ChatViewModel: ObservableObject, BitchatDelegate {
    // MARK: - Published Properties
    
    @Published var messages: [BitchatMessage] = []
    private let maxMessages = 1337 // Maximum messages before oldest are removed
    @Published var isConnected = false
    private var hasNotifiedNetworkAvailable = false
    private var recentlySeenPeers: Set<String> = []
    private var lastNetworkNotificationTime = Date.distantPast
    private var networkResetTimer: Timer? = nil
    private let networkResetGraceSeconds: TimeInterval = 600 // 10 minutes; avoid refiring on short drops/reconnects
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
    
    private let commandProcessor: CommandProcessor
    private let messageRouter: MessageRouter
    private let privateChatManager: PrivateChatManager
    private let unifiedPeerService: UnifiedPeerService
    private let autocompleteService: AutocompleteService
    
    // Computed properties for compatibility
    @MainActor
    var connectedPeers: [String] { Array(unifiedPeerService.connectedPeerIDs) }
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
    
    // Missing properties that were removed during refactoring
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
    
    var meshService: Transport = BLEService()
    private var nostrRelayManager: NostrRelayManager?
    // PeerManager replaced by UnifiedPeerService
    private var processedNostrEvents = Set<String>()  // Simple deduplication
    private var processedNostrEventOrder: [String] = []
    private let maxProcessedNostrEvents = 2000
    private let userDefaults = UserDefaults.standard
    private let nicknameKey = "bitchat.nickname"
    // Location channel state
    #if os(iOS)
    @Published private var activeChannel: ChannelID = .mesh
    private var geoSubscriptionID: String? = nil
    private var geoDmSubscriptionID: String? = nil
    private var currentGeohash: String? = nil
    private var geoNicknames: [String: String] = [:] // pubkeyHex(lowercased) -> nickname
    #endif
    
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
    @Published var bluetoothState: CBManagerState = .unknown
    
    // Messages are naturally ephemeral - no persistent storage
    // Persist mesh public timeline across channel switches
    private var meshTimeline: [BitchatMessage] = []
    private let meshTimelineCap = 1337
    #if os(iOS)
    // Persist per-geohash public timelines across switches
    private var geoTimelines: [String: [BitchatMessage]] = [:] // geohash -> messages
    private let geoTimelineCap = 1337
    // Channel activity tracking for background nudges
    private var lastPublicActivityAt: [String: Date] = [:]   // channelKey -> last activity time
    private var lastPublicActivityNotifyAt: [String: Date] = [:]
    private let channelInactivityThreshold: TimeInterval = 9 * 60
    // Geohash participants (per geohash: pubkey -> lastSeen)
    private var geoParticipants: [String: [String: Date]] = [:]
    @Published private(set) var geohashPeople: [GeoPerson] = []
    private var geoParticipantsTimer: Timer? = nil
    // Participants who indicated they teleported (by tag in their events)
    @Published private(set) var teleportedGeo: Set<String> = []  // lowercased pubkey hex
    // Sampling subscriptions for multiple geohashes (when channel sheet is open)
    private var geoSamplingSubs: [String: String] = [:] // subID -> geohash
    #endif
    
    // MARK: - Message Delivery Tracking
    
    // Delivery tracking
    private var cancellables = Set<AnyCancellable>()
    
    // Track sent read receipts to avoid duplicates (persisted across launches)
    // Note: Persistence happens automatically in didSet, no lifecycle observers needed
    private var sentReadReceipts: Set<String> = [] {  // messageID set
        didSet {
            // Only persist if there are changes
            guard oldValue != sentReadReceipts else { return }
            
            // Persist to UserDefaults whenever it changes
            if let data = try? JSONEncoder().encode(Array(sentReadReceipts)) {
                UserDefaults.standard.set(data, forKey: "sentReadReceipts")
                // Force synchronization for immediate persistence (ensures data is written to disk)
                UserDefaults.standard.synchronize()
                
                // Verify persistence by re-reading
                if let verifyData = UserDefaults.standard.data(forKey: "sentReadReceipts"),
                   let _ = try? JSONDecoder().decode([String].self, from: verifyData) {
                    // Only log errors, not successful persistence
                    // Successfully persisted
                } else {
                    SecureLogger.log("⚠️ Failed to verify persistence of read receipts",
                                    category: SecureLogger.session, level: .error)
                }
            } else {
                SecureLogger.log("❌ Failed to encode read receipts for persistence",
                                category: SecureLogger.session, level: .error)
            }
        }
    }
    
    // Track processed Nostr ACKs to avoid duplicate processing
    private var processedNostrAcks: Set<String> = []  // "messageId:ackType:senderPubkey" format
    // Track which GeoDM messages we've already sent a delivery ACK for (by messageID)
    private var sentGeoDeliveryAcks: Set<String> = []
    
    // Track app startup phase to prevent marking old messages as unread
    private var isStartupPhase = true
    
    // Track Nostr pubkey mappings for unknown senders
    private var nostrKeyMapping: [String: String] = [:]  // senderPeerID -> nostrPubkey
    
    // MARK: - Initialization
    
    @MainActor
    init() {
        // Load persisted read receipts
        if let data = UserDefaults.standard.data(forKey: "sentReadReceipts"),
           let receipts = try? JSONDecoder().decode([String].self, from: data) {
            self.sentReadReceipts = Set(receipts)
            // Successfully loaded read receipts
        } else {
            // No persisted read receipts found
        }
        
        // Initialize services
        self.commandProcessor = CommandProcessor()
        self.privateChatManager = PrivateChatManager(meshService: meshService)
        self.unifiedPeerService = UnifiedPeerService(meshService: meshService)
        let nostrTransport = NostrTransport()
        self.messageRouter = MessageRouter(mesh: meshService, nostr: nostrTransport)
        // Route receipts from PrivateChatManager through MessageRouter
        self.privateChatManager.messageRouter = self.messageRouter
        self.autocompleteService = AutocompleteService()
        
        // Wire up dependencies
        self.commandProcessor.chatViewModel = self
        
        // Subscribe to privateChatManager changes to trigger UI updates
        privateChatManager.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        self.commandProcessor.meshService = meshService
        
        loadNickname()
        loadVerifiedFingerprints()
        meshService.delegate = self
        
        // Log startup info
        
        // Log fingerprint after a delay to ensure encryption service is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
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
            nostrRelayManager = NostrRelayManager.shared
            SecureLogger.log("Initializing Nostr relay connections", category: SecureLogger.session, level: .debug)
            nostrRelayManager?.connect()
            
            // Small delay to ensure read receipts are fully loaded
            // This prevents race conditions where messages arrive before initialization completes
            try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
            
            // Set up Nostr message handling directly
            setupNostrMessageHandling()

            // Attempt to flush any queued outbox after Nostr comes online
            messageRouter.flushAllOutbox()
            
            // End startup phase after 2 seconds
            // During startup phase, we:
            // 1. Skip cleanup of read receipts
            // 2. Only block OLD messages from being marked as unread
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                self.isStartupPhase = false
            }
            
            // Bind unified peer service's peer list to our published property
            let cancellable = unifiedPeerService.$peers
                .receive(on: DispatchQueue.main)
                .sink { [weak self] peers in
                    guard let self = self else { return }
                    // Update peers directly
                    self.allPeers = peers
                    // Force UI update
                    self.objectWillChange.send()
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

            // Resubscribe geohash on relay reconnect (iOS only)
            #if os(iOS)
            if let relayMgr = self.nostrRelayManager {
                relayMgr.$isConnected
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] connected in
                        guard let self = self else { return }
                        if connected {
                            Task { @MainActor in
                                self.resubscribeCurrentGeohash()
                            }
                        }
                    }
                    .store(in: &self.cancellables)
            }
            #endif
        }

        // Set up Noise encryption callbacks
        setupNoiseCallbacks()

        #if os(iOS)
        // Observe location channel selection
        LocationChannelManager.shared.$selectedChannel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] channel in
                guard let self = self else { return }
                Task { @MainActor in
                    self.switchLocationChannel(to: channel)
                }
            }
            .store(in: &cancellables)
        // Initialize with current selection
        Task { @MainActor in
            self.switchLocationChannel(to: LocationChannelManager.shared.selectedChannel)
        }
        #endif
        
        // Request notification permission
        NotificationService.shared.requestAuthorization()
        
        
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
        // Resubscribe geohash on app foreground
        // Resubscribe handled via appDidBecomeActive selector
        
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

    #if os(iOS)
    // Resubscribe to the active geohash channel without clearing timeline
    @MainActor
    private func resubscribeCurrentGeohash() {
        guard case .location(let ch) = activeChannel else { return }
        guard let subID = geoSubscriptionID else {
            // No existing subscription; set it up
            switchLocationChannel(to: activeChannel)
            return
        }
        // Ensure participant decay timer is running
        startGeoParticipantsTimer()
        // Unsubscribe + resubscribe
        NostrRelayManager.shared.unsubscribe(id: subID)
        let filter = NostrFilter.geohashEphemeral(ch.geohash, since: Date().addingTimeInterval(-3600), limit: 200)
        NostrRelayManager.shared.subscribe(filter: filter, id: subID) { [weak self] event in
            guard let self = self else { return }
            guard event.kind == NostrProtocol.EventKind.ephemeralEvent.rawValue else { return }
            if self.processedNostrEvents.contains(event.id) { return }
            self.processedNostrEvents.insert(event.id)
            if let gh = self.currentGeohash,
               let myGeoIdentity = try? NostrIdentityBridge.deriveIdentity(forGeohash: gh),
               myGeoIdentity.publicKeyHex.lowercased() == event.pubkey.lowercased() { return }
            if let nickTag = event.tags.first(where: { $0.first == "n" }), nickTag.count >= 2 {
                let nick = nickTag[1]
                self.geoNicknames[event.pubkey.lowercased()] = nick
            }
            // Store mapping for geohash sender IDs used in messages (ensures consistent colors)
            let key16 = "nostr_" + String(event.pubkey.prefix(16))
            self.nostrKeyMapping[key16] = event.pubkey
            let key8 = "nostr:" + String(event.pubkey.prefix(8))
            self.nostrKeyMapping[key8] = event.pubkey

            // Update participants last-seen for this pubkey
            self.recordGeoParticipant(pubkeyHex: event.pubkey)
            
            // Track teleported tag (only our format ["t","teleport"]) for icon state
            let hasTeleportTag = event.tags.contains(where: { tag in
                tag.count >= 2 && tag[0].lowercased() == "t" && tag[1].lowercased() == "teleport"
            })
            if hasTeleportTag {
                let key = event.pubkey.lowercased()
                Task { @MainActor in self.teleportedGeo = self.teleportedGeo.union([key]) }
            }
            let senderName = self.displayNameForNostrPubkey(event.pubkey)
            let content = event.content
            let timestamp = Date(timeIntervalSince1970: TimeInterval(event.created_at))
            let mentions = self.parseMentions(from: content)
            let msg = BitchatMessage(
                id: event.id,
                sender: senderName,
                content: content,
                timestamp: timestamp,
                isRelay: false,
                originalSender: nil,
                isPrivate: false,
                recipientNickname: nil,
                senderPeerID: "nostr:\(event.pubkey.prefix(8))",
                mentions: mentions.isEmpty ? nil : mentions
            )
            Task { @MainActor in
                self.handlePublicMessage(msg)
                self.checkForMentions(msg)
                self.sendHapticFeedback(for: msg)
            }
        }
        // Resubscribe geohash DMs for this identity
        if let dmSub = geoDmSubscriptionID { NostrRelayManager.shared.unsubscribe(id: dmSub); geoDmSubscriptionID = nil }
        do {
            let id = try NostrIdentityBridge.deriveIdentity(forGeohash: ch.geohash)
            let dmSub = "geo-dm-\(ch.geohash)"
            geoDmSubscriptionID = dmSub
            let dmFilter = NostrFilter.giftWrapsFor(pubkey: id.publicKeyHex, since: Date().addingTimeInterval(-86400))
            NostrRelayManager.shared.subscribe(filter: dmFilter, id: dmSub) { [weak self] giftWrap in
                guard let self = self else { return }
                if self.processedNostrEvents.contains(giftWrap.id) { return }
                self.recordProcessedEvent(giftWrap.id)
                guard let (content, senderPubkey, rumorTs) = try? NostrProtocol.decryptPrivateMessage(giftWrap: giftWrap, recipientIdentity: id) else { return }
                guard content.hasPrefix("bitchat1:") else { return }
                guard let packetData = Self.base64URLDecode(String(content.dropFirst("bitchat1:".count))),
                      let packet = BitchatPacket.from(packetData) else { return }
                guard packet.type == MessageType.noiseEncrypted.rawValue else { return }
                guard let noisePayload = NoisePayload.decode(packet.payload) else { return }
                let messageTimestamp = Date(timeIntervalSince1970: TimeInterval(rumorTs))
                let convKey = "nostr_" + String(senderPubkey.prefix(16))
                self.nostrKeyMapping[convKey] = senderPubkey
                switch noisePayload.type {
                case .privateMessage:
                    guard let pm = PrivateMessagePacket.decode(from: noisePayload.data) else { return }
                    let messageId = pm.messageID
                    // Send delivery ACK immediately (once per message ID)
                    if !self.sentGeoDeliveryAcks.contains(messageId) {
                        let nt = NostrTransport()
                        nt.senderPeerID = self.meshService.myPeerID
                        nt.sendDeliveryAckGeohash(for: messageId, toRecipientHex: senderPubkey, from: id)
                        self.sentGeoDeliveryAcks.insert(messageId)
                    }
                    // Dedup storage
                    if self.privateChats[convKey]?.contains(where: { $0.id == messageId }) == true { return }
                    for (_, arr) in self.privateChats { if arr.contains(where: { $0.id == messageId }) { return } }
                    let senderName = self.displayNameForNostrPubkey(senderPubkey)
                    let isViewing = (self.selectedPrivateChatPeer == convKey)
                    // pared back: omit view-state log
                    let wasReadBefore = self.sentReadReceipts.contains(messageId)
                    let isRecentMessage = Date().timeIntervalSince(messageTimestamp) < 30
                    let shouldMarkUnread = !wasReadBefore && !isViewing && isRecentMessage
                let msg = BitchatMessage(
                    id: messageId,
                    sender: senderName,
                    content: pm.content,
                    timestamp: messageTimestamp,
                    isRelay: false,
                    originalSender: nil,
                    isPrivate: true,
                    recipientNickname: self.nickname,
                    senderPeerID: convKey,
                    mentions: nil,
                    deliveryStatus: .delivered(to: self.nickname, at: Date())
                )
                    // Respect geohash blocks
                    if SecureIdentityStateManager.shared.isNostrBlocked(pubkeyHexLowercased: senderPubkey) {
                        return
                    }
                    if self.privateChats[convKey] == nil { self.privateChats[convKey] = [] }
                    self.privateChats[convKey]?.append(msg)
                    self.trimPrivateChatMessagesIfNeeded(for: convKey)
                    if shouldMarkUnread { self.unreadPrivateMessages.insert(convKey) }
                    if isViewing {
                        // pared back: omit pre-send READ log
                        if !wasReadBefore {
                            let nt = NostrTransport()
                            nt.senderPeerID = self.meshService.myPeerID
                            nt.sendReadReceiptGeohash(messageId, toRecipientHex: senderPubkey, from: id)
                            self.sentReadReceipts.insert(messageId)
                        }
                    } else {
                        // Optionally notify if app backgrounded and message is truly unread
                        #if os(iOS)
                        if shouldMarkUnread && UIApplication.shared.applicationState != .active {
                            NotificationService.shared.sendPrivateMessageNotification(
                                from: senderName,
                                message: pm.content,
                                peerID: convKey
                            )
                        }
                        #endif
                    }
                    self.objectWillChange.send()
                case .delivered:
                    if let messageID = String(data: noisePayload.data, encoding: .utf8) {
                        if let idx = self.privateChats[convKey]?.firstIndex(where: { $0.id == messageID }) {
                            self.privateChats[convKey]?[idx].deliveryStatus = .delivered(to: self.displayNameForNostrPubkey(senderPubkey), at: Date())
                            self.objectWillChange.send()
                            SecureLogger.log("GeoDM: recv DELIVERED for mid=\(messageID.prefix(8))… from=\(senderPubkey.prefix(8))…",
                                            category: SecureLogger.session, level: .info)
                        } else {
                            SecureLogger.log("GeoDM: delivered ack for unknown mid=\(messageID.prefix(8))… conv=\(convKey)",
                                            category: SecureLogger.session, level: .warning)
                        }
                    }
                case .readReceipt:
                    if let messageID = String(data: noisePayload.data, encoding: .utf8) {
                        if let idx = self.privateChats[convKey]?.firstIndex(where: { $0.id == messageID }) {
                            self.privateChats[convKey]?[idx].deliveryStatus = .read(by: self.displayNameForNostrPubkey(senderPubkey), at: Date())
                            self.objectWillChange.send()
                            SecureLogger.log("GeoDM: recv READ for mid=\(messageID.prefix(8))… from=\(senderPubkey.prefix(8))…",
                                            category: SecureLogger.session, level: .info)
                        } else {
                            SecureLogger.log("GeoDM: read ack for unknown mid=\(messageID.prefix(8))… conv=\(convKey)",
                                            category: SecureLogger.session, level: .warning)
                        }
                    }
                }
            }
        } catch { }
    }
    #endif

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
        
        // Get the peer's nickname to check for temporary Nostr peer IDs
        let peerNickname = meshService.peerNickname(peerID: peerID)?.lowercased() ?? ""

        // Check if any temporary Nostr peer IDs have unread messages from this nickname
        for unreadPeerID in unreadPrivateMessages {
            if unreadPeerID.hasPrefix("nostr_") {
                // Check if messages from this temporary peer match the nickname
                if let messages = privateChats[unreadPeerID],
                   let firstMessage = messages.first,
                   firstMessage.sender.lowercased() == peerNickname {
                    return true
                }
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
    
    // Called when we receive a peer's public key
    @MainActor
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
                    trimPrivateChatMessagesIfNeeded(for: currentPeerID)
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
            #if os(iOS)
            var displaySender = nickname
            var localSenderPeerID = meshService.myPeerID
            if case .location(let ch) = activeChannel,
               let myGeoIdentity = try? NostrIdentityBridge.deriveIdentity(forGeohash: ch.geohash) {
                let suffix = String(myGeoIdentity.publicKeyHex.suffix(4))
                displaySender = nickname + "#" + suffix
                localSenderPeerID = "nostr:\(myGeoIdentity.publicKeyHex.prefix(8))"
            }
            #else
            let displaySender = nickname
            let localSenderPeerID = meshService.myPeerID
            #endif

            let message = BitchatMessage(
                sender: displaySender,
                content: content,
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
            // Persist to channel-specific timelines
            #if os(iOS)
            switch activeChannel {
            case .mesh:
                meshTimeline.append(message)
                trimMeshTimelineIfNeeded()
            case .location(let ch):
                var arr = geoTimelines[ch.geohash] ?? []
                arr.append(message)
                if arr.count > geoTimelineCap {
                    let remove = arr.count - geoTimelineCap
                    arr.removeFirst(remove)
                }
                geoTimelines[ch.geohash] = arr
            }
            #else
            meshTimeline.append(message)
            trimMeshTimelineIfNeeded()
            #endif
            trimMessagesIfNeeded()
            
            // Force immediate UI update for user's own messages
            objectWillChange.send()

            // Update channel activity time on send
            #if os(iOS)
            switch activeChannel {
            case .mesh:
                lastPublicActivityAt["mesh"] = Date()
            case .location(let ch):
                lastPublicActivityAt["geo:\(ch.geohash)"] = Date()
            }
            #endif
            
            #if os(iOS)
            if case .location(let ch) = activeChannel {
                // Send to geohash channel via Nostr ephemeral
                Task { @MainActor in
                    do {
                        let identity = try NostrIdentityBridge.deriveIdentity(forGeohash: ch.geohash)
                        let event = try NostrProtocol.createEphemeralGeohashEvent(
                            content: content,
                            geohash: ch.geohash,
                            senderIdentity: identity,
                            nickname: self.nickname,
                            teleported: LocationChannelManager.shared.teleported
                        )
                        NostrRelayManager.shared.sendEvent(event)
                        // Track ourselves as active participant
                        self.recordGeoParticipant(pubkeyHex: identity.publicKeyHex)
                        SecureLogger.log("GeoTeleport: sent geo message pub=\(identity.publicKeyHex.prefix(8))… teleported=\(LocationChannelManager.shared.teleported)",
                                        category: SecureLogger.session, level: .debug)
                        // If we tagged this as teleported, also mark our pubkey in teleportedGeo for UI
                        if LocationChannelManager.shared.teleported {
                            let key = identity.publicKeyHex.lowercased()
                            self.teleportedGeo = self.teleportedGeo.union([key])
                            SecureLogger.log("GeoTeleport: mark self teleported key=\(key.prefix(8))… total=\(self.teleportedGeo.count)",
                                            category: SecureLogger.session, level: .info)
                        }
                    } catch {
                        SecureLogger.log("❌ Failed to send geohash message: \(error)", category: SecureLogger.session, level: .error)
                        self.addSystemMessage("failed to send to location channel")
                    }
                }
            } else {
                // Send via mesh with mentions
                meshService.sendMessage(content, mentions: mentions)
            }
            #else
            // Send via mesh with mentions (non-iOS)
            meshService.sendMessage(content, mentions: mentions)
            #endif
        }
    }

    #if os(iOS)
    @MainActor
    private func switchLocationChannel(to channel: ChannelID) {
        activeChannel = channel
        // Reset deduplication set and optionally hydrate timeline for mesh
        processedNostrEvents.removeAll()
        processedNostrEventOrder.removeAll()
        switch channel {
        case .mesh:
            messages = meshTimeline
            stopGeoParticipantsTimer()
            geohashPeople = []
            teleportedGeo.removeAll()
        case .location(let ch):
            // Sanitize existing timeline (filter any prior empty-content entries)
            var arr = geoTimelines[ch.geohash] ?? []
            let before = arr.count
            arr.removeAll { $0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if arr.count != before { geoTimelines[ch.geohash] = arr }
            messages = arr
        }
        // Unsubscribe previous
        if let sub = geoSubscriptionID {
            NostrRelayManager.shared.unsubscribe(id: sub)
            geoSubscriptionID = nil
        }
        if let dmSub = geoDmSubscriptionID {
            NostrRelayManager.shared.unsubscribe(id: dmSub)
            geoDmSubscriptionID = nil
        }
        currentGeohash = nil
        // Reset nickname cache for geochat participants
        geoNicknames.removeAll()
        geohashPeople = []
        
        guard case .location(let ch) = channel else { return }
        currentGeohash = ch.geohash
        // Ensure self appears immediately in the people list; mark teleported state if applicable
        if let id = try? NostrIdentityBridge.deriveIdentity(forGeohash: ch.geohash) {
            self.recordGeoParticipant(pubkeyHex: id.publicKeyHex)
            #if os(iOS)
            if LocationChannelManager.shared.teleported {
                let key = id.publicKeyHex.lowercased()
                teleportedGeo = teleportedGeo.union([key])
                SecureLogger.log("GeoTeleport: channel switch mark self teleported key=\(key.prefix(8))… total=\(teleportedGeo.count)",
                                category: SecureLogger.session, level: .info)
            }
            #endif
        }
        let subID = "geo-\(ch.geohash)"
        geoSubscriptionID = subID
        startGeoParticipantsTimer()
        let filter = NostrFilter.geohashEphemeral(ch.geohash, since: Date().addingTimeInterval(-3600), limit: 200)
        NostrRelayManager.shared.subscribe(filter: filter, id: subID) { [weak self] event in
            guard let self = self else { return }
            // Only handle ephemeral kind 20000 with matching tag
            guard event.kind == NostrProtocol.EventKind.ephemeralEvent.rawValue else { return }
            // Deduplicate
            if self.processedNostrEvents.contains(event.id) { return }
            self.recordProcessedEvent(event.id)
            // Log incoming tags for diagnostics
            let tagSummary = event.tags.map { "[" + $0.joined(separator: ",") + "]" }.joined(separator: ",")
            SecureLogger.log("GeoTeleport: recv pub=\(event.pubkey.prefix(8))… tags=\(tagSummary)",
                            category: SecureLogger.session, level: .debug)
            // Track teleport tag for participants – only our format ["t", "teleport"]
            let hasTeleportTag: Bool = event.tags.contains(where: { tag in
                tag.count >= 2 && tag[0].lowercased() == "t" && tag[1].lowercased() == "teleport"
            })
            if hasTeleportTag {
                let key = event.pubkey.lowercased()
                Task { @MainActor in
                    self.teleportedGeo = self.teleportedGeo.union([key])
                    SecureLogger.log("GeoTeleport: mark peer teleported key=\(key.prefix(8))… total=\(self.teleportedGeo.count)",
                                    category: SecureLogger.session, level: .info)
                }
            }
            // Skip our own events (we already locally echoed)
            if let gh = self.currentGeohash,
               let myGeoIdentity = try? NostrIdentityBridge.deriveIdentity(forGeohash: gh),
               myGeoIdentity.publicKeyHex.lowercased() == event.pubkey.lowercased() {
                return
            }
            // Cache nickname from tag if present
            if let nickTag = event.tags.first(where: { $0.first == "n" }), nickTag.count >= 2 {
                let nick = nickTag[1]
                self.geoNicknames[event.pubkey.lowercased()] = nick
            }
            // If this pubkey is blocked, skip mapping, participants, and timeline
            if SecureIdentityStateManager.shared.isNostrBlocked(pubkeyHexLowercased: event.pubkey) {
                return
            }
            // Store mapping for geohash DM initiation
            let key16 = "nostr_" + String(event.pubkey.prefix(16))
            self.nostrKeyMapping[key16] = event.pubkey
            let key8 = "nostr:" + String(event.pubkey.prefix(8))
            self.nostrKeyMapping[key8] = event.pubkey
            // Update participants last-seen for this pubkey
            self.recordGeoParticipant(pubkeyHex: event.pubkey)
            
            let senderName = self.displayNameForNostrPubkey(event.pubkey)
            let content = event.content
            // If this is a teleport presence event (no content), don't add to timeline
            if let teleTag = event.tags.first(where: { $0.first == "t" }), teleTag.count >= 2, (teleTag[1] == "teleport"),
               content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return
            }
            let timestamp = Date(timeIntervalSince1970: TimeInterval(event.created_at))
            let mentions = self.parseMentions(from: content)
            let msg = BitchatMessage(
                id: event.id,
                sender: senderName,
                content: content,
                timestamp: timestamp,
                isRelay: false,
                originalSender: nil,
                isPrivate: false,
                recipientNickname: nil,
                senderPeerID: "nostr:\(event.pubkey.prefix(8))",
                mentions: mentions.isEmpty ? nil : mentions
            )
            Task { @MainActor in
                self.handlePublicMessage(msg)
                self.checkForMentions(msg)
                self.sendHapticFeedback(for: msg)
            }
        }

        // Subscribe to Nostr gift wraps (DMs) for this geohash identity
        do {
            let id = try NostrIdentityBridge.deriveIdentity(forGeohash: ch.geohash)
            let dmSub = "geo-dm-\(ch.geohash)"
            geoDmSubscriptionID = dmSub
            // pared back logging: subscribe debug only
            SecureLogger.log("GeoDM: subscribing DMs pub=\(id.publicKeyHex.prefix(8))… sub=\(dmSub)",
                            category: SecureLogger.session, level: .debug)
            let dmFilter = NostrFilter.giftWrapsFor(pubkey: id.publicKeyHex, since: Date().addingTimeInterval(-86400))
            NostrRelayManager.shared.subscribe(filter: dmFilter, id: dmSub) { [weak self] giftWrap in
                guard let self = self else { return }
                // Dedup basic
                if self.processedNostrEvents.contains(giftWrap.id) { return }
                self.recordProcessedEvent(giftWrap.id)
                // Decrypt with per-geohash identity
                guard let (content, senderPubkey, rumorTs) = try? NostrProtocol.decryptPrivateMessage(giftWrap: giftWrap, recipientIdentity: id) else {
                    SecureLogger.log("GeoDM: failed decrypt giftWrap id=\(giftWrap.id.prefix(8))…",
                                    category: SecureLogger.session, level: .warning)
                    return
                }
                SecureLogger.log("GeoDM: decrypted gift-wrap id=\(giftWrap.id.prefix(16))... from=\(senderPubkey.prefix(8))...",
                                category: SecureLogger.session, level: .debug)
                guard content.hasPrefix("bitchat1:") else { return }
                guard let packetData = Self.base64URLDecode(String(content.dropFirst("bitchat1:".count))),
                      let packet = BitchatPacket.from(packetData) else { return }
                guard packet.type == MessageType.noiseEncrypted.rawValue else { return }
                guard let noisePayload = NoisePayload.decode(packet.payload) else { return }
                let messageTimestamp = Date(timeIntervalSince1970: TimeInterval(rumorTs))
                let convKey = "nostr_" + String(senderPubkey.prefix(16))
                self.nostrKeyMapping[convKey] = senderPubkey
                switch noisePayload.type {
                case .privateMessage:
                    guard let pm = PrivateMessagePacket.decode(from: noisePayload.data) else { return }
                    let messageId = pm.messageID
                    SecureLogger.log("GeoDM: recv PM <- sender=\(senderPubkey.prefix(8))… mid=\(messageId.prefix(8))…",
                                    category: SecureLogger.session, level: .info)
                    // Send delivery ACK immediately (even if duplicate), once per messageID
                    if !self.sentGeoDeliveryAcks.contains(messageId) {
                        let nostrTransport = NostrTransport()
                        nostrTransport.senderPeerID = self.meshService.myPeerID
                    // pared back: omit pre-send log
                        nostrTransport.sendDeliveryAckGeohash(for: messageId, toRecipientHex: senderPubkey, from: id)
                        self.sentGeoDeliveryAcks.insert(messageId)
                    }
                    // Duplicate check
                    if self.privateChats[convKey]?.contains(where: { $0.id == messageId }) == true { return }
                    for (_, arr) in self.privateChats { if arr.contains(where: { $0.id == messageId }) { return } }
                    let senderName = self.displayNameForNostrPubkey(senderPubkey)
                    let isViewing = (self.selectedPrivateChatPeer == convKey)
                    let wasReadBefore = self.sentReadReceipts.contains(messageId)
                    let isRecentMessage = Date().timeIntervalSince(messageTimestamp) < 30
                    let shouldMarkUnread = !wasReadBefore && !isViewing && isRecentMessage
                    let msg = BitchatMessage(
                        id: messageId,
                        sender: senderName,
                        content: pm.content,
                        timestamp: messageTimestamp,
                        isRelay: false,
                        originalSender: nil,
                        isPrivate: true,
                        recipientNickname: self.nickname,
                        senderPeerID: convKey,
                        mentions: nil,
                        deliveryStatus: .delivered(to: self.nickname, at: Date())
                    )
                    if self.privateChats[convKey] == nil { self.privateChats[convKey] = [] }
                    self.privateChats[convKey]?.append(msg)
                    self.trimPrivateChatMessagesIfNeeded(for: convKey)
                    if shouldMarkUnread { self.unreadPrivateMessages.insert(convKey) }
                    // Send READ if viewing this conversation
                    if isViewing {
                        // pared back: omit pre-send READ log
                        if !wasReadBefore {
                            let nostrTransport = NostrTransport()
                            nostrTransport.senderPeerID = self.meshService.myPeerID
                            nostrTransport.sendReadReceiptGeohash(messageId, toRecipientHex: senderPubkey, from: id)
                            self.sentReadReceipts.insert(messageId)
                        }
                    } else {
                        // pared back: omit defer READ log
                    }
                    // Notify only when app is backgrounded and not viewing, and only if not already read
                    #if os(iOS)
                    if !isViewing && shouldMarkUnread {
                        if UIApplication.shared.applicationState != .active {
                            NotificationService.shared.sendPrivateMessageNotification(
                                from: senderName,
                                message: pm.content,
                                peerID: convKey
                            )
                            // pared back: omit notification log
                        }
                    }
                    #endif
                    self.objectWillChange.send()
                default:
                    // Handle delivered/read receipts for our sent messages
                    switch noisePayload.type {
                    case .delivered:
                        if let messageID = String(data: noisePayload.data, encoding: .utf8) {
                            if let idx = self.privateChats[convKey]?.firstIndex(where: { $0.id == messageID }) {
                                self.privateChats[convKey]?[idx].deliveryStatus = .delivered(to: self.displayNameForNostrPubkey(senderPubkey), at: Date())
                                self.objectWillChange.send()
                                SecureLogger.log("GeoDM: recv DELIVERED for mid=\(messageID.prefix(8))… from=\(senderPubkey.prefix(8))…",
                                                category: SecureLogger.session, level: .info)
                            } else {
                                SecureLogger.log("GeoDM: delivered ack for unknown mid=\(messageID.prefix(8))… conv=\(convKey)",
                                                category: SecureLogger.session, level: .warning)
                            }
                        }
                    case .readReceipt:
                        if let messageID = String(data: noisePayload.data, encoding: .utf8) {
                            if let idx = self.privateChats[convKey]?.firstIndex(where: { $0.id == messageID }) {
                                self.privateChats[convKey]?[idx].deliveryStatus = .read(by: self.displayNameForNostrPubkey(senderPubkey), at: Date())
                                self.objectWillChange.send()
                                SecureLogger.log("GeoDM: recv READ for mid=\(messageID.prefix(8))… from=\(senderPubkey.prefix(8))…",
                                                category: SecureLogger.session, level: .info)
                            } else {
                                SecureLogger.log("GeoDM: read ack for unknown mid=\(messageID.prefix(8))… conv=\(convKey)",
                                                category: SecureLogger.session, level: .warning)
                            }
                        }
                    default:
                        break
                    }
                }
            }
        } catch {
            // ignore
        }
        // Presence announcement removed; we will tag actual chat events instead
    }

    // MARK: - Geohash Participants (iOS)
    #if os(iOS)
    struct GeoPerson: Identifiable, Equatable {
        let id: String        // pubkey hex (lowercased)
        let displayName: String
        let lastSeen: Date
    }

    private func recordGeoParticipant(pubkeyHex: String) {
        guard let gh = currentGeohash else { return }
        let key = pubkeyHex.lowercased()
        var map = geoParticipants[gh] ?? [:]
        map[key] = Date()
        geoParticipants[gh] = map
        refreshGeohashPeople()
    }

    private func recordGeoParticipant(pubkeyHex: String, geohash: String) {
        let key = pubkeyHex.lowercased()
        var map = geoParticipants[geohash] ?? [:]
        map[key] = Date()
        geoParticipants[geohash] = map
        // Only refresh list if this geohash is currently selected
        if currentGeohash == geohash {
            refreshGeohashPeople()
        }
    }

    private func refreshGeohashPeople() {
        guard let gh = currentGeohash else { geohashPeople = []; return }
        let cutoff = Date().addingTimeInterval(-5 * 60)
        var map = geoParticipants[gh] ?? [:]
        // Prune expired entries
        map = map.filter { $0.value >= cutoff }
        // Remove blocked Nostr pubkeys
        map = map.filter { !SecureIdentityStateManager.shared.isNostrBlocked(pubkeyHexLowercased: $0.key) }
        geoParticipants[gh] = map
        // Build display list
        let people = map
            .map { (pub, seen) in
                GeoPerson(id: pub, displayName: displayNameForNostrPubkey(pub), lastSeen: seen)
            }
            .sorted { $0.lastSeen > $1.lastSeen }
        geohashPeople = people
    }

    private func startGeoParticipantsTimer() {
        stopGeoParticipantsTimer()
        geoParticipantsTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshGeohashPeople()
            }
        }
    }

    private func stopGeoParticipantsTimer() {
        geoParticipantsTimer?.invalidate()
        geoParticipantsTimer = nil
    }
    #endif

    // MARK: - Public helpers (iOS)
    #if os(iOS)
    /// Return the current, pruned, sorted people list for the active geohash without mutating state.
    @MainActor
    func visibleGeohashPeople() -> [GeoPerson] {
        guard let gh = currentGeohash else { return [] }
        let cutoff = Date().addingTimeInterval(-5 * 60)
        let map = (geoParticipants[gh] ?? [:])
            .filter { $0.value >= cutoff }
            .filter { !SecureIdentityStateManager.shared.isNostrBlocked(pubkeyHexLowercased: $0.key) }
        let people = map
            .map { (pub, seen) in GeoPerson(id: pub, displayName: displayNameForNostrPubkey(pub), lastSeen: seen) }
            .sorted { $0.lastSeen > $1.lastSeen }
        return people
    }
    /// Returns the current participant count for a specific geohash, using the 5-minute activity window.
    @MainActor
    func geohashParticipantCount(for geohash: String) -> Int {
        let cutoff = Date().addingTimeInterval(-5 * 60)
        let map = geoParticipants[geohash] ?? [:]
        return map.values.filter { $0 >= cutoff }.count
    }

    // Geohash block helpers
    @MainActor
    func isGeohashUserBlocked(pubkeyHexLowercased: String) -> Bool {
        return SecureIdentityStateManager.shared.isNostrBlocked(pubkeyHexLowercased: pubkeyHexLowercased)
    }
    @MainActor
    func blockGeohashUser(pubkeyHexLowercased: String, displayName: String) {
        let hex = pubkeyHexLowercased.lowercased()
        SecureIdentityStateManager.shared.setNostrBlocked(hex, isBlocked: true)
        
        // Remove from participants for all geohashes
        for (gh, var map) in geoParticipants {
            map.removeValue(forKey: hex)
            geoParticipants[gh] = map
        }
        refreshGeohashPeople()
        
        // Remove their public messages from current geohash timeline and visible list
        if let gh = currentGeohash {
            if var arr = geoTimelines[gh] {
                arr.removeAll { msg in
                    if let spid = msg.senderPeerID, spid.hasPrefix("nostr") {
                        if let full = nostrKeyMapping[spid]?.lowercased() { return full == hex }
                    }
                    return false
                }
                geoTimelines[gh] = arr
            }
            // Also filter currently bound messages if we are in geohash channel
            switch activeChannel {
            case .location:
                messages.removeAll { msg in
                    if let spid = msg.senderPeerID, spid.hasPrefix("nostr") {
                        if let full = nostrKeyMapping[spid]?.lowercased() { return full == hex }
                    }
                    return false
                }
            default:
                break
            }
        }
        
        // Remove geohash DM conversation if exists
        let convKey = "nostr_" + String(hex.prefix(16))
        if privateChats[convKey] != nil {
            privateChats.removeValue(forKey: convKey)
            unreadPrivateMessages.remove(convKey)
        }
        
        // Remove mapping keys pointing to this pubkey to avoid accidental resolution
        for (k, v) in nostrKeyMapping where v.lowercased() == hex { nostrKeyMapping.removeValue(forKey: k) }
        
        addSystemMessage("blocked \(displayName) in geohash chats")
    }
    @MainActor
    func unblockGeohashUser(pubkeyHexLowercased: String, displayName: String) {
        SecureIdentityStateManager.shared.setNostrBlocked(pubkeyHexLowercased, isBlocked: false)
        addSystemMessage("unblocked \(displayName) in geohash chats")
    }

    /// Begin sampling multiple geohashes (used by channel sheet) without changing active channel.
    @MainActor
    func beginGeohashSampling(for geohashes: [String]) {
        // Determine which to add and which to remove
        let desired = Set(geohashes)
        let current = Set(geoSamplingSubs.values)
        let toAdd = desired.subtracting(current)
        let toRemove = current.subtracting(desired)

        // Unsubscribe removed
        for (subID, gh) in geoSamplingSubs where toRemove.contains(gh) {
            NostrRelayManager.shared.unsubscribe(id: subID)
            geoSamplingSubs.removeValue(forKey: subID)
        }

        // Subscribe new
        for gh in toAdd {
            let subID = "geo-sample-\(gh)"
            geoSamplingSubs[subID] = gh
            let filter = NostrFilter.geohashEphemeral(gh, since: Date().addingTimeInterval(-300), limit: 100)
            NostrRelayManager.shared.subscribe(filter: filter, id: subID) { [weak self] event in
                guard let self = self else { return }
                guard event.kind == NostrProtocol.EventKind.ephemeralEvent.rawValue else { return }
                // Update participants for this specific geohash
                self.recordGeoParticipant(pubkeyHex: event.pubkey, geohash: gh)
            }
        }
    }

    /// Stop sampling all extra geohashes.
    @MainActor
    func endGeohashSampling() {
        for subID in geoSamplingSubs.keys { NostrRelayManager.shared.unsubscribe(id: subID) }
        geoSamplingSubs.removeAll()
    }
    #endif

    private func displayNameForNostrPubkey(_ pubkeyHex: String) -> String {
        let suffix = String(pubkeyHex.suffix(4))
        // If this is our per-geohash identity, use our nickname
        if let gh = currentGeohash, let myGeoIdentity = try? NostrIdentityBridge.deriveIdentity(forGeohash: gh) {
            if myGeoIdentity.publicKeyHex.lowercased() == pubkeyHex.lowercased() {
                return nickname + "#" + suffix
            }
        }
        // If we have a known nickname tag for this pubkey, use it
        if let nick = geoNicknames[pubkeyHex.lowercased()], !nick.isEmpty {
            return nick + "#" + suffix
        }
        // Otherwise, anonymous with collision-resistant suffix
        return "anon#\(suffix)"
    }

    // Helper: display name for current active channel (for notifications)
    private func activeChannelDisplayName() -> String {
        #if os(iOS)
        switch activeChannel {
        case .mesh:
            return "#mesh"
        case .location(let ch):
            return "#\(ch.geohash)"
        }
        #else
        return "#mesh"
        #endif
    }

    // Dedup helper with small memory cap
    private func recordProcessedEvent(_ id: String) {
        processedNostrEvents.insert(id)
        processedNostrEventOrder.append(id)
        if processedNostrEventOrder.count > maxProcessedNostrEvents {
            let overflow = processedNostrEventOrder.count - maxProcessedNostrEvents
            for _ in 0..<overflow {
                if let old = processedNostrEventOrder.first {
                    processedNostrEventOrder.removeFirst()
                    processedNostrEvents.remove(old)
                }
            }
        }
    }
    #endif
    
    /// Sends an encrypted private message to a specific peer.
    /// - Parameters:
    ///   - content: The message content to encrypt and send
    ///   - peerID: The recipient's peer ID
    /// - Note: Automatically establishes Noise encryption if not already active
    @MainActor
    func sendPrivateMessage(_ content: String, to peerID: String) {
        guard !content.isEmpty else { return }
        
        // Geohash DM routing: conversation keys start with "nostr_"
        #if os(iOS)
        if peerID.hasPrefix("nostr_") {
            guard case .location(let ch) = activeChannel else {
                addSystemMessage("cannot send: not in a location channel")
                return
            }
            let messageID = UUID().uuidString
            // Local echo in the DM thread
            let message = BitchatMessage(
                id: messageID,
                sender: nickname,
                content: content,
                timestamp: Date(),
                isRelay: false,
                originalSender: nil,
                isPrivate: true,
                recipientNickname: nickname,
                senderPeerID: meshService.myPeerID,
                mentions: nil,
                deliveryStatus: .sending
            )
            if privateChats[peerID] == nil { privateChats[peerID] = [] }
            privateChats[peerID]?.append(message)
            trimPrivateChatMessagesIfNeeded(for: peerID)
            objectWillChange.send()

            // Resolve recipient hex from mapping
            guard let recipientHex = nostrKeyMapping[peerID] else {
                if let msgIdx = privateChats[peerID]?.firstIndex(where: { $0.id == messageID }) {
                    privateChats[peerID]?[msgIdx].deliveryStatus = .failed(reason: "unknown recipient")
                }
                return
            }
            // Respect geohash blocks
            if SecureIdentityStateManager.shared.isNostrBlocked(pubkeyHexLowercased: recipientHex) {
                if let msgIdx = privateChats[peerID]?.firstIndex(where: { $0.id == messageID }) {
                    privateChats[peerID]?[msgIdx].deliveryStatus = .failed(reason: "user is blocked")
                }
                addSystemMessage("cannot send message: user is blocked.")
                return
            }
            // Send via Nostr using per-geohash identity
            do {
                let id = try NostrIdentityBridge.deriveIdentity(forGeohash: ch.geohash)
                // Prevent messaging ourselves
                if recipientHex.lowercased() == id.publicKeyHex.lowercased() {
                    if let idx = privateChats[peerID]?.firstIndex(where: { $0.id == messageID }) {
                        privateChats[peerID]?[idx].deliveryStatus = .failed(reason: "cannot message yourself")
                    }
                    return
                }
                SecureLogger.log("GeoDM: local send mid=\(messageID.prefix(8))… to=\(recipientHex.prefix(8))… conv=\(peerID)",
                                category: SecureLogger.session, level: .debug)
                let nostrTransport = NostrTransport()
                nostrTransport.senderPeerID = meshService.myPeerID
                nostrTransport.sendPrivateMessageGeohash(content: content, toRecipientHex: recipientHex, from: id, messageID: messageID)
                if let msgIdx = privateChats[peerID]?.firstIndex(where: { $0.id == messageID }) {
                    privateChats[peerID]?[msgIdx].deliveryStatus = .sent
                }
            } catch {
                if let idx = privateChats[peerID]?.firstIndex(where: { $0.id == messageID }) {
                    privateChats[peerID]?[idx].deliveryStatus = .failed(reason: "send error")
                }
            }
            return
        }
        #endif

        // Check if blocked
        if unifiedPeerService.isBlocked(peerID) {
            let nickname = meshService.peerNickname(peerID: peerID) ?? "user"
            addSystemMessage("cannot send message to \(nickname): user is blocked.")
            return
        }
        
        // Determine routing method and recipient nickname
        guard let noiseKey = Data(hexString: peerID) else { return }
        let isConnected = meshService.isPeerConnected(peerID)
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
        trimPrivateChatMessagesIfNeeded(for: peerID)
        
        // Trigger UI update for sent message
        objectWillChange.send()
        
        // Send via appropriate transport (BLE if connected, else Nostr when possible)
        if isConnected || (isMutualFavorite && hasNostrKey) {
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

    #if os(iOS)
    // MARK: - Geohash DMs initiation
    @MainActor
    func startGeohashDM(withPubkeyHex hex: String) {
        let convKey = "nostr_" + String(hex.prefix(16))
        nostrKeyMapping[convKey] = hex
        selectedPrivateChatPeer = convKey
    }

    @MainActor
    func fullNostrHex(forSenderPeerID senderID: String) -> String? {
        return nostrKeyMapping[senderID]
    }

    @MainActor
    func geohashDisplayName(for convKey: String) -> String {
        guard let full = nostrKeyMapping[convKey] else {
            let suffix = String(convKey.suffix(4))
            return "anon#\(suffix)"
        }
        let suffix = String(full.suffix(4))
        if let nick = geoNicknames[full.lowercased()], !nick.isEmpty {
            return nick + "#" + suffix
        }
        return "anon#\(suffix)"
    }
    #endif
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
        trimPrivateChatMessagesIfNeeded(for: peerID)
        objectWillChange.send()
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
        
        // Also consolidate messages from temporary Nostr peer IDs
        // These are messages received via Nostr when we didn't know the sender's Noise key
        // They're stored under "nostr_" + first 16 chars of Nostr pubkey
        let currentPeerNickname = peerNickname.lowercased()
        var tempPeerIDsToConsolidate: [String] = []
        
        // Find all temporary Nostr peer IDs that have messages from the same nickname
        for (storedPeerID, messages) in privateChats {
            if storedPeerID.hasPrefix("nostr_") && storedPeerID != peerID {
                // Check if ALL messages from this temporary peer have the same sender nickname
                // This is more reliable than just checking the first message
                let nicknamesMatch = messages.allSatisfy { msg in
                    msg.sender.lowercased() == currentPeerNickname
                }
                if nicknamesMatch && !messages.isEmpty {
                    tempPeerIDsToConsolidate.append(storedPeerID)
                }
            }
        }
        
        // Consolidate messages from temporary Nostr peer IDs
        if !tempPeerIDsToConsolidate.isEmpty {
            if privateChats[peerID] == nil {
                privateChats[peerID] = []
            }
            
            let existingMessageIds = Set(privateChats[peerID]?.map { $0.id } ?? [])
            var consolidatedCount = 0
            
            var hadUnreadTemp = false
            for tempPeerID in tempPeerIDsToConsolidate {
                // Check if this temp peer ID had unread messages
                if unreadPrivateMessages.contains(tempPeerID) {
                    hadUnreadTemp = true
                }
                
                if let tempMessages = privateChats[tempPeerID] {
                    for message in tempMessages {
                        if !existingMessageIds.contains(message.id) {
                            // Create a new message with the updated sender peer ID
                            let updatedMessage = BitchatMessage(
                                id: message.id,
                                sender: message.sender,
                                content: message.content,
                                timestamp: message.timestamp,
                                isRelay: message.isRelay,
                                originalSender: message.originalSender,
                                isPrivate: message.isPrivate,
                                recipientNickname: message.recipientNickname,
                                senderPeerID: peerID,  // Update to match current peer
                                mentions: message.mentions,
                                deliveryStatus: message.deliveryStatus
                            )
                            privateChats[peerID]?.append(updatedMessage)
                            consolidatedCount += 1
                        }
                    }
                    // Remove the temporary storage
                    privateChats.removeValue(forKey: tempPeerID)
                    unreadPrivateMessages.remove(tempPeerID)
                }
            }
            
            // If any temp peer ID had unread messages, mark the consolidated peer as unread
            if hadUnreadTemp {
                unreadPrivateMessages.insert(peerID)
                SecureLogger.log("📬 Transferred unread status from temp peer IDs to \(peerID)", 
                                category: SecureLogger.session, level: .debug)
            }
            
            if consolidatedCount > 0 {
                // Sort by timestamp
                privateChats[peerID]?.sort { $0.timestamp < $1.timestamp }
                
                SecureLogger.log("📥 Consolidated \(consolidatedCount) Nostr messages from temporary peer IDs to \(peerNickname)", 
                                category: SecureLogger.session, level: .info)
            }
        }
        
        // Trigger handshake if needed (mesh peers only). Skip for Nostr geohash conv keys.
        if !peerID.hasPrefix("nostr_") && !peerID.hasPrefix("nostr:") {
            let sessionState = meshService.getNoiseSessionState(for: peerID)
            switch sessionState {
            case .none, .failed:
                meshService.triggerHandshake(with: peerID)
            default:
                break
            }
        } else {
            SecureLogger.log("GeoDM: skipping mesh handshake for virtual peerID=\(peerID)",
                            category: SecureLogger.session, level: .debug)
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
    
    @MainActor
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
    
    @MainActor
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.markPrivateMessagesAsRead(from: peerID)
            }
        }
        // Also resubscribe the current geohash channel if active
        #if os(iOS)
        resubscribeCurrentGeohash()
        #endif
    }
    
    @MainActor
    @objc private func userDidTakeScreenshot() {
        // Send screenshot notification based on current context
        let screenshotMessage = "* \(nickname) took a screenshot *"
        
        if let peerID = selectedPrivateChatPeer {
            // In private chat - send to the other person
            if let peerNickname = meshService.peerNickname(peerID: peerID) {
                // Only send screenshot notification if we have an established session
                // This prevents triggering handshake requests for screenshot notifications
                let sessionState = meshService.getNoiseSessionState(for: peerID)
                switch sessionState {
                case .established:
                    // Send the message directly without going through sendPrivateMessage to avoid local echo
                    messageRouter.sendPrivate(screenshotMessage, to: peerID, recipientNickname: peerNickname, messageID: UUID().uuidString)
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
                recipientNickname: meshService.peerNickname(peerID: peerID),
                senderPeerID: meshService.myPeerID
            )
            var chats = privateChats
            if chats[peerID] == nil {
                chats[peerID] = []
            }
            chats[peerID]?.append(localNotification)
            privateChats = chats  // Trigger setter
            trimPrivateChatMessagesIfNeeded(for: peerID)
            
        } else {
            // In public chat - send to active public channel
            #if os(iOS)
            switch activeChannel {
            case .mesh:
                meshService.sendMessage(screenshotMessage, mentions: [])
            case .location(let ch):
                Task { @MainActor in
                    do {
                        let identity = try NostrIdentityBridge.deriveIdentity(forGeohash: ch.geohash)
                        let event = try NostrProtocol.createEphemeralGeohashEvent(
                            content: screenshotMessage,
                            geohash: ch.geohash,
                            senderIdentity: identity,
                            nickname: self.nickname,
                            teleported: LocationChannelManager.shared.teleported
                        )
                        NostrRelayManager.shared.sendEvent(event)
                        // Track ourselves as active participant
                        self.recordGeoParticipant(pubkeyHex: identity.publicKeyHex)
                    } catch {
                        SecureLogger.log("❌ Failed to send geohash screenshot message: \(error)", category: SecureLogger.session, level: .error)
                        self.addSystemMessage("failed to send to location channel")
                    }
                }
            }
            #else
            meshService.sendMessage(screenshotMessage, mentions: [])
            #endif

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
        // Send leave message to all peers
        meshService.stopServices()
        
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
        
        // If we know the original transport, use it for the read receipt
        if originalTransport == "nostr" {
            // Skip read receipts for Nostr messages - unnecessary complexity
            // The radical simplification plan says to accept occasional loss
        } else if meshService.peerNickname(peerID: actualPeerID) != nil {
            // Use mesh for connected peers (default behavior)
            messageRouter.sendReadReceipt(receipt, to: actualPeerID)
        } else {
            // Skip read receipts for offline peers - fire and forget principle
        }
    }
    
    @MainActor
    func markPrivateMessagesAsRead(from peerID: String) {
        privateChatManager.markAsRead(from: peerID)
        
        // Handle GeoDM (nostr_*) read receipts directly via per-geohash identity
        #if os(iOS)
        if peerID.hasPrefix("nostr_"),
           let recipientHex = nostrKeyMapping[peerID],
           case .location(let ch) = LocationChannelManager.shared.selectedChannel,
           let id = try? NostrIdentityBridge.deriveIdentity(forGeohash: ch.geohash) {
            let messages = privateChats[peerID] ?? []
            for message in messages where message.senderPeerID == peerID && !message.isRelay {
                if !sentReadReceipts.contains(message.id) {
                    SecureLogger.log("GeoDM: sending READ for mid=\(message.id.prefix(8))… to=\(recipientHex.prefix(8))…",
                                    category: SecureLogger.session, level: .debug)
                    let nostrTransport = NostrTransport()
                    nostrTransport.senderPeerID = meshService.myPeerID
                    nostrTransport.sendReadReceiptGeohash(message.id, toRecipientHex: recipientHex, from: id)
                    sentReadReceipts.insert(message.id)
                }
            }
            return
        }
        #endif

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
        #if os(iOS)
        // When in a geohash channel, allow resolving by geohash participant nickname
        switch LocationChannelManager.shared.selectedChannel {
        case .location:
            let base: String = {
                if let hashIndex = nickname.firstIndex(of: "#") { return String(nickname[..<hashIndex]) }
                return nickname
            }().lowercased()
            // Try exact match against cached geoNicknames (pubkey -> nickname)
            if let pub = geoNicknames.first(where: { (_, nick) in nick.lowercased() == base })?.key {
                let convKey = "nostr_" + String(pub.prefix(16))
                nostrKeyMapping[convKey] = pub
                return convKey
            }
        default: break
        }
        #endif
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
        
        // IMPORTANT: Clear Nostr-related state
        // Disconnect from Nostr relays and clear subscriptions
        nostrRelayManager?.disconnect()
        nostrRelayManager = nil
        
        // Clear Nostr identity associations
        NostrIdentityBridge.clearAllAssociations()
        
        // Disconnect from all peers and clear persistent identity
        // This will force creation of a new identity (new fingerprint) on next launch
        meshService.emergencyDisconnectAll()
        
        // Force immediate UserDefaults synchronization
        userDefaults.synchronize()
        
        // Reinitialize Nostr with new identity
        // This will generate new Nostr keys derived from new Noise keys
        Task { @MainActor in
            // Small delay to ensure cleanup completes
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            
            // Reinitialize Nostr relay manager with new identity
            nostrRelayManager = NostrRelayManager()
            setupNostrMessageHandling()
            nostrRelayManager?.connect()
        }
        
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
            #if os(iOS)
            switch activeChannel {
            case .mesh:
                let values = meshService.getPeerNicknames().values
                return Array(values.filter { $0 != meshService.myNickname })
            case .location(let ch):
                // From geochash participants we have seen via Nostr events
                var tokens = Set<String>()
                for (pubkey, nick) in geoNicknames {
                    let suffix = String(pubkey.suffix(4))
                    tokens.insert("\(nick)#\(suffix)")
                }
                // Optionally exclude self nick#abcd from suggestions
                if let id = try? NostrIdentityBridge.deriveIdentity(forGeohash: ch.geohash) {
                    let myToken = nickname + "#" + String(id.publicKeyHex.suffix(4))
                    tokens.remove(myToken)
                }
                return Array(tokens)
            }
            #else
            let values = meshService.getPeerNicknames().values
            return Array(values.filter { $0 != meshService.myNickname })
            #endif
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
        let mentionPattern = "@([\\p{L}0-9_]+)"
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
    
    @MainActor
    func formatMessageAsText(_ message: BitchatMessage, colorScheme: ColorScheme) -> AttributedString {
        // Determine if this message was sent by self (mesh, geo, or DM)
        let isSelf: Bool = {
            if let spid = message.senderPeerID {
                #if os(iOS)
                if case .location(let ch) = activeChannel, spid.hasPrefix("nostr:") {
                    if let myGeo = try? NostrIdentityBridge.deriveIdentity(forGeohash: ch.geohash) {
                        return spid == "nostr:\(myGeo.publicKeyHex.prefix(8))"
                    }
                }
                #endif
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
            
            // Process content with hashtags and mentions
            let content = message.content
            
            // For extremely long content, render as plain text to avoid heavy regex/layout work,
            // unless the content includes Cashu tokens we want to chip-render below
            let containsCashuEarly: Bool = {
                let pattern = "\\bcashu[AB][A-Za-z0-9._-]{40,}\\b"
                if let rx = try? NSRegularExpression(pattern: pattern, options: []) {
                    return rx.numberOfMatches(in: content, options: [], range: NSRange(location: 0, length: content.count)) > 0
                }
                return false
            }()
            if (content.count > 4000 || content.hasVeryLongToken(threshold: 1024)) && !containsCashuEarly {
                var plainStyle = AttributeContainer()
                plainStyle.foregroundColor = baseColor
                plainStyle.font = isSelf
                    ? .system(size: 14, weight: .bold, design: .monospaced)
                    : .system(size: 14, design: .monospaced)
                result.append(AttributedString(content).mergingAttributes(plainStyle))
            } else {
            let hashtagPattern = "#([a-zA-Z0-9_]+)"
            // Allow optional '#abcd' suffix in mentions
            let mentionPattern = "@([\\p{L}0-9_]+(?:#[a-fA-F0-9]{4})?)"
            // Cashu token detector: cashuA/cashuB + long base64url; allow '.' and shorter variants
            let cashuPattern = "\\bcashu[AB][A-Za-z0-9._-]{40,}\\b"
            // Lightning invoices and links
            let bolt11Pattern = "(?i)\\bln(bc|tb|bcrt)[0-9][a-z0-9]{50,}\\b"
            let lnurlPattern = "(?i)\\blnurl1[a-z0-9]{20,}\\b"
            let lightningSchemePattern = "(?i)\\blightning:[^\\s]+"
            
            let hashtagRegex = try? NSRegularExpression(pattern: hashtagPattern, options: [])
            let mentionRegex = try? NSRegularExpression(pattern: mentionPattern, options: [])
            let cashuRegex = try? NSRegularExpression(pattern: cashuPattern, options: [])
            let bolt11Regex = try? NSRegularExpression(pattern: bolt11Pattern, options: [])
            let lnurlRegex = try? NSRegularExpression(pattern: lnurlPattern, options: [])
            let lightningSchemeRegex = try? NSRegularExpression(pattern: lightningSchemePattern, options: [])
            
            // Use NSDataDetector for URL detection
            let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
            
            let hashtagMatches = hashtagRegex?.matches(in: content, options: [], range: NSRange(location: 0, length: content.count)) ?? []
            let mentionMatches = mentionRegex?.matches(in: content, options: [], range: NSRange(location: 0, length: content.count)) ?? []
            let urlMatches = detector?.matches(in: content, options: [], range: NSRange(location: 0, length: content.count)) ?? []
            let cashuMatches = cashuRegex?.matches(in: content, options: [], range: NSRange(location: 0, length: content.count)) ?? []
            let lightningMatches = lightningSchemeRegex?.matches(in: content, options: [], range: NSRange(location: 0, length: content.count)) ?? []
            let bolt11Matches = bolt11Regex?.matches(in: content, options: [], range: NSRange(location: 0, length: content.count)) ?? []
            let lnurlMatches = lnurlRegex?.matches(in: content, options: [], range: NSRange(location: 0, length: content.count)) ?? []
            
            // Combine and sort matches, excluding hashtags/URLs overlapping mentions
            let mentionRanges = mentionMatches.map { $0.range(at: 0) }
            func overlapsMention(_ r: NSRange) -> Bool {
                for mr in mentionRanges { if NSIntersectionRange(r, mr).length > 0 { return true } }
                return false
            }
            var allMatches: [(range: NSRange, type: String)] = []
            for match in hashtagMatches where !overlapsMention(match.range(at: 0)) {
                allMatches.append((match.range(at: 0), "hashtag"))
            }
            for match in mentionMatches {
                allMatches.append((match.range(at: 0), "mention"))
            }
            for match in urlMatches where !overlapsMention(match.range) {
                allMatches.append((match.range, "url"))
            }
            for match in cashuMatches where !overlapsMention(match.range(at: 0)) {
                allMatches.append((match.range(at: 0), "cashu"))
            }
            // Lightning scheme first to avoid overlapping submatches
            for match in lightningMatches where !overlapsMention(match.range(at: 0)) {
                allMatches.append((match.range(at: 0), "lightning"))
            }
            // Exclude overlaps with lightning/url for bolt11/lnurl
            let occupied: [NSRange] = urlMatches.map { $0.range } + lightningMatches.map { $0.range(at: 0) }
            func overlapsOccupied(_ r: NSRange) -> Bool {
                for or in occupied { if NSIntersectionRange(r, or).length > 0 { return true } }
                return false
            }
            for match in bolt11Matches where !overlapsMention(match.range(at: 0)) && !overlapsOccupied(match.range(at: 0)) {
                allMatches.append((match.range(at: 0), "bolt11"))
            }
            for match in lnurlMatches where !overlapsMention(match.range(at: 0)) && !overlapsOccupied(match.range(at: 0)) {
                allMatches.append((match.range(at: 0), "lnurl"))
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
                        beforeStyle.foregroundColor = baseColor
                        beforeStyle.font = isSelf
                            ? .system(size: 14, weight: .bold, design: .monospaced)
                            : .system(size: 14, design: .monospaced)
                        if isMentioned {
                            beforeStyle.font = beforeStyle.font?.bold()
                        }
                        result.append(AttributedString(beforeText).mergingAttributes(beforeStyle))
                    }
                    
                    // Add styled match
                    let matchText = String(content[nsRange])
                    if type == "mention" {
                        // Split optional '#abcd' suffix and color suffix light grey
                        let (mBase, mSuffix) = splitSuffix(from: matchText.replacingOccurrences(of: "@", with: ""))
                        // Determine if this mention targets me (resolves with optional suffix per active channel)
                        let mySuffix: String? = {
                            #if os(iOS)
                            if case .location(let ch) = activeChannel, let id = try? NostrIdentityBridge.deriveIdentity(forGeohash: ch.geohash) {
                                return String(id.publicKeyHex.suffix(4))
                            }
                            #endif
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
                        if type == "hashtag" {
                            // If the hashtag is a valid geohash, make it tappable (bitchat://geohash/<gh>)
                            let token = String(matchText.dropFirst()).lowercased()
                            let allowed = Set("0123456789bcdefghjkmnpqrstuvwxyz")
                            let isGeohash = (2...12).contains(token.count) && token.allSatisfy { allowed.contains($0) }
                            var tagStyle = AttributeContainer()
                            tagStyle.font = isSelf
                                ? .system(size: 14, weight: .bold, design: .monospaced)
                                : .system(size: 14, design: .monospaced)
                            tagStyle.foregroundColor = baseColor
                            if isGeohash, let url = URL(string: "bitchat://geohash/\(token)") {
                                tagStyle.link = url
                                tagStyle.underlineStyle = .single
                            }
                            result.append(AttributedString(matchText).mergingAttributes(tagStyle))
                        } else if type == "cashu" {
                            // Skip inline token; a styled chip is rendered below the message
                            // We insert a single space to avoid words sticking together
                            var spacer = AttributeContainer()
                            spacer.foregroundColor = baseColor
                            spacer.font = isSelf
                                ? .system(size: 14, weight: .bold, design: .monospaced)
                                : .system(size: 14, design: .monospaced)
                            result.append(AttributedString(" ").mergingAttributes(spacer))
                        } else if type == "lightning" || type == "bolt11" || type == "lnurl" {
                            // Skip inline invoice/link; a styled chip is rendered below the message
                            var spacer = AttributeContainer()
                            spacer.foregroundColor = baseColor
                            spacer.font = isSelf
                                ? .system(size: 14, weight: .bold, design: .monospaced)
                                : .system(size: 14, design: .monospaced)
                            result.append(AttributedString(" ").mergingAttributes(spacer))
                        } else {
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
                    }
                    lastEnd = nsRange.upperBound
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
    
    func formatMessage(_ message: BitchatMessage, colorScheme: ColorScheme) -> AttributedString {
        var result = AttributedString()
        
        let isDark = colorScheme == .dark
        let primaryColor = isDark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
        
        if message.sender == "system" {
            let content = AttributedString("* \(message.content) *")
            var contentStyle = AttributeContainer()
            contentStyle.foregroundColor = Color.gray
            contentStyle.font = .system(size: 12, design: .monospaced).italic()
            result.append(content.mergingAttributes(contentStyle))
            
            // Add timestamp at the end for system messages
            let timestamp = AttributedString(" [\(formatTimestamp(message.timestamp))]")
            var timestampStyle = AttributeContainer()
            timestampStyle.foregroundColor = Color.gray.opacity(0.5)
            timestampStyle.font = .system(size: 10, design: .monospaced)
            result.append(timestamp.mergingAttributes(timestampStyle))
        } else {
            let sender = AttributedString("<@\(message.sender)> ")
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
            let pattern = "@([\\p{L}0-9_]+)"
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
                relayStyle.foregroundColor = primaryColor.opacity(0.7)
                relayStyle.font = .system(size: 11, design: .monospaced)
                result.append(relay.mergingAttributes(relayStyle))
            }
            
            // Add timestamp at the end (smaller, light grey)
            let timestamp = AttributedString(" [\(formatTimestamp(message.timestamp))]")
            var timestampStyle = AttributeContainer()
            timestampStyle.foregroundColor = Color.gray.opacity(0.7)
            timestampStyle.font = .system(size: 10, design: .monospaced)
            result.append(timestamp.mergingAttributes(timestampStyle))
        }
        
        return result
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
            let removeCount = messages.count - maxMessages
            messages.removeFirst(removeCount)
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
        var hue = Double(djb2(seed) % 360) / 360.0
        // Avoid orange (~30°) reserved for self
        let orange = 30.0 / 360.0
        if abs(hue - orange) < 0.05 { hue = fmod(hue + 0.12, 1.0) }
        let saturation: Double = isDark ? 0.80 : 0.70
        let brightness: Double = isDark ? 0.75 : 0.45
        let c = Color(hue: hue, saturation: saturation, brightness: brightness)
        peerColorCache[cacheKey] = c
        return c
    }

    @MainActor
    private func peerColor(for message: BitchatMessage, isDark: Bool) -> Color {
        var seed: String
        if let spid = message.senderPeerID {
            if spid.hasPrefix("nostr:") || spid.hasPrefix("nostr_") {
                // Normalize to the bare short id, then prefer full mapping when available
                let bare: String = {
                    if spid.hasPrefix("nostr:") { return String(spid.dropFirst(6)) }
                    if spid.hasPrefix("nostr_") { return String(spid.dropFirst(6)) }
                    return spid
                }()
                let full = nostrKeyMapping[spid]?.lowercased() ?? bare.lowercased()
                seed = "nostr:" + full
            } else if spid.count == 16, let full = getNoiseKeyForShortID(spid)?.lowercased() {
                seed = "noise:" + full
            } else {
                seed = spid.lowercased()
            }
        } else {
            seed = message.sender.lowercased()
        }
        return colorForPeerSeed(seed, isDark: isDark)
    }

    // Public helpers for views to color peers consistently in lists
    @MainActor
    func colorForNostrPubkey(_ pubkeyHexLowercased: String, isDark: Bool) -> Color {
        return colorForPeerSeed("nostr:" + pubkeyHexLowercased.lowercased(), isDark: isDark)
    }

    @MainActor
    func colorForMeshPeer(id peerID: String, isDark: Bool) -> Color {
        // Mirror message coloring: prefer stable full noise key mapping when available, else short ID
        if let full = getNoiseKeyForShortID(peerID)?.lowercased() {
            return colorForPeerSeed("noise:" + full, isDark: isDark)
        }
        return colorForPeerSeed(peerID.lowercased(), isDark: isDark)
    }

    private func trimMeshTimelineIfNeeded() {
        if meshTimeline.count > meshTimelineCap {
            let removeCount = meshTimeline.count - meshTimelineCap
            meshTimeline.removeFirst(removeCount)
        }
    }

    // Clear the current public channel's timeline (visible + persistent buffer)
    @MainActor
    func clearCurrentPublicTimeline() {
        #if os(iOS)
        switch activeChannel {
        case .mesh:
            messages.removeAll()
            meshTimeline.removeAll()
        case .location(let ch):
            messages.removeAll()
            geoTimelines[ch.geohash] = []
        }
        #else
        messages.removeAll()
        meshTimeline.removeAll()
        #endif
    }
    
    private func trimPrivateChatMessagesIfNeeded(for peerID: String) {
        // Handled by PrivateChatManager
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
        // Deprecated - messages are now added directly in didReceiveMessage to avoid double processing
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
    
    private func getFingerprint_old(for peerID: String) -> String? {
        // Remove debug logging to prevent console spam during view updates
        
        // First try to get fingerprint from mesh service's peer ID rotation mapping
        if let fingerprint = meshService.getFingerprint(for: peerID) {
            return fingerprint
        }
        
        // Check noise service (direct Noise session fingerprint)
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
    
    func didReceiveMessage(_ message: BitchatMessage) {
        Task { @MainActor in
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
    }

    // Low-level BLE events
    func didReceiveNoisePayload(from peerID: String, type: NoisePayloadType, payload: Data, timestamp: Date) {
        Task { @MainActor in
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
            }
        }
    }

    func didReceivePublicMessage(from peerID: String, nickname: String, content: String, timestamp: Date) {
        Task { @MainActor in
            let publicMentions = parseMentions(from: content)
            let msg = BitchatMessage(
                id: UUID().uuidString,
                sender: nickname,
                content: content,
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
    }

    // Mention parsing moved from BLE – use the existing non-optional helper below
    // MARK: - Peer Connection Events
    
    func didConnectToPeer(_ peerID: String) {
        SecureLogger.log("🤝 Peer connected: \(peerID)", category: SecureLogger.session, level: .debug)
        
        // Handle all main actor work async
        Task { @MainActor in
            isConnected = true
            
            // Register ephemeral session with identity manager
            SecureIdentityStateManager.shared.registerEphemeralSession(peerID: peerID)
            
            // Check if we favorite this peer and resend notification on reconnect
            // This ensures Nostr key mapping is maintained across reconnections
            if let peer = unifiedPeerService.getPeer(by: peerID),
               let favoriteStatus = FavoritesPersistenceService.shared.getFavoriteStatus(for: peer.noisePublicKey),
               favoriteStatus.isFavorite {
                // Resend favorite notification with our Nostr key after a short delay
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                meshService.sendFavoriteNotification(to: peerID, isFavorite: true)
                SecureLogger.log("📤 Resent favorite notification to reconnected peer \(peerID)", 
                                category: SecureLogger.session, level: .debug)
            }
            
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
        
        // Connection messages removed to reduce chat noise
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
        
        // Disconnection messages removed to reduce chat noise
    }
    
    func didUpdatePeerList(_ peers: [String]) {
        // UI updates must run on the main thread.
        // The delegate callback is not guaranteed to be on the main thread.
        DispatchQueue.main.async {
            // Update through peer manager
            // UnifiedPeerService updates automatically via subscriptions
            self.isConnected = !peers.isEmpty
            
            // Clean up stale unread peer IDs whenever peer list updates
            self.cleanupStaleUnreadPeerIDs()
            
            // Smart notification logic for "bitchatters nearby"
            if !peers.isEmpty {
                // Cancel any pending reset if peers are back
                self.networkResetTimer?.invalidate()
                self.networkResetTimer = nil
                // Only count mesh peers (actually connected via Bluetooth)
                let meshPeers = peers.filter { peerID in
                    self.meshService.isPeerConnected(peerID)
                }
                
                // Check if we have new mesh peers we haven't seen recently
                let currentPeerSet = Set(meshPeers)
                let newPeers = currentPeerSet.subtracting(self.recentlySeenPeers)
                // Send notification if:
                // 1. We have mesh peers (not just Nostr-only)
                // 2. There are new peers we haven't seen (rising-edge)
                // 3. We haven't already notified since the last sustained-empty period
                if meshPeers.count > 0 && !newPeers.isEmpty && !self.hasNotifiedNetworkAvailable {
                    self.hasNotifiedNetworkAvailable = true
                    self.lastNetworkNotificationTime = Date()
                    self.recentlySeenPeers = currentPeerSet
                    NotificationService.shared.sendNetworkAvailableNotification(peerCount: meshPeers.count)
                    SecureLogger.log("👥 Sent bitchatters nearby notification for \(meshPeers.count) mesh peers", 
                                   category: SecureLogger.session, level: .info)
                }
            } else {
                // No peers - schedule a graceful reset to avoid refiring on brief drops
                if self.networkResetTimer == nil {
                    self.networkResetTimer = Timer.scheduledTimer(withTimeInterval: self.networkResetGraceSeconds, repeats: false) { [weak self] _ in
                        guard let self = self else { return }
                        self.hasNotifiedNetworkAvailable = false
                        self.recentlySeenPeers.removeAll()
                        self.networkResetTimer = nil
                        SecureLogger.log("⏳ Mesh empty for \(Int(self.networkResetGraceSeconds))s — reset network notification state", category: SecureLogger.session, level: .debug)
                    }
                }
            }
            
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
    
    /// Clean up stale unread peer IDs that no longer exist in the peer list
    @MainActor
    private func cleanupStaleUnreadPeerIDs() {
        let currentPeerIDs = Set(unifiedPeerService.peers.map { $0.id })
        let staleIDs = unreadPrivateMessages.subtracting(currentPeerIDs)
        
        if !staleIDs.isEmpty {
            var idsToRemove: [String] = []
            for staleID in staleIDs {
                // Don't remove temporary Nostr peer IDs that have messages
                if staleID.hasPrefix("nostr_") {
                    // Check if we have messages from this temporary peer
                    if let messages = privateChats[staleID], !messages.isEmpty {
                        // Keep this ID - it has messages
                        continue
                    }
                }
                
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
        let matches = regex?.matches(in: content, options: [], range: NSRange(location: 0, length: content.count)) ?? []
        
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
        #if os(iOS)
        if case .location(let ch) = activeChannel {
            Task { @MainActor in
                do {
                    let identity = try NostrIdentityBridge.deriveIdentity(forGeohash: ch.geohash)
                    let event = try NostrProtocol.createEphemeralGeohashEvent(
                        content: content,
                        geohash: ch.geohash,
                        senderIdentity: identity,
                        nickname: self.nickname,
                        teleported: LocationChannelManager.shared.teleported
                    )
                    NostrRelayManager.shared.sendEvent(event)
                } catch {
                    SecureLogger.log("❌ Failed to send geohash raw message: \(error)", category: SecureLogger.session, level: .error)
                }
            }
            return
        }
        #endif
        // Default: send over mesh
        meshService.sendMessage(content, mentions: [])
    }
    
    // MARK: - Simplified Nostr Integration (Inlined from MessageRouter)
    
    // Removed inlined Nostr send helpers in favor of MessageRouter
    
    @MainActor
    private func setupNostrMessageHandling() {
        guard let currentIdentity = try? NostrIdentityBridge.getCurrentNostrIdentity() else { 
            SecureLogger.log("⚠️ No Nostr identity available for message handling", category: SecureLogger.session, level: .warning)
            return 
        }
        
        SecureLogger.log("🔑 Setting up Nostr subscription for pubkey: \(currentIdentity.publicKeyHex.prefix(16))...", 
                        category: SecureLogger.session, level: .debug)
        
        // Subscribe to Nostr messages
        let filter = NostrFilter.giftWrapsFor(
            pubkey: currentIdentity.publicKeyHex,
            since: Date().addingTimeInterval(-86400)  // Last 24 hours
        )
        
        nostrRelayManager?.subscribe(filter: filter, id: "chat-messages") { [weak self] event in
            Task { @MainActor in
                self?.handleNostrMessage(event)
            }
        }
    }
    
    @MainActor
    private func handleNostrMessage(_ giftWrap: NostrEvent) {
        // Simple deduplication
        if processedNostrEvents.contains(giftWrap.id) { return }
        processedNostrEvents.insert(giftWrap.id)
        
        // Client-side filtering: ignore messages older than 24 hours
        // Add 15 minutes buffer since gift wrap timestamps are randomized ±15 minutes
        let messageAge = Date().timeIntervalSince1970 - TimeInterval(giftWrap.created_at)
        if messageAge > 87300 { // 24 hours + 15 minutes
            return // Ignoring old message
        }
        
        // Processing Nostr message
        
        guard let currentIdentity = try? NostrIdentityBridge.getCurrentNostrIdentity() else { return }
        
        do {
            let (content, senderPubkey, rumorTimestamp) = try NostrProtocol.decryptPrivateMessage(
                giftWrap: giftWrap,
                recipientIdentity: currentIdentity
            )
            
            // Expect embedded BitChat packet content
            guard content.hasPrefix("bitchat1:") else {
                SecureLogger.log("Ignoring non-embedded Nostr DM content", category: SecureLogger.session, level: .debug)
                return
            }

            guard let packetData = Self.base64URLDecode(String(content.dropFirst("bitchat1:".count))),
                  let packet = BitchatPacket.from(packetData) else {
                SecureLogger.log("Failed to decode embedded BitChat packet from Nostr DM", category: SecureLogger.session, level: .error)
                return
            }

            // Only process typed noiseEncrypted envelope for private messages/receipts
            guard packet.type == MessageType.noiseEncrypted.rawValue else {
                SecureLogger.log("Unsupported embedded packet type: \(packet.type)", category: SecureLogger.session, level: .warning)
                return
            }

            // Validate recipient
            if let rid = packet.recipientID {
                let ridHex = rid.map { String(format: "%02x", $0) }.joined()
                if ridHex != meshService.myPeerID {
                    return
                }
            }

            // Parse plaintext typed payload
            guard let noisePayload = NoisePayload.decode(packet.payload) else {
                SecureLogger.log("Failed to parse embedded NoisePayload", category: SecureLogger.session, level: .error)
                return
            }

            // Map sender by Nostr pubkey to Noise key when possible
            let senderNoiseKey = findNoiseKey(for: senderPubkey)
            let actualSenderNoiseKey = senderNoiseKey // may be nil
            let messageTimestamp = Date(timeIntervalSince1970: TimeInterval(rumorTimestamp))
            let senderNickname = (actualSenderNoiseKey != nil) ? (FavoritesPersistenceService.shared.getFavoriteStatus(for: actualSenderNoiseKey!)?.peerNickname ?? "Unknown") : "Unknown"
            // Stable target ID if we know Noise key; otherwise temporary Nostr-based peer
            let targetPeerID = actualSenderNoiseKey?.hexEncodedString() ?? ("nostr_" + senderPubkey.prefix(16))

            switch noisePayload.type {
            case .privateMessage:
                guard let pm = PrivateMessagePacket.decode(from: noisePayload.data) else { return }
                let messageId = pm.messageID
                let messageContent = pm.content

                // Favorite/unfavorite notifications embedded as private messages
                if messageContent.hasPrefix("[FAVORITED]") || messageContent.hasPrefix("[UNFAVORITED]") {
                    if let key = actualSenderNoiseKey {
                        handleFavoriteNotificationFromMesh(messageContent, from: key.hexEncodedString(), senderNickname: senderNickname)
                    }
                    return
                }

                // Check for duplicate
                var messageExistsLocally = false
                if privateChats[targetPeerID]?.contains(where: { $0.id == messageId }) == true {
                    messageExistsLocally = true
                }
                if !messageExistsLocally {
                    for (_, messages) in privateChats {
                        if messages.contains(where: { $0.id == messageId }) { messageExistsLocally = true; break }
                    }
                }
                if messageExistsLocally { return }

                let wasReadBefore = sentReadReceipts.contains(messageId)

                // Is viewing?
                var isViewingThisChat = false
                if selectedPrivateChatPeer == targetPeerID {
                    isViewingThisChat = true
                } else if let selectedPeer = selectedPrivateChatPeer,
                          let selectedPeerData = unifiedPeerService.getPeer(by: selectedPeer),
                          let key = actualSenderNoiseKey,
                          selectedPeerData.noisePublicKey == key {
                    isViewingThisChat = true
                }

                // Recency check
                let isRecentMessage = Date().timeIntervalSince(messageTimestamp) < 30
                let shouldMarkAsUnread = !wasReadBefore && !isViewingThisChat && (isRecentMessage || !isStartupPhase)

                let message = BitchatMessage(
                    id: messageId,
                    sender: senderNickname,
                    content: messageContent,
                    timestamp: messageTimestamp,
                    isRelay: false,
                    originalSender: nil,
                    isPrivate: true,
                    recipientNickname: nickname,
                    senderPeerID: targetPeerID,
                    mentions: nil,
                    deliveryStatus: .delivered(to: nickname, at: Date())
                )

                if privateChats[targetPeerID] == nil { privateChats[targetPeerID] = [] }
                if let idx = privateChats[targetPeerID]?.firstIndex(where: { $0.id == messageId }) {
                    privateChats[targetPeerID]?[idx] = message
                } else {
                    privateChats[targetPeerID]?.append(message)
                }
                // Sanitize to avoid duplicate IDs
                privateChatManager.sanitizeChat(for: targetPeerID)
                trimPrivateChatMessagesIfNeeded(for: targetPeerID)

                // Mirror to ephemeral if applicable
                if let key = actualSenderNoiseKey,
                   let ephemeralPeerID = unifiedPeerService.peers.first(where: { $0.noisePublicKey == key })?.id,
                   ephemeralPeerID != targetPeerID {
                    if privateChats[ephemeralPeerID] == nil { privateChats[ephemeralPeerID] = [] }
                    if let idx = privateChats[ephemeralPeerID]?.firstIndex(where: { $0.id == messageId }) {
                        privateChats[ephemeralPeerID]?[idx] = message
                    } else {
                        privateChats[ephemeralPeerID]?.append(message)
                        trimPrivateChatMessagesIfNeeded(for: ephemeralPeerID)
                    }
                    privateChatManager.sanitizeChat(for: ephemeralPeerID)
                }

                // Send delivery ack via Nostr embedded if not previously read and we know sender's Noise key
                if !wasReadBefore, let key = actualSenderNoiseKey {
                    SecureLogger.log("Sending DELIVERED ack for \(messageId.prefix(8))… via router", category: SecureLogger.session, level: .debug)
                    messageRouter.sendDeliveryAck(messageId, to: key.hexEncodedString())
                }

                if wasReadBefore {
                    // do nothing
                } else if isViewingThisChat {
                    unreadPrivateMessages.remove(targetPeerID)
                    if let key = actualSenderNoiseKey,
                       let ephemeralPeerID = unifiedPeerService.peers.first(where: { $0.noisePublicKey == key })?.id {
                        unreadPrivateMessages.remove(ephemeralPeerID)
                    }
                    if !sentReadReceipts.contains(messageId), let key = actualSenderNoiseKey {
                        let receipt = ReadReceipt(originalMessageID: messageId, readerID: meshService.myPeerID, readerNickname: nickname)
                        SecureLogger.log("Viewing chat; sending READ ack for \(messageId.prefix(8))… via router", category: SecureLogger.session, level: .debug)
                        messageRouter.sendReadReceipt(receipt, to: key.hexEncodedString())
                        sentReadReceipts.insert(messageId)
                    }
                } else {
                    if shouldMarkAsUnread {
                        unreadPrivateMessages.insert(targetPeerID)
                        if let key = actualSenderNoiseKey,
                           let ephemeralPeerID = unifiedPeerService.peers.first(where: { $0.noisePublicKey == key })?.id,
                           ephemeralPeerID != targetPeerID {
                            unreadPrivateMessages.insert(ephemeralPeerID)
                        }
                        if isRecentMessage {
                            NotificationService.shared.sendPrivateMessageNotification(
                                from: senderNickname,
                                message: messageContent,
                                peerID: targetPeerID
                            )
                        }
                    }
                }

                objectWillChange.send()

            case .delivered:
                guard let messageID = String(data: noisePayload.data, encoding: .utf8) else { return }
                let peerName = senderNickname
                // Update status to delivered
                if let messages = privateChats[targetPeerID], let idx = messages.firstIndex(where: { $0.id == messageID }) {
                    privateChats[targetPeerID]?[idx].deliveryStatus = .delivered(to: peerName, at: Date())
                    objectWillChange.send()
                }

            case .readReceipt:
                guard let messageID = String(data: noisePayload.data, encoding: .utf8) else { return }
                let peerName = senderNickname
                if let messages = privateChats[targetPeerID], let idx = messages.firstIndex(where: { $0.id == messageID }) {
                    privateChats[targetPeerID]?[idx].deliveryStatus = .read(by: peerName, at: Date())
                    objectWillChange.send()
                }
            }
            
        } catch {
            SecureLogger.log("Failed to decrypt Nostr message: \(error)", category: SecureLogger.session, level: .error)
        }
    }
    
    @MainActor
    private func handleFavoriteNotification(content: String, from nostrPubkey: String) {
        let isFavorite = content.hasPrefix("FAVORITED")
        guard let senderNoiseKey = findNoiseKey(for: nostrPubkey) else { return }
        
        FavoritesPersistenceService.shared.updatePeerFavoritedUs(
            peerNoisePublicKey: senderNoiseKey,
            favorited: isFavorite,
            peerNostrPublicKey: nostrPubkey
        )
    }
    
    @MainActor
    private func handleNostrAcknowledgment(content: String, from senderPubkey: String) {
        // Parse ACK format: "ACK:TYPE:MESSAGE_ID"
        let parts = content.split(separator: ":", maxSplits: 2)
        guard parts.count >= 3 else {
            SecureLogger.log("⚠️ Invalid ACK format: \(content)", category: SecureLogger.session, level: .warning)
            return
        }
        
        let ackType = String(parts[1])
        let messageId = String(parts[2])
        
        // Check if we've already processed this ACK
        let ackKey = "\(messageId):\(ackType):\(senderPubkey)"
        if processedNostrAcks.contains(ackKey) {
            // Skip duplicate ACK
            return
        }
        processedNostrAcks.insert(ackKey)
        
        SecureLogger.log("📨 Received \(ackType) ACK for message \(messageId.prefix(16))... from \(senderPubkey.prefix(16))...", 
                        category: SecureLogger.session, level: .debug)
        
        // Verify the sender has a valid Noise key
        guard findNoiseKey(for: senderPubkey) != nil else {
            // Cannot find Noise key for ACK sender
            return
        }
        
        // Find and update the message status in ALL private chats (both stable and ephemeral)
        var messageFound = false
        for (chatPeerID, messages) in privateChats {
            if let index = messages.firstIndex(where: { $0.id == messageId }) {
                // Update delivery status based on ACK type
                switch ackType {
                case "DELIVERED":
                    privateChats[chatPeerID]?[index].deliveryStatus = .delivered(to: "recipient", at: Date())
                case "READ":
                    privateChats[chatPeerID]?[index].deliveryStatus = .read(by: "recipient", at: Date())
                default:
                    SecureLogger.log("⚠️ Unknown ACK type: \(ackType)", category: SecureLogger.session, level: .warning)
                }
                
                messageFound = true
                SecureLogger.log("✅ Updated message \(messageId.prefix(16))... status to \(ackType) in chat \(chatPeerID.prefix(16))...", 
                                category: SecureLogger.session, level: .info)
                // Don't break - continue to update in all chats where this message exists
            }
        }
        
        if messageFound {
            objectWillChange.send()
        } else {
            SecureLogger.log("⚠️ Could not find message \(messageId) to update status from ACK", 
                            category: SecureLogger.session, level: .warning)
        }
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
    
    // Removed local TLV decoder; using PrivateMessagePacket.decode from Protocols
    
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
        
        // Update the favorite relationship
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
        
        // Show system message
        let action = isFavorite ? "favorited" : "unfavorited"
        addSystemMessage("\(senderNickname) \(action) you")
    }
    
    @MainActor
    private func handleNostrMessageFromUnknownSender(
        messageId: String,
        content: String,
        senderPubkey: String,
        senderNickname: String? = nil,
        timestamp: Date
    ) {
        // Check if we already have this message in local storage
        for (_, messages) in privateChats {
            if messages.contains(where: { $0.id == messageId }) {
                return // Skipping duplicate message
            }
        }
        
        // Check if we've read this message before (in a previous session)
        let wasReadBefore = sentReadReceipts.contains(messageId)
        
        // Try to find sender by checking all known peers for nickname matches
        // This is a fallback when we receive Nostr messages from someone not in favorites
        
        // For now, create a temporary peer ID based on Nostr pubkey
        // This allows the message to be displayed even without Noise key mapping
        let tempPeerID = "nostr_" + senderPubkey.prefix(16)
        
        // Check if we're viewing this unknown sender's chat
        let isViewingThisChat = selectedPrivateChatPeer == tempPeerID
        
        // Check if message is recent (less than 30 seconds old)
        let messageAgeSeconds = Date().timeIntervalSince(timestamp)
        let isRecentMessage = messageAgeSeconds < 30
        
        // Determine if we should mark as unread BEFORE adding to chats
        // During startup phase, only block OLD messages from being marked as unread
        // Recent messages should always be marked as unread if not previously read
        let shouldMarkAsUnread = !wasReadBefore && !isViewingThisChat && (isRecentMessage || !isStartupPhase)
        
        // Use provided nickname or try to extract from previous messages
        var finalSenderNickname = senderNickname ?? "Unknown"
        
        // If no nickname provided, check if we have any previous messages from this Nostr key
        if senderNickname == nil {
            for (_, messages) in privateChats {
                if let previousMessage = messages.first(where: { 
                    $0.senderPeerID == tempPeerID 
                }) {
                    finalSenderNickname = previousMessage.sender
                    break
                }
            }
        }
        
        // Create the message
        let message = BitchatMessage(
            id: messageId,
            sender: finalSenderNickname,
            content: content,
            timestamp: timestamp,
            isRelay: false,
            originalSender: nil,
            isPrivate: true,
            recipientNickname: nickname,
            senderPeerID: tempPeerID,
            mentions: nil,
            deliveryStatus: .delivered(to: nickname, at: Date())
        )
        
        // Store in private chats
        if privateChats[tempPeerID] == nil {
            privateChats[tempPeerID] = []
        }
        privateChats[tempPeerID]?.append(message)
        trimPrivateChatMessagesIfNeeded(for: tempPeerID)
        
        // For unknown senders (no Noise key), skip sending Nostr ACKs
        
        // Handle based on read status
        if wasReadBefore {
            // Message was read in a previous session - don't mark as unread or notify
            // Not marking previously-read message as unread
        } else if isViewingThisChat {
            // Viewing this chat - mark as read
            // No read ACKs for unknown senders
        } else {
            // Not viewing and not previously read
            // Use pre-calculated shouldMarkAsUnread to avoid UI flicker
            if shouldMarkAsUnread {
                unreadPrivateMessages.insert(tempPeerID)
                
                // Only notify if it's a recent message
                if isRecentMessage {
                    NotificationService.shared.sendPrivateMessageNotification(
                        from: finalSenderNickname,
                        message: content,
                        peerID: tempPeerID
                    )
                } else {
                    // Not notifying for old message
                }
            }
            // Not notifying for old message
        }
        
        SecureLogger.log("📬 Stored Nostr message from unknown sender \(finalSenderNickname) in temporary peer \(tempPeerID)", 
                        category: SecureLogger.session, level: .info)
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
            // Check geohash (Nostr) blocks using mapping to full pubkey
            if peerID.hasPrefix("nostr") {
                if let full = nostrKeyMapping[peerID]?.lowercased() {
                    if SecureIdentityStateManager.shared.isNostrBlocked(pubkeyHexLowercased: full) { return true }
                }
            }
            return false
        }
        return false
    }

    // MARK: - Geohash Nickname Resolution (for /block in geohash)
    @MainActor
    func nostrPubkeyForDisplayName(_ name: String) -> String? {
        // Look up current visible geohash participants for an exact displayName match
        for p in visibleGeohashPeople() {
            if p.displayName == name { return p.id }
        }
        return nil
    }
    
    /// Process action messages (hugs, slaps) into system messages
    private func processActionMessage(_ message: BitchatMessage) -> BitchatMessage {
        let isActionMessage = message.content.hasPrefix("* ") && message.content.hasSuffix(" *") &&
                              (message.content.contains("🫂") || message.content.contains("🐟") || 
                               message.content.contains("took a screenshot"))
        
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
            let cutoffTime = Date().addingTimeInterval(-24 * 60 * 60)
            
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
                trimPrivateChatMessagesIfNeeded(for: peerID)
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
        trimPrivateChatMessagesIfNeeded(for: peerID)
        
        // Trigger UI update
        objectWillChange.send()
        
        // Handle fingerprint-based chat updates
        if let chatFingerprint = selectedPrivateChatFingerprint,
           let senderFingerprint = peerIDToPublicKeyFingerprint[peerID],
           chatFingerprint == senderFingerprint && selectedPrivateChatPeer != peerID {
            selectedPrivateChatPeer = peerID
        }
        
        updatePrivateChatPeerIfNeeded()
        
        // Handle notifications and read receipts
        // Check if we should send notification (only for truly unread and recent messages)
        if selectedPrivateChatPeer != peerID {
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.markPrivateMessagesAsRead(from: peerID)
            }
        }
    }
    
    /// Handle incoming public message
    @MainActor
    private func handlePublicMessage(_ message: BitchatMessage) {
        let finalMessage = processActionMessage(message)

        // Drop if sender is blocked (covers geohash via Nostr pubkey mapping)
        if isMessageBlocked(finalMessage) { return }

        // Classify origin: geochat if senderPeerID starts with 'nostr:', else mesh (or system)
        let isGeo = finalMessage.senderPeerID?.hasPrefix("nostr:") == true

        // Persist mesh messages to mesh timeline always
        if !isGeo && finalMessage.sender != "system" {
            meshTimeline.append(finalMessage)
            trimMeshTimelineIfNeeded()
        }

        // Persist geochat messages to per-geohash timeline (iOS-only)
        #if os(iOS)
        if isGeo && finalMessage.sender != "system" {
            if let gh = currentGeohash {
                var arr = geoTimelines[gh] ?? []
                arr.append(finalMessage)
                if arr.count > geoTimelineCap {
                    let remove = arr.count - geoTimelineCap
                    arr.removeFirst(remove)
                }
                geoTimelines[gh] = arr
            }
        }
        #endif

        // Only add message to current timeline if it matches active channel or is system
        let isSystem = finalMessage.sender == "system"
        let channelMatches: Bool = {
            #if os(iOS)
            switch activeChannel {
            case .mesh: return !isGeo || isSystem
            case .location: return isGeo || isSystem
            }
            #else
            // On non-iOS builds, we don't have location channels; accept all
            return true
            #endif
        }()

        guard channelMatches else { return }

        // Background nudge: notify on new activity after inactivity threshold in current channel
        #if os(iOS)
        if UIApplication.shared.applicationState != .active {
            let channelKey: String = {
                switch activeChannel {
                case .mesh: return "mesh"
                case .location(let ch): return "geo:\(ch.geohash)"
                }
            }()
            let now = Date()
            if let last = lastPublicActivityAt[channelKey], now.timeIntervalSince(last) >= channelInactivityThreshold {
                // Optional: simple cooldown to avoid duplicate bursts
                let lastNotified = lastPublicActivityNotifyAt[channelKey] ?? .distantPast
                if now.timeIntervalSince(lastNotified) >= 60 {
                    let title = activeChannelDisplayName()
                    let body = "new chats!"
                    NotificationService.shared.sendLocalNotification(title: title, body: body, identifier: "channel-activity-\(channelKey)-\(now.timeIntervalSince1970)")
                    lastPublicActivityNotifyAt[channelKey] = now
                }
            }
            lastPublicActivityAt[channelKey] = now
        }
        #endif

        // Check if this is our own message being echoed back (avoid dup)
        if finalMessage.sender != nickname && finalMessage.sender != "system" {
            if !finalMessage.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                addMessage(finalMessage)
            }
            return
        }

        if finalMessage.sender != "system" {
            // Check for duplicates
            let messageExists = messages.contains { existingMsg in
                if existingMsg.id == finalMessage.id { return true }
                if existingMsg.content == finalMessage.content && existingMsg.sender == finalMessage.sender {
                    let timeDiff = abs(existingMsg.timestamp.timeIntervalSince(finalMessage.timestamp))
                    return timeDiff < 1.0
                }
                return false
            }
            if !messageExists && !finalMessage.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                addMessage(finalMessage)
            }
        } else {
            if !finalMessage.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                addMessage(finalMessage)
            }
        }
    }
    
    /// Check for mentions and send notifications
    
private func checkForMentions(_ message: BitchatMessage) {
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
    private func sendHapticFeedback(for message: BitchatMessage) {
        #if os(iOS)
        guard UIApplication.shared.applicationState == .active else { return }
        
        // Build acceptable target tokens: base nickname and, if in a location channel, nickname with '#abcd'
        var tokens: [String] = [nickname]
        #if os(iOS)
        switch activeChannel {
        case .location(let ch):
            if let id = try? NostrIdentityBridge.deriveIdentity(forGeohash: ch.geohash) {
                let d = String(id.publicKeyHex.suffix(4))
                tokens.append(nickname + "#" + d)
            }
        default:
            break
        }
        #endif

        let hugsMe = tokens.contains { message.content.contains("hugs \($0)") } || message.content.contains("hugs you")
        let slapsMe = tokens.contains { message.content.contains("slaps \($0) around") } || message.content.contains("slaps you around")

        let isHugForMe = message.content.contains("🫂") && hugsMe
        let isSlapForMe = message.content.contains("🐟") && slapsMe
        
        if isHugForMe && message.sender != nickname {
            // Long warm haptic for hugs
            let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
            impactFeedback.prepare()
            
            for i in 0..<8 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.15) {
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
// End of ChatViewModel class
