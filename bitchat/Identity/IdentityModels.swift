//
// IdentityModels.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import BitFoundation

// MARK: - Identity Model

/// Represents the cryptographic layer of identity - the stable Noise Protocol static key pair.
/// This identity outlives any change to a peer's network ID and enables secure communication.
/// The fingerprint serves as the permanent identifier for a peer's cryptographic identity, and
/// its first 8 bytes are the peer ID broadcast on the mesh.
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

    // Verified fingerprints (cryptographic proof)
    var verifiedFingerprints: Set<String> = []

    // Blocked Nostr pubkeys (lowercased hex) for geohash chats
    var blockedNostrPubkeys: Set<String> = []

    // Vouching (transitive verification). All three fields are Optional so
    // caches persisted before this feature decode cleanly — decodeIfPresent
    // is used below, and a missing key must not trip the "unreadable cache"
    // recovery path that discards everything.

    // Vouchee fingerprint -> accepted vouches (capped per vouchee)
    var vouchesByVouchee: [String: [VouchRecord]]? = nil

    // Peer fingerprint -> when we last sent them a vouch batch (rate limit)
    var vouchBatchSentAt: [String: Date]? = nil

    // Fingerprint -> when we verified it (orders outgoing vouch batches;
    // entries verified before this field exists sort as oldest)
    var verifiedAt: [String: Date]? = nil

    // Stable Noise fingerprints that proved encrypted private-media support
    // inside an authenticated Noise session. Optional for decoding caches
    // written before this migration. Entries are monotonic until a panic wipe
    // so an old/replayed announce cannot silently downgrade a peer.
    var privateMediaCapableFingerprints: Set<String>? = nil

    // Noise-fingerprint -> Ed25519 announcement key, learned only from the
    // authenticated peer-state payload. This prevents a self-signed announce
    // containing a copied public Noise key from replacing a previously bound
    // public-message signing identity. Optional for old cache compatibility.
    var authenticatedSigningKeysByFingerprint: [String: Data]? = nil

    // Fingerprint -> Cryptographic identity (noise + pinned signing key).
    // Persisting the signing-key pin is security-critical: it must survive
    // app restarts so an attacker cannot replay a known peer's
    // noiseKey/peerID with their own signing key and be treated as first
    // contact (TOFU downgrade).
    var cryptographicIdentities: [String: CryptographicIdentity] = [:]

    // Schema version for future migrations
    var version: Int = 1

    init() {}

    // Custom decoding so caches written by older builds (missing newer keys
    // such as `cryptographicIdentities` or the vouching fields) still load
    // instead of being discarded. Every field uses decodeIfPresent so a
    // missing key falls back to its default rather than throwing.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        socialIdentities = try container.decodeIfPresent([String: SocialIdentity].self, forKey: .socialIdentities) ?? [:]
        verifiedFingerprints = try container.decodeIfPresent(Set<String>.self, forKey: .verifiedFingerprints) ?? []
        blockedNostrPubkeys = try container.decodeIfPresent(Set<String>.self, forKey: .blockedNostrPubkeys) ?? []
        vouchesByVouchee = try container.decodeIfPresent([String: [VouchRecord]].self, forKey: .vouchesByVouchee)
        vouchBatchSentAt = try container.decodeIfPresent([String: Date].self, forKey: .vouchBatchSentAt)
        verifiedAt = try container.decodeIfPresent([String: Date].self, forKey: .verifiedAt)
        privateMediaCapableFingerprints = try container.decodeIfPresent(Set<String>.self, forKey: .privateMediaCapableFingerprints)
        authenticatedSigningKeysByFingerprint = try container.decodeIfPresent([String: Data].self, forKey: .authenticatedSigningKeysByFingerprint)
        cryptographicIdentities = try container.decodeIfPresent([String: CryptographicIdentity].self, forKey: .cryptographicIdentities) ?? [:]
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
    }
}

//

// MARK: - Migration Support
//
