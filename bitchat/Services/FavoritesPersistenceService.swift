import BitLogger
import BitFoundation
import Foundation
import Combine
#if os(iOS)
import UIKit
#endif

/// Manages persistent favorite relationships between peers
@MainActor
final class FavoritesPersistenceService: ObservableObject {

    static let expectedNoiseKeyLength = 32
    
    struct FavoriteRelationship: Codable {
        let peerNoisePublicKey: Data
        let peerNostrPublicKey: String?
        let peerNickname: String
        let isFavorite: Bool
        let theyFavoritedUs: Bool
        let favoritedAt: Date
        let lastUpdated: Date
        // Track what we last sent as OUR npub to this peer, to avoid resending unless it changes
        // Note: we do not track which npub we last sent to them; sending happens only on favorite toggle
        
        var isMutual: Bool {
            isFavorite && theyFavoritedUs
        }

        /// True when `peerNostrPublicKey` decodes to a valid 32-byte secp256k1 Nostr key.
        var hasValidNostrPublicKey: Bool {
            FavoritesPersistenceService.nostrPubkeyHex(from: peerNostrPublicKey) != nil
        }
    }
    
    // We intentionally do not track when we last sent our npub; sending happens only on favorite toggle.

    private static let storageKey = "chat.bitchat.favorites"
    private static let keychainService = "chat.bitchat.favorites"
    private let keychain: KeychainManagerProtocol
    private enum DeferredMutation {
        case addFavorite(noiseKey: Data, nostrPublicKey: String?, nickname: String, at: Date)
        case establishMutualFavorite(noiseKey: Data, nostrPublicKey: String?, nickname: String, at: Date)
        case removeFavorite(noiseKey: Data, at: Date)
        case updatePeerFavoritedUs(noiseKey: Data, favorited: Bool, nickname: String?, nostrPublicKey: String?, at: Date)
    }

    /// True when the initial keychain read failed due to a transient error
    /// (e.g. locked boot) rather than `.itemNotFound`. While true, `saveFavorites()`
    /// refuses to overwrite the Keychain with an incomplete in-memory map so
    /// existing favorites are never clobbered.
    private var loadUnavailable = false
    /// Ordered log of mutations received while `loadUnavailable` was true so
    /// `retryDeferredLoad()` can replay them directly onto the durable Keychain
    /// baseline without clobbering untouched fields (e.g. `isFavorite`).
    private var deferredMutations: [DeferredMutation] = []
    #if os(iOS)
    private var protectedDataObserver: NSObjectProtocol?
    #endif
    
    @Published private(set) var favorites: [Data: FavoriteRelationship] = [:] { // Noise pubkey -> relationship
        didSet { rebuildNostrKeyIndex() }
    }
    @Published private(set) var mutualFavorites: Set<Data> = []
    private var noiseKeyByNostrKey: [String: Data] = [:] // npub and lowercase hex -> Noise pubkey
    
    static let shared = FavoritesPersistenceService()

    init(keychain: KeychainManagerProtocol = KeychainManager.makeDefault()) {
        self.keychain = keychain
        loadFavorites()
        
        // Update mutual favorites when favorites change
        $favorites
            .map { favorites in
                Set(favorites.compactMap { $0.value.isMutual ? $0.key : nil })
            }
            .assign(to: &$mutualFavorites)

        #if os(iOS)
        protectedDataObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.retryDeferredLoad()
            }
        }
        #endif
    }

    deinit {
        #if os(iOS)
        if let protectedDataObserver {
            NotificationCenter.default.removeObserver(protectedDataObserver)
        }
        #endif
    }

    // MARK: - Key Validation Helpers

    /// Normalizes a Nostr public key (`npub1...` or 64-char hex) to a canonical
    /// Bech32 `npub1...` string if it decodes to 32 bytes, or `nil` otherwise.
    nonisolated static func normalizeNostrNpub(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("npub1") {
            guard let (hrp, data) = try? Bech32.decode(lower),
                  hrp == "npub",
                  data.count == 32 else {
                return nil
            }
            return lower
        }
        if lower.count == 64, let data = Data(hexString: lower), data.count == 32 {
            return try? Bech32.encode(hrp: "npub", data: data)
        }
        return nil
    }

    /// Decodes a Nostr public key (`npub1...` or 64-char hex) into a 64-char
    /// lowercase hex string if valid (32 bytes), or `nil` otherwise.
    nonisolated static func nostrPubkeyHex(from raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("npub1") {
            guard let (hrp, data) = try? Bech32.decode(lower),
                  hrp == "npub",
                  data.count == 32 else {
                return nil
            }
            return data.hexEncodedString().lowercased()
        }
        if lower.count == 64, let data = Data(hexString: lower), data.count == 32 {
            return lower
        }
        return nil
    }

    private static func resolveDisplayNickname(incoming: String?, existing: String?) -> String {
        let validIncoming = incoming.flatMap { name -> String? in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed.isEmpty || trimmed == "Unknown") ? nil : trimmed
        }
        let validExisting = existing.flatMap { name -> String? in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed.isEmpty || trimmed == "Unknown") ? nil : trimmed
        }
        return validIncoming ?? validExisting ?? "Unknown"
    }

    /// O(1) reverse lookup from a Nostr pubkey (either `npub1...` or 64-char hex)
    /// to the peer's Noise static public key.
    func noisePublicKey(forNostrPubkey nostrPubkey: String) -> Data? {
        noiseKeyByNostrKey[nostrPubkey] ?? noiseKeyByNostrKey[nostrPubkey.lowercased()]
    }

    private func rebuildNostrKeyIndex() {
        var index: [String: Data] = [:]
        index.reserveCapacity(favorites.count * 2)
        // Sort deterministically so mutual favorites and newer updates win
        // consistently if two records ever share a Nostr key.
        let ordered = favorites.sorted { lhs, rhs in
            if lhs.value.isMutual != rhs.value.isMutual {
                return !lhs.value.isMutual && rhs.value.isMutual
            }
            if lhs.value.lastUpdated != rhs.value.lastUpdated {
                return lhs.value.lastUpdated < rhs.value.lastUpdated
            }
            return lhs.key.hexEncodedString() < rhs.key.hexEncodedString()
        }
        for (noiseKey, relationship) in ordered {
            guard let storedKey = relationship.peerNostrPublicKey, !storedKey.isEmpty else { continue }
            index[storedKey] = noiseKey
            index[storedKey.lowercased()] = noiseKey
            if let hex = Self.nostrPubkeyHex(from: storedKey) {
                index[hex] = noiseKey
                if let npub = Self.normalizeNostrNpub(storedKey) {
                    index[npub] = noiseKey
                }
            }
        }
        noiseKeyByNostrKey = index
    }
    
    /// Add or update a favorite
    @discardableResult
    func addFavorite(
        peerNoisePublicKey: Data,
        peerNostrPublicKey: String? = nil,
        peerNickname: String
    ) -> Bool {
        guard peerNoisePublicKey.count == Self.expectedNoiseKeyLength else {
            SecureLogger.warning("⚠️ Refusing to add favorite with invalid Noise key length: \(peerNoisePublicKey.count)", category: .security)
            return false
        }

        let now = Date()
        if loadUnavailable {
            deferredMutations.append(.addFavorite(
                noiseKey: peerNoisePublicKey,
                nostrPublicKey: peerNostrPublicKey,
                nickname: peerNickname,
                at: now
            ))
        }

        let relationship = Self.applyAddFavorite(
            to: &favorites,
            peerNoisePublicKey: peerNoisePublicKey,
            peerNostrPublicKey: peerNostrPublicKey,
            peerNickname: peerNickname,
            at: now
        )
        SecureLogger.info("⭐️ Adding favorite: \(relationship.peerNickname) (\(peerNoisePublicKey.hexEncodedString()))", category: .session)
        if relationship.isMutual {
            SecureLogger.info("💕 Mutual favorite relationship established with \(relationship.peerNickname)!", category: .session)
        }
        saveFavorites()
        
        // Notify observers
        NotificationCenter.default.post(
            name: .favoriteStatusChanged,
            object: nil,
            userInfo: ["peerPublicKey": peerNoisePublicKey]
        )
        return true
    }

    /// Atomically establishes a mutual favorite relationship (used when
    /// accepting a cryptographically bound friend invite) with a single
    /// Keychain write and a single notification.
    @discardableResult
    func establishMutualFavorite(
        peerNoisePublicKey: Data,
        peerNostrPublicKey: String?,
        peerNickname: String
    ) -> Bool {
        guard peerNoisePublicKey.count == Self.expectedNoiseKeyLength else {
            SecureLogger.warning("⚠️ Refusing to establish mutual favorite with invalid Noise key length: \(peerNoisePublicKey.count)", category: .security)
            return false
        }

        let now = Date()
        if loadUnavailable {
            deferredMutations.append(.establishMutualFavorite(
                noiseKey: peerNoisePublicKey,
                nostrPublicKey: peerNostrPublicKey,
                nickname: peerNickname,
                at: now
            ))
        }

        let relationship = Self.applyEstablishMutualFavorite(
            to: &favorites,
            peerNoisePublicKey: peerNoisePublicKey,
            peerNostrPublicKey: peerNostrPublicKey,
            peerNickname: peerNickname,
            at: now
        )
        SecureLogger.info("💕 Establishing mutual favorite: \(relationship.peerNickname) (\(peerNoisePublicKey.hexEncodedString()))", category: .session)
        saveFavorites()

        NotificationCenter.default.post(
            name: .favoriteStatusChanged,
            object: nil,
            userInfo: ["peerPublicKey": peerNoisePublicKey]
        )
        return true
    }
    
    /// Remove a favorite
    func removeFavorite(peerNoisePublicKey: Data) {
        guard peerNoisePublicKey.count == Self.expectedNoiseKeyLength else { return }

        let now = Date()
        if loadUnavailable {
            deferredMutations.append(.removeFavorite(noiseKey: peerNoisePublicKey, at: now))
        }

        guard let existing = favorites[peerNoisePublicKey] else { return }
        SecureLogger.info("⭐️ Removing favorite: \(existing.peerNickname) (\(peerNoisePublicKey.hexEncodedString()))", category: .session)
        
        Self.applyRemoveFavorite(to: &favorites, peerNoisePublicKey: peerNoisePublicKey, at: now)
        saveFavorites()
        
        // Notify observers
        NotificationCenter.default.post(
            name: .favoriteStatusChanged,
            object: nil,
            userInfo: ["peerPublicKey": peerNoisePublicKey]
        )
    }
    
    /// Update when we learn a peer favorited/unfavorited us
    func updatePeerFavoritedUs(
        peerNoisePublicKey: Data,
        favorited: Bool,
        peerNickname: String? = nil,
        peerNostrPublicKey: String? = nil
    ) {
        guard peerNoisePublicKey.count == Self.expectedNoiseKeyLength else {
            SecureLogger.warning("⚠️ Ignoring favorite notification with invalid Noise key length: \(peerNoisePublicKey.count)", category: .security)
            return
        }

        let now = Date()
        if loadUnavailable {
            deferredMutations.append(.updatePeerFavoritedUs(
                noiseKey: peerNoisePublicKey,
                favorited: favorited,
                nickname: peerNickname,
                nostrPublicKey: peerNostrPublicKey,
                at: now
            ))
        }

        let displayName = Self.resolveDisplayNickname(
            incoming: peerNickname,
            existing: favorites[peerNoisePublicKey]?.peerNickname
        )
        SecureLogger.info("📨 Received favorite notification: \(displayName) \(favorited ? "favorited" : "unfavorited") us", category: .session)
        
        let updated = Self.applyUpdatePeerFavoritedUs(
            to: &favorites,
            peerNoisePublicKey: peerNoisePublicKey,
            favorited: favorited,
            peerNickname: peerNickname,
            peerNostrPublicKey: peerNostrPublicKey,
            at: now
        )
        if updated?.isMutual == true {
            SecureLogger.info("💕 Mutual favorite relationship established with \(displayName)!", category: .session)
        }
        
        saveFavorites()
        
        // Notify observers
        NotificationCenter.default.post(
            name: .favoriteStatusChanged,
            object: nil,
            userInfo: ["peerPublicKey": peerNoisePublicKey]
        )
    }

    private static func applyAddFavorite(
        to map: inout [Data: FavoriteRelationship],
        peerNoisePublicKey: Data,
        peerNostrPublicKey: String?,
        peerNickname: String,
        at now: Date
    ) -> FavoriteRelationship {
        let existing = map[peerNoisePublicKey]
        let displayName = resolveDisplayNickname(incoming: peerNickname, existing: existing?.peerNickname)
        let validatedNostrKey = normalizeNostrNpub(peerNostrPublicKey)
            ?? normalizeNostrNpub(existing?.peerNostrPublicKey)
        let relationship = FavoriteRelationship(
            peerNoisePublicKey: peerNoisePublicKey,
            peerNostrPublicKey: validatedNostrKey,
            peerNickname: displayName,
            isFavorite: true,
            theyFavoritedUs: existing?.theyFavoritedUs ?? false,
            favoritedAt: existing?.favoritedAt ?? now,
            lastUpdated: now
        )
        map[peerNoisePublicKey] = relationship
        return relationship
    }

    private static func applyEstablishMutualFavorite(
        to map: inout [Data: FavoriteRelationship],
        peerNoisePublicKey: Data,
        peerNostrPublicKey: String?,
        peerNickname: String,
        at now: Date
    ) -> FavoriteRelationship {
        let existing = map[peerNoisePublicKey]
        let displayName = resolveDisplayNickname(incoming: peerNickname, existing: existing?.peerNickname)
        let validatedNostrKey = normalizeNostrNpub(peerNostrPublicKey)
            ?? normalizeNostrNpub(existing?.peerNostrPublicKey)
        let relationship = FavoriteRelationship(
            peerNoisePublicKey: peerNoisePublicKey,
            peerNostrPublicKey: validatedNostrKey,
            peerNickname: displayName,
            isFavorite: true,
            theyFavoritedUs: true,
            favoritedAt: existing?.favoritedAt ?? now,
            lastUpdated: now
        )
        map[peerNoisePublicKey] = relationship
        return relationship
    }

    private static func applyRemoveFavorite(
        to map: inout [Data: FavoriteRelationship],
        peerNoisePublicKey: Data,
        at now: Date
    ) {
        guard let existing = map[peerNoisePublicKey] else { return }
        if existing.theyFavoritedUs {
            map[peerNoisePublicKey] = FavoriteRelationship(
                peerNoisePublicKey: existing.peerNoisePublicKey,
                peerNostrPublicKey: existing.peerNostrPublicKey,
                peerNickname: existing.peerNickname,
                isFavorite: false,
                theyFavoritedUs: true,
                favoritedAt: existing.favoritedAt,
                lastUpdated: now
            )
        } else {
            map.removeValue(forKey: peerNoisePublicKey)
        }
    }

    @discardableResult
    private static func applyUpdatePeerFavoritedUs(
        to map: inout [Data: FavoriteRelationship],
        peerNoisePublicKey: Data,
        favorited: Bool,
        peerNickname: String?,
        peerNostrPublicKey: String?,
        at now: Date
    ) -> FavoriteRelationship? {
        let existing = map[peerNoisePublicKey]
        let displayName = resolveDisplayNickname(incoming: peerNickname, existing: existing?.peerNickname)
        let validatedNostrKey = normalizeNostrNpub(peerNostrPublicKey)
            ?? normalizeNostrNpub(existing?.peerNostrPublicKey)
        let relationship = FavoriteRelationship(
            peerNoisePublicKey: peerNoisePublicKey,
            peerNostrPublicKey: validatedNostrKey,
            peerNickname: displayName,
            isFavorite: existing?.isFavorite ?? false,
            theyFavoritedUs: favorited,
            favoritedAt: existing?.favoritedAt ?? now,
            lastUpdated: now
        )
        if !relationship.isFavorite && !relationship.theyFavoritedUs {
            map.removeValue(forKey: peerNoisePublicKey)
            return nil
        }
        map[peerNoisePublicKey] = relationship
        return relationship
    }
    
    /// Check if a peer is favorited by us
    func isFavorite(_ peerNoisePublicKey: Data) -> Bool {
        favorites[peerNoisePublicKey]?.isFavorite ?? false
    }
    
    /// Check if we have a mutual favorite relationship
    func isMutualFavorite(_ peerNoisePublicKey: Data) -> Bool {
        favorites[peerNoisePublicKey]?.isMutual ?? false
    }
    
    /// Get favorite status for a peer
    func getFavoriteStatus(for peerNoisePublicKey: Data) -> FavoriteRelationship? {
        favorites[peerNoisePublicKey]
    }

    /// Resolve favorite status by short peer ID (16-hex derived from Noise pubkey)
    /// Falls back to scanning favorites and matching on derived peer ID.
    func getFavoriteStatus(forPeerID peerID: PeerID) -> FavoriteRelationship? {
        // Quick sanity: peerID should be 16 hex chars (8 bytes)
        guard peerID.isShort else { return nil }
        for (pubkey, rel) in favorites where PeerID(publicKey: pubkey) == peerID {
            return rel
        }
        return nil
    }
    
    /// Clear all favorites - used for panic mode
    func clearAllFavorites() {
        SecureLogger.warning("🧹 Clearing all favorites (panic mode)", category: .session)
        
        loadUnavailable = false
        deferredMutations.removeAll()
        favorites.removeAll()
        
        // Delete from keychain directly
        keychain.delete(
            key: Self.storageKey,
            service: Self.keychainService
        )
        
        // Post notification for UI update
        NotificationCenter.default.post(name: .favoriteStatusChanged, object: nil)
    }

    /// Re-attempts loading favorites from Keychain after a locked-boot
    /// `.deviceLocked` / transient failure, replaying any in-session mutations
    /// in order onto the recovered durable baseline.
    func retryDeferredLoad() {
        guard loadUnavailable else { return }
        let data: Data
        switch keychain.loadWithResult(
            key: Self.storageKey,
            service: Self.keychainService
        ) {
        case .success(let loadedData):
            data = loadedData
        case .itemNotFound:
            loadUnavailable = false
            let hadDeferredMutations = !deferredMutations.isEmpty
            deferredMutations.removeAll()
            if hadDeferredMutations {
                saveFavorites()
                NotificationCenter.default.post(name: .favoriteStatusChanged, object: nil)
            }
            return
        case .deviceLocked, .authenticationFailed, .accessDenied, .otherError:
            return
        }

        guard let (durable, needsCleanup) = decodeAndDeduplicate(data) else {
            return
        }

        let pendingMutations = deferredMutations
        var merged = durable
        for mutation in pendingMutations {
            switch mutation {
            case .addFavorite(let noiseKey, let nostrPublicKey, let nickname, let at):
                _ = Self.applyAddFavorite(
                    to: &merged,
                    peerNoisePublicKey: noiseKey,
                    peerNostrPublicKey: nostrPublicKey,
                    peerNickname: nickname,
                    at: at
                )
            case .establishMutualFavorite(let noiseKey, let nostrPublicKey, let nickname, let at):
                _ = Self.applyEstablishMutualFavorite(
                    to: &merged,
                    peerNoisePublicKey: noiseKey,
                    peerNostrPublicKey: nostrPublicKey,
                    peerNickname: nickname,
                    at: at
                )
            case .removeFavorite(let noiseKey, let at):
                Self.applyRemoveFavorite(to: &merged, peerNoisePublicKey: noiseKey, at: at)
            case .updatePeerFavoritedUs(let noiseKey, let favorited, let nickname, let nostrPublicKey, let at):
                Self.applyUpdatePeerFavoritedUs(
                    to: &merged,
                    peerNoisePublicKey: noiseKey,
                    favorited: favorited,
                    peerNickname: nickname,
                    peerNostrPublicKey: nostrPublicKey,
                    at: at
                )
            }
        }

        loadUnavailable = false
        deferredMutations.removeAll()
        favorites = merged
        if needsCleanup || !pendingMutations.isEmpty {
            saveFavorites()
        }
        NotificationCenter.default.post(name: .favoriteStatusChanged, object: nil)
        SecureLogger.info("✅ Recovered \(merged.count) favorite relationship(s) after unlock", category: .session)
    }
    
    // MARK: - Persistence
    
    private func saveFavorites() {
        guard !loadUnavailable else {
            SecureLogger.warning("⚠️ Skipping favorites save while prior keychain read was unavailable", category: .security)
            return
        }
        let relationships = Array(favorites.values)
        // Saving favorite relationships to keychain
        
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(relationships)
            
            // Store in keychain for security
            keychain.save(
                key: Self.storageKey,
                data: data,
                service: Self.keychainService,
                accessible: nil
            )
            
            // Successfully saved favorites
        } catch {
            SecureLogger.error("Failed to save favorites: \(error)", category: .session)
        }
    }
    
    private func loadFavorites() {
        // Loading favorites from keychain
        let data: Data
        switch keychain.loadWithResult(
            key: Self.storageKey,
            service: Self.keychainService
        ) {
        case .success(let loadedData):
            loadUnavailable = false
            data = loadedData
        case .itemNotFound:
            loadUnavailable = false
            return
        case .deviceLocked, .authenticationFailed, .accessDenied, .otherError:
            loadUnavailable = true
            SecureLogger.warning("⚠️ Favorites keychain read unavailable at launch; deferring writes to prevent overwrite", category: .security)
            return
        }
        
        guard let (loaded, needsCleanup) = decodeAndDeduplicate(data) else {
            return
        }

        favorites = loaded
        if needsCleanup {
            saveFavorites()
            NotificationCenter.default.post(name: .favoriteStatusChanged, object: nil)
        }
    }

    private func decodeAndDeduplicate(_ data: Data) -> (favorites: [Data: FavoriteRelationship], needsCleanup: Bool)? {
        do {
            let decoder = JSONDecoder()
            let relationships = try decoder.decode([FavoriteRelationship].self, from: data)
            
            SecureLogger.info("✅ Loaded \(relationships.count) favorite relationships", category: .session)
            
            // Build dictionary locally and assign once so `favorites.didSet`
            // runs `rebuildNostrKeyIndex()` once in O(N) instead of O(N²).
            var loaded: [Data: FavoriteRelationship] = [:]
            loaded.reserveCapacity(relationships.count)
            var droppedInvalid = false
            var hadDuplicates = false

            for relationship in relationships {
                guard relationship.peerNoisePublicKey.count == Self.expectedNoiseKeyLength else {
                    SecureLogger.warning("⚠️ Dropping favorite with invalid Noise key length (\(relationship.peerNoisePublicKey.count))", category: .security)
                    droppedInvalid = true
                    continue
                }
                let normalizedKey = Self.normalizeNostrNpub(relationship.peerNostrPublicKey)
                let cleaned = FavoriteRelationship(
                    peerNoisePublicKey: relationship.peerNoisePublicKey,
                    peerNostrPublicKey: normalizedKey,
                    peerNickname: relationship.peerNickname,
                    isFavorite: relationship.isFavorite,
                    theyFavoritedUs: relationship.theyFavoritedUs,
                    favoritedAt: relationship.favoritedAt,
                    lastUpdated: relationship.lastUpdated
                )
                if cleaned.peerNostrPublicKey == nil {
                    SecureLogger.warning("⚠️ No Nostr public key stored for '\(cleaned.peerNickname)'", category: .session)
                }

                if let existing = loaded[cleaned.peerNoisePublicKey] {
                    hadDuplicates = true
                    SecureLogger.warning("⚠️ Duplicate favorite found for public key \(cleaned.peerNoisePublicKey.hexEncodedString()) - nicknames: '\(existing.peerNickname)' vs '\(cleaned.peerNickname)'", category: .session)
                    loaded[cleaned.peerNoisePublicKey] = Self.mergeDuplicate(existing: existing, incoming: cleaned)
                } else {
                    loaded[cleaned.peerNoisePublicKey] = cleaned
                }
            }

            return (loaded, droppedInvalid || hadDuplicates)
        } catch {
            SecureLogger.error("Failed to load favorites: \(error)", category: .session)
            return nil
        }
    }

    private static func mergeDuplicate(
        existing: FavoriteRelationship,
        incoming: FavoriteRelationship
    ) -> FavoriteRelationship {
        let newer = incoming.lastUpdated >= existing.lastUpdated ? incoming : existing
        let older = incoming.lastUpdated >= existing.lastUpdated ? existing : incoming
        return FavoriteRelationship(
            peerNoisePublicKey: newer.peerNoisePublicKey,
            peerNostrPublicKey: newer.peerNostrPublicKey ?? older.peerNostrPublicKey,
            peerNickname: resolveDisplayNickname(incoming: newer.peerNickname, existing: older.peerNickname),
            isFavorite: newer.isFavorite,
            theyFavoritedUs: newer.theyFavoritedUs,
            favoritedAt: min(existing.favoritedAt, incoming.favoritedAt),
            lastUpdated: newer.lastUpdated
        )
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let favoriteStatusChanged = Notification.Name("FavoriteStatusChanged")
}
