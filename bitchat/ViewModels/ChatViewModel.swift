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

import BitLogger
import Foundation
import SwiftUI
import CryptoKit
import Combine
import CommonCrypto
import CoreBluetooth
#if os(iOS)
import UIKit
#endif
import UniformTypeIdentifiers

/// Manages the application state and business logic for BitChat.
/// Acts as the primary coordinator between UI components and backend services,
/// implementing the BitchatDelegate protocol to handle network events.
final class ChatViewModel: ObservableObject, BitchatDelegate {
    // Precompiled regexes and detectors reused across formatting
    private enum Regexes {
        static let hashtag: NSRegularExpression = {
            try! NSRegularExpression(pattern: "#([a-zA-Z0-9_]+)", options: [])
        }()
        static let mention: NSRegularExpression = {
            try! NSRegularExpression(pattern: "@([\\p{L}0-9_]+(?:#[a-fA-F0-9]{4})?)", options: [])
        }()
        static let cashu: NSRegularExpression = {
            try! NSRegularExpression(pattern: "\\bcashu[AB][A-Za-z0-9._-]{40,}\\b", options: [])
        }()
        static let bolt11: NSRegularExpression = {
            try! NSRegularExpression(pattern: "(?i)\\bln(bc|tb|bcrt)[0-9][a-z0-9]{50,}\\b", options: [])
        }()
        static let lnurl: NSRegularExpression = {
            try! NSRegularExpression(pattern: "(?i)\\blnurl1[a-z0-9]{20,}\\b", options: [])
        }()
        static let lightningScheme: NSRegularExpression = {
            try! NSRegularExpression(pattern: "(?i)\\blightning:[^\\s]+", options: [])
        }()
        static let linkDetector: NSDataDetector? = {
            try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        }()
        static let quickCashuPresence: NSRegularExpression = {
            try! NSRegularExpression(pattern: "\\bcashu[AB][A-Za-z0-9._-]{40,}\\b", options: [])
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
            if spid.hasPrefix("nostr:") || spid.hasPrefix("nostr_") {
                let bare: String = {
                    if spid.hasPrefix("nostr:") { return String(spid.dropFirst(6)) }
                    if spid.hasPrefix("nostr_") { return String(spid.dropFirst(6)) }
                    return spid
                }()
                let full = (nostrKeyMapping[spid] ?? bare).lowercased()
                return "nostr:" + full
            } else if spid.count == 16, let full = getNoiseKeyForShortID(spid)?.lowercased() {
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
        let h = prefix.djb2()
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
    private var hasNotifiedNetworkAvailable = false
    private var recentlySeenPeers: Set<String> = []
    private var lastNetworkNotificationTime = Date.distantPast
    private var networkResetTimer: Timer? = nil
    private let networkResetGraceSeconds: TimeInterval = TransportConfig.networkResetGraceSeconds // avoid refiring on short drops/reconnects
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
    
    let meshService: Transport
    let identityManager: SecureIdentityStateManagerProtocol
    
    private var nostrRelayManager: NostrRelayManager?
    // PeerManager replaced by UnifiedPeerService
    private var processedNostrEvents = Set<String>()  // Simple deduplication
    private var processedNostrEventOrder: [String] = []
    private let maxProcessedNostrEvents = TransportConfig.uiProcessedNostrEventsCap
    private let userDefaults = UserDefaults.standard
    private let keychain: KeychainManagerProtocol
    private let nicknameKey = "bitchat.nickname"
    // Location channel state (macOS supports manual geohash selection)
    @Published private var activeChannel: ChannelID = .mesh
    private var geoSubscriptionID: String? = nil
    private var geoDmSubscriptionID: String? = nil
    private var currentGeohash: String? = nil
    private var geoNicknames: [String: String] = [:] // pubkeyHex(lowercased) -> nickname
    // Show Tor status once per app launch
    private var torStatusAnnounced = false
    private var torProgressCancellable: AnyCancellable?
    private var lastTorProgressAnnounced = -1
    // Queue geohash-only system messages if user isn't on a location channel yet
    private var pendingGeohashSystemMessages: [String] = []
    // Track whether a Tor restart is pending so we only announce
    // "tor restarted" after an actual restart, not the first launch.
    private var torRestartPending: Bool = false
    // Ensure we set up DM subscription only once per app session
    private var nostrHandlersSetup: Bool = false
    
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

    // Presentation state for privacy gating
    @Published var isLocationChannelsSheetPresented: Bool = false
    @Published var isAppInfoPresented: Bool = false
    @Published var showScreenshotPrivacyWarning: Bool = false
    
    // Messages are naturally ephemeral - no persistent storage
    // Persist mesh public timeline across channel switches
    private var meshTimeline: [BitchatMessage] = []
    private let meshTimelineCap = TransportConfig.meshTimelineCap
    // Persist per-geohash public timelines across switches
    private var geoTimelines: [String: [BitchatMessage]] = [:] // geohash -> messages
    private let geoTimelineCap = TransportConfig.geoTimelineCap
    // Channel activity tracking for background nudges
    private var lastPublicActivityAt: [String: Date] = [:]   // channelKey -> last activity time
    private var lastPublicActivityNotifyAt: [String: Date] = [:]
    private let channelInactivityThreshold: TimeInterval = TransportConfig.uiChannelInactivityThresholdSeconds
    // Geohash participants (per geohash: pubkey -> lastSeen)
    private var geoParticipants: [String: [String: Date]] = [:]
    @Published private(set) var geohashPeople: [GeoPerson] = []
    private var geoParticipantsTimer: Timer? = nil
    // Participants who indicated they teleported (by tag in their events)
    @Published private(set) var teleportedGeo: Set<String> = []  // lowercased pubkey hex
    // Sampling subscriptions for multiple geohashes (when channel sheet is open)
    private var geoSamplingSubs: [String: String] = [:] // subID -> geohash
    private var lastGeoNotificationAt: [String: Date] = [:] // geohash -> last notify time
    
    
    // MARK: - Message Delivery Tracking
    
    // Delivery tracking
    private var cancellables = Set<AnyCancellable>()
    private var transferIdToMessageIDs: [String: [String]] = [:]
    private var messageIDToTransferId: [String: String] = [:]

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
                UserDefaults.standard.set(data, forKey: "sentReadReceipts")
            } else {
                SecureLogger.error("❌ Failed to encode read receipts for persistence", category: .session)
            }
        }
    }

    // Throttle verification response toasts per peer to avoid spam
    private var lastVerifyToastAt: [String: Date] = [:]
    
    // Track processed Nostr ACKs to avoid duplicate processing
    private var processedNostrAcks: Set<String> = []  // "messageId:ackType:senderPubkey" format
    // Track which GeoDM messages we've already sent a delivery ACK for (by messageID)
    private var sentGeoDeliveryAcks: Set<String> = []
    
    // Track app startup phase to prevent marking old messages as unread
    private var isStartupPhase = true
    // Announce Tor initial readiness once per launch to avoid duplicates
    private var torInitialReadyAnnounced: Bool = false
    
    // Track Nostr pubkey mappings for unknown senders
    private var nostrKeyMapping: [String: String] = [:]  // senderPeerID -> nostrPubkey
    
    // MARK: - Initialization
    
    @MainActor
    init(
        keychain: KeychainManagerProtocol,
        identityManager: SecureIdentityStateManagerProtocol
    ) {
        self.keychain = keychain
        self.identityManager = identityManager
        self.meshService = BLEService(keychain: keychain, identityManager: identityManager)
        
        // Load persisted read receipts
        if let data = UserDefaults.standard.data(forKey: "sentReadReceipts"),
           let receipts = try? JSONDecoder().decode([String].self, from: data) {
            self.sentReadReceipts = Set(receipts)
            // Successfully loaded read receipts
        } else {
            // No persisted read receipts found
        }
        
        // Initialize services
        self.commandProcessor = CommandProcessor(identityManager: identityManager)
        self.privateChatManager = PrivateChatManager(meshService: meshService)
        self.unifiedPeerService = UnifiedPeerService(meshService: meshService, identityManager: identityManager)
        let nostrTransport = NostrTransport(keychain: keychain)
        self.messageRouter = MessageRouter(mesh: meshService, nostr: nostrTransport)
        // Route receipts from PrivateChatManager through MessageRouter
        self.privateChatManager.messageRouter = self.messageRouter
        // Allow UnifiedPeerService to route favorite notifications via mesh/Nostr
        self.unifiedPeerService.messageRouter = self.messageRouter
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
        DispatchQueue.main.asyncAfter(deadline: .now() + TransportConfig.uiStartupInitialDelaySeconds) { [weak self] in
            if let self = self {
                _ = self.getMyFingerprint()
            }
        }
        
        // Set nickname before starting services
        meshService.setNickname(nickname)
        
        // Start mesh service immediately
        meshService.startServices()
        
        // Announce Tor status (geohash-only; do not show in mesh chat). Only when auto-start is allowed.
        if TorManager.shared.torEnforced && !torStatusAnnounced && TorManager.shared.isAutoStartAllowed() {
            torStatusAnnounced = true
            addGeohashOnlySystemMessage(
                L10n.string(
                    "system.tor.starting",
                    comment: "System message when Tor is starting"
                )
            )
            // Suppress incremental Tor progress messages
            torProgressCancellable = nil
        } else if !TorManager.shared.torEnforced && !torStatusAnnounced {
            torStatusAnnounced = true
            addGeohashOnlySystemMessage(
                L10n.string(
                    "system.tor.dev_bypass",
                    comment: "System message when Tor bypass is enabled in development"
                )
            )
        }

        // Initialize Nostr relay manager regardless of Tor readiness; connection is controlled elsewhere
        nostrRelayManager = NostrRelayManager.shared
        // Attempt to flush any queued outbox (mesh/Nostr routing will gate appropriately)
        messageRouter.flushAllOutbox()
        // End startup phase after a short delay
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(TransportConfig.uiStartupPhaseDurationSeconds * 1_000_000_000))
            self.isStartupPhase = false
        }
        // Bind unified peer service's peer list to our published property
        let peersCancellable = unifiedPeerService.$peers
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
                        SecureLogger.warning("⚠️ Duplicate peer ID detected: \(peer.id) (\(peer.displayName))", category: .session)
                    }
                }
                self.peerIndex = uniquePeers
                // Update private chat peer ID if needed when peers change
                if self.selectedPrivateChatFingerprint != nil {
                    self.updatePrivateChatPeerIfNeeded()
                }
            }
        self.cancellables.insert(peersCancellable)

        // Resubscribe geohash on relay reconnect
        if let relayMgr = self.nostrRelayManager {
            relayMgr.$isConnected
                .receive(on: DispatchQueue.main)
                .sink { [weak self] connected in
                    guard let self = self else { return }
                    if connected {
                        Task { @MainActor in
                            // Set up DM handler once on first connect
                            if !self.nostrHandlersSetup {
                                self.setupNostrMessageHandling()
                                self.nostrHandlersSetup = true
                            }
                            self.resubscribeCurrentGeohash()
                            // Re-init sampling for regional + bookmarked geohashes after reconnect
                            let regional = LocationChannelManager.shared.availableChannels.map { $0.geohash }
                            let bookmarks = GeohashBookmarksStore.shared.bookmarks
                            let union = Array(Set(regional).union(bookmarks))
                            if TorManager.shared.isForeground() {
                                self.beginGeohashSampling(for: union)
                            } else {
                                self.endGeohashSampling()
                            }
                        }
                    }
                }
                .store(in: &self.cancellables)
        }

        // Set up Noise encryption callbacks
        setupNoiseCallbacks()

        TransferProgressManager.shared.publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleTransferEvent(event)
            }
            .store(in: &cancellables)

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

        // Foreground-only: sample nearby geohashes + bookmarks (disabled in background)
        LocationChannelManager.shared.$availableChannels
            .receive(on: DispatchQueue.main)
            .sink { [weak self] channels in
                guard let self = self else { return }
                let regional = channels.map { $0.geohash }
                let bookmarks = GeohashBookmarksStore.shared.bookmarks
                let union = Array(Set(regional).union(bookmarks))
                Task { @MainActor in
                    if TorManager.shared.isForeground() {
                        self.beginGeohashSampling(for: union)
                    } else {
                        self.endGeohashSampling()
                    }
                }
            }
            .store(in: &cancellables)

        // Also observe bookmark changes to update sampling
        GeohashBookmarksStore.shared.$bookmarks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] bookmarks in
                guard let self = self else { return }
                let regional = LocationChannelManager.shared.availableChannels.map { $0.geohash }
                let union = Array(Set(regional).union(bookmarks))
                Task { @MainActor in
                    if TorManager.shared.isForeground() {
                        self.beginGeohashSampling(for: union)
                    } else {
                        self.endGeohashSampling()
                    }
                }
            }
            .store(in: &cancellables)

        // Kick off initial sampling if we have regional channels or bookmarks (foreground only)
        do {
            let regional = LocationChannelManager.shared.availableChannels.map { $0.geohash }
            let bookmarks = GeohashBookmarksStore.shared.bookmarks
            let union = Array(Set(regional).union(bookmarks))
            if !union.isEmpty && TorManager.shared.isForeground() {
                Task { @MainActor in self.beginGeohashSampling(for: union) }
            }
        }
        // Refresh channels once when authorized to seed sampling
        LocationChannelManager.shared.$permissionState
            .receive(on: DispatchQueue.main)
            .sink { state in
                if state == .authorized { LocationChannelManager.shared.refreshChannels() }
            }
            .store(in: &cancellables)

        // Track teleport flag changes to keep our own teleported marker in sync with regional status
        LocationChannelManager.shared.$teleported
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isTeleported in
                guard let self = self else { return }
                Task { @MainActor in
                    guard case .location(let ch) = self.activeChannel,
                          let id = try? NostrIdentityBridge.deriveIdentity(forGeohash: ch.geohash) else { return }
                    let key = id.publicKeyHex.lowercased()
                    let hasRegional = !LocationChannelManager.shared.availableChannels.isEmpty
                    let inRegional = LocationChannelManager.shared.availableChannels.contains { $0.geohash == ch.geohash }
                    if isTeleported && hasRegional && !inRegional {
                        self.teleportedGeo = self.teleportedGeo.union([key])
                    } else {
                        self.teleportedGeo.remove(key)
                    }
                }
            }
            .store(in: &cancellables)
        
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
        // Tor lifecycle notifications: inform user when Tor restarts and when ready (macOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTorWillRestart),
            name: .TorWillRestart,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTorDidBecomeReady),
            name: .TorDidBecomeReady,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTorWillStart),
            name: .TorWillStart,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTorPreferenceChanged(_:)),
            name: .TorUserPreferenceChanged,
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
        // Tor lifecycle notifications: inform user when Tor restarts and when ready
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTorWillRestart),
            name: .TorWillRestart,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTorDidBecomeReady),
            name: .TorDidBecomeReady,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTorWillStart),
            name: .TorWillStart,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTorPreferenceChanged(_:)),
            name: .TorUserPreferenceChanged,
            object: nil
        )
        #endif
    }
    
    // MARK: - Deinitialization
    
    deinit {
        // No need to force UserDefaults synchronization
    }

    // MARK: - Tor notifications
    @objc private func handleTorWillStart() {
        Task { @MainActor in
            if !self.torStatusAnnounced && TorManager.shared.torEnforced {
                self.torStatusAnnounced = true
                // Post only in geohash channels (queue if not active)
                self.addGeohashOnlySystemMessage(
                    L10n.string(
                        "system.tor.starting",
                        comment: "System message when Tor is starting"
                    )
                )
            }
        }
    }
    @objc private func handleTorWillRestart() {
        Task { @MainActor in
            self.torRestartPending = true
            // Post only in geohash channels (queue if not active)
            self.addGeohashOnlySystemMessage(
                L10n.string(
                    "system.tor.restarting",
                    comment: "System message when Tor is restarting"
                )
            )
        }
    }

    @objc private func handleTorDidBecomeReady() {
        Task { @MainActor in
            // Only announce "restarted" if we actually restarted this session
            if self.torRestartPending {
                // Post only in geohash channels (queue if not active)
                self.addGeohashOnlySystemMessage(
                    L10n.string(
                        "system.tor.restarted",
                        comment: "System message when Tor has restarted"
                    )
                )
                self.torRestartPending = false
            } else if TorManager.shared.torEnforced && !self.torInitialReadyAnnounced {
                // Initial start completed
                self.addGeohashOnlySystemMessage(
                    L10n.string(
                        "system.tor.started",
                        comment: "System message when Tor has started"
                    )
                )
                self.torInitialReadyAnnounced = true
            }
        }
    }

    @objc private func handleTorPreferenceChanged(_ notification: Notification) {
        Task { @MainActor in
            self.torStatusAnnounced = false
            self.torInitialReadyAnnounced = false
            self.torRestartPending = false
        }
    }
    
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
        let filter = NostrFilter.geohashEphemeral(
            ch.geohash,
            since: Date().addingTimeInterval(-TransportConfig.nostrGeohashInitialLookbackSeconds),
            limit: TransportConfig.nostrGeohashInitialLimit
        )
        let subRelays = GeoRelayDirectory.shared.closestRelays(
            toGeohash: ch.geohash,
            count: TransportConfig.nostrGeoRelayCount
        )
        NostrRelayManager.shared.subscribe(filter: filter, id: subID, relayUrls: subRelays) { [weak self] event in
            self?.subscribeNostrEvent(event)
        }
        // Resubscribe geohash DMs for this identity
        if let dmSub = geoDmSubscriptionID {
            NostrRelayManager.shared.unsubscribe(id: dmSub); geoDmSubscriptionID = nil
        }
        
        if let id = try? NostrIdentityBridge.deriveIdentity(forGeohash: ch.geohash) {
            let dmSub = "geo-dm-\(ch.geohash)"
            geoDmSubscriptionID = dmSub
            let dmFilter = NostrFilter.giftWrapsFor(pubkey: id.publicKeyHex, since: Date().addingTimeInterval(-TransportConfig.nostrDMSubscribeLookbackSeconds))
            NostrRelayManager.shared.subscribe(filter: dmFilter, id: dmSub) { [weak self] giftWrap in
                self?.subscribeGiftWrap(giftWrap, id: id)
            }
        }
    }
    
    private func subscribeNostrEvent(_ event: NostrEvent) {
        guard event.kind == NostrProtocol.EventKind.ephemeralEvent.rawValue,
              !processedNostrEvents.contains(event.id)
        else {
            return
        }

        processedNostrEvents.insert(event.id)
        
        if let gh = currentGeohash,
           let myGeoIdentity = try? NostrIdentityBridge.deriveIdentity(forGeohash: gh),
           myGeoIdentity.publicKeyHex.lowercased() == event.pubkey.lowercased() {
            // Skip very recent self-echo from relay, but allow older events (e.g., after app restart)
            let eventTime = Date(timeIntervalSince1970: TimeInterval(event.created_at))
            if Date().timeIntervalSince(eventTime) < 15 {
                return
            }
        }
        
        if let nickTag = event.tags.first(where: { $0.first == "n" }), nickTag.count >= 2 {
            let nick = nickTag[1].trimmingCharacters(in: .whitespacesAndNewlines)
            geoNicknames[event.pubkey.lowercased()] = nick
        }
        
        // Store mapping for geohash sender IDs used in messages (ensures consistent colors)
        let key16 = "nostr_" + String(event.pubkey.prefix(TransportConfig.nostrConvKeyPrefixLength))
        nostrKeyMapping[key16] = event.pubkey
        let key8 = "nostr:" + String(event.pubkey.prefix(TransportConfig.nostrShortKeyDisplayLength))
        nostrKeyMapping[key8] = event.pubkey

        // Update participants last-seen for this pubkey
        recordGeoParticipant(pubkeyHex: event.pubkey)
        
        // Track teleported tag (only our format ["t","teleport"]) for icon state
        let hasTeleportTag = event.tags.contains(where: { tag in
            tag.count >= 2 && tag[0].lowercased() == "t" && tag[1].lowercased() == "teleport"
        })
        
        if hasTeleportTag {
            let key = event.pubkey.lowercased()
            // Do not mark our own key from historical events; rely on manager.teleported for self
            let isSelf: Bool = {
                if let gh = currentGeohash, let my = try? NostrIdentityBridge.deriveIdentity(forGeohash: gh) {
                    return my.publicKeyHex.lowercased() == key
                }
                return false
            }()
            if !isSelf {
                Task { @MainActor in
                    teleportedGeo = teleportedGeo.union([key])
                }
            }
        }
        
        let senderName = displayNameForNostrPubkey(event.pubkey)
        let content = event.content.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Clamp future timestamps to now to avoid future-dated messages skewing order
        let rawTs = Date(timeIntervalSince1970: TimeInterval(event.created_at))
        let timestamp = min(rawTs, Date())
        let mentions = parseMentions(from: content)
        let msg = BitchatMessage(
            id: event.id,
            sender: senderName,
            content: content,
            timestamp: timestamp,
            isRelay: false,
            senderPeerID: "nostr:\(event.pubkey.prefix(TransportConfig.nostrShortKeyDisplayLength))",
            mentions: mentions.isEmpty ? nil : mentions
        )
        Task { @MainActor in
            handlePublicMessage(msg)
            checkForMentions(msg)
            sendHapticFeedback(for: msg)
        }
    }
    
    private func subscribeGiftWrap(_ giftWrap: NostrEvent, id: NostrIdentity) {
        guard !processedNostrEvents.contains(giftWrap.id) else { return }
        recordProcessedEvent(giftWrap.id)
        
        guard let (content, senderPubkey, rumorTs) = try? NostrProtocol.decryptPrivateMessage(giftWrap: giftWrap, recipientIdentity: id),
              content.hasPrefix("bitchat1:"),
              let packetData = Self.base64URLDecode(String(content.dropFirst("bitchat1:".count))),
              let packet = BitchatPacket.from(packetData),
              packet.type == MessageType.noiseEncrypted.rawValue,
              let noisePayload = NoisePayload.decode(packet.payload)
        else {
            return
        }
        
        let messageTimestamp = Date(timeIntervalSince1970: TimeInterval(rumorTs))
        let convKey = "nostr_" + String(senderPubkey.prefix(TransportConfig.nostrConvKeyPrefixLength))
        nostrKeyMapping[convKey] = senderPubkey
        
        switch noisePayload.type {
        case .privateMessage:
            handlePrivateMessage(payload: noisePayload, senderPubkey: senderPubkey, convKey: convKey, id: id, messageTimestamp: messageTimestamp)
        case .delivered:
            handleDelivered(noisePayload, senderPubkey: senderPubkey, convKey: convKey)
        case .readReceipt:
            handleReadReceipt(noisePayload, senderPubkey: senderPubkey, convKey: convKey)
        case .verifyChallenge, .verifyResponse:
            // QR verification payloads over Nostr are not supported; ignore in geohash DMs
            break
        }
    }
    
    private func handlePrivateMessage(
        payload: NoisePayload,
        senderPubkey: String,
        convKey: String,
        id: NostrIdentity,
        messageTimestamp: Date
    ) {
        guard let pm = PrivateMessagePacket.decode(from: payload.data) else { return }
        let messageId = pm.messageID
        
        sendDeliveryAckIfNeeded(to: messageId, senderPubKey: senderPubkey, from: id)
        
        // Respect geohash blocks
        if identityManager.isNostrBlocked(pubkeyHexLowercased: senderPubkey) {
            return
        }
        
        // Dedup storage
        if privateChats[convKey]?.contains(where: { $0.id == messageId }) == true { return }
        for (_, arr) in privateChats { if arr.contains(where: { $0.id == messageId }) { return } }
        let senderName = displayNameForNostrPubkey(senderPubkey)
        
        let msg = BitchatMessage(
            id: messageId,
            sender: senderName,
            content: pm.content,
            timestamp: messageTimestamp,
            isRelay: false,
            isPrivate: true,
            recipientNickname: nickname,
            senderPeerID: convKey,
            deliveryStatus: .delivered(to: nickname, at: Date())
        )
        
        if privateChats[convKey] == nil {
            privateChats[convKey] = []
        }
        privateChats[convKey]?.append(msg)
        trimPrivateChatMessagesIfNeeded(for: convKey)
        
        // pared back: omit view-state log
        let isViewing = selectedPrivateChatPeer == convKey
        let wasReadBefore = sentReadReceipts.contains(messageId)
        let isRecentMessage = Date().timeIntervalSince(messageTimestamp) < 30
        let shouldMarkUnread = !wasReadBefore && !isViewing && isRecentMessage
        if shouldMarkUnread {
            unreadPrivateMessages.insert(convKey)
        }
        
        if isViewing {
            // pared back: omit pre-send READ log
            sendReadReceiptIfNeeded(to: messageId, senderPubKey: senderPubkey, from: id)
        } else {
            // Notify for truly unread and recent messages when not viewing
            if shouldMarkUnread {
                NotificationService.shared.sendPrivateMessageNotification(
                    from: senderName,
                    message: pm.content,
                    peerID: convKey
                )
            }
        }
        objectWillChange.send()
    }
    
    private func sendDeliveryAckIfNeeded(to messageId: String, senderPubKey: String, from id: NostrIdentity) {
        guard !sentGeoDeliveryAcks.contains(messageId) else { return }
        let nt = NostrTransport(keychain: keychain)
        nt.senderPeerID = meshService.myPeerID
        nt.sendDeliveryAckGeohash(for: messageId, toRecipientHex: senderPubKey, from: id)
        sentGeoDeliveryAcks.insert(messageId)
    }
    
    private func sendReadReceiptIfNeeded(to messageId: String, senderPubKey: String, from id: NostrIdentity) {
        guard !sentReadReceipts.contains(messageId) else { return }
        let nt = NostrTransport(keychain: keychain)
        nt.senderPeerID = meshService.myPeerID
        nt.sendReadReceiptGeohash(messageId, toRecipientHex: senderPubKey, from: id)
        sentReadReceipts.insert(messageId)
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
            // Also check for geohash (Nostr) DM conv key if this peer has a known Nostr pubkey
            if let nostrHex = peer.nostrPublicKey {
                let convKey = "nostr_" + String(nostrHex.prefix(TransportConfig.nostrConvKeyPrefixLength))
                if unreadPrivateMessages.contains(convKey) {
                    return true
                }
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
        identityManager.updateHandshakeState(peerID: peerID, state: .completed(fingerprint: fingerprintStr))
        
        // Update encryption status now that we have the fingerprint
        updateEncryptionStatus(for: peerID)
        
        // Check if we have a claimed nickname for this peer
        let peerNicknames = meshService.getPeerNicknames()
        if let nickname = peerNicknames[peerID], nickname != "Unknown" && nickname != "anon\(peerID.prefix(4))" {
            // Update or create social identity with the claimed nickname
            if var identity = identityManager.getSocialIdentity(for: fingerprintStr) {
                identity.claimedNickname = nickname
                identityManager.updateSocialIdentity(identity)
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
                identityManager.updateSocialIdentity(newIdentity)
            }
        }
        
        // Check if this peer is the one we're in a private chat with
        updatePrivateChatPeerIfNeeded()
        
        // If we're in a private chat with this peer (by fingerprint), send pending read receipts
        if let chatFingerprint = selectedPrivateChatFingerprint,
           chatFingerprint == fingerprintStr {
            // Send read receipts for any unread messages from this peer
            // Use a small delay to ensure the connection is fully established
        DispatchQueue.main.asyncAfter(deadline: .now() + TransportConfig.uiReadReceiptRetryLongSeconds) { [weak self] in
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
                sendPrivateMessage(content, to: selectedPeer)
            }
            return
        }
        
        // Parse mentions from the content (use original content for user intent)
        let mentions = parseMentions(from: content)
        
        // Add message to local display
        var displaySender = nickname
        var localSenderPeerID = meshService.myPeerID
        if case .location(let ch) = activeChannel,
           let myGeoIdentity = try? NostrIdentityBridge.deriveIdentity(forGeohash: ch.geohash) {
            let suffix = String(myGeoIdentity.publicKeyHex.suffix(4))
            displaySender = nickname + "#" + suffix
            localSenderPeerID = "nostr:\(myGeoIdentity.publicKeyHex.prefix(TransportConfig.nostrShortKeyDisplayLength))"
        }

        let message = BitchatMessage(
            sender: displaySender,
            content: trimmed,
            timestamp: Date(),
            isRelay: false,
            senderPeerID: localSenderPeerID,
            mentions: mentions.isEmpty ? nil : mentions
        )
        
        // Add to main messages immediately for user feedback
        messages.append(message)
        
        // Update content LRU for near-dup detection
        let ckey = normalizedContentKey(message.content)
        recordContentKey(ckey, timestamp: message.timestamp)
        
        // Persist to channel-specific timelines
        switch activeChannel {
        case .mesh:
            meshTimeline.append(message)
            trimMeshTimelineIfNeeded()
        case .location(let ch):
            var arr = geoTimelines[ch.geohash] ?? []
            arr.append(message)
            if arr.count > geoTimelineCap {
                arr = Array(arr.suffix(geoTimelineCap))
            }
            geoTimelines[ch.geohash] = arr
        }
        trimMessagesIfNeeded()
        
        // Force immediate UI update for user's own messages
        objectWillChange.send()

        updateChannelActivityTimeThenSend(content: content, trimmed: trimmed, mentions: mentions)
    }
    
    private func updateChannelActivityTimeThenSend(content: String, trimmed: String, mentions: [String]) {
        switch activeChannel {
        case .mesh:
            lastPublicActivityAt["mesh"] = Date()
            // Send via mesh with mentions
            meshService.sendMessage(content, mentions: mentions)
        case .location(let ch):
            lastPublicActivityAt["geo:\(ch.geohash)"] = Date()
            // Send to geohash channel via Nostr ephemeral
            Task { @MainActor in
                sendGeohash(ch: ch, content: trimmed)
            }
        }
    }
    
    @MainActor
    private func sendGeohash(ch: GeohashChannel, content: String) {
        do {
            let identity = try NostrIdentityBridge.deriveIdentity(forGeohash: ch.geohash)

            let event = try NostrProtocol.createEphemeralGeohashEvent(
                content: content,
                geohash: ch.geohash,
                senderIdentity: identity,
                nickname: nickname,
                teleported: LocationChannelManager.shared.teleported
            )
            
            let targetRelays = GeoRelayDirectory.shared.closestRelays(
                toGeohash: ch.geohash,
                count: TransportConfig.nostrGeoRelayCount
            )
            
            if targetRelays.isEmpty {
                SecureLogger.warning("Geo: no geohash relays available for \(ch.geohash); not sending", category: .session)
            } else {
                NostrRelayManager.shared.sendEvent(event, to: targetRelays)
            }

            // Track ourselves as active participant
            recordGeoParticipant(pubkeyHex: identity.publicKeyHex)
            let shortKey = "nostr:" + identity.publicKeyHex.prefix(TransportConfig.nostrShortKeyDisplayLength)
            nostrKeyMapping[shortKey] = identity.publicKeyHex
            SecureLogger.debug("GeoTeleport: sent geo message pub=\(identity.publicKeyHex.prefix(8))… teleported=\(LocationChannelManager.shared.teleported)", category: .session)
            
            // If we tagged this as teleported, also mark our pubkey in teleportedGeo for UI
            // Only when not in our regional set (and regional list is known)
            let hasRegional = !LocationChannelManager.shared.availableChannels.isEmpty
            let inRegional = LocationChannelManager.shared.availableChannels.contains { $0.geohash == ch.geohash }
            
            if LocationChannelManager.shared.teleported && hasRegional && !inRegional {
                let key = identity.publicKeyHex.lowercased()
                teleportedGeo = teleportedGeo.union([key])
                SecureLogger.info("GeoTeleport: mark self teleported key=\(key.prefix(8))… total=\(teleportedGeo.count)", category: .session)
            }
        } catch {
            SecureLogger.error("❌ Failed to send geohash message: \(error)", category: .session)
            addSystemMessage(
                L10n.string(
                    "system.location.send_failed",
                    comment: "System message when a location channel send fails"
                )
            )
        }
    }

    @MainActor
    private func switchLocationChannel(to channel: ChannelID) {
        // Flush pending public buffer to avoid cross-channel bleed
        publicBufferTimer?.invalidate(); publicBufferTimer = nil
        publicBuffer.removeAll(keepingCapacity: false)
        activeChannel = channel
        // Reset deduplication set and optionally hydrate timeline for mesh
        processedNostrEvents.removeAll()
        processedNostrEventOrder.removeAll()
        switch channel {
        case .mesh:
            messages = meshTimeline
            // Debug: log if any empty messages are present
            let emptyMesh = messages.filter { $0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
            if emptyMesh > 0 {
                SecureLogger.debug("RenderGuard: mesh timeline contains \(emptyMesh) empty messages", category: .session)
            }
            stopGeoParticipantsTimer()
            geohashPeople = []
            teleportedGeo.removeAll()
        case .location(let ch):
            // Persist the cleaned/sorted timeline for this geohash
            let deduped = geoTimelines[ch.geohash]?.cleanedAndDeduped() ?? []
            geoTimelines[ch.geohash] = deduped
            messages = deduped
        }
        // If switching to a location channel, flush any pending geohash-only system messages
        if case .location = channel, !pendingGeohashSystemMessages.isEmpty {
            for m in pendingGeohashSystemMessages {
                addPublicSystemMessage(m)
            }
            pendingGeohashSystemMessages.removeAll(keepingCapacity: false)
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
        
        // Ensure self appears immediately in the people list; mark teleported state only when truly teleported
        if let id = try? NostrIdentityBridge.deriveIdentity(forGeohash: ch.geohash) {
            recordGeoParticipant(pubkeyHex: id.publicKeyHex)
            let hasRegional = !LocationChannelManager.shared.availableChannels.isEmpty
            let inRegional = LocationChannelManager.shared.availableChannels.contains { $0.geohash == ch.geohash }
            let key = id.publicKeyHex.lowercased()
            if LocationChannelManager.shared.teleported && hasRegional && !inRegional {
                teleportedGeo = teleportedGeo.union([key])
                SecureLogger.info("GeoTeleport: channel switch mark self teleported key=\(key.prefix(8))… total=\(teleportedGeo.count)", category: .session)
            } else {
                teleportedGeo.remove(key)
            }
        }
        
        let subID = "geo-\(ch.geohash)"
        geoSubscriptionID = subID
        startGeoParticipantsTimer()
        let ts = Date().addingTimeInterval(-TransportConfig.nostrGeohashInitialLookbackSeconds)
        let filter = NostrFilter.geohashEphemeral(ch.geohash, since: ts, limit: TransportConfig.nostrGeohashInitialLimit)
        let subRelays = GeoRelayDirectory.shared.closestRelays(toGeohash: ch.geohash, count: 5)
        NostrRelayManager.shared.subscribe(filter: filter, id: subID, relayUrls: subRelays) { [weak self] event in
            self?.handleNostrEvent(event)
        }

        subscribeToGeoChat(ch)
    }
    
    private func handleNostrEvent(_ event: NostrEvent) {
        // Only handle ephemeral kind 20000 with matching tag
        guard event.kind == NostrProtocol.EventKind.ephemeralEvent.rawValue else { return }
        
        // Deduplicate
        if processedNostrEvents.contains(event.id) { return }
        recordProcessedEvent(event.id)
        
        // Log incoming tags for diagnostics
        let tagSummary = event.tags.map { "[" + $0.joined(separator: ",") + "]" }.joined(separator: ",")
        SecureLogger.debug("GeoTeleport: recv pub=\(event.pubkey.prefix(8))… tags=\(tagSummary)", category: .session)
        
        // Track teleport tag for participants – only our format ["t", "teleport"]
        let hasTeleportTag: Bool = event.tags.contains { tag in
            tag.count >= 2 && tag[0].lowercased() == "t" && tag[1].lowercased() == "teleport"
        }
        
        let isSelf: Bool = {
            if let gh = currentGeohash, let my = try? NostrIdentityBridge.deriveIdentity(forGeohash: gh) {
                return my.publicKeyHex.lowercased() == event.pubkey.lowercased()
            }
            return false
        }()

        if hasTeleportTag {
            // Avoid marking our own key from historical events; rely on manager.teleported for self
            if !isSelf {
                let key = event.pubkey.lowercased()
                Task { @MainActor in
                    teleportedGeo = teleportedGeo.union([key])
                    SecureLogger.info("GeoTeleport: mark peer teleported key=\(key.prefix(8))… total=\(teleportedGeo.count)", category: .session)
                }
            }
        }
        
        // Skip only very recent self-echo from relay; include older self events for hydration
        if isSelf {
            let eventTime = Date(timeIntervalSince1970: TimeInterval(event.created_at))
            if Date().timeIntervalSince(eventTime) < 15 {
                return
            }
        }
        
        // Cache nickname from tag if present
        if let nickTag = event.tags.first(where: { $0.first == "n" }), nickTag.count >= 2 {
            let nick = nickTag[1].trimmingCharacters(in: .whitespacesAndNewlines)
            geoNicknames[event.pubkey.lowercased()] = nick
        }
        
        // If this pubkey is blocked, skip mapping, participants, and timeline
        if identityManager.isNostrBlocked(pubkeyHexLowercased: event.pubkey) {
            return
        }
        
        // Store mapping for geohash DM initiation
        let key16 = "nostr_" + String(event.pubkey.prefix(TransportConfig.nostrConvKeyPrefixLength))
        nostrKeyMapping[key16] = event.pubkey
        let key8 = "nostr:" + String(event.pubkey.prefix(TransportConfig.nostrShortKeyDisplayLength))
        nostrKeyMapping[key8] = event.pubkey
        
        // Update participants last-seen for this pubkey
        recordGeoParticipant(pubkeyHex: event.pubkey)
        
        let senderName = displayNameForNostrPubkey(event.pubkey)
        let content = event.content
        
        // If this is a teleport presence event (no content), don't add to timeline
        if let teleTag = event.tags.first(where: { $0.first == "t" }), teleTag.count >= 2, (teleTag[1] == "teleport"),
           content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }
        
        // Clamp future timestamps
        let rawTs = Date(timeIntervalSince1970: TimeInterval(event.created_at))
        let mentions = parseMentions(from: content)
        let msg = BitchatMessage(
            id: event.id,
            sender: senderName,
            content: content,
            timestamp: min(rawTs, Date()),
            isRelay: false,
            senderPeerID: "nostr:\(event.pubkey.prefix(TransportConfig.nostrShortKeyDisplayLength))",
            mentions: mentions.isEmpty ? nil : mentions
        )
        
        Task { @MainActor in
            handlePublicMessage(msg)
            checkForMentions(msg)
            sendHapticFeedback(for: msg)
        }
    }
    
    @MainActor
    private func subscribeToGeoChat(_ ch: GeohashChannel) {
        guard let id = try? NostrIdentityBridge.deriveIdentity(forGeohash: ch.geohash) else { return }
        
        let dmSub = "geo-dm-\(ch.geohash)"
        geoDmSubscriptionID = dmSub
        // pared back logging: subscribe debug only
        // Log GeoDM subscribe only when Tor is ready to avoid early noise
        if TorManager.shared.isReady {
            SecureLogger.debug("GeoDM: subscribing DMs pub=\(id.publicKeyHex.prefix(8))… sub=\(dmSub)", category: .session)
        }
        let dmFilter = NostrFilter.giftWrapsFor(pubkey: id.publicKeyHex, since: Date().addingTimeInterval(-TransportConfig.nostrDMSubscribeLookbackSeconds))
        NostrRelayManager.shared.subscribe(filter: dmFilter, id: dmSub) { [weak self] giftWrap in
            self?.handleGiftWrap(giftWrap, id: id)
        }
    }
    
    private func handleGiftWrap(_ giftWrap: NostrEvent, id: NostrIdentity) {
        if processedNostrEvents.contains(giftWrap.id) {
            return
        }
        recordProcessedEvent(giftWrap.id)
        
        // Decrypt with per-geohash identity
        guard let (content, senderPubkey, rumorTs) = try? NostrProtocol.decryptPrivateMessage(giftWrap: giftWrap, recipientIdentity: id) else {
            SecureLogger.warning("GeoDM: failed decrypt giftWrap id=\(giftWrap.id.prefix(8))…", category: .session)
            return
        }
        
        SecureLogger.debug("GeoDM: decrypted gift-wrap id=\(giftWrap.id.prefix(16))... from=\(senderPubkey.prefix(8))...", category: .session)
        
        guard content.hasPrefix("bitchat1:"),
              let packetData = Self.base64URLDecode(String(content.dropFirst("bitchat1:".count))),
              let packet = BitchatPacket.from(packetData),
              packet.type == MessageType.noiseEncrypted.rawValue,
              let payload = NoisePayload.decode(packet.payload)
        else {
            return
        }
        
        let convKey = "nostr_" + String(senderPubkey.prefix(16))
        nostrKeyMapping[convKey] = senderPubkey
        
        switch payload.type {
        case .privateMessage:
            let messageTimestamp = Date(timeIntervalSince1970: TimeInterval(rumorTs))
            handlePrivateMessage(payload, senderPubkey: senderPubkey, convKey: convKey, id: id, messageTimestamp: messageTimestamp)
        case .delivered:
            handleDelivered(payload, senderPubkey: senderPubkey, convKey: convKey)
        case .readReceipt:
            handleReadReceipt(payload, senderPubkey: senderPubkey, convKey: convKey)
        
        // Explicitly list other cases so we get compile-time check if a new case is added in the future
        case .verifyChallenge, .verifyResponse:
            break
        }
    }
    
    private func handlePrivateMessage(
        _ payload: NoisePayload,
        senderPubkey: String,
        convKey: String,
        id: NostrIdentity,
        messageTimestamp: Date
    ) {
        guard let pm = PrivateMessagePacket.decode(from: payload.data) else { return }
        let messageId = pm.messageID
        
        SecureLogger.info("GeoDM: recv PM <- sender=\(senderPubkey.prefix(8))… mid=\(messageId.prefix(8))…", category: .session)
        
        sendDeliveryAckIfNeeded(to: messageId, senderPubKey: senderPubkey, from: id)
        
        // Duplicate check
        if privateChats[convKey]?.contains(where: { $0.id == messageId }) == true { return }
        for (_, arr) in privateChats {
            if arr.contains(where: { $0.id == messageId }) {
                return
            }
        }
        
        let senderName = displayNameForNostrPubkey(senderPubkey)
        let msg = BitchatMessage(
            id: messageId,
            sender: senderName,
            content: pm.content,
            timestamp: messageTimestamp,
            isRelay: false,
            isPrivate: true,
            recipientNickname: nickname,
            senderPeerID: convKey,
            deliveryStatus: .delivered(to: nickname, at: Date())
        )
        
        if privateChats[convKey] == nil {
            privateChats[convKey] = []
        }
        privateChats[convKey]?.append(msg)
        trimPrivateChatMessagesIfNeeded(for: convKey)
        
        let isViewing = selectedPrivateChatPeer == convKey
        let wasReadBefore = sentReadReceipts.contains(messageId)
        let isRecentMessage = Date().timeIntervalSince(messageTimestamp) < 30
        let shouldMarkUnread = !wasReadBefore && !isViewing && isRecentMessage
        if shouldMarkUnread {
            unreadPrivateMessages.insert(convKey)
        }
        
        // Send READ if viewing this conversation
        if isViewing {
            // pared back: omit pre-send READ log
            sendReadReceiptIfNeeded(to: messageId, senderPubKey: senderPubkey, from: id)
        } else {
            // pared back: omit defer READ log
        }
        
        // Notify for truly unread and recent messages when not viewing
        if !isViewing && shouldMarkUnread {
            NotificationService.shared.sendPrivateMessageNotification(
                from: senderName,
                message: pm.content,
                peerID: convKey
            )
        }
        
        objectWillChange.send()
    }
    
    private func handleDelivered(_ payload: NoisePayload, senderPubkey: String, convKey: String) {
        guard let messageID = String(data: payload.data, encoding: .utf8) else { return }
        
        if let idx = privateChats[convKey]?.firstIndex(where: { $0.id == messageID }) {
            privateChats[convKey]?[idx].deliveryStatus = .delivered(to: displayNameForNostrPubkey(senderPubkey), at: Date())
            objectWillChange.send()
            SecureLogger.info("GeoDM: recv DELIVERED for mid=\(messageID.prefix(8))… from=\(senderPubkey.prefix(8))…", category: .session)
        } else {
            SecureLogger.warning("GeoDM: delivered ack for unknown mid=\(messageID.prefix(8))… conv=\(convKey)", category: .session)
        }
    }
    
    private func handleReadReceipt(_ payload: NoisePayload, senderPubkey: String, convKey: String) {
        guard let messageID = String(data: payload.data, encoding: .utf8) else { return }
        
        if let idx = privateChats[convKey]?.firstIndex(where: { $0.id == messageID }) {
            privateChats[convKey]?[idx].deliveryStatus = .read(by: displayNameForNostrPubkey(senderPubkey), at: Date())
            objectWillChange.send()
            SecureLogger.info("GeoDM: recv READ for mid=\(messageID.prefix(8))… from=\(senderPubkey.prefix(8))…", category: .session)
        } else {
            SecureLogger.warning("GeoDM: read ack for unknown mid=\(messageID.prefix(8))… conv=\(convKey)", category: .session)
        }
    }

    // MARK: - Geohash Participants
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
        let cutoff = Date().addingTimeInterval(-TransportConfig.uiRecentCutoffFiveMinutesSeconds)
        var map = geoParticipants[gh] ?? [:]
        // Prune expired entries
        map = map.filter { $0.value >= cutoff }
        // Remove blocked Nostr pubkeys
        map = map.filter { !identityManager.isNostrBlocked(pubkeyHexLowercased: $0.key) }
        geoParticipants[gh] = map
        // Build display list
        let people = map
            .map { (pub, seen) in
                GeoPerson(id: pub, displayName: displayNameForNostrPubkey(pub), lastSeen: seen)
            }
            .sorted { $0.lastSeen > $1.lastSeen }
        geohashPeople = people
    }

    @MainActor
    func isSelfSender(peerID: String?, displayName: String?) -> Bool {
        guard let peerID else { return false }
        if peerID == meshService.myPeerID { return true }
        let lowerPeer = peerID.lowercased()
        guard lowerPeer.hasPrefix("nostr") else { return false }

        if let mapped = nostrKeyMapping[peerID]?.lowercased(),
           let gh = currentGeohash,
           let myIdentity = try? NostrIdentityBridge.deriveIdentity(forGeohash: gh) {
            if mapped == myIdentity.publicKeyHex.lowercased() { return true }
        }

        if let gh = currentGeohash,
           let myIdentity = try? NostrIdentityBridge.deriveIdentity(forGeohash: gh) {
            let myLower = myIdentity.publicKeyHex.lowercased()
            let shortLen = TransportConfig.nostrShortKeyDisplayLength
            let shortKey = "nostr:" + myLower.prefix(shortLen)
            if lowerPeer == shortKey { return true }
            let suffix = myIdentity.publicKeyHex.suffix(4)
            let expected = (nickname + "#" + suffix).lowercased()
            if let display = displayName?.lowercased(), display == expected { return true }
        }

        return false
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
    
    // MARK: - Public helpers
    /// Return the current, pruned, sorted people list for the active geohash without mutating state.
    @MainActor
    func visibleGeohashPeople() -> [GeoPerson] {
        guard let gh = currentGeohash else { return [] }
        let cutoff = Date().addingTimeInterval(-TransportConfig.uiRecentCutoffFiveMinutesSeconds)
        let map = (geoParticipants[gh] ?? [:])
            .filter { $0.value >= cutoff }
            .filter { !identityManager.isNostrBlocked(pubkeyHexLowercased: $0.key) }
        let people = map
            .map { (pub, seen) in GeoPerson(id: pub, displayName: displayNameForNostrPubkey(pub), lastSeen: seen) }
            .sorted { $0.lastSeen > $1.lastSeen }
        return people
    }
    /// Returns the current participant count for a specific geohash, using the 5-minute activity window.
    @MainActor
    func geohashParticipantCount(for geohash: String) -> Int {
        let cutoff = Date().addingTimeInterval(-TransportConfig.uiRecentCutoffFiveMinutesSeconds)
        let map = geoParticipants[geohash] ?? [:]
        return map.values.filter { $0 >= cutoff }.count
    }

    // Geohash block helpers
    @MainActor
    func isGeohashUserBlocked(pubkeyHexLowercased: String) -> Bool {
        return identityManager.isNostrBlocked(pubkeyHexLowercased: pubkeyHexLowercased)
    }
    @MainActor
    func blockGeohashUser(pubkeyHexLowercased: String, displayName: String) {
        let hex = pubkeyHexLowercased.lowercased()
        identityManager.setNostrBlocked(hex, isBlocked: true)
        
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
        let convKey = "nostr_" + String(hex.prefix(TransportConfig.nostrConvKeyPrefixLength))
        if privateChats[convKey] != nil {
            privateChats.removeValue(forKey: convKey)
            unreadPrivateMessages.remove(convKey)
        }
        
        // Remove mapping keys pointing to this pubkey to avoid accidental resolution
        for (k, v) in nostrKeyMapping where v.lowercased() == hex { nostrKeyMapping.removeValue(forKey: k) }
        
        addSystemMessage(
            L10n.string(
                "system.geohash.blocked",
                comment: "System message shown when a user is blocked in geohash chats",
                displayName
            )
        )
    }
    @MainActor
    func unblockGeohashUser(pubkeyHexLowercased: String, displayName: String) {
        identityManager.setNostrBlocked(pubkeyHexLowercased, isBlocked: false)
        addSystemMessage(
            L10n.string(
                "system.geohash.unblocked",
                comment: "System message shown when a user is unblocked in geohash chats",
                displayName
            )
        )
    }

    /// Begin sampling multiple geohashes (used by channel sheet) without changing active channel.
    @MainActor
    func beginGeohashSampling(for geohashes: [String]) {
        // Disable sampling when app is backgrounded (Tor is stopped there)
        if !TorManager.shared.isForeground() {
            endGeohashSampling()
            return
        }
        // Determine which to add and which to remove
        let desired = Set(geohashes)
        let current = Set(geoSamplingSubs.values)
        let toAdd = desired.subtracting(current)
        let toRemove = current.subtracting(desired)

        for (subID, gh) in geoSamplingSubs where toRemove.contains(gh) {
            NostrRelayManager.shared.unsubscribe(id: subID)
            geoSamplingSubs.removeValue(forKey: subID)
        }

        for gh in toAdd {
            subscribe(gh)
        }
    }
    
    @MainActor
    private func subscribe(_ gh: String) {
        let subID = "geo-sample-\(gh)"
        geoSamplingSubs[subID] = gh
        let filter = NostrFilter.geohashEphemeral(
            gh,
            since: Date().addingTimeInterval(-TransportConfig.nostrGeohashSampleLookbackSeconds),
            limit: TransportConfig.nostrGeohashSampleLimit
        )
        let subRelays = GeoRelayDirectory.shared.closestRelays(toGeohash: gh, count: 5)
        NostrRelayManager.shared.subscribe(filter: filter, id: subID, relayUrls: subRelays) { [weak self] event in
            self?.subscribeNostrEvent(event, gh: gh)
        }
    }
    
    private func subscribeNostrEvent(_ event: NostrEvent, gh: String) {
        guard event.kind == NostrProtocol.EventKind.ephemeralEvent.rawValue else { return }
        
        // Compute current participant count (5-minute window) BEFORE updating with this event
        let cutoff = Date().addingTimeInterval(-TransportConfig.uiRecentCutoffFiveMinutesSeconds)
        let existingCount = geoParticipants[gh]?.values.filter { $0 >= cutoff }.count ?? 0
        
        // Update participants for this specific geohash
        recordGeoParticipant(pubkeyHex: event.pubkey, geohash: gh)
        
        // Notify only on rising-edge: previously zero people, now someone sends a chat
        let content = event.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        
        // Respect geohash blocks
        if identityManager.isNostrBlocked(pubkeyHexLowercased: event.pubkey.lowercased()) { return }
        
        // Skip self identity for this geohash
        if let my = try? NostrIdentityBridge.deriveIdentity(forGeohash: gh), my.publicKeyHex.lowercased() == event.pubkey.lowercased() { return }
        
        // Only trigger when there were zero participants in this geohash recently
        guard existingCount == 0 else { return }
        
        // Avoid notifications for old sampled events when launching or (re)subscribing
        let eventTime = Date(timeIntervalSince1970: TimeInterval(event.created_at))
        if Date().timeIntervalSince(eventTime) > 30 { return }
        
        // Foreground-only notifications: app must be active, and not already viewing this geohash
        #if os(iOS)
        guard UIApplication.shared.applicationState == .active else { return }
        if case .location(let ch) = activeChannel, ch.geohash == gh { return }
        #elseif os(macOS)
        guard NSApplication.shared.isActive else { return }
        if case .location(let ch) = activeChannel, ch.geohash == gh { return }
        #endif
        
        cooldownPerGeohash(gh, content: content, event: event)
    }
    
    private func cooldownPerGeohash(_ gh: String, content: String, event: NostrEvent) {
        let now = Date()
        let last = lastGeoNotificationAt[gh] ?? .distantPast
        if now.timeIntervalSince(last) < TransportConfig.uiGeoNotifyCooldownSeconds { return }
        
        // Compose a short preview
        let preview: String = {
            let maxLen = TransportConfig.uiGeoNotifySnippetMaxLen
            if content.count <= maxLen { return content }
            let idx = content.index(content.startIndex, offsetBy: maxLen)
            return String(content[..<idx]) + "…"
        }()

        Task { @MainActor in
            lastGeoNotificationAt[gh] = now
            // Pre-populate the target geohash timeline so the triggering message appears when user opens it
            var arr = geoTimelines[gh] ?? []
            let senderSuffix = String(event.pubkey.suffix(4))
            let nick = geoNicknames[event.pubkey.lowercased()]
            let senderName = (nick?.isEmpty == false ? nick! : "anon") + "#" + senderSuffix
            
            // Clamp future timestamps
            let rawTs = Date(timeIntervalSince1970: TimeInterval(event.created_at))
            let ts = min(rawTs, Date())
            let mentions = self.parseMentions(from: content)
            let msg = BitchatMessage(
                id: event.id,
                sender: senderName,
                content: content,
                timestamp: ts,
                isRelay: false,
                senderPeerID: "nostr:\(event.pubkey.prefix(TransportConfig.nostrShortKeyDisplayLength))",
                mentions: mentions.isEmpty ? nil : mentions
            )
            if !arr.contains(where: { $0.id == msg.id }) {
                arr.append(msg)
                if arr.count > geoTimelineCap { arr = Array(arr.suffix(geoTimelineCap)) }
                geoTimelines[gh] = arr
            }
            NotificationService.shared.sendGeohashActivityNotification(geohash: gh, bodyPreview: preview)
        }
    }

    /// Stop sampling all extra geohashes.
    @MainActor
    func endGeohashSampling() {
        for subID in geoSamplingSubs.keys { NostrRelayManager.shared.unsubscribe(id: subID) }
        geoSamplingSubs.removeAll()
    }

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
        switch activeChannel {
        case .mesh:
            return "#mesh"
        case .location(let ch):
            return "#\(ch.geohash)"
        }
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
            addSystemMessage(
                L10n.string(
                    "system.dm.blocked_recipient",
                    comment: "System message when attempting to message a blocked user",
                    nickname
                )
            )
            return
        }
        
        // Geohash DM routing: conversation keys start with "nostr_"
        if peerID.hasPrefix("nostr_") {
            sendGeohashDM(content, to: peerID)
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
        trimPrivateChatMessagesIfNeeded(for: peerID)
        
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
                privateChats[peerID]?[index].deliveryStatus = .failed(
                    reason: L10n.string(
                        "content.delivery.reason.unreachable",
                        comment: "Failure reason when a peer is unreachable"
                    )
                )
            }
            addSystemMessage(
                L10n.string(
                    "system.dm.unreachable",
                    comment: "System message when a recipient is unreachable",
                    recipientNickname ?? L10n.string("system.common.user", comment: "Fallback recipient name")
                )
            )
        }
    }
    
    private func sendGeohashDM(_ content: String, to peerID: String) {
        guard case .location(let ch) = activeChannel else {
            addSystemMessage(
                L10n.string(
                    "system.location.not_in_channel",
                    comment: "System message when attempting to send without being in a location channel"
                )
            )
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
            isPrivate: true,
            recipientNickname: nickname,
            senderPeerID: meshService.myPeerID,
            deliveryStatus: .sending
        )
        
        if privateChats[peerID] == nil {
            privateChats[peerID] = []
        }
        
        privateChats[peerID]?.append(message)
        trimPrivateChatMessagesIfNeeded(for: peerID)
        objectWillChange.send()

        // Resolve recipient hex from mapping
        guard let recipientHex = nostrKeyMapping[peerID] else {
            if let msgIdx = privateChats[peerID]?.firstIndex(where: { $0.id == messageID }) {
                privateChats[peerID]?[msgIdx].deliveryStatus = .failed(
                    reason: L10n.string(
                        "content.delivery.reason.unknown_recipient",
                        comment: "Failure reason when the recipient is unknown"
                    )
                )
            }
            return
        }
        
        // Respect geohash blocks
        if identityManager.isNostrBlocked(pubkeyHexLowercased: recipientHex) {
            if let msgIdx = privateChats[peerID]?.firstIndex(where: { $0.id == messageID }) {
                privateChats[peerID]?[msgIdx].deliveryStatus = .failed(
                    reason: L10n.string(
                        "content.delivery.reason.blocked",
                        comment: "Failure reason when the user is blocked"
                    )
                )
            }
            addSystemMessage(
                L10n.string(
                    "system.dm.blocked_generic",
                    comment: "System message when sending fails because user is blocked"
                )
            )
            return
        }
        
        // Send via Nostr using per-geohash identity
        do {
            let id = try NostrIdentityBridge.deriveIdentity(forGeohash: ch.geohash)
            // Prevent messaging ourselves
            if recipientHex.lowercased() == id.publicKeyHex.lowercased() {
                if let idx = privateChats[peerID]?.firstIndex(where: { $0.id == messageID }) {
                privateChats[peerID]?[idx].deliveryStatus = .failed(
                    reason: L10n.string(
                        "content.delivery.reason.self",
                        comment: "Failure reason when attempting to message yourself"
                    )
                )
            }
                return
            }
            SecureLogger.debug("GeoDM: local send mid=\(messageID.prefix(8))… to=\(recipientHex.prefix(8))… conv=\(peerID)", category: .session)
            let nostrTransport = NostrTransport(keychain: keychain)
            nostrTransport.senderPeerID = meshService.myPeerID
            nostrTransport.sendPrivateMessageGeohash(content: content, toRecipientHex: recipientHex, from: id, messageID: messageID)
            if let msgIdx = privateChats[peerID]?.firstIndex(where: { $0.id == messageID }) {
                privateChats[peerID]?[msgIdx].deliveryStatus = .sent
            }
        } catch {
            if let idx = privateChats[peerID]?.firstIndex(where: { $0.id == messageID }) {
                privateChats[peerID]?[idx].deliveryStatus = .failed(
                    reason: L10n.string(
                        "content.delivery.reason.send_error",
                        comment: "Failure reason for a generic send error"
                    )
                )
            }
        }
    }

    // MARK: - Media Transfers

    private enum MediaSendError: Error {
        case encodingFailed
        case tooLarge
        case copyFailed
    }

    @MainActor
    func sendVoiceNote(at url: URL) {
        let targetPeer = selectedPrivateChatPeer
        let message = enqueueMediaMessage(content: "[voice] \(url.lastPathComponent)", targetPeer: targetPeer)
        let messageID = message.id
        let transferId = makeTransferID(messageID: messageID)

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            do {
                let data = try Data(contentsOf: url)
                guard data.count <= FileTransferLimits.maxVoiceNoteBytes else {
                    SecureLogger.warning("Voice note exceeds size limit (\(data.count) bytes)", category: .session)
                    try? FileManager.default.removeItem(at: url)
                    await MainActor.run {
                        self.handleMediaSendFailure(messageID: messageID, reason: "Voice note too large")
                    }
                    return
                }
                let packet = BitchatFilePacket(
                    fileName: url.lastPathComponent,
                    fileSize: UInt64(data.count),
                    mimeType: "audio/mp4",
                    content: data
                )
                guard packet.encode() != nil else { throw MediaSendError.encodingFailed }
                await MainActor.run {
                    self.registerTransfer(transferId: transferId, messageID: messageID)
                    if let peerID = targetPeer {
                        self.meshService.sendFilePrivate(packet, to: peerID, transferId: transferId)
                    } else {
                        self.meshService.sendFileBroadcast(packet, transferId: transferId)
                    }
                }
            } catch {
                SecureLogger.error("Voice note send failed: \(error)", category: .session)
                await MainActor.run {
                    self.handleMediaSendFailure(messageID: messageID, reason: "Failed to send voice note")
                }
            }
        }
    }

    @MainActor
    func sendImage(from sourceURL: URL, cleanup: (() -> Void)? = nil) {
        let targetPeer = selectedPrivateChatPeer

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            var processedURL: URL?
            do {
                let outputURL = try ImageUtils.processImage(at: sourceURL)
                processedURL = outputURL
                let data = try Data(contentsOf: outputURL)
                guard data.count <= FileTransferLimits.maxImageBytes else {
                    SecureLogger.warning("Processed image exceeds size limit (\(data.count) bytes)", category: .session)
                    await MainActor.run {
                        self.addSystemMessage("Image is too large to send.")
                    }
                    try? FileManager.default.removeItem(at: outputURL)
                    return
                }
                let packet = BitchatFilePacket(
                    fileName: outputURL.lastPathComponent,
                    fileSize: UInt64(data.count),
                    mimeType: "image/jpeg",
                    content: data
                )
                guard packet.encode() != nil else { throw MediaSendError.encodingFailed }
                await MainActor.run {
                    let message = self.enqueueMediaMessage(content: "[image] \(outputURL.lastPathComponent)", targetPeer: targetPeer)
                    let messageID = message.id
                    let transferId = self.makeTransferID(messageID: messageID)
                    self.registerTransfer(transferId: transferId, messageID: messageID)
                    if let peerID = targetPeer {
                        self.meshService.sendFilePrivate(packet, to: peerID, transferId: transferId)
                    } else {
                        self.meshService.sendFileBroadcast(packet, transferId: transferId)
                    }
                }
            } catch {
                SecureLogger.error("Image send preparation failed: \(error)", category: .session)
                await MainActor.run {
                    self.addSystemMessage("Failed to prepare image for sending.")
                }
                if let url = processedURL {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            cleanup?()
        }
    }

    @MainActor
    func sendFileAttachment(from sourceURL: URL) {
        let targetPeer = selectedPrivateChatPeer

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            defer { try? FileManager.default.removeItem(at: sourceURL) }
            var destinationURL: URL?
            do {
                let data = try Data(contentsOf: sourceURL)
                guard FileTransferLimits.isValidPayload(data.count) else {
                    throw MediaSendError.tooLarge
                }

                let destination = try self.prepareOutgoingFileCopy(from: sourceURL, data: data)
                destinationURL = destination
                let packet = BitchatFilePacket(
                    fileName: destination.lastPathComponent,
                    fileSize: UInt64(data.count),
                    mimeType: self.mimeType(for: destination),
                    content: data
                )
                guard packet.encode() != nil else {
                    try? FileManager.default.removeItem(at: destination)
                    throw MediaSendError.encodingFailed
                }

                await MainActor.run {
                    let message = self.enqueueMediaMessage(content: "[file] \(destination.lastPathComponent)", targetPeer: targetPeer)
                    let messageID = message.id
                    let transferId = self.makeTransferID(messageID: messageID)
                    self.registerTransfer(transferId: transferId, messageID: messageID)
                    if let peerID = targetPeer {
                        self.meshService.sendFilePrivate(packet, to: peerID, transferId: transferId)
                    } else {
                        self.meshService.sendFileBroadcast(packet, transferId: transferId)
                    }
                }
            } catch MediaSendError.tooLarge {
                await MainActor.run {
                    self.addSystemMessage("File is too large to send.")
                }
            } catch {
                if let destination = destinationURL {
                    try? FileManager.default.removeItem(at: destination)
                }
                SecureLogger.error("File attachment send failed: \(error)", category: .session)
                await MainActor.run {
                    self.addSystemMessage("Failed to send file.")
                }
            }
        }
    }

    @MainActor
    func cancelMediaSend(messageID: String) {
        if let transferId = messageIDToTransferId[messageID],
           let active = transferIdToMessageIDs[transferId]?.first,
           active == messageID {
            meshService.cancelTransfer(transferId)
        }
        clearTransferMapping(for: messageID)
        removeMessage(withID: messageID, cleanupFile: true)
    }

    @MainActor
    func deleteMediaMessage(messageID: String) {
        clearTransferMapping(for: messageID)
        removeMessage(withID: messageID, cleanupFile: true)
    }

    @MainActor
    private func enqueueMediaMessage(content: String, targetPeer: String?) -> BitchatMessage {
        let timestamp = Date()
        let message: BitchatMessage

        if let peerID = targetPeer {
            message = BitchatMessage(
                sender: nickname,
                content: content,
                timestamp: timestamp,
                isRelay: false,
                originalSender: nil,
                isPrivate: true,
                recipientNickname: nicknameForPeer(peerID),
                senderPeerID: meshService.myPeerID,
                deliveryStatus: .sending
            )
            var chats = privateChats
            chats[peerID, default: []].append(message)
            privateChats = chats
            trimPrivateChatMessagesIfNeeded(for: peerID)
        } else {
            let (displayName, senderPeerID) = currentPublicSender()
            message = BitchatMessage(
                sender: displayName,
                content: content,
                timestamp: timestamp,
                isRelay: false,
                originalSender: nil,
                isPrivate: false,
                recipientNickname: nil,
                senderPeerID: senderPeerID,
                deliveryStatus: .sending
            )
            messages.append(message)
            switch activeChannel {
            case .mesh:
                meshTimeline.append(message)
                trimMeshTimelineIfNeeded()
            case .location(let ch):
                var arr = geoTimelines[ch.geohash] ?? []
                arr.append(message)
                if arr.count > geoTimelineCap {
                    arr = Array(arr.suffix(geoTimelineCap))
                }
                geoTimelines[ch.geohash] = arr
            }
            trimMessagesIfNeeded()
        }

        let key = normalizedContentKey(message.content)
        recordContentKey(key, timestamp: timestamp)
        objectWillChange.send()
        return message
    }

    private func currentPublicSender() -> (name: String, peerID: String) {
        var displaySender = nickname
        var senderPeerID = meshService.myPeerID
        if case .location(let ch) = activeChannel,
           let identity = try? NostrIdentityBridge.deriveIdentity(forGeohash: ch.geohash) {
            let suffix = String(identity.publicKeyHex.suffix(4))
            displaySender = nickname + "#" + suffix
            let shortKey = identity.publicKeyHex.prefix(TransportConfig.nostrShortKeyDisplayLength)
            senderPeerID = "nostr:\(shortKey)"
        }
        return (displaySender, senderPeerID)
    }

    @MainActor
    private func nicknameForPeer(_ peerID: String) -> String {
        if let name = meshService.peerNickname(peerID: peerID) {
            return name
        }
        if let favorite = FavoritesPersistenceService.shared.getFavoriteStatus(forPeerID: peerID),
           !favorite.peerNickname.isEmpty {
            return favorite.peerNickname
        }
        if let noiseKey = Data(hexString: peerID),
           let favorite = FavoritesPersistenceService.shared.getFavoriteStatus(for: noiseKey),
           !favorite.peerNickname.isEmpty {
            return favorite.peerNickname
        }
        return "user"
    }

    @MainActor
    private func registerTransfer(transferId: String, messageID: String) {
        transferIdToMessageIDs[transferId, default: []].append(messageID)
        messageIDToTransferId[messageID] = transferId
    }

    private func makeTransferID(messageID: String) -> String {
        "\(messageID)-\(UUID().uuidString)"
    }

    @MainActor
    private func clearTransferMapping(for messageID: String) {
        guard let transferId = messageIDToTransferId.removeValue(forKey: messageID) else { return }
        guard var queue = transferIdToMessageIDs[transferId] else { return }
        if !queue.isEmpty {
            if queue.first == messageID {
                queue.removeFirst()
            } else if let idx = queue.firstIndex(of: messageID) {
                queue.remove(at: idx)
            }
        }
        transferIdToMessageIDs[transferId] = queue.isEmpty ? nil : queue
    }

    @MainActor
    private func handleMediaSendFailure(messageID: String, reason: String) {
        updateMessageDeliveryStatus(messageID, status: .failed(reason: reason))
        clearTransferMapping(for: messageID)
    }

    @MainActor
    private func handleTransferEvent(_ event: TransferProgressManager.Event) {
        switch event {
        case .started(let id, let total):
            guard let messageID = transferIdToMessageIDs[id]?.first else { return }
            updateMessageDeliveryStatus(messageID, status: .partiallyDelivered(reached: 0, total: total))
        case .updated(let id, let sent, let total):
            guard let messageID = transferIdToMessageIDs[id]?.first else { return }
            updateMessageDeliveryStatus(messageID, status: .partiallyDelivered(reached: sent, total: total))
        case .completed(let id, _):
            guard let messageID = transferIdToMessageIDs[id]?.first else { return }
            updateMessageDeliveryStatus(messageID, status: .sent)
            clearTransferMapping(for: messageID)
        case .cancelled(let id, _, _):
            guard let messageID = transferIdToMessageIDs[id]?.first else { return }
            clearTransferMapping(for: messageID)
            removeMessage(withID: messageID, cleanupFile: true)
        }
    }

    private func cleanupLocalFile(forMessage message: BitchatMessage) {
        let prefixes = ["[voice] ": "voicenotes/outgoing",
                        "[image] ": "images/outgoing",
                        "[file] ": "files/outgoing"]
        guard let entry = prefixes.first(where: { message.content.hasPrefix($0.key) }) else { return }
        let filename = String(message.content.dropFirst(entry.key.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filename.isEmpty, let base = try? applicationFilesDirectory() else { return }
        let target = base.appendingPathComponent(entry.value, isDirectory: true).appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: target.path) {
            try? FileManager.default.removeItem(at: target)
        }
    }

    private func prepareOutgoingFileCopy(from sourceURL: URL, data: Data) throws -> URL {
        let base = try applicationFilesDirectory().appendingPathComponent("files/outgoing", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: nil)

        let rawName = sourceURL.lastPathComponent
        let sanitized = sanitizeOutgoingFileName(rawName.isEmpty ? "file" : rawName)
        var destination = base.appendingPathComponent(sanitized)
        var counter = 1
        while FileManager.default.fileExists(atPath: destination.path) {
            let baseName = (sanitized as NSString).deletingPathExtension
            let ext = (sanitized as NSString).pathExtension
            let newName: String
            if ext.isEmpty {
                newName = "\(baseName) (\(counter))"
            } else {
                newName = "\(baseName) (\(counter)).\(ext)"
            }
            destination = base.appendingPathComponent(newName)
            counter += 1
        }

        try data.write(to: destination, options: .atomic)
        return destination
    }

    private func sanitizeOutgoingFileName(_ name: String) -> String {
        var candidate = name
        candidate = candidate.replacingOccurrences(of: "\\", with: "/")
        candidate = candidate.components(separatedBy: "/").last ?? name
        candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.isEmpty { candidate = "file" }
        let invalid = CharacterSet(charactersIn: "<>:\"|?*")
        candidate = candidate.components(separatedBy: invalid).joined(separator: "_")
        if candidate.isEmpty { candidate = "file" }
        if (candidate as NSString).pathExtension.isEmpty {
            candidate += ".bin"
        }
        return candidate
    }

    private func mimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if !ext.isEmpty,
           let type = UTType(filenameExtension: ext),
           let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }

    private func applicationFilesDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let filesDir = base.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true, attributes: nil)
        return filesDir
    }

    @MainActor
    private func removeMessage(withID messageID: String, cleanupFile: Bool = false) {
        var removedMessage: BitchatMessage?

        if let idx = messages.firstIndex(where: { $0.id == messageID }) {
            removedMessage = messages.remove(at: idx)
        }

        meshTimeline.removeAll { $0.id == messageID }

        for key in Array(geoTimelines.keys) {
            var entries = geoTimelines[key] ?? []
            if let idx = entries.firstIndex(where: { $0.id == messageID }) {
                removedMessage = removedMessage ?? entries[idx]
                entries.remove(at: idx)
                if entries.isEmpty {
                    geoTimelines.removeValue(forKey: key)
                } else {
                    geoTimelines[key] = entries
                }
            }
        }

        var chats = privateChats
        for (peerID, items) in chats {
            let filtered = items.filter { $0.id != messageID }
            if filtered.count != items.count {
                if filtered.isEmpty {
                    chats.removeValue(forKey: peerID)
                } else {
                    chats[peerID] = filtered
                }
                if removedMessage == nil {
                    removedMessage = items.first(where: { $0.id == messageID })
                }
            }
        }
        privateChats = chats

        if cleanupFile, let message = removedMessage {
            cleanupLocalFile(forMessage: message)
        }

        objectWillChange.send()
    }

    // MARK: - Geohash DMs initiation
    @MainActor
    func startGeohashDM(withPubkeyHex hex: String) {
        let convKey = "nostr_" + String(hex.prefix(TransportConfig.nostrConvKeyPrefixLength))
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
            bluetoothAlertMessage = L10n.string(
                "content.alert.bluetooth_required.off",
                comment: "Message shown when Bluetooth is turned off"
            )
            showBluetoothAlert = true
        case .unauthorized:
            bluetoothAlertMessage = L10n.string(
                "content.alert.bluetooth_required.permission",
                comment: "Message shown when Bluetooth permission is missing"
            )
            showBluetoothAlert = true
        case .unsupported:
            bluetoothAlertMessage = L10n.string(
                "content.alert.bluetooth_required.unsupported",
                comment: "Message shown when the device lacks Bluetooth support"
            )
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
            addSystemMessage(
                L10n.string(
                    "system.chat.blocked",
                    comment: "System message when starting chat fails because peer is blocked",
                    peerNickname
                )
            )
            return
        }
        
        // Check mutual favorites for offline messaging
        if let peer = unifiedPeerService.getPeer(by: peerID),
           peer.isFavorite && !peer.theyFavoritedUs && !peer.isConnected {
            addSystemMessage(
                L10n.string(
                    "system.chat.requires_favorite",
                    comment: "System message when mutual favorite requirement blocks chat",
                    peerNickname
                )
            )
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
                SecureLogger.debug("📬 Transferred unread status from temp peer IDs to \(peerID)", category: .session)
            }
            
            if consolidatedCount > 0 {
                // Sort by timestamp
                privateChats[peerID]?.sort { $0.timestamp < $1.timestamp }
                
                SecureLogger.info("📥 Consolidated \(consolidatedCount) Nostr messages from temporary peer IDs to \(peerNickname)", category: .session)
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
            SecureLogger.debug("GeoDM: skipping mesh handshake for virtual peerID=\(peerID)", category: .session)
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
        
        SecureLogger.info("📖 Handling read receipt for message \(receipt.originalMessageID) from Nostr", category: .session)
        
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
                    SecureLogger.info("📱 Updating private chat peer ID due to key change: \(oldPeerID) -> \(newPeerID)", category: .session)
                    
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
                        SecureLogger.debug("📱 Migrating private chat messages from \(oldPeerID) to \(newPeerID)", category: .session)
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
        // Subscriptions will be resent after connections come back up
    }
    
    @MainActor
    @objc private func userDidTakeScreenshot() {
        // Respect privacy: do not broadcast screenshots taken from non-chat sheets
        if isLocationChannelsSheetPresented {
            // Show a warning about sharing location screenshots publicly
            showScreenshotPrivacyWarning = true
            return
        }
        if isAppInfoPresented {
            // Silently ignore screenshots of app info
            return
        }

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
                    SecureLogger.debug("Skipping screenshot notification to \(peerID) - no established session", category: .security)
                }
            }
            
            // Show local notification immediately as system message (only in chat)
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
                        let targetRelays = GeoRelayDirectory.shared.closestRelays(toGeohash: ch.geohash, count: 5)
                        if targetRelays.isEmpty {
                            SecureLogger.warning("Geo: no geohash relays available for \(ch.geohash); not sending", category: .session)
                        } else {
                            NostrRelayManager.shared.sendEvent(event, to: targetRelays)
                        }
                        // Track ourselves as active participant
                        self.recordGeoParticipant(pubkeyHex: identity.publicKeyHex)
                    } catch {
                        SecureLogger.error("❌ Failed to send geohash screenshot message: \(error)", category: .session)
                        self.addSystemMessage(
                            L10n.string(
                                "system.location.send_failed",
                                comment: "System message when a location channel send fails"
                            )
                        )
                    }
                }
            }
            

            // Show local notification immediately as system message (only in chat)
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
        // No-op; avoid forcing synchronize on resign
    }
    
    @objc func applicationWillTerminate() {
        // Send leave message to all peers
        meshService.stopServices()
        
        // Force save any pending identity changes (verifications, favorites, etc)
        identityManager.forceSave()
        
        // Verify identity key is still there
        _ = keychain.verifyIdentityKeyExists()
        
        // No need to force synchronize here
        
        // Verify identity key after save
        _ = keychain.verifyIdentityKeyExists()
    }
    
    @objc private func appWillTerminate() {
        // No need to force synchronize here
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
                        SecureLogger.info("📖 Resolved updated peer ID for read receipt: \(peerID) -> \(currentPeerID)", category: .session)
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
        
        // Handle GeoDM (nostr_*) read receipts directly via per-geohash identity
        if peerID.hasPrefix("nostr_"),
           let recipientHex = nostrKeyMapping[peerID],
           case .location(let ch) = LocationChannelManager.shared.selectedChannel,
           let id = try? NostrIdentityBridge.deriveIdentity(forGeohash: ch.geohash) {
            let messages = privateChats[peerID] ?? []
            for message in messages where message.senderPeerID == peerID && !message.isRelay {
                if !sentReadReceipts.contains(message.id) {
                    SecureLogger.debug("GeoDM: sending READ for mid=\(message.id.prefix(8))… to=\(recipientHex.prefix(8))…", category: .session)
                    let nostrTransport = NostrTransport(keychain: keychain)
                    nostrTransport.senderPeerID = meshService.myPeerID
                    nostrTransport.sendReadReceiptGeohash(message.id, toRecipientHex: recipientHex, from: id)
                    sentReadReceipts.insert(message.id)
                }
            }
            return
        }

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
        // When in a geohash channel, allow resolving by geohash participant nickname
        switch LocationChannelManager.shared.selectedChannel {
        case .location:
            // If a disambiguation suffix is present (e.g., "name#abcd"), try exact displayName match first
            if nickname.contains("#") {
                if let person = visibleGeohashPeople().first(where: { $0.displayName == nickname }) {
                    let convKey = "nostr_" + String(person.id.prefix(TransportConfig.nostrConvKeyPrefixLength))
                    nostrKeyMapping[convKey] = person.id
                    return convKey
                }
            }
            let base: String = {
                if let hashIndex = nickname.firstIndex(of: "#") { return String(nickname[..<hashIndex]) }
                return nickname
            }().lowercased()
            // Try exact match against cached geoNicknames (pubkey -> nickname)
            if let pub = geoNicknames.first(where: { (_, nick) in nick.lowercased() == base })?.key {
                let convKey = "nostr_" + String(pub.prefix(TransportConfig.nostrConvKeyPrefixLength))
                nostrKeyMapping[convKey] = pub
                return convKey
            }
        default:
            break
        }
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
        _ = keychain.deleteAllKeychainData()
        
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
        identityManager.clearAllIdentityData()
        peerIDToPublicKeyFingerprint.removeAll()
        
        // Clear persistent favorites from keychain
        FavoritesPersistenceService.shared.clearAllFavorites()
        
        // Identity manager has cleared persisted identity data above
        
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
        if let bleService = meshService as? BLEService {
            bleService.resetIdentityForPanic(currentNickname: nickname)
        }
        
        // No need to force UserDefaults synchronization
        
        // Reinitialize Nostr with new identity
        // This will generate new Nostr keys derived from new Noise keys
        Task { @MainActor in
            // Small delay to ensure cleanup completes
            try? await Task.sleep(nanoseconds: TransportConfig.uiAsyncShortSleepNs) // 0.1 seconds
            
            // Reinitialize Nostr relay manager with new identity
            nostrRelayManager = NostrRelayManager()
            setupNostrMessageHandling()
            nostrRelayManager?.connect()
        }
        
        // Force immediate UI update for panic mode
        // UI updates immediately - no flushing needed
        
    }
    
    // MARK: - Autocomplete
    
    func updateAutocomplete(for text: String, cursorPosition: Int) {
        // Build candidate list based on active channel
        let peerCandidates: [String] = {
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
                // In geohash channels, compare against our per-geohash nostr short ID
                if case .location(let ch) = activeChannel, spid.hasPrefix("nostr:") {
                    if let myGeo = try? NostrIdentityBridge.deriveIdentity(forGeohash: ch.geohash) {
                        return spid == "nostr:\(myGeo.publicKeyHex.prefix(TransportConfig.nostrShortKeyDisplayLength))"
                    }
                }
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
            let (baseName, suffix) = message.sender.splitSuffix()
            var senderStyle = AttributeContainer()
            // Use consistent color for all senders
            senderStyle.foregroundColor = baseColor
            // Bold the user's own nickname
            let fontWeight: Font.Weight = isSelf ? .bold : .medium
            senderStyle.font = .bitchatSystem(size: 14, weight: fontWeight, design: .monospaced)
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
            // Compute NSString-backed length for regex/nsrange correctness with multi-byte characters
            let nsContent = content as NSString
            let nsLen = nsContent.length
            let containsCashuEarly: Bool = {
                let rx = Regexes.quickCashuPresence
                return rx.numberOfMatches(in: content, options: [], range: NSRange(location: 0, length: nsLen)) > 0
            }()
            if (content.count > 4000 || content.hasVeryLongToken(threshold: 1024)) && !containsCashuEarly {
                var plainStyle = AttributeContainer()
                plainStyle.foregroundColor = baseColor
                plainStyle.font = isSelf
                    ? .bitchatSystem(size: 14, weight: .bold, design: .monospaced)
                    : .bitchatSystem(size: 14, design: .monospaced)
                result.append(AttributedString(content).mergingAttributes(plainStyle))
            } else {
            // Reuse compiled regexes and detector
            let hashtagRegex = Regexes.hashtag
            let mentionRegex = Regexes.mention
            let cashuRegex = Regexes.cashu
            let bolt11Regex = Regexes.bolt11
            let lnurlRegex = Regexes.lnurl
            let lightningSchemeRegex = Regexes.lightningScheme
            let detector = Regexes.linkDetector
            let hasMentionsHint = content.contains("@")
            let hasHashtagsHint = content.contains("#")
            let hasURLHint = content.contains("://") || content.contains("www.") || content.contains("http")
            let hasLightningHint = content.lowercased().contains("ln") || content.lowercased().contains("lightning:")
            let hasCashuHint = content.lowercased().contains("cashu")

            let hashtagMatches = hasHashtagsHint ? hashtagRegex.matches(in: content, options: [], range: NSRange(location: 0, length: nsLen)) : []
            let mentionMatches = hasMentionsHint ? mentionRegex.matches(in: content, options: [], range: NSRange(location: 0, length: nsLen)) : []
            let urlMatches = hasURLHint ? (detector?.matches(in: content, options: [], range: NSRange(location: 0, length: nsLen)) ?? []) : []
            let cashuMatches = hasCashuHint ? cashuRegex.matches(in: content, options: [], range: NSRange(location: 0, length: nsLen)) : []
            let lightningMatches = hasLightningHint ? lightningSchemeRegex.matches(in: content, options: [], range: NSRange(location: 0, length: nsLen)) : []
            let bolt11Matches = hasLightningHint ? bolt11Regex.matches(in: content, options: [], range: NSRange(location: 0, length: nsLen)) : []
            let lnurlMatches = hasLightningHint ? lnurlRegex.matches(in: content, options: [], range: NSRange(location: 0, length: nsLen)) : []
            
            // Combine and sort matches, excluding hashtags/URLs overlapping mentions
            let mentionRanges = mentionMatches.map { $0.range(at: 0) }
            func overlapsMention(_ r: NSRange) -> Bool {
                for mr in mentionRanges { if NSIntersectionRange(r, mr).length > 0 { return true } }
                return false
            }
            // Helper: check if a hashtag is immediately attached to a preceding @mention (e.g., @name#abcd)
            func attachedToMention(_ r: NSRange) -> Bool {
                if let nsRange = Range(r, in: content), nsRange.lowerBound > content.startIndex {
                    var i = content.index(before: nsRange.lowerBound)
                    while true {
                        let ch = content[i]
                        if ch.isWhitespace || ch.isNewline { break }
                        if ch == "@" { return true }
                        if i == content.startIndex { break }
                        i = content.index(before: i)
                    }
                }
                return false
            }
            // Helper: ensure '#' starts a new token (start-of-line or whitespace before '#')
            func isStandaloneHashtag(_ r: NSRange) -> Bool {
                guard let nsRange = Range(r, in: content) else { return false }
                if nsRange.lowerBound == content.startIndex { return true }
                let prev = content.index(before: nsRange.lowerBound)
                return content[prev].isWhitespace || content[prev].isNewline
            }
            var allMatches: [(range: NSRange, type: String)] = []
            for match in hashtagMatches where !overlapsMention(match.range(at: 0)) && !attachedToMention(match.range(at: 0)) && isStandaloneHashtag(match.range(at: 0)) {
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
                    if lastEnd < nsRange.lowerBound {
                        let beforeText = String(content[lastEnd..<nsRange.lowerBound])
                        if !beforeText.isEmpty {
                            var beforeStyle = AttributeContainer()
                            beforeStyle.foregroundColor = baseColor
                            beforeStyle.font = isSelf
                                ? .bitchatSystem(size: 14, weight: .bold, design: .monospaced)
                                : .bitchatSystem(size: 14, design: .monospaced)
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
                        let (mBase, mSuffix) = matchText.splitSuffix()
                        // Determine if this mention targets me (resolves with optional suffix per active channel)
                        let mySuffix: String? = {
                            if case .location(let ch) = activeChannel, let id = try? NostrIdentityBridge.deriveIdentity(forGeohash: ch.geohash) {
                                return String(id.publicKeyHex.suffix(4))
                            }
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
                        mentionStyle.font = .bitchatSystem(size: 14, weight: isSelf ? .bold : .semibold, design: .monospaced)
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
                            // Do not link if this hashtag is directly attached to an @mention (e.g., @name#geohash)
                            let attachedToMention: Bool = {
                                // nsRange is the Range<String.Index> for this match within content
                                // Walk left until whitespace/newline; if we encounter '@' first, treat as part of mention
                                if nsRange.lowerBound > content.startIndex {
                                    var i = content.index(before: nsRange.lowerBound)
                                    while true {
                                        let ch = content[i]
                                        if ch.isWhitespace || ch.isNewline { break }
                                        if ch == "@" { return true }
                                        if i == content.startIndex { break }
                                        i = content.index(before: i)
                                    }
                                }
                                return false
                            }()
                            // Also require the '#' to start a new token (whitespace or start-of-line before '#')
                            let standalone: Bool = {
                                if nsRange.lowerBound == content.startIndex { return true }
                                let prev = content.index(before: nsRange.lowerBound)
                                return content[prev].isWhitespace || content[prev].isNewline
                            }()
                            var tagStyle = AttributeContainer()
                            tagStyle.font = isSelf
                                ? .bitchatSystem(size: 14, weight: .bold, design: .monospaced)
                                : .bitchatSystem(size: 14, design: .monospaced)
                            tagStyle.foregroundColor = baseColor
                            if isGeohash && !attachedToMention && standalone, let url = URL(string: "bitchat://geohash/\(token)") {
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
                                ? .bitchatSystem(size: 14, weight: .bold, design: .monospaced)
                                : .bitchatSystem(size: 14, design: .monospaced)
                            result.append(AttributedString(" ").mergingAttributes(spacer))
                        } else if type == "lightning" || type == "bolt11" || type == "lnurl" {
                            // Skip inline invoice/link; a styled chip is rendered below the message
                            var spacer = AttributeContainer()
                            spacer.foregroundColor = baseColor
                            spacer.font = isSelf
                                ? .bitchatSystem(size: 14, weight: .bold, design: .monospaced)
                                : .bitchatSystem(size: 14, design: .monospaced)
                            result.append(AttributedString(" ").mergingAttributes(spacer))
                        } else {
                            // Keep URL styling and make it tappable via .link attribute
                            var matchStyle = AttributeContainer()
                            matchStyle.font = .bitchatSystem(size: 14, weight: isSelf ? .bold : .semibold, design: .monospaced)
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
                    ? .bitchatSystem(size: 14, weight: .bold, design: .monospaced)
                    : .bitchatSystem(size: 14, design: .monospaced)
                if isMentioned {
                    remainingStyle.font = remainingStyle.font?.bold()
                }
                result.append(AttributedString(remainingText).mergingAttributes(remainingStyle))
            }
            }
            
            // Add timestamp at the end (smaller, light grey)
            let timestamp = AttributedString(" [\(message.formattedTimestamp)]")
            var timestampStyle = AttributeContainer()
            timestampStyle.foregroundColor = Color.gray.opacity(0.7)
            timestampStyle.font = .bitchatSystem(size: 10, design: .monospaced)
            result.append(timestamp.mergingAttributes(timestampStyle))
        } else {
            // System message
            var contentStyle = AttributeContainer()
            contentStyle.foregroundColor = Color.gray
            let content = AttributedString("* \(message.content) *")
            contentStyle.font = .bitchatSystem(size: 12, design: .monospaced).italic()
            result.append(content.mergingAttributes(contentStyle))
            
            // Add timestamp at the end for system messages too
            let timestamp = AttributedString(" [\(message.formattedTimestamp)]")
            var timestampStyle = AttributeContainer()
            timestampStyle.foregroundColor = Color.gray.opacity(0.5)
            timestampStyle.font = .bitchatSystem(size: 10, design: .monospaced)
            result.append(timestamp.mergingAttributes(timestampStyle))
        }
        
        // Cache the formatted text
        message.setCachedFormattedText(result, isDark: isDark, isSelf: isSelf)
        
        return result
    }

    @MainActor
    func formatMessageHeader(_ message: BitchatMessage, colorScheme: ColorScheme) -> AttributedString {
        let isSelf: Bool = {
            if let spid = message.senderPeerID {
                if case .location(let ch) = activeChannel, spid.hasPrefix("nostr:") {
                    if let myGeo = try? NostrIdentityBridge.deriveIdentity(forGeohash: ch.geohash) {
                        return spid == "nostr:\(myGeo.publicKeyHex.prefix(TransportConfig.nostrShortKeyDisplayLength))"
                    }
                }
                return spid == meshService.myPeerID
            }
            if message.sender == nickname { return true }
            if message.sender.hasPrefix(nickname + "#") { return true }
            return false
        }()

        let isDark = colorScheme == .dark
        let baseColor: Color = isSelf ? .orange : peerColor(for: message, isDark: isDark)

        if message.sender == "system" {
            var style = AttributeContainer()
            style.foregroundColor = baseColor
            style.font = .bitchatSystem(size: 14, weight: .medium, design: .monospaced)
            return AttributedString(message.sender).mergingAttributes(style)
        }

        var result = AttributedString()
        let (baseName, suffix) = message.sender.splitSuffix()
        var senderStyle = AttributeContainer()
        senderStyle.foregroundColor = baseColor
        senderStyle.font = .bitchatSystem(size: 14, weight: isSelf ? .bold : .medium, design: .monospaced)
        if let spid = message.senderPeerID,
           let url = URL(string: "bitchat://user/\(spid.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? spid)") {
            senderStyle.link = url
        }

        result.append(AttributedString("<@").mergingAttributes(senderStyle))
        result.append(AttributedString(baseName).mergingAttributes(senderStyle))
        if !suffix.isEmpty {
            var suffixStyle = senderStyle
            suffixStyle.foregroundColor = baseColor.opacity(0.6)
            result.append(AttributedString(suffix).mergingAttributes(suffixStyle))
        }
        result.append(AttributedString("> ").mergingAttributes(senderStyle))
        return result
    }
    
    func formatMessage(_ message: BitchatMessage, colorScheme: ColorScheme) -> AttributedString {
        var result = AttributedString()
        
        let isDark = colorScheme == .dark
        let primaryColor = isDark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
        
        if message.sender == "system" {
            let content = AttributedString("* \(message.content) *")
            var contentStyle = AttributeContainer()
            contentStyle.foregroundColor = Color.gray
            contentStyle.font = .bitchatSystem(size: 12, design: .monospaced).italic()
            result.append(content.mergingAttributes(contentStyle))
            
            // Add timestamp at the end for system messages
            let timestamp = AttributedString(" [\(message.formattedTimestamp)]")
            var timestampStyle = AttributeContainer()
            timestampStyle.foregroundColor = Color.gray.opacity(0.5)
            timestampStyle.font = .bitchatSystem(size: 10, design: .monospaced)
            result.append(timestamp.mergingAttributes(timestampStyle))
        } else {
            let sender = AttributedString("<@\(message.sender)> ")
            var senderStyle = AttributeContainer()
            
            // Use consistent color for all senders
            senderStyle.foregroundColor = primaryColor
            // Bold the user's own nickname
            let fontWeight: Font.Weight = message.sender == nickname ? .bold : .medium
            senderStyle.font = .bitchatSystem(size: 12, weight: fontWeight, design: .monospaced)
            result.append(sender.mergingAttributes(senderStyle))
            
            
            // Process content to highlight mentions
            let contentText = message.content
            var processedContent = AttributedString()
            
            // Regular expression to find @mentions
            let pattern = "@([\\p{L}0-9_]+)"
            let regex = try? NSRegularExpression(pattern: pattern, options: [])
            let nsContent = contentText as NSString
            let nsLen = nsContent.length
            let matches = regex?.matches(in: contentText, options: [], range: NSRange(location: 0, length: nsLen)) ?? []
            
            var lastEndIndex = contentText.startIndex
            
            for match in matches {
                // Add text before the mention
                if let range = Range(match.range(at: 0), in: contentText) {
                    if lastEndIndex < range.lowerBound {
                        let beforeText = String(contentText[lastEndIndex..<range.lowerBound])
                        if !beforeText.isEmpty {
                            var normalStyle = AttributeContainer()
                            normalStyle.font = .bitchatSystem(size: 14, design: .monospaced)
                            normalStyle.foregroundColor = isDark ? Color.white : Color.black
                            processedContent.append(AttributedString(beforeText).mergingAttributes(normalStyle))
                        }
                    }
                    
                    // Add the mention with highlight
                    let mentionText = String(contentText[range])
                    var mentionStyle = AttributeContainer()
                    mentionStyle.font = .bitchatSystem(size: 14, weight: .semibold, design: .monospaced)
                    mentionStyle.foregroundColor = Color.orange
                    processedContent.append(AttributedString(mentionText).mergingAttributes(mentionStyle))
                    
                    if lastEndIndex < range.upperBound { lastEndIndex = range.upperBound }
                }
            }
            
            // Add any remaining text
            if lastEndIndex < contentText.endIndex {
                let remainingText = String(contentText[lastEndIndex...])
                var normalStyle = AttributeContainer()
                normalStyle.font = .bitchatSystem(size: 14, design: .monospaced)
                normalStyle.foregroundColor = isDark ? Color.white : Color.black
                processedContent.append(AttributedString(remainingText).mergingAttributes(normalStyle))
            }
            
            result.append(processedContent)
            
            if message.isRelay, let originalSender = message.originalSender {
                let relay = AttributedString(" (via \(originalSender))")
                var relayStyle = AttributeContainer()
                relayStyle.foregroundColor = primaryColor.opacity(0.7)
                relayStyle.font = .bitchatSystem(size: 11, design: .monospaced)
                result.append(relay.mergingAttributes(relayStyle))
            }
            
            // Add timestamp at the end (smaller, light grey)
            let timestamp = AttributedString(" [\(message.formattedTimestamp)]")
            var timestampStyle = AttributeContainer()
            timestampStyle.foregroundColor = Color.gray.opacity(0.7)
            timestampStyle.font = .bitchatSystem(size: 10, design: .monospaced)
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
            messages = Array(messages.suffix(maxMessages))
        }
    }

    @MainActor
    private func peerColor(for message: BitchatMessage, isDark: Bool) -> Color {
        if let spid = message.senderPeerID {
            if spid.hasPrefix("nostr:") || spid.hasPrefix("nostr_") {
                let bare: String = {
                    if spid.hasPrefix("nostr:") { return String(spid.dropFirst(6)) }
                    if spid.hasPrefix("nostr_") { return String(spid.dropFirst(6)) }
                    return spid
                }()
                let full = nostrKeyMapping[spid]?.lowercased() ?? bare.lowercased()
                return getNostrPaletteColor(for: full, isDark: isDark)
            } else if spid.count == 16 {
                // Mesh short ID
                return getPeerPaletteColor(for: spid, isDark: isDark)
            } else {
                return getPeerPaletteColor(for: spid.lowercased(), isDark: isDark)
            }
        }
        // Fallback when we only have a display name
        return Color(peerSeed: message.sender.lowercased(), isDark: isDark)
    }

    // Public helpers for views to color peers consistently in lists
    @MainActor
    func colorForNostrPubkey(_ pubkeyHexLowercased: String, isDark: Bool) -> Color {
        return getNostrPaletteColor(for: pubkeyHexLowercased.lowercased(), isDark: isDark)
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
        return Color(peerSeed: meshSeed(for: peerID), isDark: isDark)
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
            let h = (currentSeeds[id] ?? id).djb2()
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

    // MARK: - Nostr People Minimal-Distance Palette (same algo)
    private var nostrPaletteLight: [String: (slot: Int, ring: Int, hue: Double)] = [:]
    private var nostrPaletteDark: [String: (slot: Int, ring: Int, hue: Double)] = [:]
    private var nostrPaletteSeeds: [String: String] = [:] // pubkey -> seed used

    @MainActor
    private func getNostrPaletteColor(for pubkeyHexLowercased: String, isDark: Bool) -> Color {
        rebuildNostrPaletteIfNeeded()
        let entry = (isDark ? nostrPaletteDark[pubkeyHexLowercased] : nostrPaletteLight[pubkeyHexLowercased])
        let myHex: String? = {
            if case .location(let ch) = LocationChannelManager.shared.selectedChannel,
               let id = try? NostrIdentityBridge.deriveIdentity(forGeohash: ch.geohash) {
                return id.publicKeyHex.lowercased()
            }
            return nil
        }()
        if let me = myHex, pubkeyHexLowercased == me { return .orange }
        let saturation: Double = isDark ? 0.80 : 0.70
        let baseBrightness: Double = isDark ? 0.75 : 0.45
        let ringDelta = isDark ? TransportConfig.uiPeerPaletteRingBrightnessDeltaDark : TransportConfig.uiPeerPaletteRingBrightnessDeltaLight
        if let e = entry {
            let brightness = min(1.0, max(0.0, baseBrightness + ringDelta * Double(e.ring)))
            return Color(hue: e.hue, saturation: saturation, brightness: brightness)
        }
        // Fallback to seed color if not in palette (e.g., transient)
        return Color(peerSeed: "nostr:" + pubkeyHexLowercased, isDark: isDark)
    }

    @MainActor
    private func rebuildNostrPaletteIfNeeded() {
        // Build seeds map from currently visible geohash people (excluding self)
        let myHex: String? = {
            if case .location(let ch) = LocationChannelManager.shared.selectedChannel,
               let id = try? NostrIdentityBridge.deriveIdentity(forGeohash: ch.geohash) {
                return id.publicKeyHex.lowercased()
            }
            return nil
        }()
        let people = visibleGeohashPeople()
        var currentSeeds: [String: String] = [:]
        for p in people where p.id != myHex { currentSeeds[p.id] = "nostr:" + p.id }

        if currentSeeds == nostrPaletteSeeds,
           nostrPaletteLight.keys.count == currentSeeds.count,
           nostrPaletteDark.keys.count == currentSeeds.count {
            return
        }
        nostrPaletteSeeds = currentSeeds

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
            for i in 0..<slotCount { slots.append(Double(i) / Double(slotCount)) }
        }

        func circDist(_ a: Double, _ b: Double) -> Double {
            let d = abs(a - b)
            return d > 0.5 ? 1.0 - d : d
        }

        let peers = currentSeeds.keys.sorted()
        let prefIndex: [String: Int] = Dictionary(uniqueKeysWithValues: peers.map { id in
            let h = (currentSeeds[id] ?? id).djb2()
            let idx = Int(h % UInt64(slots.count))
            return (id, idx)
        })

        var mapping: [String: (slot: Int, ring: Int, hue: Double)] = [:]
        var usedSlots = Set<Int>()
        var usedHues: [Double] = []

        let prev = nostrPaletteLight.isEmpty ? nostrPaletteDark : nostrPaletteLight
        for (id, entry) in prev {
            if peers.contains(id), entry.slot < slots.count {
                mapping[id] = (entry.slot, entry.ring, slots[entry.slot])
                usedSlots.insert(entry.slot)
                usedHues.append(slots[entry.slot])
            }
        }

        let unassigned = peers.filter { mapping[$0] == nil }
        for id in unassigned {
            let preferred = prefIndex[id] ?? 0
            if !usedSlots.contains(preferred) && preferred < slots.count {
                mapping[id] = (preferred, 0, slots[preferred])
                usedSlots.insert(preferred)
                usedHues.append(slots[preferred])
                continue
            }
            var bestSlot: Int? = nil
            var bestScore: Double = -1
            for sIdx in 0..<slots.count where !usedSlots.contains(sIdx) {
                let hue = slots[sIdx]
                let minDist = usedHues.isEmpty ? 1.0 : usedHues.map { circDist(hue, $0) }.min() ?? 1.0
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

        let stillUnassigned = peers.filter { mapping[$0] == nil }
        if !stillUnassigned.isEmpty {
            for (idx, id) in stillUnassigned.enumerated() {
                let preferred = prefIndex[id] ?? 0
                let goldenStep = 7
                let s = (preferred + idx * goldenStep) % slots.count
                mapping[id] = (s, 1, slots[s])
            }
        }

        nostrPaletteLight = mapping
        nostrPaletteDark = mapping
    }

    // Clear the current public channel's timeline (visible + persistent buffer)
    @MainActor
    func clearCurrentPublicTimeline() {
        switch activeChannel {
        case .mesh:
            messages.removeAll()
            meshTimeline.removeAll()
        case .location(let ch):
            messages.removeAll()
            geoTimelines[ch.geohash] = []
        }
    }
    
    private func trimPrivateChatMessagesIfNeeded(for peerID: String) {
        // Handled by PrivateChatManager
    }
    
    // MARK: - Message Management
    
    private func addMessage(_ message: BitchatMessage) {
        // Check for duplicates
        guard !messages.contains(where: { $0.id == message.id }) else { return }
        messages.append(message)
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
            if let identity = identityManager.getSocialIdentity(for: fingerprint) {
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
        identityManager.setVerified(fingerprint: fingerprint, verified: true)
        
        // Update local set for UI
        verifiedFingerprints.insert(fingerprint)
        
        // Update encryption status after verification
        updateEncryptionStatus(for: peerID)
    }

    @MainActor
    func unverifyFingerprint(for peerID: String) {
        guard let fingerprint = getFingerprint(for: peerID) else { return }
        identityManager.setVerified(fingerprint: fingerprint, verified: false)
        identityManager.forceSave()
        verifiedFingerprints.remove(fingerprint)
        updateEncryptionStatus(for: peerID)
    }
    
    @MainActor
    func loadVerifiedFingerprints() {
        // Load verified fingerprints directly from secure storage
        verifiedFingerprints = identityManager.getVerifiedFingerprints()
        // Log snapshot for debugging persistence
        let sample = Array(verifiedFingerprints.prefix(TransportConfig.uiFingerprintSampleCount)).map { $0.prefix(8) }.joined(separator: ", ")
        SecureLogger.info("🔐 Verified loaded: \(verifiedFingerprints.count) [\(sample)]", category: .security)
        // Also log any offline favorites and whether we consider them verified
        let offlineFavorites = unifiedPeerService.favorites.filter { !$0.isConnected }
        for fav in offlineFavorites {
            let fp = unifiedPeerService.getFingerprint(for: fav.id)
            let isVer = fp.flatMap { verifiedFingerprints.contains($0) } ?? false
            let fpShort = fp?.prefix(8) ?? "nil"
            SecureLogger.info("⭐️ Favorite offline: \(fav.nickname) fp=\(fpShort) verified=\(isVer)", category: .security)
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
            DispatchQueue.main.async {
                guard let self = self else { return }

                SecureLogger.debug("🔐 Authenticated: \(peerID)", category: .security)

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
                    SecureLogger.debug("🗺️ Mapped short peerID to Noise key for header continuity: \(peerID) -> \(stable.prefix(8))…", category: .session)
                }

                // If a QR verification is pending but not sent yet, send it now that session is authenticated
                if var pending = self.pendingQRVerifications[peerID], pending.sent == false {
                    self.meshService.sendVerifyChallenge(to: peerID, noiseKeyHex: pending.noiseKeyHex, nonceA: pending.nonceA)
                    pending.sent = true
                    self.pendingQRVerifications[peerID] = pending
                    SecureLogger.debug("📤 Sent deferred verify challenge to \(peerID) after handshake", category: .security)
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
                        SecureLogger.info("🔐 Marking verified fingerprint: \(short)", category: .security)
                        identityManager.setVerified(fingerprint: fp, verified: true)
                        identityManager.forceSave()
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
    }

    func didReceivePublicMessage(from peerID: String, nickname: String, content: String, timestamp: Date) {
        Task { @MainActor in
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
    
    func didConnectToPeer(_ peerID: String) {
        SecureLogger.debug("🤝 Peer connected: \(peerID)", category: .session)
        
        // Handle all main actor work async
        Task { @MainActor in
            isConnected = true
            
            // Register ephemeral session with identity manager
            identityManager.registerEphemeralSession(peerID: peerID, handshakeState: .none)
            
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
        
        //
    }
    
    func didDisconnectFromPeer(_ peerID: String) {
        SecureLogger.debug("👋 Peer disconnected: \(peerID)", category: .session)
        
        // Remove ephemeral session from identity manager
        identityManager.removeEphemeralSession(peerID: peerID)

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
                // Count mesh peers that are connected OR recently reachable via mesh relays
                let meshPeers = peers.filter { peerID in
                    self.meshService.isPeerConnected(peerID) || self.meshService.isPeerReachable(peerID)
                }
                
                // Rising-edge only: previously zero peers, now > 0 peers
                let currentPeerSet = Set(meshPeers)
                let hadNone = self.recentlySeenPeers.isEmpty
                if meshPeers.count > 0 && hadNone && !self.hasNotifiedNetworkAvailable {
                    self.hasNotifiedNetworkAvailable = true
                    self.lastNetworkNotificationTime = Date()
                    self.recentlySeenPeers = currentPeerSet
                    NotificationService.shared.sendNetworkAvailableNotification(peerCount: meshPeers.count)
                    SecureLogger.info("👥 Sent bitchatters nearby notification for \(meshPeers.count) mesh peers", category: .session)
                }
            } else {
                // No peers — immediately reset to allow next rising-edge to notify
                self.hasNotifiedNetworkAvailable = false
                self.recentlySeenPeers.removeAll()
                if self.networkResetTimer != nil {
                    self.networkResetTimer?.invalidate()
                    self.networkResetTimer = nil
                }
                SecureLogger.debug("⏳ Mesh empty — reset network notification state", category: .session)
            }
            
            // Register ephemeral sessions for all connected peers
            for peerID in peers {
                self.identityManager.registerEphemeralSession(peerID: peerID, handshakeState: .none)
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
                SecureLogger.debug("🧹 Cleaned up \(idsToRemove.count) stale unread peer IDs", category: .session)
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
            SecureLogger.debug("🧹 Cleaned up \(removedCount) old read receipts", category: .session)
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
                SecureLogger.error("Failed to decode Nostr npub: \(error)", category: .session)
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
        return identityManager.isFavorite(fingerprint: fingerprint)
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
        if case .mesh = activeChannel {
            messages.append(systemMessage)
        }
        objectWillChange.send()
    }

    /// Public helper to add a system message to the public chat timeline.
    /// Also persists the message into the active channel's backing store so it survives timeline rebinds.
    @MainActor
    func addPublicSystemMessage(_ content: String) {
        let systemMessage = BitchatMessage(
            sender: "system",
            content: content,
            timestamp: Date(),
            isRelay: false
        )
        // Append to current visible messages
        messages.append(systemMessage)
        // Persist into the backing store for the active channel to survive rebinds
        switch activeChannel {
        case .mesh:
            meshTimeline.append(systemMessage)
        case .location(let ch):
            var arr = geoTimelines[ch.geohash] ?? []
            arr.append(systemMessage)
            geoTimelines[ch.geohash] = arr
        }
        objectWillChange.send()
    }

    /// Add a system message only if viewing a geohash location channel (never post to mesh).
    @MainActor
    func addGeohashOnlySystemMessage(_ content: String) {
        if case .location = activeChannel {
            addPublicSystemMessage(content)
        } else {
            // Not on a location channel yet: queue to show when user switches
            pendingGeohashSystemMessages.append(content)
        }
    }
    // Send a public message without adding a local user echo.
    // Used for emotes where we want a local system-style confirmation instead.
    @MainActor
    func sendPublicRaw(_ content: String) {
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
                    let targetRelays = GeoRelayDirectory.shared.closestRelays(toGeohash: ch.geohash, count: 5)
                    if targetRelays.isEmpty {
                        NostrRelayManager.shared.sendEvent(event)
                    } else {
                        NostrRelayManager.shared.sendEvent(event, to: targetRelays)
                    }
                } catch {
                    SecureLogger.error("❌ Failed to send geohash raw message: \(error)", category: .session)
                }
            }
            return
        }
        // Default: send over mesh
        meshService.sendMessage(content, mentions: [])
    }
    
    // MARK: - Simplified Nostr Integration (Inlined from MessageRouter)
    
    //
    
    @MainActor
    private func setupNostrMessageHandling() {
        guard let currentIdentity = try? NostrIdentityBridge.getCurrentNostrIdentity() else { 
            SecureLogger.warning("⚠️ No Nostr identity available for message handling", category: .session)
            return 
        }
        
        SecureLogger.debug("🔑 Setting up Nostr subscription for pubkey: \(currentIdentity.publicKeyHex.prefix(16))...", category: .session)
        
        // Subscribe to Nostr messages
        let filter = NostrFilter.giftWrapsFor(
            pubkey: currentIdentity.publicKeyHex,
            since: Date().addingTimeInterval(-TransportConfig.nostrDMSubscribeLookbackSeconds)  // Last 24 hours
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
        
        processNostrMessage(giftWrap)
    }
    
    @MainActor
    private func processNostrMessage(_ giftWrap: NostrEvent) {
        guard let currentIdentity = try? NostrIdentityBridge.getCurrentNostrIdentity() else { return }
        
        do {
            let (content, senderPubkey, rumorTimestamp) = try NostrProtocol.decryptPrivateMessage(
                giftWrap: giftWrap,
                recipientIdentity: currentIdentity
            )
            
            // Expect embedded BitChat packet content
            guard content.hasPrefix("bitchat1:") else {
                SecureLogger.debug("Ignoring non-embedded Nostr DM content", category: .session)
                return
            }

            guard let packetData = Self.base64URLDecode(String(content.dropFirst("bitchat1:".count))),
                  let packet = BitchatPacket.from(packetData) else {
                SecureLogger.error("Failed to decode embedded BitChat packet from Nostr DM", category: .session)
                return
            }

            // Only process typed noiseEncrypted envelope for private messages/receipts
            guard packet.type == MessageType.noiseEncrypted.rawValue else {
                SecureLogger.warning("Unsupported embedded packet type: \(packet.type)", category: .session)
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
                SecureLogger.error("Failed to parse embedded NoisePayload", category: .session)
                return
            }

            // Map sender by Nostr pubkey to Noise key when possible
            let senderNoiseKey = findNoiseKey(for: senderPubkey)
            let actualSenderNoiseKey = senderNoiseKey // may be nil
            let messageTimestamp = Date(timeIntervalSince1970: TimeInterval(rumorTimestamp))
            let senderNickname = (actualSenderNoiseKey != nil) ? (FavoritesPersistenceService.shared.getFavoriteStatus(for: actualSenderNoiseKey!)?.peerNickname ?? "Unknown") : "Unknown"
            // Stable target ID if we know Noise key; otherwise temporary Nostr-based peer
            let targetPeerID = actualSenderNoiseKey?.hexEncodedString() ?? ("nostr_" + senderPubkey.prefix(TransportConfig.nostrConvKeyPrefixLength))

            switch noisePayload.type {
            case .privateMessage:
                handlePrivateMessage(
                    noisePayload,
                    actualSenderNoiseKey: actualSenderNoiseKey,
                    senderNickname: senderNickname,
                    targetPeerID: targetPeerID,
                    messageTimestamp: messageTimestamp,
                    senderPubkey: senderPubkey
                )

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
            case .verifyChallenge, .verifyResponse:
                // Ignore verification payloads arriving via Nostr path for now
                break
            }
            
        } catch {
            SecureLogger.error("Failed to decrypt Nostr message: \(error)", category: .session)
        }
    }
    
    @MainActor
    private func handlePrivateMessage(
        _ payload: NoisePayload,
        actualSenderNoiseKey: Data?,
        senderNickname: String,
        targetPeerID: String,
        messageTimestamp: Date,
        senderPubkey: String
    ) {
        guard let pm = PrivateMessagePacket.decode(from: payload.data) else { return }
        let messageId = pm.messageID
        let messageContent = pm.content

        // Favorite/unfavorite notifications embedded as private messages
        if messageContent.hasPrefix("[FAVORITED]") || messageContent.hasPrefix("[UNFAVORITED]") {
            if let key = actualSenderNoiseKey {
                handleFavoriteNotificationFromMesh(messageContent, from: key.hexEncodedString(), senderNickname: senderNickname)
            }
            return
        }

        if isDuplicateMessage(messageId, targetPeerID: targetPeerID) {
            return
        }

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
            isPrivate: true,
            recipientNickname: nickname,
            senderPeerID: targetPeerID,
            deliveryStatus: .delivered(to: nickname, at: Date())
        )
        
        addMessageToPrivateChatsIfNeeded(message, targetPeerID: targetPeerID)
        mirrorToEphemeralIfNeeded(message, targetPeerID: targetPeerID, key: actualSenderNoiseKey)

        sendDeliveryAckViaNostrEmbedded(
            message,
            wasReadBefore: wasReadBefore,
            senderPubkey: senderPubkey,
            key: actualSenderNoiseKey
        )

        if wasReadBefore {
            // do nothing
        } else if isViewingThisChat {
            handleViewingThisChat(
                message,
                targetPeerID: targetPeerID,
                key: actualSenderNoiseKey,
                senderPubkey: senderPubkey
            )
        } else {
            markAsUnreadIfNeeded(
                shouldMarkAsUnread: shouldMarkAsUnread,
                targetPeerID: targetPeerID,
                key: actualSenderNoiseKey,
                isRecentMessage: isRecentMessage,
                senderNickname: senderNickname,
                messageContent: messageContent
            )
        }

        objectWillChange.send()
    }
    
    private func isDuplicateMessage(_ messageId: String, targetPeerID: String) -> Bool {
        if privateChats[targetPeerID]?.contains(where: { $0.id == messageId }) == true {
            return true
        }
        for (_, messages) in privateChats where messages.contains(where: { $0.id == messageId }) {
            return true
        }
        return false
    }
    
    private func addMessageToPrivateChatsIfNeeded(_ message: BitchatMessage, targetPeerID: String) {
        if privateChats[targetPeerID] == nil {
            privateChats[targetPeerID] = []
        }
        if let idx = privateChats[targetPeerID]?.firstIndex(where: { $0.id == message.id }) {
            privateChats[targetPeerID]?[idx] = message
        } else {
            privateChats[targetPeerID]?.append(message)
        }
        // Sanitize to avoid duplicate IDs
        privateChatManager.sanitizeChat(for: targetPeerID)
        trimPrivateChatMessagesIfNeeded(for: targetPeerID)
    }
    
    @MainActor
    private func mirrorToEphemeralIfNeeded(_ message: BitchatMessage, targetPeerID: String, key: Data?) {
        guard let key,
              let ephemeralPeerID = unifiedPeerService.peers.first(where: { $0.noisePublicKey == key })?.id,
              ephemeralPeerID != targetPeerID
        else {
            return
        }
        
        if privateChats[ephemeralPeerID] == nil {
            privateChats[ephemeralPeerID] = []
        }
        if let idx = privateChats[ephemeralPeerID]?.firstIndex(where: { $0.id == message.id }) {
            privateChats[ephemeralPeerID]?[idx] = message
        } else {
            privateChats[ephemeralPeerID]?.append(message)
            trimPrivateChatMessagesIfNeeded(for: ephemeralPeerID)
        }
        privateChatManager.sanitizeChat(for: ephemeralPeerID)
    }
    
    @MainActor
    private func sendDeliveryAckViaNostrEmbedded(_ message: BitchatMessage, wasReadBefore: Bool, senderPubkey: String, key: Data?) {
        guard !wasReadBefore else { return }
        
        if let key {
            SecureLogger.debug("Sending DELIVERED ack for \(message.id.prefix(8))… via router", category: .session)
            messageRouter.sendDeliveryAck(message.id, to: key.hexEncodedString())
        } else if let id = try? NostrIdentityBridge.getCurrentNostrIdentity() {
            // Fallback: no Noise mapping yet — send directly to sender's Nostr pubkey
            let nt = NostrTransport(keychain: keychain)
            nt.senderPeerID = meshService.myPeerID
            nt.sendDeliveryAckGeohash(for: message.id, toRecipientHex: senderPubkey, from: id)
            SecureLogger.debug("Sent DELIVERED ack directly to Nostr pub=\(senderPubkey.prefix(8))… for mid=\(message.id.prefix(8))…", category: .session)
        }
    }
    
    @MainActor
    private func handleViewingThisChat(_ message: BitchatMessage, targetPeerID: String, key: Data?, senderPubkey: String) {
        unreadPrivateMessages.remove(targetPeerID)
        if let key,
           let ephemeralPeerID = unifiedPeerService.peers.first(where: { $0.noisePublicKey == key })?.id {
            unreadPrivateMessages.remove(ephemeralPeerID)
        }
        if !sentReadReceipts.contains(message.id) {
            if let key {
                let receipt = ReadReceipt(originalMessageID: message.id, readerID: meshService.myPeerID, readerNickname: nickname)
                SecureLogger.debug("Viewing chat; sending READ ack for \(message.id.prefix(8))… via router", category: .session)
                messageRouter.sendReadReceipt(receipt, to: key.hexEncodedString())
                sentReadReceipts.insert(message.id)
            } else if let id = try? NostrIdentityBridge.getCurrentNostrIdentity() {
                let nt = NostrTransport(keychain: keychain)
                nt.senderPeerID = meshService.myPeerID
                nt.sendReadReceiptGeohash(message.id, toRecipientHex: senderPubkey, from: id)
                sentReadReceipts.insert(message.id)
                SecureLogger.debug("Viewing chat; sent READ ack directly to Nostr pub=\(senderPubkey.prefix(8))… for mid=\(message.id.prefix(8))…", category: .session)
            }
        }
    }
    
    @MainActor
    private func markAsUnreadIfNeeded(
        shouldMarkAsUnread: Bool,
        targetPeerID: String,
        key: Data?,
        isRecentMessage: Bool,
        senderNickname: String,
        messageContent: String
    ) {
        guard shouldMarkAsUnread else { return }
        
        unreadPrivateMessages.insert(targetPeerID)
        if let key,
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
            SecureLogger.warning("⚠️ Invalid ACK format: \(content)", category: .session)
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
        
        SecureLogger.debug("📨 Received \(ackType) ACK for message \(messageId.prefix(16))... from \(senderPubkey.prefix(16))...", category: .session)
        
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
                    SecureLogger.warning("⚠️ Unknown ACK type: \(ackType)", category: .session)
                }
                
                messageFound = true
                SecureLogger.info("✅ Updated message \(messageId.prefix(16))... status to \(ackType) in chat \(chatPeerID.prefix(16))...", category: .session)
                // Don't break - continue to update in all chats where this message exists
            }
        }
        
        if messageFound {
            objectWillChange.send()
        } else {
            SecureLogger.warning("⚠️ Could not find message \(messageId) to update status from ACK", category: .session)
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
            SecureLogger.info("📝 Received Nostr npub in favorite notification: \(nostrPubkey ?? "none")", category: .session)
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
            SecureLogger.warning("⚠️ Cannot get Noise key for peer \(peerID)", category: .session)
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

        // If they favorited us and provided their Nostr key, ensure it's stored (log only)
        if isFavorite && nostrPubkey != nil {
            SecureLogger.info("💾 Storing Nostr key association for \(senderNickname): \(nostrPubkey!.prefix(16))...", category: .session)
        }

        // Only show a system message when the state changes, and only in mesh
        if prior != isFavorite {
            let action = isFavorite ? "favorited" : "unfavorited"
            addMeshOnlySystemMessage("\(senderNickname) \(action) you")
        }
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
        let tempPeerID = "nostr_" + senderPubkey.prefix(TransportConfig.nostrConvKeyPrefixLength)
        
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
        
        SecureLogger.info("📬 Stored Nostr message from unknown sender \(finalSenderNickname) in temporary peer \(tempPeerID)", category: .session)
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
                SecureLogger.warning("⚠️ Invalid hex public key format: \(nostrPubkey.prefix(16))...", category: .session)
                return nil 
            }
            
            do {
                npubToMatch = try Bech32.encode(hrp: "npub", data: pubkeyData)
            } catch {
                SecureLogger.warning("⚠️ Failed to convert hex to npub: \(error)", category: .session)
                return nil
            }
        }
        
        // Search through favorites for matching Nostr pubkey
        for (noiseKey, relationship) in FavoritesPersistenceService.shared.favorites {
            if let storedNostrKey = relationship.peerNostrPublicKey {
                // Compare npub format
                if storedNostrKey == npubToMatch {
                    // SecureLogger.debug("✅ Found Noise key for Nostr sender (npub match)", category: .session)
                    return noiseKey
                }
                
                // Also try hex comparison if stored value is hex
                if !storedNostrKey.hasPrefix("npub") && storedNostrKey == nostrPubkey {
                    SecureLogger.debug("✅ Found Noise key for Nostr sender (hex match)", category: .session)
                    return noiseKey
                }
            }
        }
        
        SecureLogger.debug("⚠️ No matching Noise key found for Nostr pubkey: \(nostrPubkey.prefix(16))... (tried npub: \(npubToMatch.prefix(16))...)", category: .session)
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
            SecureLogger.debug("📤 Sent favorite notification via BLE to \(peerID)", category: .session)
        } else if let key = noiseKey {
            // Send via Nostr for offline peers (using router)
            let recipientPeerID = key.hexEncodedString()
            messageRouter.sendFavoriteNotification(to: recipientPeerID, isFavorite: isFavorite)
        } else {
            SecureLogger.warning("⚠️ Cannot send favorite notification - peer not connected and no Nostr pubkey", category: .session)
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
                    if identityManager.isNostrBlocked(pubkeyHexLowercased: full) { return true }
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
                            SecureLogger.info("📦 Partially migrating \(recentMessages.count) of \(messages.count) messages from \(oldPeerID)", category: .session)
                        }
                        
                        SecureLogger.info("📦 Migrating \(recentMessages.count) recent messages from old peer ID \(oldPeerID) to \(peerID) (fingerprint match)", category: .session)
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
                            
                            SecureLogger.warning("📦 Migrating \(recentMessages.count) recent messages from old peer ID \(oldPeerID) to \(peerID) (nickname match)", category: .session)
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
                    SecureLogger.info("📱 Updated selectedPrivateChatPeer from old ID to \(peerID) during migration", category: .session)
                }
            }
        }
    }
    
    /// Handle incoming private message
    @MainActor
    private func handlePrivateMessage(_ message: BitchatMessage) {
        SecureLogger.debug("📥 handlePrivateMessage called for message from \(message.sender)", category: .session)
        let senderPeerID = message.senderPeerID ?? getPeerIDForNickname(message.sender)
        
        guard let peerID = senderPeerID else { 
            SecureLogger.warning("⚠️ Could not get peer ID for sender \(message.sender)", category: .session)
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
                    
                    SecureLogger.info("📥 Consolidated \(nostrMessages.count) Nostr messages from stable key to ephemeral peer \(peerID)", category: .session)
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
            DispatchQueue.main.asyncAfter(deadline: .now() + TransportConfig.uiReadReceiptRetryShortSeconds) { [weak self] in
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
        if !isGeo && finalMessage.sender != "system" {
            meshTimeline.append(finalMessage)
            trimMeshTimelineIfNeeded()
        }

        // Persist geochat messages to per-geohash timeline
        if isGeo && finalMessage.sender != "system" {
            if let gh = currentGeohash {
                var arr = geoTimelines[gh] ?? []
                // Dedup by message ID before appending to per-geohash timeline
                if !arr.contains(where: { $0.id == finalMessage.id }) {
                    arr.append(finalMessage)
                    if arr.count > geoTimelineCap { arr = Array(arr.suffix(geoTimelineCap)) }
                    geoTimelines[gh] = arr
                }
            }
        }

        // Only add message to current timeline if it matches active channel or is system
        let isSystem = finalMessage.sender == "system"
        let channelMatches: Bool = {
            switch activeChannel {
            case .mesh: return !isGeo || isSystem
            case .location: return isGeo || isSystem
            }
        }()

        guard channelMatches else { return }

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
                                                 selector: #selector(onPublicBufferTimerFired(_:)),
                                                 userInfo: nil,
                                                 repeats: false)
    }

    @MainActor
    private func flushPublicBuffer() {
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
        // Channel-aware insertion policy: geohash uses strict ordering; mesh allows small out-of-order appends
        let threshold: TimeInterval = {
            switch activeChannel {
            case .location: return TransportConfig.uiLateInsertThresholdGeo
            case .mesh: return TransportConfig.uiLateInsertThreshold
            }
        }()
        let lastTs = messages.last?.timestamp ?? .distantPast
        for m in added {
            if m.timestamp < lastTs.addingTimeInterval(-threshold) {
                let idx = insertionIndexByTimestamp(m.timestamp)
                if idx >= messages.count { messages.append(m) } else { messages.insert(m, at: idx) }
            } else if threshold == 0 {
                // Strict ordering for geohash: always insert by timestamp
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

    // Timer selector to avoid @Sendable closure capture issues under Swift 6
    @MainActor @objc
    private func onPublicBufferTimerFired(_ timer: Timer) {
        flushPublicBuffer()
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
        SecureLogger.info("🔔 Mention from \(message.sender)", category: .session)
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
// End of ChatViewModel class
