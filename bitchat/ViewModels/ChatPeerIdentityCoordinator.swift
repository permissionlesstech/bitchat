import BitFoundation
import BitLogger
import CoreBluetooth
import Foundation

/// The narrow surface `ChatPeerIdentityCoordinator` needs from its owner.
///
/// Follows the `ChatDeliveryContext` exemplar: the coordinator depends on the
/// minimal context it actually uses instead of holding an `unowned` back-ref
/// to the whole `ChatViewModel`. This keeps the coordinator independently
/// testable (see `ChatPeerIdentityCoordinatorContextTests`) and makes its true
/// dependencies explicit. Several members are flattened service accesses —
/// this coordinator implements the `ChatViewModel`-level peer-identity API, so
/// its context members deliberately sit one level below those wrappers
/// (`unifiedIsBlocked(_:)` vs `isPeerBlocked(_:)`, `unifiedFingerprint(for:)`
/// vs `getFingerprint(for:)`, …) to avoid call cycles.
@MainActor
protocol ChatPeerIdentityContext: AnyObject {
    // MARK: Conversation state
    var privateChats: [PeerID: [BitchatMessage]] { get }
    /// A single private chat's timeline. Witnessed by the store-direct
    /// lookup on `ChatViewModel` (no `privateChats` dictionary build).
    func privateMessages(for peerID: PeerID) -> [BitchatMessage]
    var unreadPrivateMessages: Set<PeerID> { get }
    /// Clears the peer's unread flag (single-writer store intent).
    func markPrivateChatRead(_ peerID: PeerID)
    /// Moves all messages from `oldPeerID`'s chat into `newPeerID`'s chat
    /// (dedup by ID, order preserved, unread carried, old chat removed).
    func migratePrivateChat(from oldPeerID: PeerID, to newPeerID: PeerID)
    var selectedPrivateChatPeer: PeerID? { get set }
    var selectedPrivateChatFingerprint: String? { get set }
    var myPeerID: PeerID { get }
    var activeChannel: ChannelID { get }
    /// Signals that message state changed so observers refresh (e.g. `objectWillChange.send()`).
    func notifyUIChanged()
    func addSystemMessage(_ content: String)

    // MARK: Private chat session lifecycle
    /// Merges messages stored under alternate peer-ID representations into `peerID`'s chat.
    /// Returns `true` when unread messages were discovered during consolidation.
    @discardableResult
    func consolidatePrivateMessages(for peerID: PeerID, peerNickname: String) -> Bool
    /// Marks read receipts as sent for own messages already delivered/read in
    /// `peerID`'s chat. (Single mutation path into the owner's
    /// `sentReadReceipts`; this coordinator never touches the raw set.)
    func syncReadReceiptsForSentMessages(for peerID: PeerID)
    /// Re-targets the private chat session: selection mutates through the
    /// `ConversationStore` intent (the store owns selection).
    func beginPrivateChatSession(with peerID: PeerID)
    func markPrivateMessagesAsRead(from peerID: PeerID)

    // MARK: Unified peer service
    var connectedPeers: Set<PeerID> { get }
    /// The peer's current entry in the unified peer service, if known.
    func unifiedPeer(for peerID: PeerID) -> BitchatPeer?
    func unifiedIsBlocked(_ peerID: PeerID) -> Bool
    func unifiedToggleFavorite(_ peerID: PeerID)
    func unifiedFingerprint(for peerID: PeerID) -> String?
    func unifiedPeerID(forNickname nickname: String) -> PeerID?
    /// Resolves the ephemeral (short) peer ID for a known Noise public key, if connected.
    func ephemeralPeerID(forNoiseKey noiseKey: Data) -> PeerID?

    // MARK: Mesh & Noise sessions
    func peerNickname(for peerID: PeerID) -> String?
    func meshPeerNicknames() -> [PeerID: String]
    func noiseSessionState(for peerID: PeerID) -> LazyHandshakeState
    func triggerHandshake(with peerID: PeerID)
    func hasEstablishedNoiseSession(with peerID: PeerID) -> Bool
    func hasNoiseSession(with peerID: PeerID) -> Bool
    /// Our own Noise identity fingerprint.
    func noiseIdentityFingerprint() -> String

    // MARK: Identity store (fingerprints & encryption status)
    func setStoredFingerprint(_ fingerprint: String, for peerID: PeerID)
    /// Moves the stored fingerprint mapping from `oldPeerID` to `newPeerID`,
    /// falling back to `fallback` when none was stored. Returns the migrated fingerprint.
    func migrateFingerprintMapping(from oldPeerID: PeerID, to newPeerID: PeerID, fallback: String?) -> String?
    func isVerifiedFingerprint(_ fingerprint: String) -> Bool
    func setEncryptionStatus(_ status: EncryptionStatus?, for peerID: PeerID)
    func cachedEncryptionStatus(for peerID: PeerID) -> EncryptionStatus?
    func setCachedEncryptionStatus(_ status: EncryptionStatus, for peerID: PeerID)
    func invalidateStoredEncryptionCache(for peerID: PeerID?)
    func socialIdentity(forFingerprint fingerprint: String) -> SocialIdentity?

    // MARK: Favorites
    /// The persisted favorite relationship for the peer's Noise static key, if any.
    func favoriteRelationship(forNoiseKey noiseKey: Data) -> FavoritesPersistenceService.FavoriteRelationship?
    /// The persisted favorite relationship for a short (ephemeral) peer ID, if any.
    func favoriteRelationship(forPeerID peerID: PeerID) -> FavoritesPersistenceService.FavoriteRelationship?
    /// Adds (or updates) a favorite in the favorites store.
    func addFavorite(noiseKey: Data, nostrPublicKey: String?, nickname: String)
    /// Removes a favorite from the favorites store.
    func removeFavorite(noiseKey: Data)

    // MARK: Geohash & Nostr
    var geoNicknames: [String: String] { get }
    func visibleGeohashPeople() -> [GeoPerson]
    /// Records the Nostr pubkey behind a (possibly virtual) peer ID.
    func registerNostrKeyMapping(_ pubkey: String, for peerID: PeerID)
    func bridgedNostrPublicKey(for noiseKey: Data) -> String?
    func sendFavoriteNotificationViaNostr(noisePublicKey: Data, isFavorite: Bool)
}

extension ChatViewModel: ChatPeerIdentityContext {
    // `privateChats`, `unreadPrivateMessages`, `selectedPrivateChatPeer`,
    // `selectedPrivateChatFingerprint`, `myPeerID`,
    // `activeChannel`, `connectedPeers`, `geoNicknames`, `notifyUIChanged()`,
    // `addSystemMessage(_:)`, `peerNickname(for:)`, `meshPeerNicknames()`,
    // `ephemeralPeerID(forNoiseKey:)`, `unifiedPeer(for:)`,
    // `registerNostrKeyMapping(_:for:)`, `visibleGeohashPeople()`,
    // `markPrivateMessagesAsRead(from:)`, `sendFavoriteNotificationViaNostr`,
    // and the conversation-store sync methods are shared requirements with
    // the other contexts or satisfied by existing `ChatViewModel` members.
    // The single-writer intent op `syncReadReceiptsForSentMessages(for:)`
    // lives next to its backing state in `ChatViewModel`. The members below
    // flatten nested service accesses into intent-named calls.

    @discardableResult
    func consolidatePrivateMessages(for peerID: PeerID, peerNickname: String) -> Bool {
        privateChatManager.consolidateMessages(
            for: peerID,
            peerNickname: peerNickname,
            persistedReadReceipts: sentReadReceipts
        )
    }

    func beginPrivateChatSession(with peerID: PeerID) {
        privateChatManager.startChat(with: peerID)
    }

    func unifiedIsBlocked(_ peerID: PeerID) -> Bool {
        unifiedPeerService.isBlocked(peerID)
    }

    func unifiedToggleFavorite(_ peerID: PeerID) {
        unifiedPeerService.toggleFavorite(peerID)
    }

    func unifiedFingerprint(for peerID: PeerID) -> String? {
        unifiedPeerService.getFingerprint(for: peerID)
    }

    func unifiedPeerID(forNickname nickname: String) -> PeerID? {
        unifiedPeerService.getPeerID(for: nickname)
    }

    func noiseSessionState(for peerID: PeerID) -> LazyHandshakeState {
        meshService.getNoiseSessionState(for: peerID)
    }

    func triggerHandshake(with peerID: PeerID) {
        meshService.triggerHandshake(with: peerID)
    }

    func hasEstablishedNoiseSession(with peerID: PeerID) -> Bool {
        if case .established = meshService.getNoiseSessionState(for: peerID) { return true }
        return false
    }

    func hasNoiseSession(with peerID: PeerID) -> Bool {
        switch meshService.getNoiseSessionState(for: peerID) {
        case .established, .handshaking: return true
        case .none, .handshakeQueued, .failed: return false
        }
    }

    func noiseIdentityFingerprint() -> String {
        meshService.noiseIdentityFingerprint()
    }

    func setStoredFingerprint(_ fingerprint: String, for peerID: PeerID) {
        peerIdentityStore.setFingerprint(fingerprint, for: peerID)
    }

    func migrateFingerprintMapping(from oldPeerID: PeerID, to newPeerID: PeerID, fallback: String?) -> String? {
        peerIdentityStore.migrateFingerprintMapping(from: oldPeerID, to: newPeerID, fallback: fallback)
    }

    func isVerifiedFingerprint(_ fingerprint: String) -> Bool {
        peerIdentityStore.isVerified(fingerprint)
    }

    func setEncryptionStatus(_ status: EncryptionStatus?, for peerID: PeerID) {
        peerIdentityStore.setEncryptionStatus(status, for: peerID)
    }

    func cachedEncryptionStatus(for peerID: PeerID) -> EncryptionStatus? {
        peerIdentityStore.cachedEncryptionStatus(for: peerID)
    }

    func setCachedEncryptionStatus(_ status: EncryptionStatus, for peerID: PeerID) {
        peerIdentityStore.setCachedEncryptionStatus(status, for: peerID)
    }

    func invalidateStoredEncryptionCache(for peerID: PeerID?) {
        peerIdentityStore.invalidateEncryptionCache(for: peerID)
    }

    func socialIdentity(forFingerprint fingerprint: String) -> SocialIdentity? {
        identityManager.getSocialIdentity(for: fingerprint)
    }

    func bridgedNostrPublicKey(for noiseKey: Data) -> String? {
        idBridge.getNostrPublicKey(for: noiseKey)
    }

    // `favoriteRelationship(forNoiseKey:)` is shared with
    // `ChatPrivateConversationContext`; its witness lives in
    // `ChatPrivateConversationCoordinator.swift`.

    func favoriteRelationship(forPeerID peerID: PeerID) -> FavoritesPersistenceService.FavoriteRelationship? {
        FavoritesPersistenceService.shared.getFavoriteStatus(forPeerID: peerID)
    }

    func addFavorite(noiseKey: Data, nostrPublicKey: String?, nickname: String) {
        FavoritesPersistenceService.shared.addFavorite(
            peerNoisePublicKey: noiseKey,
            peerNostrPublicKey: nostrPublicKey,
            peerNickname: nickname
        )
    }

    func removeFavorite(noiseKey: Data) {
        FavoritesPersistenceService.shared.removeFavorite(peerNoisePublicKey: noiseKey)
    }
}

final class ChatPeerIdentityCoordinator {
    private unowned let context: any ChatPeerIdentityContext

    init(context: any ChatPeerIdentityContext) {
        self.context = context
    }

    @MainActor
    func openMostRelevantPrivateChat() {
        let unreadSorted = context.unreadPrivateMessages
            .map { ($0, context.privateMessages(for: $0).last?.timestamp ?? Date.distantPast) }
            .sorted { $0.1 > $1.1 }
        if let target = unreadSorted.first?.0 {
            startPrivateChat(with: target)
            return
        }

        let recent = context.privateChats
            .map { (id: $0.key, ts: $0.value.last?.timestamp ?? Date.distantPast) }
            .sorted { $0.ts > $1.ts }
        if let target = recent.first?.id {
            startPrivateChat(with: target)
        }
    }

    @MainActor
    func isPeerBlocked(_ peerID: PeerID) -> Bool {
        context.unifiedIsBlocked(peerID)
    }

    @MainActor
    func hasUnreadMessages(for peerID: PeerID) -> Bool {
        var noiseKeyPeerID: PeerID?
        var nostrPeerID: PeerID?

        if let peer = context.unifiedPeer(for: peerID) {
            noiseKeyPeerID = PeerID(hexData: peer.noisePublicKey)
            if let nostrHex = peer.nostrPublicKey {
                nostrPeerID = PeerID(nostr_: nostrHex)
            }
        }

        let unreadContext = ChatUnreadPeerContext(
            peerID: peerID,
            noiseKeyPeerID: noiseKeyPeerID,
            nostrPeerID: nostrPeerID,
            nickname: context.peerNickname(for: peerID)
        )

        return ChatUnreadStateResolver.hasUnreadMessages(
            for: unreadContext,
            unreadPrivateMessages: context.unreadPrivateMessages,
            privateChats: context.privateChats
        )
    }

    @MainActor
    func toggleFavorite(peerID: PeerID) {
        if let noisePublicKey = peerID.noiseKey {
            toggleFavoriteForNoiseKey(noisePublicKey, peerID: peerID)
            return
        }

        context.unifiedToggleFavorite(peerID)
        context.notifyUIChanged()
    }

    @MainActor
    func isFavorite(peerID: PeerID) -> Bool {
        if let noisePublicKey = peerID.noiseKey {
            return context.favoriteRelationship(forNoiseKey: noisePublicKey)?.isFavorite ?? false
        }

        return context.unifiedPeer(for: peerID)?.isFavorite ?? false
    }

    @MainActor
    func updatePrivateChatPeerIfNeeded() {
        guard let chatFingerprint = context.selectedPrivateChatFingerprint,
              let currentPeerID = currentPeerID(forFingerprint: chatFingerprint) else {
            return
        }

        if let oldPeerID = context.selectedPrivateChatPeer, oldPeerID != currentPeerID {
            migrateChatState(from: oldPeerID, to: currentPeerID)
            context.selectedPrivateChatPeer = currentPeerID
        } else if context.selectedPrivateChatPeer == nil {
            context.selectedPrivateChatPeer = currentPeerID
        }

        context.markPrivateChatRead(currentPeerID)
    }

    @MainActor
    func startPrivateChat(with peerID: PeerID) {
        guard peerID != context.myPeerID else { return }

        // Group chats are virtual conversations: no peer identity, favorites,
        // handshake, or message consolidation applies — just select the chat.
        if peerID.isGroup {
            context.selectedPrivateChatFingerprint = nil
            context.beginPrivateChatSession(with: peerID)
            context.markPrivateChatRead(peerID)
            return
        }

        let peerNickname = context.peerNickname(for: peerID) ?? "unknown"

        if context.unifiedIsBlocked(peerID) {
            context.addSystemMessage(
                String(
                    format: String(
                        localized: "system.chat.blocked",
                        comment: "System message when starting chat fails because peer is blocked"
                    ),
                    locale: .current,
                    peerNickname
                )
            )
            return
        }

        // No mutual-favorite gate: store-and-forward (couriers, bridge drops,
        // retained outbox) only needs the recipient's noise key, so an
        // offline non-mutual favorite is still worth writing to — the router
        // decides what delivery looks like, not chat entry.

        _ = context.consolidatePrivateMessages(for: peerID, peerNickname: peerNickname)

        if !peerID.isGeoDM && !peerID.isGeoChat {
            switch context.noiseSessionState(for: peerID) {
            case .none, .failed:
                context.triggerHandshake(with: peerID)
            case .handshakeQueued, .handshaking, .established:
                break
            }
        } else {
            SecureLogger.debug("GeoDM: skipping mesh handshake for virtual peerID=\(peerID)", category: .session)
        }

        context.syncReadReceiptsForSentMessages(for: peerID)

        if let fingerprint = getFingerprint(for: peerID) {
            context.setStoredFingerprint(fingerprint, for: peerID)
            context.selectedPrivateChatFingerprint = fingerprint
        } else {
            context.selectedPrivateChatFingerprint = nil
        }
        context.beginPrivateChatSession(with: peerID)
        context.markPrivateMessagesAsRead(from: peerID)
    }

    @MainActor
    func endPrivateChat() {
        context.selectedPrivateChatPeer = nil
        context.selectedPrivateChatFingerprint = nil
    }

    @MainActor
    func handlePeerStatusUpdate() {
        updatePrivateChatPeerIfNeeded()
    }

    func handleFavoriteStatusChanged(_ notification: Notification) {
        guard let peerPublicKey = notification.userInfo?["peerPublicKey"] as? Data else { return }

        Task { @MainActor [weak context = self.context] in
            guard let context else { return }

            if let isKeyUpdate = notification.userInfo?["isKeyUpdate"] as? Bool,
               isKeyUpdate,
               let oldKey = notification.userInfo?["oldPeerPublicKey"] as? Data {
                migrateNoiseKeyUpdate(
                    oldPeerID: PeerID(hexData: oldKey),
                    newPeerID: PeerID(hexData: peerPublicKey)
                )
            }

            updatePrivateChatPeerIfNeeded()

            if let isFavorite = notification.userInfo?["isFavorite"] as? Bool {
                let peerID = PeerID(hexData: peerPublicKey)
                let action = isFavorite ? "favorited" : "unfavorited"
                let peerNickname = favoriteNotificationNickname(for: peerID, peerPublicKey: peerPublicKey)
                context.addSystemMessage("\(peerNickname) \(action) you")
            }
        }
    }

    @MainActor
    func updateEncryptionStatusForPeers() {
        for peerID in context.connectedPeers {
            updateEncryptionStatus(for: peerID)
        }
    }

    @MainActor
    func updateEncryptionStatus(for peerID: PeerID) {
        if context.hasEstablishedNoiseSession(with: peerID) {
            context.setEncryptionStatus(verifiedEncryptionStatus(for: peerID), for: peerID)
        } else if context.hasNoiseSession(with: peerID) {
            context.setEncryptionStatus(.noiseHandshaking, for: peerID)
        } else {
            context.setEncryptionStatus(nil, for: peerID)
        }

        invalidateEncryptionCache(for: peerID)
    }

    @MainActor
    func getEncryptionStatus(for peerID: PeerID) -> EncryptionStatus {
        if let cachedStatus = context.cachedEncryptionStatus(for: peerID) {
            return cachedStatus
        }

        let hasEverEstablishedSession = getFingerprint(for: peerID) != nil
        let sessionState = context.noiseSessionState(for: peerID)

        let status: EncryptionStatus
        switch sessionState {
        case .established:
            status = verifiedEncryptionStatus(for: peerID)
        case .handshaking, .handshakeQueued:
            status = hasEverEstablishedSession ? verifiedEncryptionStatus(for: peerID) : .noiseHandshaking
        case .none:
            status = hasEverEstablishedSession ? verifiedEncryptionStatus(for: peerID) : .noHandshake
        case .failed:
            status = hasEverEstablishedSession ? verifiedEncryptionStatus(for: peerID) : .none
        }

        context.setCachedEncryptionStatus(status, for: peerID)
        return status
    }

    @MainActor
    func invalidateEncryptionCache(for peerID: PeerID? = nil) {
        context.invalidateStoredEncryptionCache(for: peerID)
    }

    @MainActor
    func getFingerprint(for peerID: PeerID) -> String? {
        context.unifiedFingerprint(for: peerID)
    }

    @MainActor
    func resolveNickname(for peerID: PeerID) -> String {
        guard !peerID.isEmpty else { return "unknown" }

        if !peerID.isHex {
            return peerID.id
        }

        if let nickname = context.meshPeerNicknames()[peerID] {
            return nickname
        }

        if let fingerprint = getFingerprint(for: peerID),
           let identity = context.socialIdentity(forFingerprint: fingerprint) {
            if let petname = identity.localPetname {
                return petname
            }
            return identity.claimedNickname
        }

        let prefixLength = min(4, peerID.id.count)
        let prefix = String(peerID.id.prefix(prefixLength))
        return prefix.starts(with: "anon") ? "peer\(prefix)" : "anon\(prefix)"
    }

    @MainActor
    func getMyFingerprint() -> String {
        context.noiseIdentityFingerprint()
    }

    @MainActor
    func getPeerIDForNickname(_ nickname: String) -> PeerID? {
        switch context.activeChannel {
        case .location:
            if nickname.contains("#"),
               let person = context.visibleGeohashPeople()
                .first(where: { $0.displayName == nickname }) {
                let conversationKey = PeerID(nostr_: person.id)
                context.registerNostrKeyMapping(person.id, for: conversationKey)
                return conversationKey
            }

            let base = nickname
                .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                .first
                .map(String.init)?
                .lowercased() ?? nickname.lowercased()
            if let pubkey = context.geoNicknames.first(where: { $0.value.lowercased() == base })?.key {
                let conversationKey = PeerID(nostr_: pubkey)
                context.registerNostrKeyMapping(pubkey, for: conversationKey)
                return conversationKey
            }

        case .mesh:
            break
        }

        return context.unifiedPeerID(forNickname: nickname)
    }

    @MainActor
    func nicknameForPeer(_ peerID: PeerID) -> String {
        if let name = context.peerNickname(for: peerID) {
            return name
        }
        if let favorite = context.favoriteRelationship(forPeerID: peerID),
           !favorite.peerNickname.isEmpty {
            return favorite.peerNickname
        }
        if let noiseKey = Data(hexString: peerID.id),
           let favorite = context.favoriteRelationship(forNoiseKey: noiseKey),
           !favorite.peerNickname.isEmpty {
            return favorite.peerNickname
        }
        // "anon" matches the default-nickname convention; "user" is banned copy.
        return "anon"
    }
}

private extension ChatPeerIdentityCoordinator {
    @MainActor
    func currentPeerID(forFingerprint fingerprint: String) -> PeerID? {
        for peerID in context.connectedPeers where getFingerprint(for: peerID) == fingerprint {
            return peerID
        }
        return nil
    }

    @MainActor
    func migrateChatState(from oldPeerID: PeerID, to newPeerID: PeerID) {
        // The store migration dedups by message ID, preserves timestamp
        // order, carries the unread flag, and removes the old chat.
        context.migratePrivateChat(from: oldPeerID, to: newPeerID)
    }

    @MainActor
    func migrateNoiseKeyUpdate(oldPeerID: PeerID, newPeerID: PeerID) {
        // Capture before the migration: the store hands its selection off to
        // `newPeerID` during `migrateChatState`, and the manager's selection
        // mirrors the store, so the old peer ID is no longer selected after.
        let wasSelected = context.selectedPrivateChatPeer == oldPeerID
        if wasSelected {
            SecureLogger.info("📱 Updating private chat peer ID due to key change: \(oldPeerID) -> \(newPeerID)", category: .session)
        } else if !context.privateMessages(for: oldPeerID).isEmpty {
            SecureLogger.debug("📱 Migrating private chat messages from \(oldPeerID) to \(newPeerID)", category: .session)
        }

        migrateChatState(from: oldPeerID, to: newPeerID)

        if wasSelected {
            context.selectedPrivateChatPeer = newPeerID
        }

        if let fingerprint = context.migrateFingerprintMapping(
            from: oldPeerID,
            to: newPeerID,
            fallback: getFingerprint(for: newPeerID)
        ) {
            if context.selectedPrivateChatPeer == newPeerID {
                context.selectedPrivateChatFingerprint = fingerprint
            }
        }
    }

    @MainActor
    func favoriteNotificationNickname(for peerID: PeerID, peerPublicKey: Data) -> String {
        if let nickname = context.peerNickname(for: peerID) {
            return nickname
        }
        if let favorite = context.favoriteRelationship(forNoiseKey: peerPublicKey) {
            return favorite.peerNickname
        }
        return "Unknown"
    }

    @MainActor
    func verifiedEncryptionStatus(for peerID: PeerID) -> EncryptionStatus {
        if let fingerprint = getFingerprint(for: peerID),
           context.isVerifiedFingerprint(fingerprint) {
            return .noiseVerified
        }
        return .noiseSecured
    }

    @MainActor
    func toggleFavoriteForNoiseKey(_ noisePublicKey: Data, peerID: PeerID) {
        if let ephemeralID = context.ephemeralPeerID(forNoiseKey: noisePublicKey) {
            context.unifiedToggleFavorite(ephemeralID)
            context.notifyUIChanged()
            return
        }

        let currentStatus = context.favoriteRelationship(forNoiseKey: noisePublicKey)
        let fallbackNickname = context.privateMessages(for: peerID).first { $0.senderPeerID == peerID }?.sender
        let plan = ChatFavoriteTogglePolicy.plan(
            currentStatus: currentStatus.map(ChatFavoriteStatusSnapshot.init),
            fallbackNickname: fallbackNickname,
            bridgedNostrKey: context.bridgedNostrPublicKey(for: noisePublicKey)
        )

        switch plan.persistenceAction {
        case .add(let nickname, let nostrKey):
            context.addFavorite(
                noiseKey: noisePublicKey,
                nostrPublicKey: nostrKey,
                nickname: nickname
            )

        case .remove:
            context.removeFavorite(noiseKey: noisePublicKey)
        }

        context.notifyUIChanged()

        if case .send(let isFavorite) = plan.notification {
            context.sendFavoriteNotificationViaNostr(
                noisePublicKey: noisePublicKey,
                isFavorite: isFavorite
            )
        }
    }
}

/// Default for conforming test contexts that model chats as a dictionary;
/// `ChatViewModel` overrides with a store-direct lookup.
extension ChatPeerIdentityContext {
    func privateMessages(for peerID: PeerID) -> [BitchatMessage] {
        privateChats[peerID] ?? []
    }
}
