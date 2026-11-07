//
// MessageType.swift
// BitFoundation
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

/// Simplified BitChat protocol message types.
/// Consolidated from the original 24 wire types down to the 9 cases below.
/// All private communication metadata (receipts, status) is embedded in noiseEncrypted payloads.
public enum MessageType: UInt8 {
    // Public messages (unencrypted)
    case announce = 0x01        // "I'm here" with nickname
    case message = 0x02         // Public chat message
    case leave = 0x03           // "I'm leaving"
    case courierEnvelope = 0x04 // Store-and-forward envelope carried by a trusted peer
    case requestSync = 0x21     // GCS filter-based sync request (local-only)

    // Noise encryption
    case noiseHandshake = 0x10  // Handshake (init or response determined by payload)
    case noiseEncrypted = 0x11  // All encrypted payloads (messages, receipts, etc.)

    // Fragmentation (simplified)
    case fragment = 0x20        // Single fragment type for large messages
    case fileTransfer = 0x22    // Binary file/audio/image payloads
    case boardPost = 0x23       // Signed geohash bulletin-board post or tombstone
    case prekeyBundle = 0x24    // Signed batch of one-time prekeys (gossiped)
    case groupMessage = 0x25    // Group-encrypted broadcast (cleartext group ID, ChaChaPoly body)

    // Mesh diagnostics
    case ping = 0x26            // Directed echo request (nonce + origin TTL)
    case pong = 0x27            // Directed echo reply (echoed nonce + origin TTL)

    // Gateway mode: signed Nostr event ferried between a mesh-only peer and
    // an internet gateway peer.
    case nostrCarrier = 0x28

    // Live voice: one signed push-to-talk burst packet (ephemeral broadcast,
    // never gossip-synced). Private bursts ride noiseEncrypted instead.
    case voiceFrame = 0x29

    // Courier spray receipts (signed, capability-gated by `.courierAck`). A
    // courier acknowledges a stored spray copy (ack) or reports a deterministic
    // refusal (decline) so the giver can restore that copy's budget.
    case courierSprayAck = 0x2A
    case courierSprayDecline = 0x2B

    /// Identity-free presence for rotating peer IDs. Carries an epoch, a fixed
    /// block of pairwise recognition tags, and capabilities — no nickname, no
    /// public keys, no neighbour list. A separate type rather than a version of
    /// `announce` because that decoder hard-requires the identity TLVs, so
    /// omitting them is a parse failure rather than a graceful degrade.
    ///
    /// `0x2C`, not the seemingly-free `0x05`: that value has been recycled
    /// twice already (`announce`, then `bulkTransferResponse`, then
    /// `fragmentStart` until #446), and a very old peer that still maps it to a
    /// fragment header would misparse presence as a partial message. Values
    /// after `voiceFrame` have only ever been allocated forward. `0x2A`/`0x2B`
    /// are spoken for by the courier spray-ack work, hence `0x2C`.
    ///
    /// Not emitted or consumed by the shipping mesh yet; see
    /// `docs/PEER-ID-ROTATION.md`.
    case announceV2 = 0x2C

    public var description: String {
        switch self {
        case .announce: return "announce"
        case .announceV2: return "announceV2"
        case .message: return "message"
        case .leave: return "leave"
        case .courierEnvelope: return "courierEnvelope"
        case .requestSync: return "requestSync"
        case .noiseHandshake: return "noiseHandshake"
        case .noiseEncrypted: return "noiseEncrypted"
        case .fragment: return "fragment"
        case .fileTransfer: return "fileTransfer"
        case .boardPost: return "boardPost"
        case .prekeyBundle: return "prekeyBundle"
        case .groupMessage: return "groupMessage"
        case .ping: return "ping"
        case .pong: return "pong"
        case .nostrCarrier: return "nostrCarrier"
        case .voiceFrame: return "voiceFrame"
        case .courierSprayAck: return "courierSprayAck"
        case .courierSprayDecline: return "courierSprayDecline"
        }
    }
}
