//
// IdentityModels.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

///
/// # IdentityModels
///
/// Defines BitChat's innovative three-layer identity model that balances
/// privacy, security, and usability in a decentralized mesh network.
///
/// ## Overview
/// BitChat's identity system separates concerns across three distinct layers:
/// 1. **Ephemeral Identity**: Short-lived, rotatable peer IDs for privacy
/// 2. **Cryptographic Identity**: Long-term Noise static keys for security
/// 3. **Social Identity**: User-assigned names and trust relationships
///
/// This separation allows users to maintain stable cryptographic identities
/// while frequently rotating their network identifiers for privacy.
///
/// ## Three-Layer Architecture
///
/// ### Layer 1: Ephemeral Identity
/// - Random 8-byte peer IDs that rotate periodically
/// - Provides network-level privacy and prevents tracking
/// - Changes don't affect cryptographic relationships
/// - Includes handshake state tracking
///
/// ### Layer 2: Cryptographic Identity
/// - Based on Noise Protocol static key pairs
/// - Fingerprint derived from SHA256 of public key
/// - Enables end-to-end encryption and authentication
/// - Persists across peer ID rotations
///
/// ### Layer 3: Social Identity
/// - User-assigned names (petnames) for contacts
/// - Trust levels from unknown to verified
/// - Favorite/blocked status
/// - Personal notes and metadata
///
/// ## Privacy Design
/// The model is designed with privacy-first principles:
/// - No mandatory persistent storage
/// - Optional identity caching with user consent
/// - Ephemeral IDs prevent long-term tracking
/// - Social mappings stored locally only
///
/// ## Trust Model
/// Four levels of trust:
/// 1. **Unknown**: New or unverified peers
/// 2. **Casual**: Basic interaction history
/// 3. **Trusted**: User has explicitly trusted
/// 4. **Verified**: Cryptographic verification completed
///
/// ## Identity Resolution
/// When a peer rotates their ephemeral ID:
/// 1. Cryptographic handshake reveals their fingerprint
/// 2. System looks up social identity by fingerprint
/// 3. UI seamlessly maintains user relationships
/// 4. Historical messages remain properly attributed
///
/// ## Conflict Resolution
/// Handles edge cases like:
/// - Multiple peers claiming same nickname
/// - Nickname changes and conflicts
/// - Identity rotation during active chats
/// - Network partitions and rejoins
///
/// ## Usage Example
/// ```swift
/// // When peer connects with new ID
/// let ephemeral = EphemeralIdentity(peerID: "abc123", ...)
/// // After handshake
/// let crypto = CryptographicIdentity(fingerprint: "sha256...", ...)
/// // User assigns name
/// let social = SocialIdentity(localPetname: "Alice", ...)
/// ```
///

import Foundation

// MARK: - Three-Layer Identity Model

/// Represents the ephemeral layer of identity - short-lived peer IDs that provide network privacy.
/// These IDs rotate periodically to prevent tracking while maintaining cryptographic relationships.
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

/// Represents the cryptographic layer of identity - the stable Noise Protocol static key pair.
/// This identity persists across ephemeral ID rotations and enables secure communication.
/// The fingerprint serves as the permanent identifier for a peer's cryptographic identity.
struct CryptographicIdentity: Codable {
    let fingerprint: String     // SHA256 of public key
    let publicKey: Data         // Noise static public key
    let firstSeen: Date
    let lastHandshake: Date?
}

/// Represents the social layer of identity - user-assigned names and trust relationships.
/// This layer provides human-friendly identification and relationship management.
/// All data in this layer is local-only and never transmitted over the network.
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

/// Persistent storage for identity mappings and relationships.
/// Provides efficient lookup between fingerprints, nicknames, and social identities.
/// Storage is optional and controlled by user privacy settings.
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

/// Strategies for resolving identity conflicts in the decentralized network.
/// Handles cases where multiple peers claim the same nickname or when
/// identity mappings become ambiguous due to network partitions.
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