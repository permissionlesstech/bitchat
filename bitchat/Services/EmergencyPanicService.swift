//
// EmergencyPanicService.swift
// bitchat
//
// Emergency data clearing for activist safety (triple-tap panic mode)
// This is free and unencumbered software released into the public domain.
//

import BitLogger
import Foundation

/// Service that handles emergency data clearing
/// Wipes all sensitive data when user triggers panic mode
@MainActor
final class EmergencyPanicService {

    // MARK: - Public API

    /// Execute emergency panic clear - wipe all sensitive data
    /// This is triggered by triple-tap gesture for activist safety
    /// - Parameters:
    ///   - keychain: Keychain manager to delete keys
    ///   - identityManager: Identity manager to clear data
    ///   - favoritesService: Favorites service to clear relationships
    ///   - userDefaults: UserDefaults to clear preferences
    ///   - meshService: Transport service to disconnect and reset
    ///   - clearMessages: Closure to clear message arrays
    ///   - generateNewNickname: Closure to generate and save new anonymous nickname
    ///   - reinitializeNostr: Closure to reinitialize Nostr with new identity
    static func executePanicClear(
        keychain: KeychainManagerProtocol,
        identityManager: SecureIdentityStateManagerProtocol,
        favoritesService: FavoritesPersistenceService,
        userDefaults: UserDefaults,
        meshService: Transport,
        clearMessages: () -> Void,
        clearPrivateChats: () -> Void,
        clearVerifiedFingerprints: () -> Void,
        clearPeerMappings: () -> Void,
        clearAutocomplete: () -> Void,
        clearPrivateChatSelection: () -> Void,
        clearReceiptTracking: () -> Void,
        clearCaches: () -> Void,
        disconnectNostr: () -> Void,
        generateNewNickname: () -> Void,
        reinitializeNostr: @escaping () async -> Void
    ) {
        SecureLogger.warning("🚨 PANIC MODE: Emergency data clear initiated", category: .security)

        // Clear all messages
        clearMessages()
        clearPrivateChats()

        // Delete all keychain data (including Noise and Nostr keys)
        _ = keychain.deleteAllKeychainData()

        // Clear UserDefaults identity data
        userDefaults.removeObject(forKey: "bitchat.noiseIdentityKey")
        userDefaults.removeObject(forKey: "bitchat.messageRetentionKey")

        // Clear verified fingerprints
        clearVerifiedFingerprints()

        // Reset nickname to anonymous
        generateNewNickname()

        // Clear favorites and peer mappings
        identityManager.clearAllIdentityData()
        clearPeerMappings()

        // Clear persistent favorites from keychain
        favoritesService.clearAllFavorites()

        // Clear autocomplete state
        clearAutocomplete()

        // Clear selected private chat
        clearPrivateChatSelection()

        // Clear read receipt tracking
        clearReceiptTracking()

        // Clear all caches
        clearCaches()

        // Disconnect from Nostr relays and clear subscriptions
        disconnectNostr()

        // Clear Nostr identity associations
        NostrIdentityBridge.clearAllAssociations()

        // Disconnect from all peers and clear persistent identity
        meshService.emergencyDisconnectAll()
        if let bleService = meshService as? BLEService {
            // Get current nickname before reset (for logging)
            let currentNick = meshService.myNickname
            bleService.resetIdentityForPanic(currentNickname: currentNick)
        }

        // Reinitialize Nostr with new identity
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: TransportConfig.uiAsyncShortSleepNs)
            await reinitializeNostr()
        }

        SecureLogger.warning("🚨 PANIC MODE: All data cleared, new identity generated", category: .security)
    }
}
