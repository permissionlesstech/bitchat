import BitLogger
import BitFoundation
import Foundation
import Combine

/// Manages persistent favorite relationships between peers
@MainActor
final class FavoritesPersistenceService: ObservableObject {
    
    struct FavoriteRelationship: Codable, Equatable {
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
    }
    
    // We intentionally do not track when we last sent our npub; sending happens only on favorite toggle.

    private static let storageKey = "chat.bitchat.favorites"
    private static let keychainService = "chat.bitchat.favorites"
    private static let pendingNostrIdentityRebindKey =
        "chat.bitchat.favorites.ndr-rebind-journal"
    private static let ndrRequiredNoiseKeysKey =
        "chat.bitchat.favorites.ndr-required-noise-keys"

    private struct PendingNostrIdentityRebind: Codable, Equatable {
        let peerNoisePublicKey: Data
        let oldNostrPublicKey: String
        let targetRelationship: FavoriteRelationship
    }

    private struct NostrIdentityAssignment {
        let requiresVerifiedCommit: Bool
    }

    private let keychain: KeychainManagerProtocol
    
    @Published private(set) var favorites: [Data: FavoriteRelationship] = [:] // Noise pubkey -> relationship
    @Published private(set) var mutualFavorites: Set<Data> = []
    private var nostrIdentityRebindAuthorizationOwner: UUID?
    private var nostrIdentityRebindAuthorizationRequired =
        DoubleRatchetFeature.isEnabled
    private var authorizeNostrIdentityRebind:
        ((Data, String?, String) -> Bool)?
    private var commitNostrIdentityRebind:
        ((Data, String, String) -> Bool)?
    private var pendingNostrIdentityRebind:
        PendingNostrIdentityRebind?
    private var ndrRequiredNoiseKeys = Set<Data>()
    private var ndrBindingStorageUnreadable = false
    
    static let shared = FavoritesPersistenceService()

    init(keychain: KeychainManagerProtocol = KeychainManager.makeDefault()) {
        self.keychain = keychain
        loadNdrRequiredNoiseKeys()
        loadPendingNostrIdentityRebind()
        loadFavorites()
        
        // Update mutual favorites when favorites change
        $favorites
            .map { favorites in
                Set(favorites.compactMap { $0.value.isMutual ? $0.key : nil })
            }
            .assign(to: &$mutualFavorites)
    }

    /// Installs the single app-lifetime NDR rebind authority. Ownership keeps
    /// a retiring view model from clearing a newer view model's guard.
    func installNostrIdentityRebindAuthorization(
        owner: UUID,
        required: Bool,
        authorize: @escaping (Data, String?, String) -> Bool,
        commit: @escaping (Data, String, String) -> Bool
    ) {
        nostrIdentityRebindAuthorizationOwner = owner
        nostrIdentityRebindAuthorizationRequired =
            required || DoubleRatchetFeature.isEnabled
        authorizeNostrIdentityRebind = authorize
        commitNostrIdentityRebind = commit
        recoverPendingNostrIdentityRebindIfPossible()
    }

    func removeNostrIdentityRebindAuthorization(owner: UUID) {
        guard nostrIdentityRebindAuthorizationOwner == owner else {
            return
        }
        nostrIdentityRebindAuthorizationOwner = nil
        authorizeNostrIdentityRebind = nil
        commitNostrIdentityRebind = nil
        nostrIdentityRebindAuthorizationRequired =
            DoubleRatchetFeature.isEnabled
    }
    
    /// Add or update a favorite
    func addFavorite(
        peerNoisePublicKey: Data,
        peerNostrPublicKey: String? = nil,
        peerNickname: String
    ) {
        guard pendingNostrIdentityRebind?.peerNoisePublicKey
                != peerNoisePublicKey
        else {
            SecureLogger.error(
                "Favorite mutation blocked by pending NDR rebind journal",
                category: .security
            )
            return
        }
        SecureLogger.info("⭐️ Adding favorite: \(peerNickname) (\(peerNoisePublicKey.hexEncodedString()))", category: .session)
        
        let existing = favorites[peerNoisePublicKey]
        
        let effectiveNostrPublicKey = Self.preservingEquivalentNostrKey(
            existing: existing?.peerNostrPublicKey,
            requested: peerNostrPublicKey
        )
        let relationship = FavoriteRelationship(
            peerNoisePublicKey: peerNoisePublicKey,
            peerNostrPublicKey:
                effectiveNostrPublicKey ?? existing?.peerNostrPublicKey,
            peerNickname: peerNickname,
            isFavorite: true,
            theyFavoritedUs: existing?.theyFavoritedUs ?? false,
            favoritedAt: existing?.favoritedAt ?? Date(),
            lastUpdated: Date()
        )

        let assignment: NostrIdentityAssignment
        if let effectiveNostrPublicKey,
           existing?.peerNostrPublicKey != effectiveNostrPublicKey
        {
            guard let authorized = beginNostrIdentityAssignment(
                peerNoisePublicKey: peerNoisePublicKey,
                oldNostrPublicKey: existing?.peerNostrPublicKey,
                newNostrPublicKey: effectiveNostrPublicKey,
                targetRelationship: relationship
            ) else {
                SecureLogger.error(
                    "Refusing unauthorized favorite Nostr identity assignment",
                    category: .security
                )
                return
            }
            assignment = authorized
        } else {
            assignment = NostrIdentityAssignment(
                requiresVerifiedCommit: false
            )
        }
        
        // Log if this creates a mutual favorite
        if relationship.isMutual {
            SecureLogger.info("💕 Mutual favorite relationship established with \(peerNickname)!", category: .session)
        }
        
        var updatedFavorites = favorites
        updatedFavorites[peerNoisePublicKey] = relationship
        if assignment.requiresVerifiedCommit {
            guard persistFavorites(updatedFavorites) else {
                return
            }
            favorites = updatedFavorites
            finishPendingNostrIdentityRebind()
        } else {
            favorites = updatedFavorites
            saveFavorites()
        }
        
        // Notify observers
        NotificationCenter.default.post(
            name: .favoriteStatusChanged,
            object: nil,
            userInfo: ["peerPublicKey": peerNoisePublicKey]
        )
    }
    
    /// Remove a favorite
    func removeFavorite(peerNoisePublicKey: Data) {
        guard pendingNostrIdentityRebind?.peerNoisePublicKey
                != peerNoisePublicKey
        else {
            SecureLogger.error(
                "Favorite removal blocked by pending NDR rebind journal",
                category: .security
            )
            return
        }
        guard let existing = favorites[peerNoisePublicKey] else { return }
        
        SecureLogger.info("⭐️ Removing favorite: \(existing.peerNickname) (\(peerNoisePublicKey.hexEncodedString()))", category: .session)
        
        // If they still favorite us, keep the record but mark us as not favoriting
        if existing.theyFavoritedUs {
            let updated = FavoriteRelationship(
                peerNoisePublicKey: existing.peerNoisePublicKey,
                peerNostrPublicKey: existing.peerNostrPublicKey,
                peerNickname: existing.peerNickname,
                isFavorite: false,
                theyFavoritedUs: true,
                favoritedAt: existing.favoritedAt,
                lastUpdated: Date()
            )
            favorites[peerNoisePublicKey] = updated
            // Keeping record - they still favorite us
        } else {
            // Neither side favorites, remove completely
            favorites.removeValue(forKey: peerNoisePublicKey)
            // Completely removed from favorites
        }
        
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
        guard pendingNostrIdentityRebind?.peerNoisePublicKey
                != peerNoisePublicKey
        else {
            SecureLogger.error(
                "Favorite mutation blocked by pending NDR rebind journal",
                category: .security
            )
            return
        }
        let existing = favorites[peerNoisePublicKey]
        // Callers that can't resolve the live nickname pass the "Unknown"
        // placeholder (e.g. a notification arriving before the announce);
        // never let it clobber a real stored nickname.
        let incoming = peerNickname.flatMap { name in
            (name.isEmpty || name == "Unknown") ? nil : name
        }
        let displayName = incoming ?? existing?.peerNickname ?? "Unknown"
        
        SecureLogger.info("📨 Received favorite notification: \(displayName) \(favorited ? "favorited" : "unfavorited") us", category: .session)
        
        let effectiveNostrPublicKey = Self.preservingEquivalentNostrKey(
            existing: existing?.peerNostrPublicKey,
            requested: peerNostrPublicKey
        )
        let relationship = FavoriteRelationship(
            peerNoisePublicKey: peerNoisePublicKey,
            peerNostrPublicKey:
                effectiveNostrPublicKey ?? existing?.peerNostrPublicKey,
            peerNickname: displayName,
            isFavorite: existing?.isFavorite ?? false,
            theyFavoritedUs: favorited,
            favoritedAt: existing?.favoritedAt ?? Date(),
            lastUpdated: Date()
        )

        let assignment: NostrIdentityAssignment
        if let effectiveNostrPublicKey,
           existing?.peerNostrPublicKey != effectiveNostrPublicKey
        {
            guard let authorized = beginNostrIdentityAssignment(
                peerNoisePublicKey: peerNoisePublicKey,
                oldNostrPublicKey: existing?.peerNostrPublicKey,
                newNostrPublicKey: effectiveNostrPublicKey,
                targetRelationship: relationship
            ) else {
                SecureLogger.error(
                    "Refusing unauthorized favorite Nostr identity assignment",
                    category: .security
                )
                return
            }
            assignment = authorized
        } else {
            assignment = NostrIdentityAssignment(
                requiresVerifiedCommit: false
            )
        }

        var updatedFavorites = favorites
        
        if !relationship.isFavorite && !relationship.theyFavoritedUs {
            // Neither side favorites, remove completely
            updatedFavorites.removeValue(forKey: peerNoisePublicKey)
            // Removed - neither side favorites anymore
        } else {
            updatedFavorites[peerNoisePublicKey] = relationship
            
            // Check if this creates a mutual favorite
            if relationship.isMutual {
                SecureLogger.info("💕 Mutual favorite relationship established with \(displayName)!", category: .session)
            }
        }
        
        if assignment.requiresVerifiedCommit {
            guard persistFavorites(updatedFavorites) else {
                return
            }
            favorites = updatedFavorites
            finishPendingNostrIdentityRebind()
        } else {
            favorites = updatedFavorites
            saveFavorites()
        }
        
        // Notify observers
        NotificationCenter.default.post(
            name: .favoriteStatusChanged,
            object: nil,
            userInfo: ["peerPublicKey": peerNoisePublicKey]
        )
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

    func peerNostrPublicKeys(
        excludingNoisePublicKey excludedNoisePublicKey: Data
    ) -> [String] {
        favorites.compactMap { noisePublicKey, relationship in
            guard noisePublicKey != excludedNoisePublicKey else {
                return nil
            }
            return relationship.peerNostrPublicKey
        }
    }

    /// Permanently requires pairwise NDR for this Noise identity. The pin is
    /// intentionally independent of the Nostr identity so an identity rebind
    /// can never reopen legacy kind-1059 fallback. Panic reset is the only
    /// normal path that clears it.
    @discardableResult
    func markNdrRequired(for peerNoisePublicKey: Data) -> Bool {
        guard !ndrBindingStorageUnreadable else { return false }
        guard !ndrRequiredNoiseKeys.contains(peerNoisePublicKey) else {
            return true
        }
        var updated = ndrRequiredNoiseKeys
        updated.insert(peerNoisePublicKey)
        guard persistNdrRequiredNoiseKeys(updated) else {
            ndrBindingStorageUnreadable = true
            SecureLogger.error(
                "Could not durably pin favorite to double-ratchet transport",
                category: .security
            )
            NotificationCenter.default.post(
                name: .favoriteStatusChanged,
                object: nil
            )
            return false
        }
        ndrRequiredNoiseKeys = updated
        NotificationCenter.default.post(
            name: .favoriteStatusChanged,
            object: nil
        )
        return true
    }

    func isNdrRequired(for peerNoisePublicKey: Data) -> Bool {
        ndrBindingStorageUnreadable
            || ndrRequiredNoiseKeys.contains(peerNoisePublicKey)
    }

    func isNdrRequired(for peerID: PeerID) -> Bool {
        if ndrBindingStorageUnreadable {
            return true
        }
        return ndrRequiredNoiseKeys.contains {
            Self.peerID(peerID, matchesNoisePublicKey: $0)
        }
    }

    /// A journal always suppresses legacy fallback, including after a build
    /// turns the rollout gate back off. A permanent pin does the same after
    /// the journal has been completed.
    func isNdrFallbackBlocked(for peerID: PeerID) -> Bool {
        if isNdrRequired(for: peerID) {
            return true
        }
        guard let pendingNostrIdentityRebind else { return false }
        return Self.peerID(
            peerID,
            matchesNoisePublicKey:
                pendingNostrIdentityRebind.peerNoisePublicKey
        )
    }

    /// Binding-dependent work is allowed only for an unambiguous durable
    /// binding. If the target favorite was committed and only journal cleanup
    /// failed, target OOB remains usable while legacy fallback stays blocked.
    func canUseNdrBinding(
        peerNoisePublicKey: Data,
        peerNostrPublicKey: String
    ) -> Bool {
        guard !ndrBindingStorageUnreadable else { return false }
        guard let pendingNostrIdentityRebind else { return true }
        guard pendingNostrIdentityRebind.peerNoisePublicKey
                == peerNoisePublicKey
        else {
            return true
        }
        return pendingNostrIdentityRebind
            .targetRelationship.peerNostrPublicKey
            == peerNostrPublicKey
            && favorites[peerNoisePublicKey]?.peerNostrPublicKey
                == peerNostrPublicKey
    }

    func canUseNdrBinding(for peerID: PeerID) -> Bool {
        guard !ndrBindingStorageUnreadable else { return false }
        guard let pendingNostrIdentityRebind,
              Self.peerID(
                peerID,
                matchesNoisePublicKey:
                    pendingNostrIdentityRebind.peerNoisePublicKey
              )
        else {
            return true
        }
        let targetNostrPublicKey = pendingNostrIdentityRebind
            .targetRelationship.peerNostrPublicKey
        return targetNostrPublicKey != nil
            && favorites[pendingNostrIdentityRebind.peerNoisePublicKey]?
                .peerNostrPublicKey == targetNostrPublicKey
    }

    /// Account-mailbox kind-1059 is a legacy transport. Once a favorite has
    /// durable pairwise state, or while its identity is being rebound, an
    /// inbound legacy envelope from either identity is a downgrade and must
    /// not be delivered under a virtual Nostr peer.
    func canAcceptLegacyNostrDM(from peerNostrPublicKey: String) -> Bool {
        guard !ndrBindingStorageUnreadable,
              let normalizedPeer =
                Self.normalizedNostrPublicKey(peerNostrPublicKey)
        else {
            return false
        }

        if let journal = pendingNostrIdentityRebind {
            if Self.normalizedNostrPublicKey(
                journal.oldNostrPublicKey
            ) == normalizedPeer
                || journal.targetRelationship.peerNostrPublicKey.flatMap(
                    Self.normalizedNostrPublicKey
                ) == normalizedPeer
            {
                return false
            }
        }

        for (noisePublicKey, relationship) in favorites {
            guard ndrRequiredNoiseKeys.contains(noisePublicKey),
                  relationship.peerNostrPublicKey.flatMap(
                    Self.normalizedNostrPublicKey
                  ) == normalizedPeer
            else {
                continue
            }
            return false
        }
        return true
    }

    var canActivateDoubleRatchetRelay: Bool {
        guard !ndrBindingStorageUnreadable else { return false }
        guard let pendingNostrIdentityRebind else { return true }
        return favorites[pendingNostrIdentityRebind.peerNoisePublicKey]?
            .peerNostrPublicKey
            == pendingNostrIdentityRebind
                .targetRelationship.peerNostrPublicKey
    }

    private func beginNostrIdentityAssignment(
        peerNoisePublicKey: Data,
        oldNostrPublicKey: String?,
        newNostrPublicKey: String,
        targetRelationship: FavoriteRelationship
    ) -> NostrIdentityAssignment? {
        // A pending transaction reserves its target identity globally. Letting
        // another favorite claim it can make crash recovery collision-fail
        // forever.
        guard pendingNostrIdentityRebind == nil else {
            return nil
        }
        if let authorizeNostrIdentityRebind {
            guard authorizeNostrIdentityRebind(
                peerNoisePublicKey,
                oldNostrPublicKey,
                newNostrPublicKey
            ) else {
                return nil
            }
        } else if nostrIdentityRebindAuthorizationRequired {
            return nil
        }

        guard let oldNostrPublicKey,
              ndrRequiredNoiseKeys.contains(peerNoisePublicKey)
        else {
            // Ordinary pre-NDR favorite identity changes remain legacy-capable.
            // Only explicit durable session evidence creates the permanent pin
            // and therefore requires destructive-retirement journaling.
            return NostrIdentityAssignment(
                requiresVerifiedCommit: false
            )
        }
        // Durable pins outlive rollout switches. A pinned binding therefore
        // always needs the same journaled retirement transaction, even in a
        // build where new NDR sessions are dark.
        guard !ndrBindingStorageUnreadable,
              let commitNostrIdentityRebind
        else {
            return nil
        }

        let journal = PendingNostrIdentityRebind(
            peerNoisePublicKey: peerNoisePublicKey,
            oldNostrPublicKey: oldNostrPublicKey,
            targetRelationship: targetRelationship
        )
        guard persistPendingNostrIdentityRebind(journal) else {
            ndrBindingStorageUnreadable = true
            return nil
        }
        pendingNostrIdentityRebind = journal
        NotificationCenter.default.post(
            name: .favoriteStatusChanged,
            object: nil
        )

        guard commitNostrIdentityRebind(
            peerNoisePublicKey,
            oldNostrPublicKey,
            newNostrPublicKey
        ) else {
            // The journal is deliberately retained. Native retirement may
            // have partially succeeded, so clearing it could reopen legacy
            // fallback against an ambiguous binding.
            return nil
        }
        return NostrIdentityAssignment(requiresVerifiedCommit: true)
    }

    private static func peerID(
        _ peerID: PeerID,
        matchesNoisePublicKey noisePublicKey: Data
    ) -> Bool {
        if let fullKey = Data(hexString: peerID.id),
           fullKey == noisePublicKey
        {
            return true
        }
        return peerID.toShort()
            == PeerID(publicKey: noisePublicKey).toShort()
    }

    private static func preservingEquivalentNostrKey(
        existing: String?,
        requested: String?
    ) -> String? {
        guard let requested else { return nil }
        guard let existing,
              normalizedNostrPublicKey(existing)
                == normalizedNostrPublicKey(requested),
              normalizedNostrPublicKey(existing) != nil
        else {
            return requested
        }
        return existing
    }

    private static func normalizedNostrPublicKey(_ value: String) -> Data? {
        let lowered = value.lowercased()
        if lowered.hasPrefix("npub") {
            guard let (hrp, data) = try? Bech32.decode(lowered),
                  hrp == "npub",
                  data.count == 32
            else {
                return nil
            }
            return data
        }
        guard lowered.count == 64,
              lowered.allSatisfy(\.isHexDigit)
        else {
            return nil
        }
        return Data(hexString: lowered)
    }
    
    /// Clear all favorites - used for panic mode
    func clearAllFavorites() {
        SecureLogger.warning("🧹 Clearing all favorites (panic mode)", category: .session)
        
        favorites.removeAll()
        saveFavorites()
        
        // Delete from keychain directly
        keychain.delete(
            key: Self.storageKey,
            service: Self.keychainService
        )
        keychain.delete(
            key: Self.pendingNostrIdentityRebindKey,
            service: Self.keychainService
        )
        keychain.delete(
            key: Self.ndrRequiredNoiseKeysKey,
            service: Self.keychainService
        )
        pendingNostrIdentityRebind = nil
        ndrRequiredNoiseKeys.removeAll()
        ndrBindingStorageUnreadable = false
        
        // Post notification for UI update
        NotificationCenter.default.post(name: .favoriteStatusChanged, object: nil)
    }
    
    // MARK: - Persistence
    
    @discardableResult
    private func saveFavorites() -> Bool {
        persistFavorites(favorites)
    }

    private func persistFavorites(
        _ relationshipsByNoiseKey: [Data: FavoriteRelationship]
    ) -> Bool {
        do {
            let relationships = relationshipsByNoiseKey.values.sorted {
                $0.peerNoisePublicKey.hexEncodedString()
                    < $1.peerNoisePublicKey.hexEncodedString()
            }
            let data = try JSONEncoder().encode(relationships)
            guard persistVerified(
                key: Self.storageKey,
                data: data,
                service: Self.keychainService
            ) else {
                SecureLogger.error(
                    "Failed to verify persisted favorites",
                    category: .security
                )
                return false
            }
            return true
        } catch {
            SecureLogger.error("Failed to save favorites: \(error)", category: .session)
            return false
        }
    }

    private func persistNdrRequiredNoiseKeys(
        _ noiseKeys: Set<Data>
    ) -> Bool {
        do {
            let sorted = noiseKeys.sorted {
                $0.hexEncodedString() < $1.hexEncodedString()
            }
            let data = try JSONEncoder().encode(sorted)
            return persistVerified(
                key: Self.ndrRequiredNoiseKeysKey,
                data: data,
                service: Self.keychainService
            )
        } catch {
            return false
        }
    }

    private func persistPendingNostrIdentityRebind(
        _ journal: PendingNostrIdentityRebind
    ) -> Bool {
        do {
            let data = try JSONEncoder().encode(journal)
            return persistVerified(
                key: Self.pendingNostrIdentityRebindKey,
                data: data,
                service: Self.keychainService
            )
        } catch {
            SecureLogger.error(
                "Failed to encode favorite NDR rebind journal",
                category: .security
            )
            return false
        }
    }

    private func persistVerified(
        key: String,
        data: Data,
        service: String
    ) -> Bool {
        keychain.save(
            key: key,
            data: data,
            service: service,
            accessible: nil
        )
        guard case .success(let stored) = keychain.loadWithResult(
            key: key,
            service: service
        ) else {
            return false
        }
        return stored == data
    }

    private func finishPendingNostrIdentityRebind() {
        guard pendingNostrIdentityRebind != nil else { return }
        keychain.delete(
            key: Self.pendingNostrIdentityRebindKey,
            service: Self.keychainService
        )
        switch keychain.loadWithResult(
            key: Self.pendingNostrIdentityRebindKey,
            service: Self.keychainService
        ) {
        case .itemNotFound:
            pendingNostrIdentityRebind = nil
        case .success:
            SecureLogger.error(
                "Favorite NDR rebind journal could not be cleared",
                category: .security
            )
        case .accessDenied, .deviceLocked, .authenticationFailed,
                .otherError:
            ndrBindingStorageUnreadable = true
            SecureLogger.error(
                "Favorite NDR rebind journal clear could not be verified",
                category: .security
            )
        }
        NotificationCenter.default.post(
            name: .favoriteStatusChanged,
            object: nil
        )
    }

    private func loadNdrRequiredNoiseKeys() {
        switch keychain.loadWithResult(
            key: Self.ndrRequiredNoiseKeysKey,
            service: Self.keychainService
        ) {
        case .itemNotFound:
            return
        case .success(let data):
            guard let values = try? JSONDecoder().decode(
                [Data].self,
                from: data
            ),
                values.allSatisfy({ $0.count == 32 })
            else {
                ndrBindingStorageUnreadable = true
                return
            }
            ndrRequiredNoiseKeys = Set(values)
        case .accessDenied, .deviceLocked, .authenticationFailed,
                .otherError:
            ndrBindingStorageUnreadable = true
        }
    }

    private func loadPendingNostrIdentityRebind() {
        switch keychain.loadWithResult(
            key: Self.pendingNostrIdentityRebindKey,
            service: Self.keychainService
        ) {
        case .itemNotFound:
            return
        case .success(let data):
            guard let journal = try? JSONDecoder().decode(
                PendingNostrIdentityRebind.self,
                from: data
            ),
                journal.peerNoisePublicKey.count == 32,
                journal.targetRelationship.peerNoisePublicKey
                    == journal.peerNoisePublicKey,
                journal.targetRelationship.peerNostrPublicKey != nil,
                journal.targetRelationship.peerNostrPublicKey
                    != journal.oldNostrPublicKey
            else {
                ndrBindingStorageUnreadable = true
                return
            }
            pendingNostrIdentityRebind = journal
        case .accessDenied, .deviceLocked, .authenticationFailed,
                .otherError:
            ndrBindingStorageUnreadable = true
        }
    }

    private func recoverPendingNostrIdentityRebindIfPossible() {
        guard !ndrBindingStorageUnreadable,
              let journal = pendingNostrIdentityRebind,
              let targetNostrPublicKey =
                journal.targetRelationship.peerNostrPublicKey,
              let commitNostrIdentityRebind
        else {
            return
        }

        let currentNostrPublicKey =
            favorites[journal.peerNoisePublicKey]?.peerNostrPublicKey
        let normalizedCurrentNostrPublicKey =
            currentNostrPublicKey.flatMap(Self.normalizedNostrPublicKey)
        guard currentNostrPublicKey == nil
                || normalizedCurrentNostrPublicKey
                    == Self.normalizedNostrPublicKey(
                        journal.oldNostrPublicKey
                    )
                || normalizedCurrentNostrPublicKey
                    == Self.normalizedNostrPublicKey(
                        targetNostrPublicKey
                    ),
              authorizeNostrIdentityRebind?(
                journal.peerNoisePublicKey,
                journal.oldNostrPublicKey,
                targetNostrPublicKey
              ) == true,
              markNdrRequired(for: journal.peerNoisePublicKey),
              commitNostrIdentityRebind(
                journal.peerNoisePublicKey,
                journal.oldNostrPublicKey,
                targetNostrPublicKey
              )
        else {
            return
        }

        var recovered = favorites
        recovered[journal.peerNoisePublicKey] =
            journal.targetRelationship
        guard persistFavorites(recovered) else {
            return
        }
        favorites = recovered
        finishPendingNostrIdentityRebind()
        NotificationCenter.default.post(
            name: .favoriteStatusChanged,
            object: nil,
            userInfo: [
                "peerPublicKey": journal.peerNoisePublicKey
            ]
        )
    }

    private func loadFavorites() {
        // Loading favorites from keychain

        let data: Data
        switch keychain.loadWithResult(
            key: Self.storageKey,
            service: Self.keychainService
        ) {
        case .itemNotFound:
            return
        case .success(let stored):
            data = stored
        case .accessDenied, .deviceLocked, .authenticationFailed,
                .otherError:
            ndrBindingStorageUnreadable = true
            return
        }
        
        do {
            let decoder = JSONDecoder()
            let relationships = try decoder.decode([FavoriteRelationship].self, from: data)
            
            SecureLogger.info("✅ Loaded \(relationships.count) favorite relationships", category: .session)
            
            // Log Nostr public key info
            for relationship in relationships {
                if relationship.peerNostrPublicKey == nil {
                    SecureLogger.warning("⚠️ No Nostr public key stored for '\(relationship.peerNickname)'", category: .session)
                }
            }
            
            // Convert to dictionary, cleaning up duplicates by public key (not nickname)
            var seenPublicKeys: [Data: FavoriteRelationship] = [:]
            var cleanedRelationships: [FavoriteRelationship] = []
            
            for relationship in relationships {
                // Check for duplicates by public key (the actual unique identifier)
                if let existing = seenPublicKeys[relationship.peerNoisePublicKey] {
                    SecureLogger.warning("⚠️ Duplicate favorite found for public key \(relationship.peerNoisePublicKey.hexEncodedString()) - nicknames: '\(existing.peerNickname)' vs '\(relationship.peerNickname)'", category: .session)
                    
                    // Keep the most recent or most complete relationship
                    if relationship.lastUpdated > existing.lastUpdated ||
                       (relationship.peerNostrPublicKey != nil && existing.peerNostrPublicKey == nil) {
                        // Replace with newer/more complete entry
                        seenPublicKeys[relationship.peerNoisePublicKey] = relationship
                        cleanedRelationships.removeAll { $0.peerNoisePublicKey == relationship.peerNoisePublicKey }
                        cleanedRelationships.append(relationship)
                    }
                } else {
                    seenPublicKeys[relationship.peerNoisePublicKey] = relationship
                    cleanedRelationships.append(relationship)
                }
            }
            
            // If we cleaned up duplicates, save the cleaned list
            if cleanedRelationships.count < relationships.count {
                // Cleaned up duplicates
                
                // Clear and rebuild favorites dictionary
                favorites.removeAll()
                for relationship in cleanedRelationships {
                    favorites[relationship.peerNoisePublicKey] = relationship
                }
                
                // Save cleaned favorites
                saveFavorites()
                
                // Notify that favorites have been cleaned up (synchronously since we're already on main actor)
                NotificationCenter.default.post(name: .favoriteStatusChanged, object: nil)
            } else {
                // No duplicates, just populate normally
                for relationship in cleanedRelationships {
                    favorites[relationship.peerNoisePublicKey] = relationship
                }
            }
            
            // Log loaded relationships
            // Loaded relationships successfully
        } catch {
            SecureLogger.error("Failed to load favorites: \(error)", category: .session)
            ndrBindingStorageUnreadable = true
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let favoriteStatusChanged = Notification.Name("FavoriteStatusChanged")
}
