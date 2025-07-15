//
// IdentityModels.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

// MARK: - Three-Layer Identity Model

// Layer 1: Ephemeral (per-session)
struct EphemeralIdentity {
    let peerID: String          // 8 random bytes
    let sessionStart: Date
    var handshakeState: HandshakeState
}

enum HandshakeState {
    case none
    case initiated
    case inProgress
    case completed(fingerprint: String)
    case failed(reason: String)
}

// Layer 2: Cryptographic (persistent)
struct CryptographicIdentity: Codable {
    let fingerprint: String     // SHA256 of public key
    let publicKey: Data         // Noise static public key
    let firstSeen: Date
    let lastHandshake: Date?
}

// Layer 3: Social (user-assigned)
struct SocialIdentity: Codable {
    let fingerprint: String
    var localPetname: String?   // User's name for this peer
    var claimedNickname: String // What peer calls themselves
    var trustLevel: TrustLevel
    var isFavorite: Bool
    var isBlocked: Bool
    var notes: String?
}

enum TrustLevel: String, Codable {
    case unknown = "unknown"
    case casual = "casual"
    case trusted = "trusted"
    case verified = "verified"
}

// MARK: - Identity Cache

struct IdentityCache: Codable {
    // Fingerprint -> Social mapping
    var socialIdentities: [String: SocialIdentity] = [:]
    
    // Nickname -> [Fingerprints] reverse index
    // Multiple fingerprints can claim same nickname
    var nicknameIndex: [String: Set<String>] = [:]
    
    // Verified fingerprints (cryptographic proof)
    var verifiedFingerprints: Set<String> = []
    
    // Last interaction timestamps (privacy: optional)
    var lastInteractions: [String: Date] = [:] 
    
    // Schema version for future migrations
    var version: Int = 1
}

// MARK: - Identity Resolution

enum IdentityHint {
    case unknown
    case likelyKnown(fingerprint: String)
    case ambiguous(candidates: Set<String>)
    case verified(fingerprint: String)
}

// MARK: - Pending Actions

struct PendingActions {
    var toggleFavorite: Bool?
    var setTrustLevel: TrustLevel?
    var setPetname: String?
}

// MARK: - Privacy Settings

struct PrivacySettings: Codable {
    // Level 1: Maximum privacy (default)
    var persistIdentityCache = false
    var showLastSeen = false
    
    // Level 2: Convenience
    var autoAcceptKnownFingerprints = false
    var rememberNicknameHistory = false
    
    // Level 3: Social
    var shareTrustNetworkHints = false  // "3 mutual contacts trust this person"
}

// MARK: - Conflict Resolution

enum ConflictResolution {
    case acceptNew(petname: String)      // "John (2)"
    case rejectNew
    case blockFingerprint(String)
    case alertUser(message: String)
}

// MARK: - UI State

struct PeerUIState {
    let peerID: String
    let nickname: String
    var identityState: IdentityState
    var connectionQuality: ConnectionQuality
    
    enum IdentityState {
        case unknown                    // Gray - No identity info
        case unverifiedKnown(String)   // Blue - Handshake done, matches cache
        case verified(String)          // Green - Cryptographically verified
        case conflict(String, String)  // Red - Nickname doesn't match fingerprint
        case pending                   // Yellow - Handshake in progress
    }
}

enum ConnectionQuality {
    case excellent
    case good
    case poor
    case disconnected
}

// MARK: - Migration Support
// Removed LegacyFavorite - no longer needed