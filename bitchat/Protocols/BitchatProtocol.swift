//
// BitchatProtocol.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

///
/// # BitchatProtocol
///
/// Defines the application-layer protocol for BitChat mesh networking, including
/// message types, packet structures, and encoding/decoding logic.
///
/// ## Overview
/// BitchatProtocol implements a binary protocol optimized for Bluetooth LE's
/// constrained bandwidth and MTU limitations. It provides:
/// - Efficient binary message encoding
/// - Message fragmentation for large payloads
/// - TTL-based routing for mesh networks
/// - Privacy features: message padding and randomized relay jitter
/// - Integration points for end-to-end encryption
///
/// ## Protocol Design
/// The protocol uses a compact binary format to minimize overhead:
/// - 1-byte message type identifier
/// - Variable-length fields with length prefixes
/// - Network byte order (big-endian) for multi-byte values
/// - PKCS#7-style padding for privacy
///
/// ## Message Flow
/// 1. **Creation**: Messages are created with type, content, and metadata
/// 2. **Encoding**: Converted to binary format with proper field ordering
/// 3. **Fragmentation**: Split if larger than BLE MTU (512 bytes)
/// 4. **Transmission**: Sent via BLEService
/// 5. **Routing**: Relayed by intermediate nodes (TTL decrements)
/// 6. **Reassembly**: Fragments collected and reassembled
/// 7. **Decoding**: Binary data parsed back to message objects
///
/// ## Security Considerations
/// - Message padding (to 256/512/1024/2048-byte blocks) obscures actual content length
/// - Randomized relay jitter reduces the traffic-analysis signal; there is no
///   cover traffic or per-message timing obfuscation
/// - Integration with Noise Protocol for E2E encryption
/// - No persistent identifiers in protocol headers
///
/// ## Message Types
/// - **Announce/Leave**: Peer presence notifications
/// - **Message**: Public chat messages
/// - **Fragment**: Multi-part message handling
/// - **NoiseHandshake/NoiseEncrypted**: Encrypted channel establishment and
///   all private payloads (messages, delivery acks, read receipts)
/// - **CourierEnvelope**: Sealed store-and-forward mail
/// - **RequestSync/FileTransfer**: Gossip history sync and media transfer
///
/// ## Future Extensions
/// The protocol is designed to be extensible:
/// - Reserved message type ranges for future use
/// - Version field for protocol evolution
/// - Optional fields for new features
///

import Foundation
import CoreBluetooth
import BitFoundation

// MARK: - Noise Payload Types

/// Types of payloads embedded within noiseEncrypted messages.
/// The first byte of decrypted Noise payload indicates the type.
/// This provides privacy - observers can't distinguish message types.
enum NoisePayloadType: UInt8 {
    // Messages and status
    case privateMessage = 0x01      // Private chat message
    case readReceipt = 0x02         // Message was read
    case delivered = 0x03           // Message was delivered
    // Private groups (0x04/0x05 reserved by other features)
    case groupInvite = 0x06         // Creator-signed group state (invite)
    case groupKeyUpdate = 0x07      // Creator-signed group state (key rotation / roster update)
    // Live voice (push-to-talk)
    case voiceFrame = 0x08          // One live voice-burst packet (see VoiceBurstPacket)
    // Verification (QR-based OOB binding)
    case verifyChallenge = 0x10     // Verification challenge
    case verifyResponse  = 0x11     // Verification response
    // Transitive verification (web of trust)
    case vouch = 0x12               // Batch of vouch attestations

    var description: String {
        switch self {
        case .privateMessage: return "privateMessage"
        case .readReceipt: return "readReceipt"
        case .delivered: return "delivered"
        case .groupInvite: return "groupInvite"
        case .groupKeyUpdate: return "groupKeyUpdate"
        case .voiceFrame: return "voiceFrame"
        case .verifyChallenge: return "verifyChallenge"
        case .verifyResponse: return "verifyResponse"
        case .vouch: return "vouch"
        }
    }
}

// MARK: - Handshake State

// Lazy handshake state tracking
enum LazyHandshakeState {
    case none                    // No session, no handshake attempted
    case handshakeQueued        // User action requires handshake
    case handshaking           // Currently in handshake process
    case established           // Session ready for use
    case failed(Error)         // Handshake failed
}

// MARK: - Delegate Protocol

protocol BitchatDelegate: AnyObject {
    func didReceiveMessage(_ message: BitchatMessage)
    func didConnectToPeer(_ peerID: PeerID)
    func didDisconnectFromPeer(_ peerID: PeerID)
    func didUpdatePeerList(_ peers: [PeerID])

    // Optional method to check if a fingerprint belongs to a favorite peer
    func isFavorite(fingerprint: String) -> Bool

    func didUpdateMessageDeliveryStatus(_ messageID: String, status: DeliveryStatus)

    // Low-level events for better separation of concerns
    func didReceiveNoisePayload(from peerID: PeerID, type: NoisePayloadType, payload: Data, timestamp: Date)

    // Encrypted group broadcast (opaque envelope; decrypted by the group coordinator)
    func didReceiveGroupMessage(payload: Data, timestamp: Date)

    // Public live-voice burst packet (signature-verified by the transport)
    func didReceivePublicVoiceFrame(from peerID: PeerID, nickname: String, payload: Data, timestamp: Date)

    // Bluetooth state updates for user notifications
    func didUpdateBluetoothState(_ state: CBManagerState)
    func didReceivePublicMessage(from peerID: PeerID, nickname: String, content: String, timestamp: Date, messageID: String?)
}

// Provide default implementation to make it effectively optional
extension BitchatDelegate {
    func isFavorite(fingerprint: String) -> Bool {
        return false
    }
    
    func didUpdateMessageDeliveryStatus(_ messageID: String, status: DeliveryStatus) {
        // Default empty implementation
    }

    func didReceiveNoisePayload(from peerID: PeerID, type: NoisePayloadType, payload: Data, timestamp: Date) {
        // Default empty implementation
    }

    func didReceiveGroupMessage(payload: Data, timestamp: Date) {
        // Default empty implementation
    }

    func didReceivePublicVoiceFrame(from peerID: PeerID, nickname: String, payload: Data, timestamp: Date) {
        // Default empty implementation
    }

    func didReceivePublicMessage(from peerID: PeerID, nickname: String, content: String, timestamp: Date, messageID: String?) {
        // Default empty implementation
    }
}
