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
import BitFoundation
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

    var publicRateLimiter = MessageRateLimiter(
        senderCapacity: TransportConfig.uiSenderRateBucketCapacity,
        senderRefillPerSec: TransportConfig.uiSenderRateBucketRefillPerSec,
        contentCapacity: TransportConfig.uiContentRateBucketCapacity,
        contentRefillPerSec: TransportConfig.uiContentRateBucketRefillPerSec
    )

    // MARK: - Published Properties
    
    @Published var messages: [BitchatMessage] = []
    @Published var currentColorScheme: ColorScheme = .light
    private let maxMessages = TransportConfig.meshTimelineCap // Maximum messages before oldest are removed
    @Published var isConnected = false
    @Published var nickname: String = "" {
        didSet {
            // Trim whitespace whenever nickname is set; whitespace-only becomes ""
            let trimmed = nickname.trimmedOrNilIfEmpty ?? ""
            if trimmed != nickname {
                nickname = trimmed
                return
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
    private lazy var outgoingCoordinator = ChatOutgoingCoordinator(viewModel: self)
    private lazy var lifecycleCoordinator = ChatLifecycleCoordinator(viewModel: self)
    private lazy var transportEventCoordinator = ChatTransportEventCoordinator(viewModel: self)
    private lazy var peerListCoordinator = ChatPeerListCoordinator(viewModel: self)
    private lazy var messageFormatter = ChatMessageFormatter(viewModel: self)
    lazy var peerIdentityCoordinator = ChatPeerIdentityCoordinator(viewModel: self)
    lazy var deliveryCoordinator = ChatDeliveryCoordinator(viewModel: self)
    lazy var composerCoordinator = ChatComposerCoordinator(viewModel: self)
    lazy var publicConversationCoordinator = ChatPublicConversationCoordinator(viewModel: self)
    lazy var privateConversationCoordinator = ChatPrivateConversationCoordinator(viewModel: self)
    lazy var nostrCoordinator = ChatNostrCoordinator(viewModel: self)
    lazy var mediaTransferCoordinator = ChatMediaTransferCoordinator(viewModel: self)
    lazy var verificationCoordinator = ChatVerificationCoordinator(viewModel: self)
    
    // Computed properties for compatibility
    @MainActor
    var connectedPeers: Set<PeerID> { unifiedPeerService.connectedPeerIDs }
    @Published var allPeers: [BitchatPeer] = []
    var privateChats: [PeerID: [BitchatMessage]] {
        get { privateChatManager.privateChats }
        set {
            privateChatManager.privateChats = newValue
            synchronizePrivateConversationStore()
        }
    }
    var selectedPrivateChatPeer: PeerID? {
        get { privateChatManager.selectedPeer }
        set { 
            if let peerID = newValue {
                privateChatManager.startChat(with: peerID)
            } else {
                privateChatManager.endChat()
            }
            synchronizePrivateConversationStore()
            synchronizeConversationSelectionStore()
        }
    }
    var unreadPrivateMessages: Set<PeerID> {
        get { privateChatManager.unreadMessages }
        set {
            privateChatManager.unreadMessages = newValue
            synchronizePrivateConversationStore()
        }
    }
    
    /// Check if there are any unread messages (including from temporary Nostr peer IDs)
    var hasAnyUnreadMessages: Bool {
        !unreadPrivateMessages.isEmpty
    }

    /// Open the most relevant private chat when tapping the toolbar unread icon.
    /// Prefers the most recently active unread conversation, otherwise the most recent PM.
    @MainActor
    func openMostRelevantPrivateChat() {
        peerIdentityCoordinator.openMostRelevantPrivateChat()
    }
    
    //
    var peerIDToPublicKeyFingerprint: [PeerID: String] {
        get { peerIdentityStore.peerFingerprintsByPeerID }
        set { peerIdentityStore.replaceFingerprintMappings(newValue) }
    }
    var selectedPrivateChatFingerprint: String? {
        get { peerIdentityStore.selectedPrivateChatFingerprint }
        set { peerIdentityStore.setSelectedPrivateChatFingerprint(newValue) }
    }

    // Resolve full Noise key for a peer's short ID (used by UI header rendering)
    @MainActor
    private func getNoiseKeyForShortID(_ shortPeerID: PeerID) -> PeerID? {
        if let mapped = peerIdentityStore.stablePeerID(forShortID: shortPeerID) { return mapped }
        // Fallback: derive from active Noise session if available
        if shortPeerID.id.count == 16,
           let key = meshService.getNoiseService().getPeerPublicKeyData(shortPeerID) {
            let stable = PeerID(hexData: key)
            peerIdentityStore.setStablePeerID(stable, forShortID: shortPeerID)
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
        if let shortPeerID = peerIdentityStore.shortPeerID(forStablePeerID: fullNoiseKeyHex) {
            return shortPeerID
        }
        return fullNoiseKeyHex
    }

    @MainActor
    func cacheStablePeerID(_ stablePeerID: PeerID, for shortPeerID: PeerID) {
        peerIdentityStore.setStablePeerID(stablePeerID, forShortID: shortPeerID)
    }

    @MainActor
    func cachedStablePeerID(for shortPeerID: PeerID) -> PeerID? {
        peerIdentityStore.stablePeerID(forShortID: shortPeerID)
    }

    var hasTrackedPrivateChatSelection: Bool {
        selectedPrivateChatFingerprint != nil
    }

    var peerIndex: [PeerID: BitchatPeer] = [:]
    
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
    let conversationStore: ConversationStore
    let identityResolver: IdentityResolver
    let peerIdentityStore: PeerIdentityStore
    let locationPresenceStore: LocationPresenceStore
    let locationManager: LocationChannelManager
    
    var nostrRelayManager: NostrRelayManager?
    private let userDefaults = UserDefaults.standard
    let keychain: KeychainManagerProtocol
    private let nicknameKey = "bitchat.nickname"
    // Location channel state (macOS supports manual geohash selection)
    var activeChannel: ChannelID {
        get { conversationStore.activeChannel }
        set {
            guard conversationStore.activeChannel != newValue else { return }
            publicMessagePipeline.updateActiveChannel(newValue)
            conversationStore.setActiveChannel(newValue)
            synchronizePublicConversationStore(for: newValue)
            synchronizeConversationSelectionStore()
            objectWillChange.send()
        }
    }
    var geoSubscriptionID: String? = nil
    var geoDmSubscriptionID: String? = nil
    var currentGeohash: String? {
        get { locationPresenceStore.currentGeohash }
        set { locationPresenceStore.setCurrentGeohash(newValue) }
    }
    var cachedGeohashIdentity: (geohash: String, identity: NostrIdentity)? = nil // Cache current geohash identity
    var geoNicknames: [String: String] {
        get { locationPresenceStore.geoNicknames }
        set { locationPresenceStore.replaceGeoNicknames(newValue) }
    } // pubkeyHex(lowercased) -> nickname
    // Show Tor status once per app launch
    var torStatusAnnounced = false
    // Track whether a Tor restart is pending so we only announce
    // "tor restarted" after an actual restart, not the first launch.
    var torRestartPending: Bool = false
    // Ensure we set up DM subscription only once per app session
    var nostrHandlersSetup: Bool = false
    var geoChannelCoordinator: GeoChannelCoordinator?
    
    // MARK: - Caches
    
    // MARK: - Social Features (Delegated to PeerStateManager)
    
    @MainActor
    var favoritePeers: Set<String> { unifiedPeerService.favoritePeers }
    @MainActor
    var blockedUsers: Set<String> { unifiedPeerService.blockedUsers }
    
    // MARK: - Encryption and Security
    
    // Noise Protocol encryption status
    var peerEncryptionStatus: [PeerID: EncryptionStatus] {
        get { peerIdentityStore.encryptionStatuses }
        set { peerIdentityStore.replaceEncryptionStatuses(newValue) }
    }
    var verifiedFingerprints: Set<String> {
        get { peerIdentityStore.verifiedFingerprints }
        set { peerIdentityStore.setVerifiedFingerprints(newValue) }
    }  // Set of verified fingerprints
    
    // Bluetooth state management
    @Published var showBluetoothAlert = false
    @Published var bluetoothAlertMessage = ""
    @Published var bluetoothState: CBManagerState = .unknown

    var timelineStore = PublicTimelineStore(
        meshCap: TransportConfig.meshTimelineCap,
        geohashCap: TransportConfig.geoTimelineCap
    )

    private func performDeliveryUpdate(_ update: @escaping @MainActor (ChatDeliveryCoordinator) -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                update(deliveryCoordinator)
            }
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            update(self.deliveryCoordinator)
        }
    }
    // Channel activity tracking for background nudges
    var lastPublicActivityAt: [String: Date] = [:]   // channelKey -> last activity time
    // Geohash participant tracker
    let participantTracker = GeohashParticipantTracker(activityCutoff: -TransportConfig.uiRecentCutoffFiveMinutesSeconds)
    // Participants who indicated they teleported (by tag in their events)
    var teleportedGeo: Set<String> {
        get { locationPresenceStore.teleportedGeo }
        set { locationPresenceStore.replaceTeleportedGeo(newValue) }
    }  // lowercased pubkey hex
    // Sampling subscriptions for multiple geohashes (when channel sheet is open)
    var geoSamplingSubs: [String: String] = [:] // subID -> geohash
    var lastGeoNotificationAt: [String: Date] = [:] // geohash -> last notify time
    
    
    // MARK: - Message Delivery Tracking
    
    var cancellables = Set<AnyCancellable>()

    var transferIdToMessageIDs: [String: [String]] {
        mediaTransferCoordinator.transferIdToMessageIDs
    }

    var messageIDToTransferId: [String: String] {
        mediaTransferCoordinator.messageIDToTransferId
    }

    // MARK: - Public message batching (UI perf)
    let publicMessagePipeline: PublicMessagePipeline
    @Published var isBatchingPublic: Bool = false
    
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

    // Track which GeoDM messages we've already sent a delivery ACK for (by messageID)
    var sentGeoDeliveryAcks: Set<String> = []
    
    // Track app startup phase to prevent marking old messages as unread
    var isStartupPhase = true
    // Announce Tor initial readiness once per launch to avoid duplicates
    var torInitialReadyAnnounced: Bool = false
    
    // Track Nostr pubkey mappings for unknown senders
    var nostrKeyMapping: [PeerID: String] = [:]  // senderPeerID -> nostrPubkey
    
    // MARK: - Initialization

    @MainActor
    convenience init(
        keychain: KeychainManagerProtocol,
        idBridge: NostrIdentityBridge,
        identityManager: SecureIdentityStateManagerProtocol,
        conversationStore: ConversationStore? = nil,
        identityResolver: IdentityResolver? = nil,
        peerIdentityStore: PeerIdentityStore? = nil,
        locationPresenceStore: LocationPresenceStore? = nil,
        locationManager: LocationChannelManager = .shared
    ) {
        let conversationStore = conversationStore ?? ConversationStore()
        let identityResolver = identityResolver ?? IdentityResolver()
        self.init(
            keychain: keychain,
            idBridge: idBridge,
            identityManager: identityManager,
            transport: BLEService(keychain: keychain, idBridge: idBridge, identityManager: identityManager),
            conversationStore: conversationStore,
            identityResolver: identityResolver,
            peerIdentityStore: peerIdentityStore ?? PeerIdentityStore(),
            locationPresenceStore: locationPresenceStore ?? LocationPresenceStore(),
            locationManager: locationManager
        )
    }

    /// Testable initializer that accepts a Transport dependency.
    /// Use this initializer for unit testing with MockTransport.
    @MainActor
    init(
        keychain: KeychainManagerProtocol,
        idBridge: NostrIdentityBridge,
        identityManager: SecureIdentityStateManagerProtocol,
        transport: Transport,
        conversationStore: ConversationStore? = nil,
        identityResolver: IdentityResolver? = nil,
        peerIdentityStore: PeerIdentityStore? = nil,
        locationPresenceStore: LocationPresenceStore? = nil,
        locationManager: LocationChannelManager = .shared
    ) {
        let conversationStore = conversationStore ?? ConversationStore()
        let identityResolver = identityResolver ?? IdentityResolver()
        let peerIdentityStore = peerIdentityStore ?? PeerIdentityStore()
        let locationPresenceStore = locationPresenceStore ?? LocationPresenceStore()
        let services = ChatViewModelServiceBundle(
            keychain: keychain,
            idBridge: idBridge,
            identityManager: identityManager,
            meshService: transport
        )

        self.keychain = keychain
        self.idBridge = idBridge
        self.identityManager = identityManager
        self.conversationStore = conversationStore
        self.identityResolver = identityResolver
        self.peerIdentityStore = peerIdentityStore
        self.locationPresenceStore = locationPresenceStore
        self.locationManager = locationManager
        self.meshService = transport
        self.commandProcessor = services.commandProcessor
        self.messageRouter = services.messageRouter
        self.privateChatManager = services.privateChatManager
        self.unifiedPeerService = services.unifiedPeerService
        self.autocompleteService = services.autocompleteService
        self.deduplicationService = services.deduplicationService
        self.publicMessagePipeline = services.publicMessagePipeline
        self.sentReadReceipts = ChatViewModelBootstrapper.loadPersistedReadReceipts()

        ChatViewModelBootstrapper(viewModel: self).configure()
        initializeConversationStore()
    }
    
    // MARK: - Deinitialization
    
    deinit {
        // No need to force UserDefaults synchronization
    }


    



        
    // MARK: - Nickname Management
    
    func loadNickname() {
        if let savedNickname = userDefaults.string(forKey: nicknameKey) {
            nickname = savedNickname.trimmed
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
        nickname = nickname.trimmedOrNilIfEmpty ?? "anon\(Int.random(in: 1000...9999))"
        saveNickname()
    }

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
        peerIdentityCoordinator.isPeerBlocked(peerID)
    }
    
    // Helper method to update selectedPrivateChatPeer if fingerprint matches
    @MainActor
    func updatePrivateChatPeerIfNeeded() {
        peerIdentityCoordinator.updatePrivateChatPeerIfNeeded()
    }
    
    // MARK: - Message Sending
    
    /// Sends a message through the BitChat network.
    /// - Parameter content: The message content to send
    /// - Note: Automatically handles command processing if content starts with '/'
    ///         Routes to private chat if one is selected, otherwise broadcasts
    @MainActor
    func sendMessage(_ content: String) {
        outgoingCoordinator.sendMessage(content)
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
        publicConversationCoordinator.visibleGeohashPeople()
    }

    /// CommandContextProvider conformance - returns visible geo participants
    func getVisibleGeoParticipants() -> [CommandGeoParticipant] {
        publicConversationCoordinator.getVisibleGeoParticipants()
    }
    /// Returns the current participant count for a specific geohash, using the 5-minute activity window.
    @MainActor
    func geohashParticipantCount(for geohash: String) -> Int {
        publicConversationCoordinator.geohashParticipantCount(for: geohash)
    }

    // MARK: - GeohashParticipantContext Protocol

    func displayNameForPubkey(_ pubkeyHex: String) -> String {
        publicConversationCoordinator.displayNameForPubkey(pubkeyHex)
    }

    func isBlocked(_ pubkeyHexLowercased: String) -> Bool {
        publicConversationCoordinator.isBlocked(pubkeyHexLowercased)
    }

    // Geohash block helpers
    @MainActor
    func isGeohashUserBlocked(pubkeyHexLowercased: String) -> Bool {
        publicConversationCoordinator.isGeohashUserBlocked(pubkeyHexLowercased: pubkeyHexLowercased)
    }
    @MainActor
    func blockGeohashUser(pubkeyHexLowercased: String, displayName: String) {
        publicConversationCoordinator.blockGeohashUser(
            pubkeyHexLowercased: pubkeyHexLowercased,
            displayName: displayName
        )
    }
    @MainActor
    func unblockGeohashUser(pubkeyHexLowercased: String, displayName: String) {
        publicConversationCoordinator.unblockGeohashUser(
            pubkeyHexLowercased: pubkeyHexLowercased,
            displayName: displayName
        )
    }



    func displayNameForNostrPubkey(_ pubkeyHex: String) -> String {
        publicConversationCoordinator.displayNameForNostrPubkey(pubkeyHex)
    }



    // MARK: - Media Transfers

    private enum MediaSendError: Error {
        case encodingFailed
        case tooLarge
        case copyFailed
    }








    func currentPublicSender() -> (name: String, peerID: PeerID) {
        publicConversationCoordinator.currentPublicSender()
    }

    @MainActor
    func nicknameForPeer(_ peerID: PeerID) -> String {
        peerIdentityCoordinator.nicknameForPeer(peerID)
    }



    @MainActor
    func removeMessage(withID messageID: String, cleanupFile: Bool = false) {
        publicConversationCoordinator.removeMessage(withID: messageID, cleanupFile: cleanupFile)
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
        peerIdentityCoordinator.startPrivateChat(with: peerID)
    }
    
    @MainActor
    func endPrivateChat() {
        peerIdentityCoordinator.endPrivateChat()
    }
    
    @MainActor
    @objc func handlePeerStatusUpdate(_ notification: Notification) {
        peerIdentityCoordinator.handlePeerStatusUpdate()
    }
    
    @objc func handleFavoriteStatusChanged(_ notification: Notification) {
        peerIdentityCoordinator.handleFavoriteStatusChanged(notification)
    }
    
    // MARK: - App Lifecycle
    
    @MainActor
    func handleDidBecomeActive() {
        lifecycleCoordinator.handleDidBecomeActive()
    }
    
    @MainActor
    func handleScreenshotCaptured() {
        lifecycleCoordinator.handleScreenshotCaptured()
    }
    
    /// Save identity state without stopping services (for backgrounding)
    func saveIdentityState() {
        lifecycleCoordinator.saveIdentityState()
    }

    @objc func applicationWillTerminate() {
        lifecycleCoordinator.applicationWillTerminate()
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
        lifecycleCoordinator.markPrivateMessagesAsRead(from: peerID)
    }

    func getMessages(for peerID: PeerID?) -> [BitchatMessage] {
        lifecycleCoordinator.getMessages(for: peerID)
    }

    @MainActor
    func getPrivateChatMessages(for peerID: PeerID) -> [BitchatMessage] {
        lifecycleCoordinator.getPrivateChatMessages(for: peerID)
    }
    
    @MainActor
    func getPeerIDForNickname(_ nickname: String) -> PeerID? {
        peerIdentityCoordinator.getPeerIDForNickname(nickname)
    }
    
    
    // MARK: - Emergency Functions
    
    // PANIC: Emergency data clearing for activist safety
    @MainActor
    func panicClearAllData() {
        // Messages are processed immediately - nothing to flush
        
        // Clear all messages
        messages.removeAll()
        timelineStore = PublicTimelineStore(
            meshCap: TransportConfig.meshTimelineCap,
            geohashCap: TransportConfig.geoTimelineCap
        )
        privateChatManager.privateChats.removeAll()
        privateChatManager.unreadMessages.removeAll()
        
        // Delete all keychain data (including Noise and Nostr keys)
        _ = keychain.deleteAllKeychainData()
        
        // Clear UserDefaults identity data
        userDefaults.removeObject(forKey: "bitchat.noiseIdentityKey")
        userDefaults.removeObject(forKey: "bitchat.messageRetentionKey")
        
        // Reset nickname to anonymous
        nickname = "anon\(Int.random(in: 1000...9999))"
        saveNickname()
        
        // Clear favorites and peer mappings
        // Clear through SecureIdentityStateManager instead of directly
        identityManager.clearAllIdentityData()
        peerIdentityStore.clearAll()
        locationPresenceStore.reset()
        
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
        
        // Clear read receipt tracking
        sentReadReceipts.removeAll()
        deduplicationService.clearAll()

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

        initializeConversationStore()

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
        composerCoordinator.updateAutocomplete(for: text, cursorPosition: cursorPosition)
    }
    
    func completeNickname(_ nickname: String, in text: inout String) -> Int {
        composerCoordinator.completeNickname(nickname, in: &text)
    }
    
    // MARK: - Message Formatting
    
    @MainActor
    func formatMessageAsText(_ message: BitchatMessage, colorScheme: ColorScheme) -> AttributedString {
        messageFormatter.formatMessageAsText(message, colorScheme: colorScheme)
    }

    @MainActor
    func formatMessageHeader(_ message: BitchatMessage, colorScheme: ColorScheme) -> AttributedString {
        messageFormatter.formatMessageHeader(message, colorScheme: colorScheme)
    }

    // MARK: - Noise Protocol Support
    
    @MainActor
    func updateEncryptionStatusForPeers() {
        peerIdentityCoordinator.updateEncryptionStatusForPeers()
    }
    
    @MainActor
    func updateEncryptionStatus(for peerID: PeerID) {
        peerIdentityCoordinator.updateEncryptionStatus(for: peerID)
    }
    
    @MainActor
    func getEncryptionStatus(for peerID: PeerID) -> EncryptionStatus {
        peerIdentityCoordinator.getEncryptionStatus(for: peerID)
    }
    
    // Clear caches when data changes
    @MainActor
    func invalidateEncryptionCache(for peerID: PeerID? = nil) {
        peerIdentityCoordinator.invalidateEncryptionCache(for: peerID)
    }
    
    
    // MARK: - Message Handling

    @MainActor
    func initializeConversationStore() {
        publicConversationCoordinator.initializeConversationStore()
    }

    @MainActor
    func synchronizePublicConversationStore(for channel: ChannelID) {
        publicConversationCoordinator.synchronizePublicConversationStore(for: channel)
    }

    @MainActor
    func synchronizePublicConversationStore(forGeohash geohash: String) {
        publicConversationCoordinator.synchronizePublicConversationStore(forGeohash: geohash)
    }

    @MainActor
    func synchronizeAllPublicConversationStores() {
        publicConversationCoordinator.synchronizeAllPublicConversationStores()
    }

    @MainActor
    func synchronizePrivateConversationStore() {
        conversationStore.synchronizePrivateChats(
            privateChatManager.privateChats,
            unreadPeerIDs: privateChatManager.unreadMessages,
            identityResolver: identityResolver
        )
    }

    @MainActor
    func synchronizeConversationSelectionStore() {
        conversationStore.setSelectedPeerID(
            privateChatManager.selectedPeer,
            activeChannel: activeChannel,
            identityResolver: identityResolver
        )
    }

    func trimMessagesIfNeeded() {
        if messages.count > maxMessages {
            messages = Array(messages.suffix(maxMessages))
        }
    }

    @MainActor
    func refreshVisibleMessages(from channel: ChannelID? = nil) {
        publicConversationCoordinator.refreshVisibleMessages(from: channel)
    }

    @MainActor
    private func peerColor(for message: BitchatMessage, isDark: Bool) -> Color {
        messageFormatter.senderColor(for: message, isDark: isDark)
    }

    // MARK: - MessageFormattingContext Protocol

    @MainActor
    func isSelfMessage(_ message: BitchatMessage) -> Bool {
        messageFormatter.isSelfMessage(message)
    }

    @MainActor
    func senderColor(for message: BitchatMessage, isDark: Bool) -> Color {
        peerColor(for: message, isDark: isDark)
    }

    @MainActor
    func peerURL(for peerID: PeerID) -> URL? {
        messageFormatter.peerURL(for: peerID)
    }

    // Public helpers for views to color peers consistently in lists
    @MainActor
    func colorForNostrPubkey(_ pubkeyHexLowercased: String, isDark: Bool) -> Color {
        messageFormatter.colorForNostrPubkey(pubkeyHexLowercased, isDark: isDark)
    }

    @MainActor
    func colorForMeshPeer(id peerID: PeerID, isDark: Bool) -> Color {
        messageFormatter.colorForMeshPeer(id: peerID, isDark: isDark)
    }

    // Clear the current public channel's timeline (visible + persistent buffer)
    @MainActor
    func clearCurrentPublicTimeline() {
        publicConversationCoordinator.clearCurrentPublicTimeline()
    }
    
    // MARK: - Message Management
    
    private func addMessage(_ message: BitchatMessage) {
        // Check for duplicates
        guard !messages.contains(where: { $0.id == message.id }) else { return }
        messages.append(message)
        trimMessagesIfNeeded()
    }
    
    // MARK: - Peer Lookup Helpers
    
    func getPeer(byID peerID: PeerID) -> BitchatPeer? {
        return peerIndex[peerID]
    }
    
    @MainActor
    func getFingerprint(for peerID: PeerID) -> String? {
        peerIdentityCoordinator.getFingerprint(for: peerID)
    }
    
    /// Helper to resolve nickname for a peer ID through various sources
    @MainActor
    func resolveNickname(for peerID: PeerID) -> String {
        peerIdentityCoordinator.resolveNickname(for: peerID)
    }
    
    @MainActor
    func getMyFingerprint() -> String {
        peerIdentityCoordinator.getMyFingerprint()
    }
    
    @MainActor
    func verifyFingerprint(for peerID: PeerID) {
        verificationCoordinator.verifyFingerprint(for: peerID)
    }

    @MainActor
    func unverifyFingerprint(for peerID: PeerID) {
        verificationCoordinator.unverifyFingerprint(for: peerID)
    }
    
    @MainActor
    func loadVerifiedFingerprints() {
        verificationCoordinator.loadVerifiedFingerprints()
    }
    
    func setupNoiseCallbacks() {
        verificationCoordinator.setupNoiseCallbacks()
    }
    
    // MARK: - BitchatDelegate Methods
    
    // MARK: - Command Handling
    
    /// Processes IRC-style commands starting with '/'.
    /// - Parameter command: The full command string including the leading slash
    /// - Note: Supports commands like /nick, /msg, /who, /slap, /clear, /help
    @MainActor
    func handleCommand(_ command: String) {
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
        transportEventCoordinator.didReceiveMessage(message)
    }

    // Low-level BLE events
    func didReceiveNoisePayload(from peerID: PeerID, type: NoisePayloadType, payload: Data, timestamp: Date) {
        transportEventCoordinator.didReceiveNoisePayload(
            from: peerID,
            type: type,
            payload: payload,
            timestamp: timestamp
        )
    }

    func didReceivePublicMessage(from peerID: PeerID, nickname: String, content: String, timestamp: Date, messageID: String?) {
        transportEventCoordinator.didReceivePublicMessage(
            from: peerID,
            nickname: nickname,
            content: content,
            timestamp: timestamp,
            messageID: messageID
        )
    }

    // MARK: - QR Verification API
    @MainActor
    func beginQRVerification(with qr: VerificationService.VerificationQR) -> Bool {
        verificationCoordinator.beginQRVerification(with: qr)
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
        transportEventCoordinator.didConnectToPeer(peerID)
    }
    
    func didDisconnectFromPeer(_ peerID: PeerID) {
        transportEventCoordinator.didDisconnectFromPeer(peerID)
    }
    
    func didUpdatePeerList(_ peers: [PeerID]) {
        peerListCoordinator.didUpdatePeerList(peers)
    }
    
    @MainActor
    func cleanupOldReadReceipts() {
        deliveryCoordinator.cleanupOldReadReceipts()
    }
    
    func parseMentions(from content: String) -> [String] {
        composerCoordinator.parseMentions(from: content)
    }
    
    func isFavorite(fingerprint: String) -> Bool {
        return identityManager.isFavorite(fingerprint: fingerprint)
    }
    
    // MARK: - Delivery Tracking
    
    func didReceiveReadReceipt(_ receipt: ReadReceipt) {
        performDeliveryUpdate { coordinator in
            coordinator.didReceiveReadReceipt(receipt)
        }
    }
    
    func didUpdateMessageDeliveryStatus(_ messageID: String, status: DeliveryStatus) {
        performDeliveryUpdate { coordinator in
            coordinator.didUpdateMessageDeliveryStatus(messageID, status: status)
        }
    }
    
    func updateMessageDeliveryStatus(_ messageID: String, status: DeliveryStatus) {
        performDeliveryUpdate { coordinator in
            coordinator.updateMessageDeliveryStatus(messageID, status: status)
        }
    }
    
    // MARK: - Helper for System Messages
    func addSystemMessage(_ content: String, timestamp: Date = Date()) {
        publicConversationCoordinator.addSystemMessage(content, timestamp: timestamp)
    }

    /// Add a system message to the mesh timeline only (never geohash).
    /// If mesh is currently active, also append to the visible `messages`.
    @MainActor
    func addMeshOnlySystemMessage(_ content: String) {
        publicConversationCoordinator.addMeshOnlySystemMessage(content)
    }

    /// Public helper to add a system message to the public chat timeline.
    /// Also persists the message into the active channel's backing store so it survives timeline rebinds.
    @MainActor
    func addPublicSystemMessage(_ content: String) {
        publicConversationCoordinator.addPublicSystemMessage(content)
    }

    /// Add a system message only if viewing a geohash location channel (never post to mesh).
    @MainActor
    func addGeohashOnlySystemMessage(_ content: String) {
        publicConversationCoordinator.addGeohashOnlySystemMessage(content)
    }
    // Send a public message without adding a local user echo.
    // Used for emotes where we want a local system-style confirmation instead.
    @MainActor
    func sendPublicRaw(_ content: String) {
        publicConversationCoordinator.sendPublicRaw(content)
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
        publicConversationCoordinator.handlePublicMessage(message)
    }
    
    /// Check for mentions and send notifications
    func checkForMentions(_ message: BitchatMessage) {
        publicConversationCoordinator.checkForMentions(message)
    }

    /// Send haptic feedback for special messages (iOS only)
    func sendHapticFeedback(for message: BitchatMessage) {
        publicConversationCoordinator.sendHapticFeedback(for: message)
    }
}
// End of ChatViewModel class
