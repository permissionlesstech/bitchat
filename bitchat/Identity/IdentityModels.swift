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
import BitFoundation

// MARK: - Three-Layer Identity Model

/// Represents the ephemeral layer of identity - short-lived peer IDs that provide network privacy.
/// These IDs rotate periodically to prevent tracking while maintaining cryptographic relationships.
struct EphemeralIdentity {
    var handshakeState: HandshakeState
}

enum HandshakeState {
    case none
    case initiated
    case inProgress
    case completed(fingerprint: String)
}

/// Represents the cryptographic layer of identity - the stable Noise Protocol static key pair.
/// This identity persists across ephemeral ID rotations and enables secure communication.
/// The fingerprint serves as the permanent identifier for a peer's cryptographic identity.
struct CryptographicIdentity: Codable {
    let fingerprint: String     // SHA256 of public key
    let publicKey: Data         // Noise static public key
    // Optional Ed25519 signing public key (used to authenticate public messages)
    var signingPublicKey: Data? = nil
    let firstSeen: Date
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

/// Trust ladder: unknown → casual → vouched → trusted → verified.
///
/// Persistence compatibility: `TrustLevel` is stored by its *String* raw
/// value ("unknown", "casual", …), not by ordinal position, so inserting
/// `vouched` mid-ladder cannot corrupt previously persisted values — every
/// pre-existing case keeps the exact raw value it was written with. The
/// `vouched` tier is additionally never persisted into `SocialIdentity`
/// (it's recomputed on read from stored vouches), so downgraded builds never
/// encounter the unfamiliar raw value.
enum TrustLevel: String, Codable {
    case unknown
    case casual
    /// Transitively trusted: vouched for by at least one peer *I* verified.
    /// Derived at read time — never written to persistent storage.
    case vouched
    case trusted
    case verified
}

// MARK: - Vouching (transitive verification)

/// One accepted vouch: a peer I verified (the voucher) attested that they
/// verified the vouchee. Validity is recomputed on read — a record only
/// counts while its voucher remains in `verifiedFingerprints` and its
/// timestamp is within `VouchAttestation.maxAge` — so unverifying a voucher
/// silently invalidates the vouches they gave without a cascade delete.
struct VouchRecord: Codable, Equatable {
    let voucherFingerprint: String
    let timestamp: Date
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
    
    // Blocked Nostr pubkeys (lowercased hex) for geohash chats
    var blockedNostrPubkeys: Set<String> = []

    // Vouching (transitive verification). All three fields are Optional so
    // caches persisted before this feature decode cleanly — the synthesized
    // decoder uses decodeIfPresent for optionals, and a missing key must not
    // trip the "unreadable cache" recovery path that discards everything.

    // Vouchee fingerprint -> accepted vouches (capped per vouchee)
    var vouchesByVouchee: [String: [VouchRecord]]? = nil

    // Peer fingerprint -> when we last sent them a vouch batch (rate limit)
    var vouchBatchSentAt: [String: Date]? = nil

    // Fingerprint -> when we verified it (orders outgoing vouch batches;
    // entries verified before this field exists sort as oldest)
    var verifiedAt: [String: Date]? = nil
}

//

// MARK: - Migration Support
//
