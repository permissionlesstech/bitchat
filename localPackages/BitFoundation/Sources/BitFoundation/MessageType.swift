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

    public var description: String {
        switch self {
        case .announce: return "announce"
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
        }
    }
}
