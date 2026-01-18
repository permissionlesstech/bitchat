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
import Combine
import CommonCrypto
import CoreBluetooth
import Tor
#if os(iOS)
import UIKit
#endif
import UniformTypeIdentifiers

/// Manages the application state and business logic for BitChat.
/// Acts as the primary coordinator between UI components and backend services,
/// implementing the BitchatDelegate protocol to handle network events.
final class ChatViewModel: ObservableObject, BitchatDelegate, CommandContextProvider, GeohashParticipantContext, MessageFormattingContext {
    // Use MessageFormattingEngine.Patterns for regex matching (shared, precompiled)
    typealias Patterns = MessageFormattingEngine.Patterns

    typealias GeoOutgoingContext = (channel: GeohashChannel, event: NostrEvent, identity: NostrIdentity, teleported: Bool)

    @MainActor
    var canSendMediaInCurrentContext: Bool {
        if let peer = selectedPrivateChatPeer {
            return !(peer.isGeoDM || peer.isGeoChat)
        }
        switch activeChannel {
        case .mesh: return true
        case .location: return false
        }
    }

    private var publicRateLimiter = MessageRateLimiter(
        senderCapacity: TransportConfig.uiSenderRateBucketCapacity,
        senderRefillPerSec: TransportConfig.uiSenderRateBucketRefillPerSec,
        contentCapacity: TransportConfig.uiContentRateBucketCapacity,
        contentRefillPerSec: TransportConfig.uiContentRateBucketRefillPerSec
    )

    @MainActor
    private func normalizedSenderKey(for message: BitchatMessage) -> String {
        if let spid = message.senderPeerID {
            if spid.isGeoChat || spid.isGeoDM {
                let full = (nostrKeyMapping[spid] ?? spid.bare).lowercased()
                return "nostr:" + full
            } else if spid.id.count == 16, let full = getNoiseKeyForShortID(spid)?.id.lowercased() {
                return "noise:" + full
            } else {
                return "mesh:" + spid.id.lowercased()
            }
        }
        return "name:" + message.sender.lowercased()
    }

    // MARK: - Published Properties
    
    @Published var messages: [BitchatMessage] = []
    @Published var currentColorScheme: ColorScheme = .light
    private let maxMessages = TransportConfig.meshTimelineCap // Maximum messages before oldest are removed
    @Published var isConnected = false
    private var recentlySeenPeers: Set<PeerID> = []
    private var lastNetworkNotificationTime = Date.distantPast
    private var networkResetTimer: Timer? = nil
    private var networkEmptyTimer: Timer? = nil
    private let networkResetGraceSeconds: TimeInterval = TransportConfig.networkResetGraceSeconds // avoid refiring on short drops/reconnects
    @Published var nickname: String = "" {
        didSet {
            // Trim whitespace whenever nickname is set
            let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != nickname {
                nickname = trimmed
            }
            // Update mesh service nickname if it's initialized
            if !meshService.myPeerID.isEmpty {
                meshService.setNickname(nickname)
            }
        }
    }
    
    // MARK: - Service Delegates

    let commandProcessor: CommandProcessor
    let messageRouter: MessageRouter
    let privateChatManager: PrivateChatManager
    let unifiedPeerService: UnifiedPeerService
    let autocompleteService: AutocompleteService
    let deduplicationService: MessageDeduplicationService  // internal for test access
    
    // Computed properties for compatibility
    @MainActor
    var connectedPeers: Set<PeerID> { unifiedPeerService.connectedPeerIDs }
    @Published var allPeers: [BitchatPeer] = []
    var privateChats: [PeerID: [BitchatMessage]] {
        get { privateChatManager.privateChats }
        set { privateChatManager.privateChats = newValue }
    }
    var selectedPrivateChatPeer: PeerID? {
        get { privateChatManager.selectedPeer }
        set { 
            if let peerID = newValue {
                privateChatManager.startChat(with: peerID)
            } else {
                privateChatManager.endChat()
            }
        }
    }
    var unreadPrivateMessages: Set<PeerID> {
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
    var peerIDToPublicKeyFingerprint: [PeerID: String] = [:]
    private var selectedPrivateChatFingerprint: String? = nil
    // Map stable short peer IDs (16-hex) to full Noise public key hex (64-hex) for session continuity
    private var shortIDToNoiseKey: [PeerID: PeerID] = [:]

    // Resolve full Noise key for a peer's short ID (used by UI header rendering)
    @MainActor
    private func getNoiseKeyForShortID(_ shortPeerID: PeerID) -> PeerID? {
        if let mapped = shortIDToNoiseKey[shortPeerID] { return mapped }
        // Fallback: derive from active Noise session if available
        if shortPeerID.id.count == 16,
           let key = meshService.getNoiseService().getPeerPublicKeyData(shortPeerID) {
            let stable = PeerID(hexData: key)
            shortIDToNoiseKey[shortPeerID] = stable
            return stable
        }
        return nil
    }

    // Resolve short mesh ID (16-hex) from a full Noise public key hex (64-hex)
    @MainActor
    func getShortIDForNoiseKey(_ fullNoiseKeyHex: PeerID) -> PeerID {
        guard fullNoiseKeyHex.id.count == 64 else { return fullNoiseKeyHex }
        // Check known peers for a noise key match
        if let match = allPeers.first(where: { PeerID(hexData: $0.noisePublicKey) == fullNoiseKeyHex }) {
            return match.peerID
        }
        // Also search cache mapping
        if let pair = shortIDToNoiseKey.first(where: { $0.value == fullNoiseKeyHex }) {
            return pair.key
        }
        return fullNoiseKeyHex
    }
    private var peerIndex: [PeerID: BitchatPeer] = [:]
    
    // MARK: - Autocomplete Properties
    
    @Published var autocompleteSuggestions: [String] = []
    @Published var showAutocomplete: Bool = false
    @Published var autocompleteRange: NSRange? = nil
    @Published var selectedAutocompleteIndex: Int = 0
    
    // Temporary property to fix compilation
    @Published var showPasswordPrompt = false
    
    // MARK: - Services and Storage
    
    let meshService: Transport
    let idBridge: NostrIdentityBridge
    let identityManager: SecureIdentityStateManagerProtocol
    
    var nostrRelayManager: NostrRelayManager?
    private let userDefaults = UserDefaults.standard
    let keychain: KeychainManagerProtocol
    private let nicknameKey = "bitchat.nickname"
    // Location channel state (macOS supports manual geohash selection)
    @Published var activeChannel: ChannelID = .mesh
    var geoSubscriptionID: String? = nil
    var geoDmSubscriptionID: String? = nil
    var currentGeohash: String? = nil
    var cachedGeohashIdentity: (geohash: String, identity: NostrIdentity)? = nil // Cache current geohash identity
    var geoNicknames: [String: String] = [:] // pubkeyHex(lowercased) -> nickname
    // Show Tor status once per app launch
    var torStatusAnnounced = false
    // Track whether a Tor restart is pending so we only announce
    // "tor restarted" after an actual restart, not the first launch.
    var torRestartPending: Bool = false
    // Ensure we set up DM subscription only once per app session
    var nostrHandlersSetup: Bool = false
    var geoChannelCoordinator: GeoChannelCoordinator?
    
    // MARK: - Caches
    
    // Caches for expensive computations
    private var encryptionStatusCache: [PeerID: EncryptionStatus] = [:]
    
    // MARK: - Social Features (Delegated to PeerStateManager)
    
    @MainActor
    var favoritePeers: Set<String> { unifiedPeerService.favoritePeers }
    @MainActor
    var blockedUsers: Set<String> { unifiedPeerService.blockedUsers }
    
    // MARK: - Encryption and Security
    
    // Noise Protocol encryption status
    @Published var peerEncryptionStatus: [PeerID: EncryptionStatus] = [:]
    @Published var verifiedFingerprints: Set<String> = []  // Set of verified fingerprints
    @Published var showingFingerprintFor: PeerID? = nil  // Currently showing fingerprint sheet for peer
    
    // Bluetooth state management
    @Published var showBluetoothAlert = false
    @Published var bluetoothAlertMessage = ""
    @Published var bluetoothState: CBManagerState = .unknown

    // Presentation state for privacy gating
    @Published var isLocationChannelsSheetPresented: Bool = false
    @Published var isAppInfoPresented: Bool = false
    @Published var showScreenshotPrivacyWarning: Bool = false
    
    var timelineStore = PublicTimelineStore(
        meshCap: TransportConfig.meshTimelineCap,
        geohashCap: TransportConfig.geoTimelineCap
    )
    // Channel activity tracking for background nudges
    var lastPublicActivityAt: [String: Date] = [:]   // channelKey -> last activity time
    // Geohash participant tracker
    let participantTracker = GeohashParticipantTracker(activityCutoff: -TransportConfig.uiRecentCutoffFiveMinutesSeconds)
    // Participants who indicated they teleported (by tag in their events)
    @Published var teleportedGeo: Set<String> = []  // lowercased pubkey hex
    // Sampling subscriptions for multiple geohashes (when channel sheet is open)
    var geoSamplingSubs: [String: String] = [:] // subID -> geohash
    var lastGeoNotificationAt: [String: Date] = [:] // geohash -> last notify time
    
    
    // MARK: - Message Delivery Tracking
    
    // Delivery tracking
    var cancellables = Set<AnyCancellable>()
    var transferIdToMessageIDs: [String: [String]] = [:]
    var messageIDToTransferId: [String: String] = [:]

    // MARK: - QR Verification (pending state)
    private struct PendingVerification {
        let noiseKeyHex: String
        let signKeyHex: String
        let nonceA: Data
        let startedAt: Date
        var sent: Bool
    }
    private var pendingQRVerifications: [PeerID: PendingVerification] = [:]
    // Last handled challenge nonce per peer to avoid duplicate responses
    private var lastVerifyNonceByPeer: [PeerID: Data] = [:]
    // Track when we last received a verify challenge from a peer (fingerprint-keyed)
    private var lastInboundVerifyChallengeAt: [String: Date] = [:] // key: fingerprint
    // Throttle mutual verification toasts per fingerprint
    private var lastMutualToastAt: [String: Date] = [:] // key: fingerprint

    // MARK: - Public message batching (UI perf)
    let publicMessagePipeline: PublicMessagePipeline
    @Published private(set) var isBatchingPublic: Bool = false
    
    // Track sent read receipts to avoid duplicates (persisted across launches)
    // Note: Persistence happens automatically in didSet, no lifecycle observers needed
    var sentReadReceipts: Set<String> = [] {  // messageID set
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
    var lastVerifyToastAt: [String: Date] = [:]

    // Track which GeoDM messages we've already sent a delivery ACK for (by messageID)
    var sentGeoDeliveryAcks: Set<String> = []
    
    // Track app startup phase to prevent marking old messages as unread
    private var isStartupPhase = true
    // Announce Tor initial readiness once per launch to avoid duplicates
    var torInitialReadyAnnounced: Bool = false
    
    // Track Nostr pubkey mappings for unknown senders
    var nostrKeyMapping: [PeerID: String] = [:]  // senderPeerID -> nostrPubkey
    
    // MARK: - Initialization

    @MainActor
    convenience init(
        keychain: KeychainManagerProtocol,
        idBridge: NostrIdentityBridge,
        identityManager: SecureIdentityStateManagerProtocol
    ) {
        self.init(
            keychain: keychain,
            idBridge: idBridge,
            identityManager: identityManager,
            transport: BLEService(keychain: keychain, idBridge: idBridge, identityManager: identityManager)
        )
    }

    /// Testable initializer that accepts a Transport dependency.
    /// Use this initializer for unit testing with MockTransport.
    @MainActor
    init(
        keychain: KeychainManagerProtocol,
        idBridge: NostrIdentityBridge,
        identityManager: SecureIdentityStateManagerProtocol,
        transport: Transport
    ) {
        self.keychain = keychain
        self.idBridge = idBridge
        self.identityManager = identityManager
        self.meshService = transport
        self.publicMessagePipeline = PublicMessagePipeline()
        
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
        self.unifiedPeerService = UnifiedPeerService(meshService: meshService, idBridge: idBridge, identityManager: identityManager)
        let nostrTransport = NostrTransport(keychain: keychain, idBridge: idBridge)
        nostrTransport.senderPeerID = meshService.myPeerID
        self.messageRouter = MessageRouter(transports: [meshService, nostrTransport])
        // Route receipts from PrivateChatManager through MessageRouter
        self.privateChatManager.messageRouter = self.messageRouter
        // Allow PrivateChatManager to look up peer info for message consolidation
        self.privateChatManager.unifiedPeerService = self.unifiedPeerService
        // Allow UnifiedPeerService to route favorite notifications via mesh/Nostr
        self.unifiedPeerService.messageRouter = self.messageRouter
        self.autocompleteService = AutocompleteService()
        self.deduplicationService = MessageDeduplicationService()

        // Wire up dependencies
        self.commandProcessor.contextProvider = self
        self.participantTracker.configure(context: self)
        
        // Subscribe to privateChatManager changes to trigger UI updates
        privateChatManager.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        // Subscribe to participantTracker changes to trigger UI updates
        participantTracker.objectWillChange
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

        publicMessagePipeline.delegate = self
        publicMessagePipeline.updateActiveChannel(activeChannel)

        // Check initial Bluetooth state after a brief delay to allow centralManager initialization
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            if let bleService = self.meshService as? BLEService {
                let state = bleService.getCurrentBluetoothState()
                self.updateBluetoothState(state)
            }
        }

        // Announce Tor status (geohash-only; do not show in mesh chat). Only when auto-start is allowed.
        if TorManager.shared.torEnforced && !torStatusAnnounced && TorManager.shared.isAutoStartAllowed() {
            torStatusAnnounced = true
            addGeohashOnlySystemMessage(
                String(localized: "system.tor.starting", comment: "System message when Tor is starting")
            )
        } else if !TorManager.shared.torEnforced && !torStatusAnnounced {
            torStatusAnnounced = true
            addGeohashOnlySystemMessage(
                String(localized: "system.tor.dev_bypass", comment: "System message when Tor bypass is enabled in development")
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
                var uniquePeers: [PeerID: BitchatPeer] = [:]
                for peer in peers {
                    // Keep the first occurrence of each peer ID
                    if uniquePeers[peer.peerID] == nil {
                        uniquePeers[peer.peerID] = peer
                    } else {
                        SecureLogger.warning("⚠️ Duplicate peer ID detected: \(peer.peerID) (\(peer.displayName))", category: .session)
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
                            self.geoChannelCoordinator?.refreshSampling()
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

        geoChannelCoordinator = GeoChannelCoordinator(
            onChannelSwitch: { [weak self] channel in
                self?.switchLocationChannel(to: channel)
            },
            beginSampling: { [weak self] geohashes in
                self?.beginGeohashSampling(for: geohashes)
            },
            endSampling: { [weak self] in
                self?.endGeohashSampling()
            }
        )

        // Track teleport flag changes to keep our own teleported marker in sync with regional status
        LocationChannelManager.shared.$teleported
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isTeleported in
                guard let self = self else { return }
                Task { @MainActor in
                    guard case .location(let ch) = self.activeChannel,
                          let id = try? idBridge.deriveIdentity(forGeohash: ch.geohash) else { return }
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
        
        // Request notification permission (guards test environment internally)
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
            selector: #selector(applicationWillTerminate),
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
            selector: #selector(applicationWillTerminate),
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
    func hasUnreadMessages(for peerID: PeerID) -> Bool {
        // First check direct unread messages
        if unreadPrivateMessages.contains(peerID) {
            return true
        }
        
        // Check if messages are stored under the stable Noise key hex
        if let peer = unifiedPeerService.getPeer(by: peerID) {
            let noiseKeyHex = PeerID(hexData: peer.noisePublicKey)
            if unreadPrivateMessages.contains(noiseKeyHex) {
                return true
            }
            // Also check for geohash (Nostr) DM conv key if this peer has a known Nostr pubkey
            if let nostrHex = peer.nostrPublicKey {
                let convKey = PeerID(nostr_: nostrHex)
                if unreadPrivateMessages.contains(convKey) {
                    return true
                }
            }
        }
        
        // Get the peer's nickname to check for temporary Nostr peer IDs
        let peerNickname = meshService.peerNickname(peerID: peerID)?.lowercased() ?? ""

        // Check if any temporary Nostr peer IDs have unread messages from this nickname
        for unreadPeerID in unreadPrivateMessages {
            if unreadPeerID.isGeoDM {
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
    func toggleFavorite(peerID: PeerID) {
        // Distinguish between ephemeral peer IDs (16 hex chars) and Noise public keys (64 hex chars)
        // Ephemeral peer IDs are 8 bytes = 16 hex characters
        // Noise public keys are 32 bytes = 64 hex characters
        
        if let noisePublicKey = peerID.noiseKey {
            // This is a stable Noise key hex (used in private chats)
            // Find the ephemeral peer ID for this Noise key
            let ephemeralPeerID = unifiedPeerService.peers.first { peer in
                peer.noisePublicKey == noisePublicKey
            }?.peerID
            
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
                    let nostrKey = currentStatus?.peerNostrPublicKey ?? idBridge.getNostrPublicKey(for: noisePublicKey)
                    
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
    func isFavorite(peerID: PeerID) -> Bool {
        // Distinguish between ephemeral peer IDs (16 hex chars) and Noise public keys (64 hex chars)
        if let noisePublicKey = peerID.noiseKey {
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
    func isPeerBlocked(_ peerID: PeerID) -> Bool {
        return unifiedPeerService.isBlocked(peerID)
    }
    
    // Helper method to find current peer ID for a fingerprint
    @MainActor
    private func getCurrentPeerIDForFingerprint(_ fingerprint: String) -> PeerID? {
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
                sendPrivateMessage(content, to: selectedPeer)
            }
            return
        }

        // Parse mentions from the content (use original content for user intent)
        let mentions = parseMentions(from: content)

        var geoContext: GeoOutgoingContext? = nil

        // Add message to local display
        var displaySender = nickname
        var localSenderPeerID = meshService.myPeerID
        var messageID: String? = nil
        var messageTimestamp = Date()

        switch activeChannel {
        case .mesh:
            break
        case .location(let ch):
            do {
                let identity = try idBridge.deriveIdentity(forGeohash: ch.geohash)
                let suffix = String(identity.publicKeyHex.suffix(4))
                displaySender = nickname + "#" + suffix
                localSenderPeerID = PeerID(nostr: identity.publicKeyHex)
                let teleported = LocationChannelManager.shared.teleported
                let event = try NostrProtocol.createEphemeralGeohashEvent(
                    content: trimmed,
                    geohash: ch.geohash,
                    senderIdentity: identity,
                    nickname: nickname,
                    teleported: teleported
                )
                messageID = event.id
                messageTimestamp = Date(timeIntervalSince1970: TimeInterval(event.created_at))
                geoContext = (channel: ch, event: event, identity: identity, teleported: teleported)
            } catch {
                SecureLogger.error("❌ Failed to prepare geohash message: \(error)", category: .session)
                addSystemMessage(
                    String(localized: "system.location.send_failed", comment: "System message when a location channel send fails")
                )
                return
            }
        }

        let message = BitchatMessage(
            id: messageID,
            sender: displaySender,
            content: trimmed,
            timestamp: messageTimestamp,
            isRelay: false,
            senderPeerID: localSenderPeerID,
            mentions: mentions.isEmpty ? nil : mentions
        )

        timelineStore.append(message, to: activeChannel)
        refreshVisibleMessages(from: activeChannel)

        // Update content LRU for near-dup detection
        let ckey = deduplicationService.normalizedContentKey(message.content)
        deduplicationService.recordContentKey(ckey, timestamp: message.timestamp)

        trimMessagesIfNeeded()

        // UI updates automatically via @Published var messages

        updateChannelActivityTimeThenSend(content: content,
                                          trimmed: trimmed,
                                          mentions: mentions,
                                          geoContext: geoContext,
                                          messageID: message.id,
                                          timestamp: message.timestamp)
    }

    private func updateChannelActivityTimeThenSend(content: String,
                                                   trimmed: String,
                                                   mentions: [String],
                                                   geoContext: GeoOutgoingContext?,
                                                   messageID: String,
                                                   timestamp: Date) {
        switch activeChannel {
        case .mesh:
            lastPublicActivityAt["mesh"] = Date()
            // Send via mesh with mentions
            meshService.sendMessage(content, mentions: mentions, messageID: messageID, timestamp: timestamp)
        case .location(let ch):
            lastPublicActivityAt["geo:\(ch.geohash)"] = Date()
            guard let context = geoContext, context.channel.geohash == ch.geohash else {
                SecureLogger.error("Geo: missing send context for \(ch.geohash)", category: .session)
                addSystemMessage(
                    String(localized: "system.location.send_failed", comment: "System message when a location channel send fails")
                )
                return
            }
            // Send to geohash channel via Nostr ephemeral
            Task { @MainActor in
                self.sendGeohash(context: context)
            }
        }
    }
    

    

    

    


    // MARK: - Geohash Participants

    @MainActor
    func isSelfSender(peerID: PeerID?, displayName: String?) -> Bool {
        guard let peerID else { return false }
        if peerID == meshService.myPeerID { return true }
        guard peerID.isGeoDM || peerID.isGeoChat else { return false }

        if let mapped = nostrKeyMapping[peerID]?.lowercased(),
           let gh = currentGeohash,
           let myIdentity = try? idBridge.deriveIdentity(forGeohash: gh) {
            if mapped == myIdentity.publicKeyHex.lowercased() { return true }
        }

        if let gh = currentGeohash,
           let myIdentity = try? idBridge.deriveIdentity(forGeohash: gh) {
            if peerID == PeerID(nostr: myIdentity.publicKeyHex) { return true }
            let suffix = myIdentity.publicKeyHex.suffix(4)
            let expected = (nickname + "#" + suffix).lowercased()
            if let display = displayName?.lowercased(), display == expected { return true }
        }

        return false
    }

    // MARK: - Public helpers

    /// Published geohash people list for SwiftUI observation
    var geohashPeople: [GeoPerson] {
        participantTracker.visiblePeople
    }

    /// Return the current, pruned, sorted people list for the active geohash without mutating state.
    @MainActor
    func visibleGeohashPeople() -> [GeoPerson] {
        participantTracker.getVisiblePeople()
    }

    /// CommandContextProvider conformance - returns visible geo participants
    func getVisibleGeoParticipants() -> [CommandGeoParticipant] {
        visibleGeohashPeople().map { CommandGeoParticipant(id: $0.id, displayName: $0.displayName) }
    }
    /// Returns the current participant count for a specific geohash, using the 5-minute activity window.
    @MainActor
    func geohashParticipantCount(for geohash: String) -> Int {
        participantTracker.participantCount(for: geohash)
    }

    // MARK: - GeohashParticipantContext Protocol

    func displayNameForPubkey(_ pubkeyHex: String) -> String {
        displayNameForNostrPubkey(pubkeyHex)
    }

    func isBlocked(_ pubkeyHexLowercased: String) -> Bool {
        identityManager.isNostrBlocked(pubkeyHexLowercased: pubkeyHexLowercased)
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
        participantTracker.removeParticipant(pubkeyHex: hex)
        
        // Remove their public messages from current geohash timeline and visible list
        if let gh = currentGeohash {
            let predicate: (BitchatMessage) -> Bool = { [self] msg in
                guard let spid = msg.senderPeerID, spid.isGeoDM || spid.isGeoChat else { return false }
                if let full = self.nostrKeyMapping[spid]?.lowercased() { return full == hex }
                return false
            }
            timelineStore.removeMessages(in: gh, where: predicate)
            if case .location = activeChannel {
                messages.removeAll(where: predicate)
            }
        }
        
        // Remove geohash DM conversation if exists
        let convKey = PeerID(nostr_: hex)
        if privateChats[convKey] != nil {
            privateChats.removeValue(forKey: convKey)
            unreadPrivateMessages.remove(convKey)
        }
        
        // Remove mapping keys pointing to this pubkey to avoid accidental resolution
        for (key, value) in self.nostrKeyMapping where value.lowercased() == hex {
            self.nostrKeyMapping.removeValue(forKey: key)
        }
        
        addSystemMessage(
            String(
                format: String(localized: "system.geohash.blocked", comment: "System message shown when a user is blocked in geohash chats"),
                locale: .current,
                displayName
            )
        )
    }
    @MainActor
    func unblockGeohashUser(pubkeyHexLowercased: String, displayName: String) {
        identityManager.setNostrBlocked(pubkeyHexLowercased, isBlocked: false)
        addSystemMessage(
            String(
                format: String(localized: "system.geohash.unblocked", comment: "System message shown when a user is unblocked in geohash chats"),
                locale: .current,
                displayName
            )
        )
    }



    func displayNameForNostrPubkey(_ pubkeyHex: String) -> String {
        let suffix = String(pubkeyHex.suffix(4))
        // If this is our per-geohash identity, use our nickname
        if let gh = currentGeohash, let myGeoIdentity = try? idBridge.deriveIdentity(forGeohash: gh) {
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



    // MARK: - Media Transfers

    private enum MediaSendError: Error {
        case encodingFailed
        case tooLarge
        case copyFailed
    }








    func currentPublicSender() -> (name: String, peerID: PeerID) {
        var displaySender = nickname
        var senderPeerID = meshService.myPeerID
        if case .location(let ch) = activeChannel,
           let identity = try? idBridge.deriveIdentity(forGeohash: ch.geohash) {
            let suffix = String(identity.publicKeyHex.suffix(4))
            displaySender = nickname + "#" + suffix
            senderPeerID = PeerID(nostr: identity.publicKeyHex)
        }
        return (displaySender, senderPeerID)
    }

    @MainActor
    func nicknameForPeer(_ peerID: PeerID) -> String {
        if let name = meshService.peerNickname(peerID: peerID) {
            return name
        }
        if let favorite = FavoritesPersistenceService.shared.getFavoriteStatus(forPeerID: peerID),
           !favorite.peerNickname.isEmpty {
            return favorite.peerNickname
        }
        if let noiseKey = Data(hexString: peerID.id),
           let favorite = FavoritesPersistenceService.shared.getFavoriteStatus(for: noiseKey),
           !favorite.peerNickname.isEmpty {
            return favorite.peerNickname
        }
        return "user"
    }



    @MainActor
    func removeMessage(withID messageID: String, cleanupFile: Bool = false) {
        var removedMessage: BitchatMessage?

        if let idx = messages.firstIndex(where: { $0.id == messageID }) {
            removedMessage = messages.remove(at: idx)
        }

        if let storeRemoved = timelineStore.removeMessage(withID: messageID) {
            removedMessage = removedMessage ?? storeRemoved
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


    /// Add a local system message to a private chat (no network send)
    @MainActor
    func addLocalPrivateSystemMessage(_ content: String, to peerID: PeerID) {
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
    @MainActor
    func updateBluetoothState(_ state: CBManagerState) {
        bluetoothState = state
        
        switch state {
        case .poweredOff:
            bluetoothAlertMessage = String(localized: "content.alert.bluetooth_required.off", comment: "Message shown when Bluetooth is turned off")
            showBluetoothAlert = true
        case .unauthorized:
            bluetoothAlertMessage = String(localized: "content.alert.bluetooth_required.permission", comment: "Message shown when Bluetooth permission is missing")
            showBluetoothAlert = true
        case .unsupported:
            bluetoothAlertMessage = String(localized: "content.alert.bluetooth_required.unsupported", comment: "Message shown when the device lacks Bluetooth support")
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
    func startPrivateChat(with peerID: PeerID) {
        // Safety check: Don't allow starting chat with ourselves
        if peerID == meshService.myPeerID {
            return
        }

        let peerNickname = meshService.peerNickname(peerID: peerID) ?? "unknown"

        // Check if the peer is blocked
        if unifiedPeerService.isBlocked(peerID) {
            addSystemMessage(
                String(
                    format: String(localized: "system.chat.blocked", comment: "System message when starting chat fails because peer is blocked"),
                    locale: .current,
                    peerNickname
                )
            )
            return
        }

        // Check mutual favorites for offline messaging
        if let peer = unifiedPeerService.getPeer(by: peerID),
           peer.isFavorite && !peer.theyFavoritedUs && !peer.isConnected {
            addSystemMessage(
                String(
                    format: String(localized: "system.chat.requires_favorite", comment: "System message when mutual favorite requirement blocks chat"),
                    locale: .current,
                    peerNickname
                )
            )
            return
        }

        // Consolidate messages from different peer ID representations (stable Noise key, temp Nostr IDs)
        // Pass persisted sentReadReceipts to correctly identify already-read messages after app restart
        _ = privateChatManager.consolidateMessages(for: peerID, peerNickname: peerNickname, persistedReadReceipts: sentReadReceipts)

        // Trigger handshake if needed (mesh peers only). Skip for Nostr geohash conv keys.
        if !peerID.isGeoDM && !peerID.isGeoChat {
            let sessionState = meshService.getNoiseSessionState(for: peerID)
            switch sessionState {
            case .none, .failed:
                meshService.triggerHandshake(with: peerID)
            case .handshakeQueued, .handshaking, .established:
                break
            }
        } else {
            SecureLogger.debug("GeoDM: skipping mesh handshake for virtual peerID=\(peerID)", category: .session)
        }

        // Sync read receipt tracking to prevent duplicates
        privateChatManager.syncReadReceiptsForSentMessages(peerID: peerID, nickname: nickname, externalReceipts: &sentReadReceipts)

        privateChatManager.startChat(with: peerID)

        // Also mark messages as read for Nostr ACKs
        // This ensures read receipts are sent even for consolidated messages
        markPrivateMessagesAsRead(from: peerID)
    }
    
    func endPrivateChat() {
        selectedPrivateChatPeer = nil
        selectedPrivateChatFingerprint = nil
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
                let oldPeerID = PeerID(hexData: oldKey)
                let newPeerID = PeerID(hexData: peerPublicKey)
                
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
                let peerID = PeerID(hexData: peerPublicKey)
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
        // Check Bluetooth state and show alert if needed
        if let bleService = meshService as? BLEService {
            let currentState = bleService.getCurrentBluetoothState()
            updateBluetoothState(currentState)
        }

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
                case  .none, .failed, .handshakeQueued, .handshaking:
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
            
        } else {
            // In public chat - send to active public channel
            switch activeChannel {
            case .mesh:
                meshService.sendMessage(screenshotMessage,
                                        mentions: [],
                                        messageID: UUID().uuidString,
                                        timestamp: Date())
            case .location(let ch):
                Task { @MainActor in
                    do {
                        let identity = try idBridge.deriveIdentity(forGeohash: ch.geohash)
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
                        self.participantTracker.recordParticipant(pubkeyHex: identity.publicKeyHex)
                    } catch {
                        SecureLogger.error("❌ Failed to send geohash screenshot message: \(error)", category: .session)
                        self.addSystemMessage(
                            String(localized: "system.location.send_failed", comment: "System message when a location channel send fails")
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
    
    /// Save identity state without stopping services (for backgrounding)
    func saveIdentityState() {
        // Force save any pending identity changes (verifications, favorites, etc)
        identityManager.forceSave()

        // Verify identity key is still there
        _ = keychain.verifyIdentityKeyExists()
    }

    @objc func applicationWillTerminate() {
        // Send leave message to all peers
        meshService.stopServices()

        // Save identity state
        saveIdentityState()
    }
    
    @MainActor
    private func sendReadReceipt(_ receipt: ReadReceipt, to peerID: PeerID, originalTransport: String? = nil) {
        // First, try to resolve the current peer ID in case they reconnected with a new ID
        var actualPeerID = peerID
        
        // Check if this peer ID exists in current nicknames
        if meshService.peerNickname(peerID: peerID) == nil {
            // Peer not found with this ID, try to find by fingerprint or nickname
            if let oldNoiseKey = Data(hexString: peerID.id),
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
    func markPrivateMessagesAsRead(from peerID: PeerID) {
        privateChatManager.markAsRead(from: peerID)
        
        // Handle GeoDM (nostr_*) read receipts directly via per-geohash identity
        if peerID.isGeoDM,
           let recipientHex = nostrKeyMapping[peerID],
           case .location(let ch) = LocationChannelManager.shared.selectedChannel,
           let id = try? idBridge.deriveIdentity(forGeohash: ch.geohash) {
            let messages = privateChats[peerID] ?? []
            for message in messages where message.senderPeerID == peerID && !message.isRelay {
                if !sentReadReceipts.contains(message.id) {
                    SecureLogger.debug("GeoDM: sending READ for mid=\(message.id.prefix(8))… to=\(recipientHex.prefix(8))…", category: .session)
                    let nostrTransport = NostrTransport(keychain: keychain, idBridge: idBridge)
                    nostrTransport.senderPeerID = meshService.myPeerID
                    nostrTransport.sendReadReceiptGeohash(message.id, toRecipientHex: recipientHex, from: id)
                    sentReadReceipts.insert(message.id)
                }
            }
            return
        }

        // Get the peer's Noise key to check for Nostr messages
        var noiseKeyHex: PeerID? = nil
        var peerNostrPubkey: String? = nil
        
        // First check if peerID is already a hex Noise key
        if let noiseKey = Data(hexString: peerID.id),
           let favoriteStatus = FavoritesPersistenceService.shared.getFavoriteStatus(for: noiseKey) {
            noiseKeyHex = peerID
            peerNostrPubkey = favoriteStatus.peerNostrPublicKey
        }
        // Otherwise get the Noise key from the peer info
        else if let peer = unifiedPeerService.getPeer(by: peerID) {
            noiseKeyHex = PeerID(hexData: peer.noisePublicKey)
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
                        let recipPeer = peerID.isHex ? peerID : (unifiedPeerService.getPeer(by: peerID)?.peerID ?? peerID)
                        let receipt = ReadReceipt(originalMessageID: message.id, readerID: meshService.myPeerID, readerNickname: nickname)
                        messageRouter.sendReadReceipt(receipt, to: recipPeer)
                        sentReadReceipts.insert(message.id)
                    }
                }
            }
        }
    }
    
    @MainActor
    func getPrivateChatMessages(for peerID: PeerID) -> [BitchatMessage] {
        var combined: [BitchatMessage] = []

        // Gather messages under the ephemeral peer ID
        if let ephemeralMessages = privateChats[peerID] {
            combined.append(contentsOf: ephemeralMessages)
        }

        // Also include messages stored under the stable Noise key (Nostr path)
        if let peer = unifiedPeerService.getPeer(by: peerID) {
            let noiseKeyHex = PeerID(hexData: peer.noisePublicKey)
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
    func getPeerIDForNickname(_ nickname: String) -> PeerID? {
        // When in a geohash channel, allow resolving by geohash participant nickname
        switch LocationChannelManager.shared.selectedChannel {
        case .location:
            // If a disambiguation suffix is present (e.g., "name#abcd"), try exact displayName match first
            if nickname.contains("#") {
                if let person = visibleGeohashPeople().first(where: { $0.displayName == nickname }) {
                    let convKey = PeerID(nostr_: person.id)
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
                let convKey = PeerID(nostr_: pub)
                nostrKeyMapping[convKey] = pub
                return convKey
            }
        case .mesh:
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
        deduplicationService.clearAll()

        // Clear all caches
        invalidateEncryptionCache()
        
        // IMPORTANT: Clear Nostr-related state
        // Disconnect from Nostr relays and clear subscriptions
        nostrRelayManager?.disconnect()
        nostrRelayManager = nil
        
        // Clear Nostr identity associations
        idBridge.clearAllAssociations()
        
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
        
        // Delete ALL media files (incoming and outgoing) in background
        Task.detached(priority: .utility) {
            do {
                let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                let filesDir = base.appendingPathComponent("files", isDirectory: true)

                // Delete the entire files directory and recreate it
                if FileManager.default.fileExists(atPath: filesDir.path) {
                    try FileManager.default.removeItem(at: filesDir)
                    SecureLogger.info("🗑️ Deleted all media files during panic clear", category: .session)
                }

                // Recreate empty directory structure
                try FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true, attributes: nil)
                try FileManager.default.createDirectory(at: filesDir.appendingPathComponent("voicenotes/incoming", isDirectory: true), withIntermediateDirectories: true, attributes: nil)
                try FileManager.default.createDirectory(at: filesDir.appendingPathComponent("voicenotes/outgoing", isDirectory: true), withIntermediateDirectories: true, attributes: nil)
                try FileManager.default.createDirectory(at: filesDir.appendingPathComponent("images/incoming", isDirectory: true), withIntermediateDirectories: true, attributes: nil)
                try FileManager.default.createDirectory(at: filesDir.appendingPathComponent("images/outgoing", isDirectory: true), withIntermediateDirectories: true, attributes: nil)
                try FileManager.default.createDirectory(at: filesDir.appendingPathComponent("files/incoming", isDirectory: true), withIntermediateDirectories: true, attributes: nil)
                try FileManager.default.createDirectory(at: filesDir.appendingPathComponent("files/outgoing", isDirectory: true), withIntermediateDirectories: true, attributes: nil)
            } catch {
                SecureLogger.error("Failed to clear media files during panic: \(error)", category: .session)
            }

            // BCH-01-013: Clear iOS app switcher snapshots
            // These are stored in Library/Caches/Snapshots/<bundle_id>/
            #if os(iOS)
            Self.clearAppSwitcherSnapshots()
            #endif
        }

        // Force immediate UI update for panic mode
        // UI updates immediately - no flushing needed

    }

    /// BCH-01-013: Clear iOS app switcher snapshots during panic mode
    /// iOS stores preview screenshots in Library/Caches/Snapshots/<bundle_id>/
    /// These could reveal sensitive information visible in the app at the time
    #if os(iOS)
    private nonisolated static func clearAppSwitcherSnapshots() {
        do {
            let cacheDir = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            let snapshotsDir = cacheDir.appendingPathComponent("Snapshots", isDirectory: true)

            // Clear all snapshots (iOS stores them in subdirectories by bundle ID and scene)
            if FileManager.default.fileExists(atPath: snapshotsDir.path) {
                let contents = try FileManager.default.contentsOfDirectory(at: snapshotsDir, includingPropertiesForKeys: nil)
                for item in contents {
                    try FileManager.default.removeItem(at: item)
                }
                SecureLogger.info("🗑️ Cleared app switcher snapshots during panic clear", category: .session)
            }
        } catch {
            SecureLogger.error("Failed to clear app switcher snapshots: \(error)", category: .session)
        }
    }
    #endif

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
                if let id = try? idBridge.deriveIdentity(forGeohash: ch.geohash) {
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
                if case .location(let ch) = activeChannel, spid.isGeoChat {
                    let myGeo: NostrIdentity? = {
                        if let cached = cachedGeohashIdentity, cached.geohash == ch.geohash {
                            return cached.identity
                        }
                        // Fallback: derive and cache (should rarely happen)
                        if let identity = try? idBridge.deriveIdentity(forGeohash: ch.geohash) {
                            cachedGeohashIdentity = (ch.geohash, identity)
                            return identity
                        }
                        return nil
                    }()
                    if let myGeo {
                        return spid == PeerID(nostr: myGeo.publicKeyHex)
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
            if let spid = message.senderPeerID, let url = URL(string: "bitchat://user/\(spid.toPercentEncoded())") {
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
                let rx = Patterns.quickCashuPresence
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
            // Reuse compiled regexes and detector from MessageFormattingEngine
            let hashtagRegex = Patterns.hashtag
            let mentionRegex = Patterns.mention
            let cashuRegex = Patterns.cashu
            let bolt11Regex = Patterns.bolt11
            let lnurlRegex = Patterns.lnurl
            let lightningSchemeRegex = Patterns.lightningScheme
            let detector = Patterns.linkDetector
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
                            if case .location(let ch) = activeChannel, let id = try? idBridge.deriveIdentity(forGeohash: ch.geohash) {
                                return String(id.publicKeyHex.suffix(4))
                            }
                            return String(meshService.myPeerID.id.prefix(4))
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
                        // Emit '@' (non-localizable symbol - use interpolation to avoid extraction)
                        let at = "@"
                        result.append(AttributedString("\(at)").mergingAttributes(mentionStyle))
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
                if case .location(let ch) = activeChannel, spid.id.hasPrefix("nostr:") {
                    if let myGeo = try? idBridge.deriveIdentity(forGeohash: ch.geohash) {
                        return spid == PeerID(nostr: myGeo.publicKeyHex)
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
           let url = URL(string: "bitchat://user/\(spid.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? spid.id)") {
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

    // MARK: - Noise Protocol Support
    
    @MainActor
    func updateEncryptionStatusForPeers() {
        for peerID in connectedPeers {
            updateEncryptionStatusForPeer(peerID)
        }
    }
    
    @MainActor
    private func updateEncryptionStatusForPeer(_ peerID: PeerID) {
        let noiseService = meshService.getNoiseService()
        
        if noiseService.hasEstablishedSession(with: peerID) {
            peerEncryptionStatus[peerID] = encryptionStatus(for: peerID)
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
    func getEncryptionStatus(for peerID: PeerID) -> EncryptionStatus {
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
            status = encryptionStatus(for: peerID)
        case .handshaking, .handshakeQueued:
            // If we've ever established a session, show secured instead of handshaking
            if hasEverEstablishedSession {
                // Check if it was verified before
                status = encryptionStatus(for: peerID)
            } else {
                // First time establishing - show handshaking
                status = .noiseHandshaking
            }
        case .none:
            // If we've ever established a session, show secured instead of no handshake
            if hasEverEstablishedSession {
                // Check if it was verified before
                status = encryptionStatus(for: peerID)
            } else {
                // Never established - show no handshake
                status = .noHandshake
            }
        case .failed:
            // If we've ever established a session, show secured instead of failed
            if hasEverEstablishedSession {
                // Check if it was verified before
                status = encryptionStatus(for: peerID)
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
    private func invalidateEncryptionCache(for peerID: PeerID? = nil) {
        if let peerID {
            encryptionStatusCache.removeValue(forKey: peerID)
        } else {
            encryptionStatusCache.removeAll()
        }
    }
    
    
    // MARK: - Message Handling
    
    func trimMessagesIfNeeded() {
        if messages.count > maxMessages {
            messages = Array(messages.suffix(maxMessages))
        }
    }

    @MainActor
    func refreshVisibleMessages(from channel: ChannelID? = nil) {
        let target = channel ?? activeChannel
        messages = timelineStore.messages(for: target)
    }

    @MainActor
    private func peerColor(for message: BitchatMessage, isDark: Bool) -> Color {
        if let spid = message.senderPeerID {
            if spid.isGeoChat || spid.isGeoDM {
                let full = nostrKeyMapping[spid]?.lowercased() ?? spid.bare.lowercased()
                return getNostrPaletteColor(for: full, isDark: isDark)
            } else if spid.id.count == 16 {
                // Mesh short ID
                return getPeerPaletteColor(for: spid, isDark: isDark)
            } else {
                return getPeerPaletteColor(for: PeerID(str: spid.id.lowercased()), isDark: isDark)
            }
        }
        // Fallback when we only have a display name
        return Color(peerSeed: message.sender.lowercased(), isDark: isDark)
    }

    // MARK: - MessageFormattingContext Protocol

    @MainActor
    func isSelfMessage(_ message: BitchatMessage) -> Bool {
        if let spid = message.senderPeerID {
            // In geohash channels, compare against our per-geohash nostr short ID
            if case .location(let ch) = activeChannel, spid.isGeoChat {
                let myGeo: NostrIdentity? = {
                    if let cached = cachedGeohashIdentity, cached.geohash == ch.geohash {
                        return cached.identity
                    }
                    // Derive and cache
                    if let identity = try? idBridge.deriveIdentity(forGeohash: ch.geohash) {
                        cachedGeohashIdentity = (ch.geohash, identity)
                        return identity
                    }
                    return nil
                }()
                if let myGeo {
                    return spid == PeerID(nostr: myGeo.publicKeyHex)
                }
            }
            return spid == meshService.myPeerID
        }
        // Fallback by nickname
        if message.sender == nickname { return true }
        if message.sender.hasPrefix(nickname + "#") { return true }
        return false
    }

    @MainActor
    func senderColor(for message: BitchatMessage, isDark: Bool) -> Color {
        return peerColor(for: message, isDark: isDark)
    }

    @MainActor
    func peerURL(for peerID: PeerID) -> URL? {
        return URL(string: "bitchat://user/\(peerID.toPercentEncoded())")
    }

    // Public helpers for views to color peers consistently in lists
    @MainActor
    func colorForNostrPubkey(_ pubkeyHexLowercased: String, isDark: Bool) -> Color {
        return getNostrPaletteColor(for: pubkeyHexLowercased.lowercased(), isDark: isDark)
    }

    @MainActor
    func colorForMeshPeer(id peerID: PeerID, isDark: Bool) -> Color {
        return getPeerPaletteColor(for: peerID, isDark: isDark)
    }

    // MARK: - Peer Palette Coordination
    private let meshPalette = MinimalDistancePalette(config: .mesh)
    private let nostrPalette = MinimalDistancePalette(config: .nostr)

    @MainActor
    private func meshSeed(for peerID: PeerID) -> String {
        if let full = getNoiseKeyForShortID(peerID)?.id.lowercased() {
            return "noise:" + full
        }
        return peerID.id.lowercased()
    }

    @MainActor
    private func getPeerPaletteColor(for peerID: PeerID, isDark: Bool) -> Color {
        if peerID == meshService.myPeerID {
            return .orange
        }

        meshPalette.ensurePalette(for: currentMeshPaletteSeeds())
        if let color = meshPalette.color(for: peerID.id, isDark: isDark) {
            return color
        }
        return Color(peerSeed: meshSeed(for: peerID), isDark: isDark)
    }

    @MainActor
    private func currentMeshPaletteSeeds() -> [String: String] {
        let myID = meshService.myPeerID
        var seeds: [String: String] = [:]
        for peer in allPeers where peer.peerID != myID {
            seeds[peer.peerID.id] = meshSeed(for: peer.peerID)
        }
        return seeds
    }

    @MainActor
    private func getNostrPaletteColor(for pubkeyHexLowercased: String, isDark: Bool) -> Color {
        let myHex = currentGeohashIdentityHex()
        if let myHex, pubkeyHexLowercased == myHex {
            return .orange
        }

        nostrPalette.ensurePalette(for: currentNostrPaletteSeeds(excluding: myHex))
        if let color = nostrPalette.color(for: pubkeyHexLowercased, isDark: isDark) {
            return color
        }
        return Color(peerSeed: "nostr:" + pubkeyHexLowercased, isDark: isDark)
    }

    @MainActor
    private func currentNostrPaletteSeeds(excluding myHex: String?) -> [String: String] {
        var seeds: [String: String] = [:]
        let excluded = myHex ?? ""
        for person in visibleGeohashPeople() where person.id != excluded {
            seeds[person.id] = "nostr:" + person.id
        }
        return seeds
    }

    @MainActor
    private func currentGeohashIdentityHex() -> String? {
        if case .location(let channel) = LocationChannelManager.shared.selectedChannel,
           let identity = try? idBridge.deriveIdentity(forGeohash: channel.geohash) {
            return identity.publicKeyHex.lowercased()
        }
        return nil
    }

    // Clear the current public channel's timeline (visible + persistent buffer)
    @MainActor
    func clearCurrentPublicTimeline() {
        // Clear messages from current timeline
        messages.removeAll()
        timelineStore.clear(channel: activeChannel)

        // Delete associated media files (images, voice notes, files) in background
        // Only delete from current chat to avoid removing private chat media
        Task.detached(priority: .utility) {
            do {
                let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                let filesDir = base.appendingPathComponent("files", isDirectory: true)

                // Only clear public media (mesh channel only - geohash media is separate)
                // Note: This is conservative - only clears outgoing since we authored those
                let outgoingDirs = [
                    filesDir.appendingPathComponent("voicenotes/outgoing", isDirectory: true),
                    filesDir.appendingPathComponent("images/outgoing", isDirectory: true),
                    filesDir.appendingPathComponent("files/outgoing", isDirectory: true)
                ]

                for dir in outgoingDirs {
                    if FileManager.default.fileExists(atPath: dir.path) {
                        try? FileManager.default.removeItem(at: dir)
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
                    }
                }
            } catch {
                SecureLogger.error("Failed to clear media files: \(error)", category: .session)
            }
        }
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
    private func updateEncryptionStatus(for peerID: PeerID) {
        let noiseService = meshService.getNoiseService()
        
        if noiseService.hasEstablishedSession(with: peerID) {
            peerEncryptionStatus[peerID] = encryptionStatus(for: peerID)
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
    
    func showFingerprint(for peerID: PeerID) {
        showingFingerprintFor = peerID
    }
    
    // MARK: - Peer Lookup Helpers
    
    func getPeer(byID peerID: PeerID) -> BitchatPeer? {
        return peerIndex[peerID]
    }
    
    @MainActor
    func getFingerprint(for peerID: PeerID) -> String? {
        return unifiedPeerService.getFingerprint(for: peerID)
    }
    
    /// Check if fingerprint is verified using our persisted data
    @MainActor
    private func encryptionStatus(for peerID: PeerID) -> EncryptionStatus {
        if let fp = getFingerprint(for: peerID), verifiedFingerprints.contains(fp) {
            return .noiseVerified
        } else {
            return .noiseSecured
        }
    }
    
    /// Helper to resolve nickname for a peer ID through various sources
    @MainActor
    private func resolveNickname(for peerID: PeerID) -> String {
        // Guard against empty or very short peer IDs
        guard !peerID.isEmpty else {
            return "unknown"
        }
        
        // Check if this might already be a nickname (not a hex peer ID)
        // Peer IDs are hex strings, so they only contain 0-9 and a-f
        if !peerID.isHex {
            // If it's already a nickname, just return it
            return peerID.id
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
        let prefixLength = min(4, peerID.id.count)
        let prefix = String(peerID.id.prefix(prefixLength))
        
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
    func verifyFingerprint(for peerID: PeerID) {
        guard let fingerprint = getFingerprint(for: peerID) else { return }
        
        // Update secure storage with verified status
        identityManager.setVerified(fingerprint: fingerprint, verified: true)
        saveIdentityState()
        
        // Update local set for UI
        verifiedFingerprints.insert(fingerprint)
        
        // Update encryption status after verification
        updateEncryptionStatus(for: peerID)
    }

    @MainActor
    func unverifyFingerprint(for peerID: PeerID) {
        guard let fingerprint = getFingerprint(for: peerID) else { return }
        identityManager.setVerified(fingerprint: fingerprint, verified: false)
        saveIdentityState()
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
            let fp = unifiedPeerService.getFingerprint(for: fav.peerID)
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
                    let stable = PeerID(hexData: keyData)
                    self.shortIDToNoiseKey[peerID] = stable
                    SecureLogger.debug("🗺️ Mapped short peerID to Noise key for header continuity: \(peerID) -> \(stable.id.prefix(8))…", category: .session)
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

    /// Find message index trying both short (16-hex) and long (64-hex) peer ID formats.
    /// Returns the peer ID where the message was found and its index, or nil if not found.
    private func findMessageIndex(messageID: String, peerID: PeerID) -> (peerID: PeerID, index: Int)? {
        // Try direct lookup first
        if let messages = privateChats[peerID],
           let idx = messages.firstIndex(where: { $0.id == messageID }) {
            return (peerID, idx)
        }

        // Try with full noise key if peerID is short (16 hex chars)
        if peerID.bare.count == 16,
           let peer = unifiedPeerService.getPeer(by: peerID),
           !peer.noisePublicKey.isEmpty {
            let longID = PeerID(hexData: peer.noisePublicKey)
            if let messages = privateChats[longID],
               let idx = messages.firstIndex(where: { $0.id == messageID }) {
                return (longID, idx)
            }
        }

        // Try with short form if peerID is long (64 hex = noise key)
        if peerID.bare.count == 64 {
            let shortID = peerID.toShort()
            if let messages = privateChats[shortID],
               let idx = messages.firstIndex(where: { $0.id == messageID }) {
                return (shortID, idx)
            }
        }

        return nil
    }

    // Low-level BLE events
    func didReceiveNoisePayload(from peerID: PeerID, type: NoisePayloadType, payload: Data, timestamp: Date) {
        Task { @MainActor in
            switch type {
            case .privateMessage:
                guard let pm = PrivateMessagePacket.decode(from: payload) else { return }

                // BCH-01-012: Check blocking before processing private message to prevent notification bypass
                if isPeerBlocked(peerID) {
                    SecureLogger.debug("🚫 Ignoring Noise payload from blocked peer: \(peerID)", category: .security)
                    return
                }

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
                guard let name = unifiedPeerService.getPeer(by: peerID)?.nickname,
                      let (foundPeerID, idx) = findMessageIndex(messageID: messageID, peerID: peerID) else { return }

                // Don't downgrade from .read to .delivered
                if case .read = privateChats[foundPeerID]?[idx].deliveryStatus { return }

                privateChats[foundPeerID]?[idx].deliveryStatus = .delivered(to: name, at: Date())
                objectWillChange.send()

            case .readReceipt:
                guard let messageID = String(data: payload, encoding: .utf8) else { return }
                guard let name = unifiedPeerService.getPeer(by: peerID)?.nickname,
                      let (foundPeerID, idx) = findMessageIndex(messageID: messageID, peerID: peerID) else { return }

                // Explicitly unwrap and re-assign to ensure the @Published setter is called
                if let messages = privateChats[foundPeerID], idx < messages.count {
                    messages[idx].deliveryStatus = .read(by: name, at: Date())
                    privateChats[foundPeerID] = messages
                    privateChatManager.objectWillChange.send()
                    objectWillChange.send()
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
                        saveIdentityState()
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

    func didReceivePublicMessage(from peerID: PeerID, nickname: String, content: String, timestamp: Date, messageID: String?) {
        Task { @MainActor in
            let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines)
            let publicMentions = parseMentions(from: normalized)
            let msg = BitchatMessage(
                id: messageID,
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
        let peerID = peer.peerID
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
    // MARK: - Bluetooth State Monitoring

    func didUpdateBluetoothState(_ state: CBManagerState) {
        Task { @MainActor in
            updateBluetoothState(state)
        }
    }

    // MARK: - Peer Connection Events

    func didConnectToPeer(_ peerID: PeerID) {
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
                let noiseKeyHex = PeerID(hexData: peer.noisePublicKey)
                shortIDToNoiseKey[peerID] = noiseKeyHex
            }

            // Flush any queued messages for this peer via router
            messageRouter.flushOutbox(for: peerID)
        }
    }
    
    func didDisconnectFromPeer(_ peerID: PeerID) {
        SecureLogger.debug("👋 Peer disconnected: \(peerID)", category: .session)
        
        // Remove ephemeral session from identity manager
        identityManager.removeEphemeralSession(peerID: peerID)

        // If the open PM is tied to this short peer ID, switch UI context to the full Noise key (offline favorite)
        var derivedStableKeyHex = shortIDToNoiseKey[peerID]
        if derivedStableKeyHex == nil,
           let key = meshService.getNoiseService().getPeerPublicKeyData(peerID) {
            derivedStableKeyHex = PeerID(hexData: key)
            shortIDToNoiseKey[peerID] = derivedStableKeyHex
        }

        if let current = selectedPrivateChatPeer, current == peerID, let stableKeyHex = derivedStableKeyHex {
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
                        senderPeerID: msg.senderPeerID == meshService.myPeerID ? meshService.myPeerID : stableKeyHex,
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
    }
    
    func didUpdatePeerList(_ peers: [PeerID]) {
        // UI updates must run on the main thread.
        // The delegate callback is not guaranteed to be on the main thread.
        DispatchQueue.main.async {
            // Update through peer manager
            // UnifiedPeerService updates automatically via subscriptions
            self.isConnected = !peers.isEmpty
            
            // Clean up stale unread peer IDs whenever peer list updates
            self.cleanupStaleUnreadPeerIDs()
            
            // Smart notification logic for "bitchatters nearby"
            let meshPeers = peers.filter { peerID in
                self.meshService.isPeerConnected(peerID) || self.meshService.isPeerReachable(peerID)
            }
            let meshPeerSet = Set(meshPeers)
            
            if meshPeerSet.isEmpty {
                self.scheduleNetworkEmptyTimer()
            } else {
                self.invalidateNetworkEmptyTimer()
                // Don't trim recentlySeenPeers here - let timers handle cleanup.
                // Trimming immediately causes peers to be treated as "new" when they
                // briefly drop and reconnect, triggering notification floods.
                let newPeers = meshPeerSet.subtracting(self.recentlySeenPeers)

                if !newPeers.isEmpty {
                    // Rate limit: max one notification per 5 minutes
                    let cooldown = TransportConfig.networkNotificationCooldownSeconds
                    if Date().timeIntervalSince(self.lastNetworkNotificationTime) >= cooldown {
                        // Only mark peers as seen when we actually notify about them
                        // This ensures peers arriving during cooldown will be included in the next notification
                        self.recentlySeenPeers.formUnion(newPeers)
                        self.lastNetworkNotificationTime = Date()
                        NotificationService.shared.sendNetworkAvailableNotification(peerCount: meshPeers.count)
                        SecureLogger.info(
                            "👥 Sent bitchatters nearby notification for \(meshPeers.count) mesh peers (new: \(newPeers.count))",
                            category: .session
                        )
                    }
                    self.scheduleNetworkResetTimer()
                }
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
        let currentPeerIDs = Set(unifiedPeerService.peers.map { $0.peerID })
        let staleIDs = unreadPrivateMessages.subtracting(currentPeerIDs)
        
        if !staleIDs.isEmpty {
            var idsToRemove: [PeerID] = []
            for staleID in staleIDs {
                // Don't remove temporary Nostr peer IDs that have messages
                if staleID.isGeoDM {
                    // Check if we have messages from this temporary peer
                    if let messages = privateChats[staleID], !messages.isEmpty {
                        // Keep this ID - it has messages
                        continue
                    }
                }
                
                // Don't remove stable Noise key hexes (64 char hex strings) that have messages
                // These are used for Nostr messages when peer is offline
                if staleID.isNoiseKeyHex {
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

    @MainActor
    private func scheduleNetworkResetTimer() {
        networkResetTimer?.invalidate()
        networkResetTimer = Timer.scheduledTimer(
            timeInterval: networkResetGraceSeconds,
            target: self,
            selector: #selector(onNetworkResetTimerFired(_:)),
            userInfo: nil,
            repeats: false
        )
    }

    @MainActor
    @objc private func onNetworkResetTimerFired(_ timer: Timer) {
        let activeMeshPeers = meshService
            .currentPeerSnapshots()
            .filter { snapshot in
                snapshot.isConnected || meshService.isPeerReachable(snapshot.peerID)
            }
        if activeMeshPeers.isEmpty {
            recentlySeenPeers.removeAll()
            SecureLogger.debug("⏱️ Network notification window reset after quiet period", category: .session)
        } else {
            SecureLogger.debug("⏱️ Skipped network notification reset; still seeing \(activeMeshPeers.count) mesh peers", category: .session)
        }
        networkResetTimer = nil
    }

    @MainActor
    private func scheduleNetworkEmptyTimer() {
        guard networkEmptyTimer == nil else { return }
        networkEmptyTimer = Timer.scheduledTimer(
            timeInterval: TransportConfig.uiMeshEmptyConfirmationSeconds,
            target: self,
            selector: #selector(onNetworkEmptyTimerFired(_:)),
            userInfo: nil,
            repeats: false
        )
        SecureLogger.debug("⏳ Mesh empty — waiting before resetting notification state", category: .session)
    }

    @MainActor
    private func invalidateNetworkEmptyTimer() {
        if networkEmptyTimer != nil {
            networkEmptyTimer?.invalidate()
            networkEmptyTimer = nil
        }
    }

    @MainActor
    @objc private func onNetworkEmptyTimerFired(_ timer: Timer) {
        let activeMeshPeers = meshService
            .currentPeerSnapshots()
            .filter { snapshot in
                snapshot.isConnected || meshService.isPeerReachable(snapshot.peerID)
            }
        if activeMeshPeers.isEmpty {
            recentlySeenPeers.removeAll()
            SecureLogger.debug("⏳ Mesh empty — notification state reset after confirmation", category: .session)
        } else {
            SecureLogger.debug("⏳ Mesh empty timer cancelled; \(activeMeshPeers.count) mesh peers detected again", category: .session)
        }
        networkEmptyTimer = nil
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
    
    func parseMentions(from content: String) -> [String] {
        // Allow optional disambiguation suffix '#abcd' for duplicate nicknames
        let regex = Patterns.mention
        let nsContent = content as NSString
        let nsLen = nsContent.length
        let matches = regex.matches(in: content, options: [], range: NSRange(location: 0, length: nsLen))
        
        var mentions: [String] = []
        let peerNicknames = meshService.getPeerNicknames()
        // Compose the valid mention tokens based on current peers (already suffixed where needed)
        var validTokens = Set(peerNicknames.values)
        // Always allow mentioning self by base nickname and suffixed disambiguator
        validTokens.insert(nickname)
        let selfSuffixToken = nickname + "#" + String(meshService.myPeerID.id.prefix(4))
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
    
    func updateMessageDeliveryStatus(_ messageID: String, status: DeliveryStatus) {
        
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
    func addSystemMessage(_ content: String, timestamp: Date = Date()) {
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
    func addMeshOnlySystemMessage(_ content: String) {
        let systemMessage = BitchatMessage(
            sender: "system",
            content: content,
            timestamp: Date(),
            isRelay: false
        )
        timelineStore.append(systemMessage, to: .mesh)
        refreshVisibleMessages()
        trimMessagesIfNeeded()
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
        timelineStore.append(systemMessage, to: activeChannel)
        refreshVisibleMessages(from: activeChannel)
        // Track the content key so relayed copies of the same system-style message are ignored
        let contentKey = deduplicationService.normalizedContentKey(systemMessage.content)
        deduplicationService.recordContentKey(contentKey, timestamp: systemMessage.timestamp)
        trimMessagesIfNeeded()
        objectWillChange.send()
    }

    /// Add a system message only if viewing a geohash location channel (never post to mesh).
    @MainActor
    func addGeohashOnlySystemMessage(_ content: String) {
        if case .location = activeChannel {
            addPublicSystemMessage(content)
        } else {
            // Not on a location channel yet: queue to show when user switches
            timelineStore.queueGeohashSystemMessage(content)
        }
    }
    // Send a public message without adding a local user echo.
    // Used for emotes where we want a local system-style confirmation instead.
    @MainActor
    func sendPublicRaw(_ content: String) {
        if case .location(let ch) = activeChannel {
            Task { @MainActor in
                do {
                    let identity = try idBridge.deriveIdentity(forGeohash: ch.geohash)
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
        meshService.sendMessage(content,
                                mentions: [],
                                messageID: UUID().uuidString,
                                timestamp: Date())
    }
    

    

    

    
    // MARK: - Base64URL utils
    static func base64URLDecode(_ s: String) -> Data? {
        var str = s.replacingOccurrences(of: "-", with: "+")
                    .replacingOccurrences(of: "_", with: "/")
        // Add padding if needed
        let rem = str.count % 4
        if rem > 0 { str.append(String(repeating: "=", count: 4 - rem)) }
        return Data(base64Encoded: str)
    }
    
    //
    

    

    

    

    

    
    /// Handle incoming public message
    @MainActor
    func handlePublicMessage(_ message: BitchatMessage) {
        let finalMessage = processActionMessage(message)

        // Drop if sender is blocked (covers geohash via Nostr pubkey mapping)
        if isMessageBlocked(finalMessage) { return }

        // Classify origin: geochat if senderPeerID starts with 'nostr:', else mesh (or system)
        let isGeo = finalMessage.senderPeerID?.isGeoChat == true

        // Apply per-sender and per-content rate limits (drop if exceeded)
        // Treat action-style system messages (which carry a senderPeerID) the same as regular user messages
        let shouldRateLimit = finalMessage.sender != "system" || finalMessage.senderPeerID != nil
        if shouldRateLimit {
            let senderKey = normalizedSenderKey(for: finalMessage)
            let contentKey = deduplicationService.normalizedContentKey(finalMessage.content)
            if !publicRateLimiter.allow(senderKey: senderKey, contentKey: contentKey) { return }
        }

        // Size cap: drop extremely large public messages early
        if finalMessage.sender != "system" && finalMessage.content.count > 16000 { return }

        // Persist mesh messages to mesh timeline always
        if !isGeo && finalMessage.sender != "system" {
            timelineStore.append(finalMessage, to: .mesh)
        }

        // Persist geochat messages to per-geohash timeline
        if isGeo && finalMessage.sender != "system" {
            if let gh = currentGeohash {
                _ = timelineStore.appendIfAbsent(finalMessage, toGeohash: gh)
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
                publicMessagePipeline.enqueue(finalMessage)
            }
        }
    }
    
        /// Check for mentions and send notifications
        
        func checkForMentions(_ message: BitchatMessage) {    // Determine our acceptable mention token. If any connected peer shares our nickname,
    // require the disambiguated form '<nickname>#<peerIDprefix>' to trigger.
    var myTokens: Set<String> = [nickname]
    let meshPeers = meshService.getPeerNicknames()
    let collisions = meshPeers.values.filter { $0.hasPrefix(nickname + "#") }
    if !collisions.isEmpty {
        let suffix = "#" + String(meshService.myPeerID.id.prefix(4))
        myTokens = [nickname + suffix]
    }
    let isMentioned = (message.mentions?.contains { myTokens.contains($0) } ?? false)

    if isMentioned && message.sender != nickname {
        SecureLogger.info("🔔 Mention from \(message.sender)", category: .session)
        NotificationService.shared.sendMentionNotification(from: message.sender, message: message.content)
    }
}

    /// Send haptic feedback for special messages (iOS only)
    func sendHapticFeedback(for message: BitchatMessage) {        #if os(iOS)
        guard UIApplication.shared.applicationState == .active else { return }
        
        // Build acceptable target tokens: base nickname and, if in a location channel, nickname with '#abcd'
        var tokens: [String] = [nickname]
        #if os(iOS)
        switch activeChannel {
        case .location(let ch):
            if let id = try? idBridge.deriveIdentity(forGeohash: ch.geohash) {
                let d = String(id.publicKeyHex.suffix(4))
                tokens.append(nickname + "#" + d)
            }
        case .mesh:
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

extension ChatViewModel: PublicMessagePipelineDelegate {
    func pipelineCurrentMessages(_ pipeline: PublicMessagePipeline) -> [BitchatMessage] {
        messages
    }

    func pipeline(_ pipeline: PublicMessagePipeline, setMessages messages: [BitchatMessage]) {
        self.messages = messages
    }

    func pipeline(_ pipeline: PublicMessagePipeline, normalizeContent content: String) -> String {
        deduplicationService.normalizedContentKey(content)
    }

    func pipeline(_ pipeline: PublicMessagePipeline, contentTimestampForKey key: String) -> Date? {
        deduplicationService.contentTimestamp(forKey: key)
    }

    func pipeline(_ pipeline: PublicMessagePipeline, recordContentKey key: String, timestamp: Date) {
        deduplicationService.recordContentKey(key, timestamp: timestamp)
    }

    func pipelineTrimMessages(_ pipeline: PublicMessagePipeline) {
        trimMessagesIfNeeded()
    }

    func pipelinePrewarmMessage(_ pipeline: PublicMessagePipeline, message: BitchatMessage) {
        _ = formatMessageAsText(message, colorScheme: currentColorScheme)
    }

    func pipelineSetBatchingState(_ pipeline: PublicMessagePipeline, isBatching: Bool) {
        isBatchingPublic = isBatching
    }
}
