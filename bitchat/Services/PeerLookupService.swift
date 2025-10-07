//
// PeerLookupService.swift
// bitchat
//
// Service for resolving peer information (nicknames, fingerprints, etc.)
// This is free and unencumbered software released into the public domain.
//

import Foundation

/// Service that resolves peer nicknames from various sources
/// Tries multiple fallbacks: mesh service, identity manager, anonymous default
final class PeerLookupService {

    // MARK: - Public API

    /// Resolve a nickname for a peer ID through various sources
    /// - Parameters:
    ///   - peerID: The peer ID to resolve
    ///   - meshService: Transport service for mesh peer nicknames
    ///   - identityManager: Identity manager for social identity lookup
    ///   - getFingerprint: Closure to get fingerprint for peer
    /// - Returns: Resolved nickname or anonymous fallback
    static func resolveNickname(
        for peerID: String,
        meshService: Transport,
        identityManager: SecureIdentityStateManagerProtocol,
        getFingerprint: (String) -> String?
    ) -> String {
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
        if let nickname = peerNicknames[PeerID(str: peerID)] {
            return nickname
        }

        // Try to resolve through fingerprint and social identity
        if let fingerprint = getFingerprint(peerID) {
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
}
