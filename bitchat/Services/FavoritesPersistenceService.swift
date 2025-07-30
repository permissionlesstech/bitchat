import Foundation
import Combine

/// Manages persistent favorite relationships between peers
@MainActor
class FavoritesPersistenceService: ObservableObject {
    
    struct FavoriteRelationship: Codable {
        let peerNoisePublicKey: Data
        let peerNostrPublicKey: String?
        let peerNickname: String
        let isFavorite: Bool
        let theyFavoritedUs: Bool
        let favoritedAt: Date
        let lastUpdated: Date
        
        var isMutual: Bool {
            isFavorite && theyFavoritedUs
        }
    }
    
    private static let storageKey = "chat.bitchat.favorites"
    private static let keychainService = "chat.bitchat.favorites"
    
    @Published private(set) var favorites: [Data: FavoriteRelationship] = [:] // Noise pubkey -> relationship
    @Published private(set) var mutualFavorites: Set<Data> = []
    
    private let userDefaults = UserDefaults.standard
    private var cancellables = Set<AnyCancellable>()
    
    static let shared = FavoritesPersistenceService()
    
    private init() {
        loadFavorites()
        
        // Update mutual favorites when favorites change
        $favorites
            .map { favorites in
                Set(favorites.compactMap { $0.value.isMutual ? $0.key : nil })
            }
            .assign(to: &$mutualFavorites)
    }
    
    /// Add or update a favorite
    func addFavorite(
        peerNoisePublicKey: Data,
        peerNostrPublicKey: String? = nil,
        peerNickname: String
    ) {
        SecureLogger.log("⭐️ Adding favorite: \(peerNickname) (\(peerNoisePublicKey.hexEncodedString()))", 
                        category: SecureLogger.session, level: .info)
        
        let existing = favorites[peerNoisePublicKey]
        
        let relationship = FavoriteRelationship(
            peerNoisePublicKey: peerNoisePublicKey,
            peerNostrPublicKey: peerNostrPublicKey ?? existing?.peerNostrPublicKey,
            peerNickname: peerNickname,
            isFavorite: true,
            theyFavoritedUs: existing?.theyFavoritedUs ?? false,
            favoritedAt: existing?.favoritedAt ?? Date(),
            lastUpdated: Date()
        )
        
        // Log if this creates a mutual favorite
        if relationship.isMutual {
            SecureLogger.log("💕 Mutual favorite relationship established with \(peerNickname)!", 
                            category: SecureLogger.session, level: .info)
        }
        
        favorites[peerNoisePublicKey] = relationship
        saveFavorites()
        
        // Notify observers
        NotificationCenter.default.post(
            name: .favoriteStatusChanged,
            object: nil,
            userInfo: ["peerPublicKey": peerNoisePublicKey]
        )
    }
    
    /// Remove a favorite
    func removeFavorite(peerNoisePublicKey: Data) {
        guard let existing = favorites[peerNoisePublicKey] else { return }
        
        SecureLogger.log("⭐️ Removing favorite: \(existing.peerNickname) (\(peerNoisePublicKey.hexEncodedString()))", 
                        category: SecureLogger.session, level: .info)
        
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
        let existing = favorites[peerNoisePublicKey]
        let displayName = peerNickname ?? existing?.peerNickname ?? "Unknown"
        
        SecureLogger.log("📨 Received favorite notification: \(displayName) \(favorited ? "favorited" : "unfavorited") us", 
                        category: SecureLogger.session, level: .info)
        
        let relationship = FavoriteRelationship(
            peerNoisePublicKey: peerNoisePublicKey,
            peerNostrPublicKey: peerNostrPublicKey ?? existing?.peerNostrPublicKey,
            peerNickname: displayName,
            isFavorite: existing?.isFavorite ?? false,
            theyFavoritedUs: favorited,
            favoritedAt: existing?.favoritedAt ?? Date(),
            lastUpdated: Date()
        )
        
        if !relationship.isFavorite && !relationship.theyFavoritedUs {
            // Neither side favorites, remove completely
            favorites.removeValue(forKey: peerNoisePublicKey)
            // Removed - neither side favorites anymore
        } else {
            favorites[peerNoisePublicKey] = relationship
            
            // Check if this creates a mutual favorite
            if relationship.isMutual {
                SecureLogger.log("💕 Mutual favorite relationship established with \(displayName)!", 
                                category: SecureLogger.session, level: .info)
            }
        }
        
        saveFavorites()
        
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
    
    /// Update Nostr public key for a peer
    func updateNostrPublicKey(for peerNoisePublicKey: Data, nostrPubkey: String) {
        guard let existing = favorites[peerNoisePublicKey] else { return }
        
        let updated = FavoriteRelationship(
            peerNoisePublicKey: existing.peerNoisePublicKey,
            peerNostrPublicKey: nostrPubkey,
            peerNickname: existing.peerNickname,
            isFavorite: existing.isFavorite,
            theyFavoritedUs: existing.theyFavoritedUs,
            favoritedAt: existing.favoritedAt,
            lastUpdated: Date()
        )
        
        favorites[peerNoisePublicKey] = updated
        saveFavorites()
    }
    
    /// Update nickname for an existing favorite
    func updateNickname(for peerNoisePublicKey: Data, newNickname: String) {
        guard let existing = favorites[peerNoisePublicKey] else { return }
        
        // Skip if nickname hasn't changed
        if existing.peerNickname == newNickname { return }
        
        // Updating nickname for favorite
        
        let updated = FavoriteRelationship(
            peerNoisePublicKey: existing.peerNoisePublicKey,
            peerNostrPublicKey: existing.peerNostrPublicKey,
            peerNickname: newNickname,
            isFavorite: existing.isFavorite,
            theyFavoritedUs: existing.theyFavoritedUs,
            favoritedAt: existing.favoritedAt,
            lastUpdated: Date()
        )
        
        favorites[peerNoisePublicKey] = updated
        saveFavorites()
        
        // Notify observers
        NotificationCenter.default.post(
            name: .favoriteStatusChanged,
            object: nil,
            userInfo: ["peerPublicKey": peerNoisePublicKey]
        )
    }
    
    /// Update noise public key when peer reconnects with new ID
    func updateNoisePublicKey(from oldKey: Data, to newKey: Data, peerNickname: String) {
        guard let existing = favorites[oldKey] else { 
            SecureLogger.log("⚠️ Cannot update noise key - no favorite found for \(oldKey.hexEncodedString())", 
                            category: SecureLogger.session, level: .warning)
            return 
        }
        
        // Check if we already have a favorite with the new key
        if favorites[newKey] != nil {
            SecureLogger.log("⚠️ Favorite already exists with new key \(newKey.hexEncodedString()), removing old entry", 
                            category: SecureLogger.session, level: .warning)
            favorites.removeValue(forKey: oldKey)
            saveFavorites()
            return
        }
        
        // Updating noise public key
        
        // Remove old entry
        favorites.removeValue(forKey: oldKey)
        
        // Add with new key
        let updated = FavoriteRelationship(
            peerNoisePublicKey: newKey,
            peerNostrPublicKey: existing.peerNostrPublicKey,
            peerNickname: peerNickname,
            isFavorite: existing.isFavorite,
            theyFavoritedUs: existing.theyFavoritedUs,
            favoritedAt: existing.favoritedAt,
            lastUpdated: Date()
        )
        
        favorites[newKey] = updated
        saveFavorites()
        
        // Notify observers with both old and new keys
        NotificationCenter.default.post(
            name: .favoriteStatusChanged,
            object: nil,
            userInfo: [
                "peerPublicKey": newKey,
                "oldPeerPublicKey": oldKey,
                "isKeyUpdate": true
            ]
        )
    }
    
    /// Get all favorites (including non-mutual)
    func getAllFavorites() -> [FavoriteRelationship] {
        favorites.values.filter { $0.isFavorite }
    }
    
    /// Get only mutual favorites
    func getMutualFavorites() -> [FavoriteRelationship] {
        favorites.values.filter { $0.isMutual }
    }
    
    /// Get all favorite relationships (including where they favorited us)
    func getAllRelationships() -> [FavoriteRelationship] {
        Array(favorites.values)
    }
    
    /// Clear all favorites - used for panic mode
    func clearAllFavorites() {
        SecureLogger.log("🧹 Clearing all favorites (panic mode)", category: SecureLogger.session, level: .warning)
        
        favorites.removeAll()
        saveFavorites()
        
        // Delete from keychain directly
        KeychainHelper.delete(
            key: Self.storageKey,
            service: Self.keychainService
        )
        
        // Post notification for UI update
        NotificationCenter.default.post(name: .favoriteStatusChanged, object: nil)
    }
    
    // MARK: - Persistence
    
    private func saveFavorites() {
        let relationships = Array(favorites.values)
        // Saving favorite relationships to keychain
        
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(relationships)
            
            // Store in keychain for security
            KeychainHelper.save(
                key: Self.storageKey,
                data: data,
                service: Self.keychainService
            )
            
            // Successfully saved favorites
        } catch {
            SecureLogger.log("Failed to save favorites: \(error)", category: SecureLogger.session, level: .error)
        }
    }
    
    private func loadFavorites() {
        // Loading favorites from keychain
        
        guard let data = KeychainHelper.load(
            key: Self.storageKey,
            service: Self.keychainService
        ) else { 
            SecureLogger.log("📭 No existing favorites found in keychain", category: SecureLogger.session, level: .info)
            return 
        }
        
        do {
            let decoder = JSONDecoder()
            let relationships = try decoder.decode([FavoriteRelationship].self, from: data)
            
            SecureLogger.log("✅ Loaded \(relationships.count) favorite relationships", 
                            category: SecureLogger.session, level: .info)
            
            // Log Nostr public key info
            for relationship in relationships {
                if relationship.peerNostrPublicKey == nil {
                    SecureLogger.log("⚠️ No Nostr public key stored for '\(relationship.peerNickname)'", 
                                    category: SecureLogger.session, level: .warning)
                }
            }
            
            // Convert to dictionary, cleaning up duplicates by public key (not nickname)
            var seenPublicKeys: [Data: FavoriteRelationship] = [:]
            var cleanedRelationships: [FavoriteRelationship] = []
            
            for relationship in relationships {
                // Check for duplicates by public key (the actual unique identifier)
                if let existing = seenPublicKeys[relationship.peerNoisePublicKey] {
                    SecureLogger.log("⚠️ Duplicate favorite found for public key \(relationship.peerNoisePublicKey.hexEncodedString()) - nicknames: '\(existing.peerNickname)' vs '\(relationship.peerNickname)'", 
                                    category: SecureLogger.session, level: .warning)
                    
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
            SecureLogger.log("Failed to load favorites: \(error)", category: SecureLogger.session, level: .error)
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let favoriteStatusChanged = Notification.Name("FavoriteStatusChanged")
}
