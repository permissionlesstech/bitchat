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
#if os(iOS)
import UIKit
#endif
import UniformTypeIdentifiers

/// Manages the application state and business logic for BitChat.
/// Acts as the primary coordinator between UI components and backend services,
/// implementing the BitchatDelegate protocol to handle network events.
final class ChatViewModel: ObservableObject, BitchatDelegate, TransportEventDelegate, CommandContextProvider, GeohashParticipantContext, MessageFormattingContext {
    // Use MessageFormattingEngine.Patterns for regex matching (shared, precompiled)
    typealias Patterns = MessageFormattingEngine.Patterns

    typealias GeoOutgoingContext = (channel: GeohashChannel, event: NostrEvent, identity: NostrIdentity, teleported: Bool)

    @MainActor
    var canSendMediaInCurrentContext: Bool {
        if let peer = selectedPrivateChatPeer {
            // Media transfer is not wired for groups in v1 (sendFilePrivate
            // rejects the virtual group_ recipient), so keep the affordance off.
            return !(peer.isGeoDM || peer.isGeoChat || peer.isGroup)
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

    /// Read-only derived view of the ACTIVE public channel's conversation in
    /// the single-writer `ConversationStore`. SwiftUI renders through
    /// `PublicChatModel` (which observes the `Conversation` object directly);
    /// this view serves the coordinators/commands that need "the visible
    /// timeline" plus tests. Hot enough that the array is cached and
    /// invalidated from the store's `changes` subject (filtered to the
    /// active conversation) and on channel switches. `objectWillChange`
    /// fires on every store change via the sink in `init`.
    @MainActor
    var messages: [BitchatMessage] {
        if let cached = visibleMessagesCache { return cached }
        // Read-only lookup (never creates the conversation): this getter
        // runs during SwiftUI renders, where mutating the store's
        // `@Published` collections would publish mid-view-update.
        let current = conversations.conversationsByID[ConversationID(channelID: activeChannel)]?.messages ?? []
        visibleMessagesCache = current
        return current
    }
    private var visibleMessagesCache: [BitchatMessage]?
    @Published var currentColorScheme: ColorScheme = .light
    @Published var currentTheme: AppTheme = .matrix
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
    private lazy var outgoingCoordinator = ChatOutgoingCoordinator(context: self)
    private lazy var lifecycleCoordinator = ChatLifecycleCoordinator(context: self)
    private lazy var transportEventCoordinator = ChatTransportEventCoordinator(context: self)
    private lazy var peerListCoordinator = ChatPeerListCoordinator(context: self)
    private lazy var messageFormatter = ChatMessageFormatter(viewModel: self)
    lazy var peerIdentityCoordinator = ChatPeerIdentityCoordinator(context: self)
    lazy var deliveryCoordinator = ChatDeliveryCoordinator(context: self)
    lazy var composerCoordinator = ChatComposerCoordinator(context: self)
    lazy var publicConversationCoordinator = ChatPublicConversationCoordinator(context: self)
    lazy var privateConversationCoordinator = ChatPrivateConversationCoordinator(context: self)
    lazy var nostrCoordinator = ChatNostrCoordinator(context: self)
    lazy var mediaTransferCoordinator = ChatMediaTransferCoordinator(context: self)
    lazy var liveVoiceCoordinator = ChatLiveVoiceCoordinator(context: self)
    lazy var verificationCoordinator = ChatVerificationCoordinator(context: self)
    lazy var groupCoordinator = ChatGroupCoordinator(context: self)
    lazy var vouchCoordinator = ChatVouchCoordinator(context: self)

    // Computed properties for compatibility
    @MainActor
    var connectedPeers: Set<PeerID> { unifiedPeerService.connectedPeerIDs }
    @Published var allPeers: [BitchatPeer] = []
    /// Nickname of whoever is talking live in the public mesh channel right
    /// now (floor-courtesy indicator on the composer mic), nil when nobody.
    @Published var activePublicVoiceTalker: String?

    /// Read-only derived view of all direct conversations in the
    /// `ConversationStore`, keyed by routing peer ID. Serves the coordinator
    /// reads that genuinely need the whole dictionary (migration scans,
    /// unread resolution); simple per-peer reads go through
    /// `privateMessages(for:)` instead. All mutations go through the
    /// private-chat intent ops below. Rebuilt per access —
    /// O(#conversations) thanks to COW message arrays; measured equal to a
    /// change-invalidated cache on `pipeline.privateIngest`, so the simpler
    /// form wins.
    @MainActor
    var privateChats: [PeerID: [BitchatMessage]] {
        conversations.directMessagesByRoutingPeerID()
    }
    @MainActor
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
    /// Read-only derived view of the store's unread direct conversations.
    /// Mutate via `markPrivateChatUnread(_:)` / `markPrivateChatRead(_:)`.
    @MainActor
    var unreadPrivateMessages: Set<PeerID> {
        conversations.unreadDirectRoutingPeerIDs()
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

    // MARK: - Services and Storage

    let meshService: Transport
    let idBridge: NostrIdentityBridge
    let identityManager: SecureIdentityStateManagerProtocol
    /// Single source of truth for conversation message state and selection
    /// (docs/CONVERSATION-STORE-DESIGN.md). Owned by `AppRuntime` and passed
    /// through.
    let conversations: ConversationStore
    let peerIdentityStore: PeerIdentityStore
    let locationPresenceStore: LocationPresenceStore
    let locationManager: LocationChannelManager

    var nostrRelayManager: NostrRelayManager?
    private let userDefaults = UserDefaults.standard
    let keychain: KeychainManagerProtocol
    /// Private group membership: keys in the keychain, metadata on disk.
    let groupStore: GroupStore
    private let nicknameKey = "bitchat.nickname"
    // Location channel state (macOS supports manual geohash selection)
    var activeChannel: ChannelID {
        get { conversations.activeChannel }
        set {
            guard conversations.activeChannel != newValue else { return }
            // Leaving a channel expedites any in-flight NIP-13 mining: the
            // pending message still sends, at the difficulty already reached.
            outgoingCoordinator.expeditePendingGeohashMining()
            conversations.setActiveChannel(newValue)
            visibleMessagesCache = nil
            objectWillChange.send()
        }
    }
    // Single-writer: mutate only via `setGeoChatSubscriptionID(_:)` / `setGeoDmSubscriptionID(_:)` below.
    private(set) var geoSubscriptionID: String? = nil
    private(set) var geoDmSubscriptionID: String? = nil
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
    var blockedUsers: Set<String> { unifiedPeerService.blockedUsers }

    // MARK: - Encryption and Security

    var verifiedFingerprints: Set<String> {
        get { peerIdentityStore.verifiedFingerprints }
        set { peerIdentityStore.setVerifiedFingerprints(newValue) }
    }  // Set of verified fingerprints

    // Bluetooth state management
    @Published var showBluetoothAlert = false
    @Published var bluetoothAlertMessage = ""
    @Published var bluetoothState: CBManagerState = .unknown

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
    // Single-writer: mutate only via `addGeoSamplingSub` / `removeGeoSamplingSub` / `clearGeoSamplingSubs` below.
    private(set) var geoSamplingSubs: [String: String] = [:] // subID -> geohash
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
    // Single-writer: mutate only via `setPublicBatching(_:)` below.
    @Published private(set) var isBatchingPublic: Bool = false

    // Backing store for `sentReadReceipts` persistence. `.standard` in
    // production; injectable so tests can use a scratch suite that does not
    // leak state between runs.
    let readReceiptsDefaults: UserDefaults

    /// Default read-receipt persistence store. Production uses `.standard`.
    /// Under test, every instance gets its own scratch suite: a per-process
    /// shared suite let one test's persisted receipts leak into another
    /// test's freshly constructed view model (surfaced as an order-dependent
    /// CI flake on a duplicated message ID), and tests never pollute
    /// `.standard`.
    static func defaultReadReceiptsDefaults() -> UserDefaults {
        guard TestEnvironment.isRunningTests else { return .standard }
        let suiteName = "chat.bitchat.tests.readReceipts.\(UUID().uuidString)"
        guard let scratch = UserDefaults(suiteName: suiteName) else { return .standard }
        scratch.removePersistentDomain(forName: suiteName)
        return scratch
    }

    // Track sent read receipts to avoid duplicates (persisted across launches)
    // Note: Persistence happens automatically in didSet, no lifecycle observers needed
    var sentReadReceipts: Set<String> = [] {  // messageID set
        didSet {
            // Only persist if there are changes
            guard oldValue != sentReadReceipts else { return }

            // Persist whenever it changes (no manual synchronize/verify re-read)
            if let data = try? JSONEncoder().encode(Array(sentReadReceipts)) {
                readReceiptsDefaults.set(data, forKey: "sentReadReceipts")
            } else {
                SecureLogger.error("❌ Failed to encode read receipts for persistence", category: .session)
            }
        }
    }

    // Track which GeoDM messages we've already sent a delivery ACK for (by messageID)
    // Single-writer: mutate only via `markGeoDeliveryAckSent(_:)` below.
    private(set) var sentGeoDeliveryAcks: Set<String> = []

    // Track app startup phase to prevent marking old messages as unread
    var isStartupPhase = true

    // ConversationStore field audit bookkeeping (see auditConversationStore()):
    // runs on the read-receipt cleanup cadence, heartbeat sampled first +
    // every `TransportConfig.conversationStoreAuditLogInterval`th audit.
    private var storeAuditCount = 0
    private var storeAuditLastAppendCount = 0
    // Announce Tor initial readiness once per launch to avoid duplicates
    var torInitialReadyAnnounced: Bool = false

    // Track Nostr pubkey mappings for unknown senders
    // Single-writer: mutate only via `registerNostrKeyMapping` / `removeNostrKeyMappings` below.
    private(set) var nostrKeyMapping: [PeerID: String] = [:]  // senderPeerID -> nostrPubkey

    // MARK: - Single-Writer Intent Operations
    // Owner-side mutation paths for state the coordinator contexts may read
    // but not write directly. Each op is the sole way to mutate its backing
    // state, so check-then-mutate races between coordinators cannot occur.

    /// Records the Nostr pubkey behind a (possibly virtual) peer ID.
    @MainActor
    func registerNostrKeyMapping(_ pubkey: String, for peerID: PeerID) {
        nostrKeyMapping[peerID] = pubkey
    }

    /// Drops every key mapping that resolves to the given (lowercased) Nostr pubkey.
    @MainActor
    func removeNostrKeyMappings(matchingPubkeyHexLowercased hex: String) {
        for (key, value) in nostrKeyMapping where value.lowercased() == hex {
            nostrKeyMapping.removeValue(forKey: key)
        }
    }

    /// Records that a read receipt is being sent for `messageID`.
    /// Returns `false` when one was already recorded — the caller must skip sending.
    @MainActor
    @discardableResult
    func markReadReceiptSent(_ messageID: String) -> Bool {
        sentReadReceipts.insert(messageID).inserted
    }

    /// Records that a GeoDM delivery ACK is being sent for `messageID`.
    /// Returns `false` when one was already recorded — the caller must skip sending.
    @MainActor
    @discardableResult
    func markGeoDeliveryAckSent(_ messageID: String) -> Bool {
        sentGeoDeliveryAcks.insert(messageID).inserted
    }

    /// Forgets that read receipts were sent for `ids` so READ acks can be
    /// re-sent after the peer reconnects.
    @MainActor
    func unmarkReadReceiptsSent(_ ids: [String]) {
        sentReadReceipts.subtract(ids)
    }

    /// Marks read receipts as sent for own messages already delivered/read in
    /// `peerID`'s chat, syncing the chat manager's tracking with the persisted
    /// set. (Wraps the manager's `inout` sync so the raw set never leaks.)
    @MainActor
    func syncReadReceiptsForSentMessages(for peerID: PeerID) {
        privateChatManager.syncReadReceiptsForSentMessages(
            peerID: peerID,
            nickname: nickname,
            externalReceipts: &sentReadReceipts
        )
    }

    /// Drops every recorded read receipt whose message ID is no longer valid.
    /// Returns the number of receipts removed.
    @MainActor
    func pruneSentReadReceipts(keeping validMessageIDs: Set<String>) -> Int {
        let oldCount = sentReadReceipts.count
        sentReadReceipts = sentReadReceipts.intersection(validMessageIDs)
        return oldCount - sentReadReceipts.count
    }

    /// Publishes the public-timeline batching state (UI animation suppression).
    @MainActor
    func setPublicBatching(_ isBatching: Bool) {
        isBatchingPublic = isBatching
    }

    @MainActor
    func setGeoChatSubscriptionID(_ id: String?) {
        geoSubscriptionID = id
    }

    @MainActor
    func setGeoDmSubscriptionID(_ id: String?) {
        geoDmSubscriptionID = id
    }

    @MainActor
    func addGeoSamplingSub(_ subID: String, forGeohash geohash: String) {
        geoSamplingSubs[subID] = geohash
    }

    @MainActor
    func removeGeoSamplingSub(_ subID: String) {
        geoSamplingSubs.removeValue(forKey: subID)
    }

    /// Clears all sampling subscriptions and returns the removed subscription IDs
    /// so the caller can unsubscribe them from the relay manager.
    @MainActor
    func clearGeoSamplingSubs() -> [String] {
        let subIDs = Array(geoSamplingSubs.keys)
        geoSamplingSubs.removeAll()
        return subIDs
    }

    /// Moves the open private chat to `newPeerID` when the current selection is
    /// one of the peer IDs being migrated away (side-effectful: re-targets the
    /// private chat session — fingerprint refresh, read receipts).
    ///
    /// Note: when this runs after a store `migrateConversation`, the store has
    /// already handed the selection itself off to `newPeerID` (and the manager
    /// mirrors it), so a selection that reads `newPeerID` is also re-targeted
    /// to run the session side effects. Selections on unrelated peers are
    /// untouched.
    @MainActor
    func handOffSelectedPrivateChat(from oldPeerIDs: [PeerID], to newPeerID: PeerID) {
        guard oldPeerIDs.contains(where: { selectedPrivateChatPeer == $0 })
                || selectedPrivateChatPeer == newPeerID else { return }
        selectedPrivateChatPeer = newPeerID
    }

    // MARK: - Private Conversation Store Intents
    // The sole mutation paths for private (direct) message state. Each op
    // forwards to the single-writer `ConversationStore`
    // (docs/CONVERSATION-STORE-DESIGN.md); the read-only `privateChats` /
    // `unreadPrivateMessages` views above are derived from the same store.

    /// Appends a private message in timestamp order. Returns `false` when a
    /// message with the same ID is already in that chat (O(1) dedup via the
    /// conversation's ID index).
    @MainActor
    @discardableResult
    func appendPrivateMessage(_ message: BitchatMessage, to peerID: PeerID) -> Bool {
        conversations.append(message, to: .directPeer(peerID))
    }

    /// Replace-or-append a private message by ID (media progress, mirrored
    /// copies); an existing message keeps its timeline position.
    @MainActor
    func upsertPrivateMessage(_ message: BitchatMessage, in peerID: PeerID) {
        conversations.upsertByID(message, in: .directPeer(peerID))
    }

    /// Applies a delivery status to a private message by ID. Returns `false`
    /// when the message is unknown or the update would downgrade the status
    /// (read beats delivered beats sent).
    @MainActor
    @discardableResult
    func setPrivateDeliveryStatus(_ status: DeliveryStatus, forMessageID messageID: String, peerID: PeerID) -> Bool {
        conversations.setDeliveryStatus(status, forMessageID: messageID, in: .directPeer(peerID))
    }

    /// Flags the peer's chat as unread (store unread state).
    @MainActor
    func markPrivateChatUnread(_ peerID: PeerID) {
        conversations.markUnread(.directPeer(peerID))
    }

    /// Clears the peer's unread flag (store unread state only; read-receipt
    /// sending stays in `PrivateChatManager.markAsRead`).
    @MainActor
    func markPrivateChatRead(_ peerID: PeerID) {
        conversations.markRead(.directPeer(peerID))
    }

    /// Empties the peer's chat but keeps the conversation alive (`/clear`).
    @MainActor
    func clearPrivateChat(_ peerID: PeerID) {
        conversations.clear(.directPeer(peerID))
    }

    /// Removes the peer's chat entirely, including unread state.
    @MainActor
    func removePrivateChat(_ peerID: PeerID) {
        conversations.removeConversation(.directPeer(peerID))
    }

    /// Moves all messages from `oldPeerID`'s chat into `newPeerID`'s chat
    /// (ephemeral↔stable peer-ID handoff): dedups by ID, preserves order,
    /// carries unread state, removes the old chat.
    @MainActor
    func migratePrivateChat(from oldPeerID: PeerID, to newPeerID: PeerID) {
        conversations.migrateConversation(from: .directPeer(oldPeerID), to: .directPeer(newPeerID))
    }

    /// A single private chat's timeline, read straight from the store —
    /// an O(1) lookup that skips the `privateChats` dictionary build. The
    /// context protocols' simple per-peer reads dispatch here.
    @MainActor
    func privateMessages(for peerID: PeerID) -> [BitchatMessage] {
        conversations.conversationsByID[.directPeer(peerID)]?.messages ?? []
    }

    /// `true` when any private chat contains a message with `messageID`
    /// (O(1) per conversation via the store's ID indexes).
    @MainActor
    func privateChatsContainMessage(withID messageID: String) -> Bool {
        conversations.directConversationsContainMessage(withID: messageID)
    }

    /// `true` when `peerID`'s chat contains a message with `messageID`.
    @MainActor
    func privateChat(_ peerID: PeerID, containsMessageWithID messageID: String) -> Bool {
        conversations.conversationsByID[.directPeer(peerID)]?.containsMessage(withID: messageID) ?? false
    }

    /// Removes a message by ID from every private chat that contains it,
    /// dropping chats that become empty. Returns the removed message, if any.
    @MainActor
    @discardableResult
    func removePrivateMessage(withID messageID: String) -> BitchatMessage? {
        var removed: BitchatMessage?
        for (id, conversation) in conversations.conversationsByID {
            guard case .direct = id, conversation.containsMessage(withID: messageID) else { continue }
            let message = conversations.removeMessage(withID: messageID, from: id)
            removed = removed ?? message
            if conversation.messages.isEmpty {
                conversations.removeConversation(id)
            }
        }
        return removed
    }

    // MARK: - Public Conversation Store Intents
    // The sole mutation paths for public (mesh/geohash) message state,
    // mirroring the private intents above. The store's per-conversation cap
    // and timestamp-ordered insert replace `PublicTimelineStore`'s trim and
    // the pipeline's late-insert positioning; the read-only `messages` shim
    // above is derived from the same store.

    /// Appends a public message in timestamp order. Returns `false` when a
    /// message with the same ID is already in that conversation (O(1) dedup
    /// via the conversation's ID index).
    @MainActor
    @discardableResult
    func appendPublicMessage(_ message: BitchatMessage, to conversationID: ConversationID) -> Bool {
        conversations.append(message, to: conversationID)
    }

    /// Appends a geohash message if absent. Returns `true` when stored
    /// (the legacy `PublicTimelineStore.appendIfAbsent` contract).
    @MainActor
    @discardableResult
    func appendGeohashMessageIfAbsent(_ message: BitchatMessage, toGeohash geohash: String) -> Bool {
        conversations.append(message, to: .geohash(geohash.lowercased()))
    }

    /// A public (mesh/geohash) channel's full timeline.
    @MainActor
    func publicMessages(for channel: ChannelID) -> [BitchatMessage] {
        conversations.conversation(for: ConversationID(channelID: channel)).messages
    }

    /// `true` when the conversation contains a message with `messageID`.
    @MainActor
    func publicConversationContainsMessage(withID messageID: String, in conversationID: ConversationID) -> Bool {
        conversations.conversationsByID[conversationID]?.containsMessage(withID: messageID) ?? false
    }

    @MainActor
    func bridgeInjectedPublicMessageIsPresent(withID messageID: String) -> Bool {
        publicMessagePipeline.containsMessage(withID: messageID) ||
            publicConversationContainsMessage(withID: messageID, in: .mesh)
    }

    /// Removes a message by ID from whichever public conversation contains
    /// it. Returns the removed message, if any.
    @MainActor
    @discardableResult
    func removePublicMessage(withID messageID: String) -> BitchatMessage? {
        publicMessagePipeline.removeMessage(withID: messageID)
        return conversations.removePublicMessage(withID: messageID)
    }

    /// Replaces an unauthenticated bridge alias with a later authenticated
    /// radio row. In addition to both storage layers, clear the content-window
    /// marker written by an already-flushed alias or it would suppress the
    /// genuine row during the next public-message batch.
    @MainActor
    func removeBridgeInjectedPublicMessage(withID messageID: String) {
        publicMessagePipeline.removeMessage(withID: messageID)
        guard let removed = conversations.removePublicMessage(withID: messageID) else { return }
        deduplicationService.forgetContent(removed.content, ifRecordedAt: removed.timestamp)
    }

    /// Removes every message matching `predicate` from a geohash
    /// conversation (block-user purge).
    @MainActor
    func removePublicMessages(fromGeohash geohash: String, where predicate: (BitchatMessage) -> Bool) {
        conversations.removeMessages(from: .geohash(geohash.lowercased()), where: predicate)
    }

    /// Empties a public conversation's timeline (`/clear`).
    @MainActor
    func clearPublicConversation(_ conversationID: ConversationID) {
        conversations.clear(conversationID)
    }

    /// Queues a system message for the next geohash channel visit. (Tiny
    /// UI-flow queue formerly on `PublicTimelineStore`; it is notice text,
    /// not conversation state, so it stays on the owner.)
    @MainActor
    func queueGeohashSystemMessage(_ content: String) {
        pendingGeohashSystemMessages.append(content)
    }

    /// Drains the queued geohash system messages (single consumer:
    /// `GeohashSubscriptionManager.switchLocationChannel`).
    @MainActor
    func drainPendingGeohashSystemMessages() -> [String] {
        defer { pendingGeohashSystemMessages.removeAll(keepingCapacity: false) }
        return pendingGeohashSystemMessages
    }

    // Single-writer: mutate only via `queueGeohashSystemMessage(_:)` /
    // `drainPendingGeohashSystemMessages()` above.
    private var pendingGeohashSystemMessages: [String] = []

    // MARK: - Initialization

    @MainActor
    convenience init(
        keychain: KeychainManagerProtocol,
        idBridge: NostrIdentityBridge,
        identityManager: SecureIdentityStateManagerProtocol,
        conversations: ConversationStore? = nil,
        peerIdentityStore: PeerIdentityStore? = nil,
        locationPresenceStore: LocationPresenceStore? = nil,
        locationManager: LocationChannelManager = .shared
    ) {
        let meshService = BLEService(keychain: keychain, idBridge: idBridge, identityManager: identityManager)
        meshService.sfMetrics = .shared
        self.init(
            keychain: keychain,
            idBridge: idBridge,
            identityManager: identityManager,
            transport: meshService,
            conversations: conversations,
            peerIdentityStore: peerIdentityStore ?? PeerIdentityStore(),
            locationPresenceStore: locationPresenceStore ?? LocationPresenceStore(),
            locationManager: locationManager,
            outboxStore: MessageOutboxStore(keychain: keychain),
            sfMetrics: .shared
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
        conversations: ConversationStore? = nil,
        peerIdentityStore: PeerIdentityStore? = nil,
        locationPresenceStore: LocationPresenceStore? = nil,
        locationManager: LocationChannelManager = .shared,
        readReceiptsDefaults: UserDefaults? = nil,
        outboxStore: MessageOutboxStore? = nil,
        sfMetrics: StoreAndForwardMetrics? = nil
    ) {
        let conversations = conversations ?? ConversationStore()
        let peerIdentityStore = peerIdentityStore ?? PeerIdentityStore()
        let locationPresenceStore = locationPresenceStore ?? LocationPresenceStore()
        let services = ChatViewModelServiceBundle(
            keychain: keychain,
            idBridge: idBridge,
            identityManager: identityManager,
            meshService: transport,
            outboxStore: outboxStore,
            sfMetrics: sfMetrics
        )

        self.keychain = keychain
        self.groupStore = GroupStore(keychain: keychain)
        self.idBridge = idBridge
        self.identityManager = identityManager
        self.conversations = conversations
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
        let readReceiptsDefaults = readReceiptsDefaults ?? Self.defaultReadReceiptsDefaults()
        self.readReceiptsDefaults = readReceiptsDefaults
        self.sentReadReceipts = ChatViewModelBootstrapper.loadPersistedReadReceipts(userDefaults: readReceiptsDefaults)

        // Republish on every store change so SwiftUI observers of the
        // view model refresh. This replaces the UI-update role of the old
        // `PrivateChatManager.@Published` dictionaries and the old
        // `@Published var messages`. Changes touching the ACTIVE public
        // conversation also invalidate the derived `messages` cache before
        // observers re-read it.
        conversations.changes
            .sink { [weak self] change in
                guard let self else { return }
                if self.changeAffectsActivePublicConversation(change) {
                    self.visibleMessagesCache = nil
                }
                self.objectWillChange.send()
            }
            .store(in: &cancellables)

        ChatViewModelBootstrapper(viewModel: self).configure()
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
        peerIdentityCoordinator.hasUnreadMessages(for: peerID)
    }

    @MainActor
    func toggleFavorite(peerID: PeerID) {
        peerIdentityCoordinator.toggleFavorite(peerID: peerID)
    }

    @MainActor
    func isFavorite(peerID: PeerID) -> Bool {
        peerIdentityCoordinator.isFavorite(peerID: peerID)
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

    /// Sends a 👋 to the mesh channel regardless of the active channel.
    @MainActor
    func sendMeshWave() {
        outgoingCoordinator.sendMeshWave()
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

    // Mesh (Noise identity) block helpers. Unlike the `/block <nickname>`
    // command, these resolve and persist the block by the peer's stable
    // fingerprint (derived from `peerID`), so the exact tapped peer is
    // (un)blocked — unambiguous across nickname collisions and functional for
    // offline peers that can no longer be resolved through the mesh service.
    @MainActor
    func blockMeshPeer(peerID: PeerID, displayName: String) {
        setMeshPeerBlocked(peerID, blocked: true, displayName: displayName)
    }

    @MainActor
    func unblockMeshPeer(peerID: PeerID, displayName: String) {
        setMeshPeerBlocked(peerID, blocked: false, displayName: displayName)
    }

    @MainActor
    private func setMeshPeerBlocked(_ peerID: PeerID, blocked: Bool, displayName: String) {
        guard unifiedPeerService.setBlocked(peerID, blocked: blocked) != nil else {
            addCommandOutput(
                String(
                    format: String(
                        localized: blocked ? "system.mesh.block_failed" : "system.mesh.unblock_failed",
                        comment: "System message shown when a mesh peer cannot be blocked or unblocked"
                    ),
                    locale: .current,
                    displayName
                )
            )
            return
        }
        addCommandOutput(
            String(
                format: String(
                    localized: blocked ? "system.mesh.blocked" : "system.mesh.unblocked",
                    comment: "System message shown when a mesh peer is blocked or unblocked"
                ),
                locale: .current,
                displayName
            )
        )
    }

    func displayNameForNostrPubkey(_ pubkeyHex: String) -> String {
        publicConversationCoordinator.displayNameForNostrPubkey(pubkeyHex)
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
        appendPrivateMessage(systemMessage, to: peerID)
        objectWillChange.send()
    }

    // MARK: - Bluetooth State Management

    /// Updates the Bluetooth state and shows appropriate alerts
    /// - Parameter state: The current Bluetooth manager state
    @MainActor
    func updateBluetoothState(_ state: CBManagerState) {
        bluetoothState = state
        let alertUpdate = ChatBluetoothAlertPolicy.update(for: state)
        showBluetoothAlert = alertUpdate.isPresented
        if let message = alertUpdate.message {
            bluetoothAlertMessage = message
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
    @objc func handlePeerStatusUpdate(_: Notification) {
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
    func markPrivateMessagesAsRead(from peerID: PeerID) {
        lifecycleCoordinator.markPrivateMessagesAsRead(from: peerID)
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

        // Clear all messages (public timelines and private chats live in the
        // single-writer ConversationStore; the derived `messages` view and
        // the legacy mirror empty with it)
        conversations.clearAll()
        pendingGeohashSystemMessages.removeAll()

        // Delete all keychain data (including Noise and Nostr keys)
        _ = keychain.deleteAllKeychainData()

        // Clear UserDefaults identity data
        userDefaults.removeObject(forKey: "bitchat.noiseIdentityKey")
        userDefaults.removeObject(forKey: "bitchat.messageRetentionKey")

        // Wipe persisted location state (selected channel, teleport set,
        // bookmarks). For an activist-safety wipe, where the user has been is
        // exactly the data an adversary inspecting the device wants.
        LocationStateManager.shared.panicWipe()

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

        // Drop courier mail carried for third parties (memory and disk),
        // our own queued outbox, the carried public history, and the
        // counters describing all of it
        CourierStore.shared.wipe()
        BridgeCourierService.shared.wipe()
        messageRouter.wipeOutbox()
        GossipMessageArchive.wipeDefault()
        StoreAndForwardMetrics.shared.reset()

        // Ambient-liveliness bookkeeping: sampled nearby-chat previews, the
        // daily sightings tally, and the echoes-dismissed watermark
        GeohashChatActivityTracker.shared.clear()
        MeshSightingsTracker.shared.clear()
        MeshEchoSettings.reset()

        // Drop private group keys and rosters (keychain + disk)
        groupStore.wipe()
        // Drop cached peers' prekey bundles (who we could write to is
        // metadata too). Our own prekey privates are keychain-backed and go
        // with deleteAllKeychainData above plus the identity reset below.
        PrekeyBundleStore.shared.wipe()
        // Drop bulletin-board posts and tombstones (memory and disk); board
        // posts are signed with our identity key and persist for days.
        BoardStore.shared.wipe()

        // Identity manager has cleared persisted identity data above

        // Clear autocomplete state
        autocompleteSuggestions.removeAll()
        showAutocomplete = false
        autocompleteRange = nil
        selectedAutocompleteIndex = 0

        // Clear selected private chat
        selectedPrivateChatPeer = nil

        // Clear live location/geohash session state. Persisted location state
        // was wiped above, but the running view model can still be scoped to a
        // geohash channel and hold subscriptions tied to the old Nostr identity.
        activeChannel = .mesh
        setGeoChatSubscriptionID(nil)
        setGeoDmSubscriptionID(nil)
        _ = clearGeoSamplingSubs()
        cachedGeohashIdentity = nil
        nostrKeyMapping.removeAll()

        // Clear read receipt tracking
        sentReadReceipts.removeAll()
        deduplicationService.clearAll()

        // IMPORTANT: Clear Nostr-related state
        // Drop relay subscriptions, handlers, pending sends, and replay state.
        // Geohash DM handlers can capture pre-wipe Nostr identities, so a plain
        // disconnect is not enough here.
        NostrRelayManager.shared.resetForPanicWipe()
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
        // This will generate new Nostr keys derived from new Noise keys.
        // Skipped under tests: connecting the shared relay singleton starts
        // real network/reconnect work that never completes and would keep the
        // test process alive (the singleton, unlike a discardable instance, is
        // never deallocated to cancel it).
        if !TestEnvironment.isRunningTests {
            Task { @MainActor in
                // Small delay to ensure cleanup completes
                try? await Task.sleep(nanoseconds: TransportConfig.uiAsyncShortSleepNs) // 0.1 seconds

                // Reinitialize Nostr relay manager with new identity. Reuse the
                // shared singleton — every other component (NostrTransport, geohash
                // subscriptions, AppRuntime observers) is bound to `.shared`, so
                // creating a fresh instance here would split relay state and leave
                // sends running against a disconnected manager.
                nostrRelayManager = NostrRelayManager.shared
                setupNostrMessageHandling()
                nostrRelayManager?.connect()
            }
        }

        // Delete ALL media files (incoming and outgoing) in background
        Task.detached(priority: .utility) {
            // Skipped under tests: the test process shares the user's real
            // ~/Library/Application Support/files tree, and this detached
            // utility-priority wipe fires at a nondeterministic time —
            // deleting media that concurrently running tests (e.g. the
            // sendImage flow) just wrote there, and the developer's real
            // app data with it.
            guard !TestEnvironment.isRunningTests else { return }
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
    func formatMessageAsText(_ message: BitchatMessage, colorScheme: ColorScheme, theme: AppTheme? = nil) -> AttributedString {
        messageFormatter.formatMessageAsText(message, colorScheme: colorScheme, theme: theme ?? currentTheme)
    }

    @MainActor
    func formatMessageHeader(_ message: BitchatMessage, colorScheme: ColorScheme, theme: AppTheme? = nil) -> AttributedString {
        messageFormatter.formatMessageHeader(message, colorScheme: colorScheme, theme: theme ?? currentTheme)
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

    /// Invalidates the derived `messages` cache and notifies observers.
    /// (Formerly pulled the channel's timeline into a stored `messages`
    /// array; `messages` is now derived from the `ConversationStore`, so
    /// only the invalidation remains. The `channel` parameter is kept for
    /// call-site compatibility — every caller passes the active channel.)
    @MainActor
    func refreshVisibleMessages(from channel: ChannelID? = nil) {
        visibleMessagesCache = nil
        objectWillChange.send()
    }

    /// `true` when a store change touches the active public conversation
    /// (so the derived `messages` cache must be invalidated).
    @MainActor
    private func changeAffectsActivePublicConversation(_ change: ConversationChange) -> Bool {
        let activeID = ConversationID(channelID: activeChannel)
        switch change {
        case .appended(let id, _),
             .updated(let id, _),
             .statusChanged(let id, _, _),
             .messageRemoved(let id, _),
             .cleared(let id),
             .removed(let id),
             .unreadChanged(let id, _):
            return id == activeID
        case .migrated(let source, let destination):
            return source == activeID || destination == activeID
        }
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
        vouchCoordinator.setupNoiseCallbacks()
    }

    /// Whether the fingerprint currently counts as vouched (≥1 valid vouch
    /// from a voucher I verified, and no explicit verification of mine).
    @MainActor
    func isVouchedFingerprint(_ fingerprint: String) -> Bool {
        identityManager.isVouched(fingerprint: fingerprint)
    }

    // MARK: - BitchatDelegate Methods

    // MARK: - Command Handling

    /// Processes IRC-style commands starting with '/'.
    /// - Parameter command: The full command string including the leading slash
    /// - Note: Supports commands like /msg, /who, /slap, /clear, /help
    @MainActor
    func handleCommand(_ command: String) {
        let result = commandProcessor.process(command)

        switch result {
        case .success(let message):
            if let msg = message {
                addCommandOutput(msg)
            }
        case .error(let message):
            addCommandOutput(message)
        case .handled:
            // Command was handled, no message needed
            break
        }
    }

    /// Command output belongs in the conversation where the user typed the
    /// command; the public timeline is invisible while a DM is open. The DM
    /// selection is read *after* processing so commands that switch chats
    /// (`/msg`) print into the conversation they just opened.
    @MainActor
    private func addCommandOutput(_ content: String) {
        if let peerID = selectedPrivateChatPeer {
            addLocalPrivateSystemMessage(content, to: peerID)
        } else {
            addSystemMessage(content)
        }
    }

    /// Origin conversation for deferred command output, captured when the
    /// command is issued (before any async work starts).
    @MainActor
    func currentCommandDestination() -> CommandOutputDestination {
        if let peerID = selectedPrivateChatPeer {
            return .privateChat(peerID)
        }
        // Deferring commands (/ping) are rejected in geohash channels, so a
        // non-DM origin is always the #mesh timeline.
        return .meshTimeline
    }

    /// Routes deferred command output (async /ping results) into the
    /// conversation captured at issue time, immune to chat switches in the
    /// meantime. A DM result lands in the origin chat's history even if that
    /// chat is no longer selected (or was cleared — it then reappears as the
    /// first message when the chat is reopened).
    @MainActor
    func addCommandOutput(_ content: String, to destination: CommandOutputDestination) {
        switch destination {
        case .privateChat(let peerID):
            addLocalPrivateSystemMessage(content, to: peerID)
        case .meshTimeline:
            publicConversationCoordinator.addMeshOnlySystemMessage(content)
        }
    }

    // MARK: - Message Reception

    @MainActor
    func didReceiveTransportEvent(_ event: TransportEvent) {
        receiveTransportEvent(event)
    }

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

    func didReceiveGroupMessage(payload: Data, timestamp: Date) {
        Task { @MainActor [weak self] in
            self?.groupCoordinator.handleGroupMessagePayload(payload, timestamp: timestamp)
        }
    }

    func didReceivePublicVoiceFrame(from peerID: PeerID, nickname: String, payload: Data, timestamp: Date) {
        Task { @MainActor [weak self] in
            self?.liveVoiceCoordinator.handlePublicVoiceFramePayload(
                from: peerID,
                nickname: nickname,
                payload: payload,
                timestamp: timestamp
            )
        }
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
        // A peer-list update follows every verified announce, which is where a
        // peer's `.vouch` capability actually arrives — retry vouching now that
        // capabilities may finally be known (closes the auth-time capability race).
        Task { @MainActor [weak self] in
            self?.vouchCoordinator.peersUpdated(peers)
        }
    }

    @MainActor
    func cleanupOldReadReceipts() {
        deliveryCoordinator.cleanupOldReadReceipts()
        auditConversationStore()
    }

    /// Periodic on-device verification of the `ConversationStore`'s
    /// correctness invariants, piggybacked on the read-receipt cleanup
    /// cadence (peer-list updates) so no extra timer exists. Loud on
    /// violation (one error line each), near-silent when healthy (sampled
    /// heartbeat: first + every Nth audit). The audit is O(total messages)
    /// and allocation-free while healthy — measured ~0.5 ms at 5k messages
    /// (see `PerformanceBaselineTests.testConversationStoreAudit`), cheap
    /// relative to its cadence, so it always runs.
    @MainActor
    private func auditConversationStore() {
        storeAuditCount += 1
        let violations = conversations.auditInvariants()
        guard violations.isEmpty else {
            for violation in violations {
                SecureLogger.error("🚨 ConversationStore invariant violated: \(violation)", category: .session)
            }
            return
        }
        let appendCount = conversations.appendCount
        if storeAuditCount == 1 || storeAuditCount.isMultiple(of: TransportConfig.conversationStoreAuditLogInterval) {
            SecureLogger.debug(
                "Store audit OK: \(conversations.conversationsByID.count) conversations, \(conversations.totalMessageCount) messages, map=\(conversations.messageIDMapCount), appends since last audit=\(appendCount - storeAuditLastAppendCount)",
                category: .session
            )
        }
        storeAuditLastAppendCount = appendCount
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

    /// Add a local system message to one specific geohash timeline, active or
    /// not. Used by the board's new-pin alerts to scope-match the pin's channel.
    @MainActor
    func addGeohashSystemMessage(_ content: String, geohash: String) {
        let systemMessage = BitchatMessage(
            sender: "system",
            content: content,
            timestamp: Date(),
            isRelay: false
        )
        appendGeohashMessageIfAbsent(systemMessage, toGeohash: geohash)
    }
    // Send a public message without adding a local user echo.
    // Used for emotes where we want a local system-style confirmation instead.
    @MainActor
    func sendPublicRaw(_ content: String) {
        publicConversationCoordinator.sendPublicRaw(content)
    }

    // Send a normal public message (with local echo) to the active channel.
    // CommandContextProvider hook for commands that post real messages
    // (`/pay`); only called when no private chat is selected.
    @MainActor
    func sendPublicMessage(_ content: String) {
        sendMessage(content)
    }

    /// Handle incoming public message
    @MainActor
    func handlePublicMessage(_ message: BitchatMessage) {
        // Bridge hints are unauthenticated and may never suppress a genuine
        // BLE sender. Once the radio packet has passed BLE signature checks,
        // replace any earlier bridge alias before this row is enqueued.
        if !message.isBridged,
           let senderPeerID = message.senderPeerID,
           !senderPeerID.isGeoChat {
            BridgeService.shared.handleAuthenticatedRadioMessage(messageID: message.id)
        }
        // A finalized voice note whose burst already streamed in live swaps
        // into the existing bubble instead of appearing twice.
        if liveVoiceCoordinator.absorbFinalizedVoiceNote(message) { return }
        publicConversationCoordinator.handlePublicMessage(message)
    }

    /// Handle an incoming public Nostr message with its validated NIP-13
    /// difficulty; sufficient PoW relaxes the per-sender rate limit.
    @MainActor
    func handlePublicMessage(_ message: BitchatMessage, powBits: Int) {
        publicConversationCoordinator.handlePublicMessage(message, powBits: powBits)
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
