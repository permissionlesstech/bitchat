//
// NostrDisplayNameService.swift
// bitchat
//
// Service for generating display names for Nostr participants
// This is free and unencumbered software released into the public domain.
//

import Foundation

/// Service that generates user-friendly display names for Nostr public keys
/// Formats as "nickname#abcd" with 4-char collision-resistant suffix
final class NostrDisplayNameService {

    // MARK: - Public API

    /// Generate display name for a Nostr public key
    /// - Parameters:
    ///   - pubkeyHex: The Nostr public key hex string
    ///   - currentGeohash: The current geohash (for detecting self)
    ///   - currentNickname: The current user's nickname
    ///   - geoNicknames: Map of known nicknames for this geohash
    /// - Returns: Formatted display name "nickname#abcd"
    static func displayName(
        forPubkey pubkeyHex: String,
        currentGeohash: String?,
        currentNickname: String,
        geoNicknames: [String: String]
    ) -> String {
        let suffix = String(pubkeyHex.suffix(4))

        // If this is our per-geohash identity, use our nickname
        if let gh = currentGeohash,
           let myGeoIdentity = try? NostrIdentityBridge.deriveIdentity(forGeohash: gh) {
            if myGeoIdentity.publicKeyHex.lowercased() == pubkeyHex.lowercased() {
                return currentNickname + "#" + suffix
            }
        }

        // If we have a known nickname tag for this pubkey, use it
        if let nick = geoNicknames[pubkeyHex.lowercased()], !nick.isEmpty {
            return nick + "#" + suffix
        }

        // Otherwise, anonymous with collision-resistant suffix
        return "anon#\(suffix)"
    }

    /// Get display name for current active channel (for notifications)
    static func channelDisplayName(_ channel: ChannelID) -> String {
        switch channel {
        case .mesh:
            return "#mesh"
        case .location(let ch):
            return "#\(ch.geohash)"
        }
    }
}
