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
/// - Privacy features like padding and timing obfuscation
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
/// - Message padding obscures actual content length
/// - Timing obfuscation prevents traffic analysis
/// - Integration with Noise Protocol for E2E encryption
/// - No persistent identifiers in protocol headers
///
/// ## Message Types
/// - **Announce/Leave**: Peer presence notifications
/// - **Message**: User chat messages (broadcast or directed)
/// - **Fragment**: Multi-part message handling
/// - **Delivery/Read**: Message acknowledgments
/// - **Noise**: Encrypted channel establishment
/// - **Version**: Protocol version negotiation
///
/// ## Future Extensions
/// The protocol is designed to be extensible:
/// - Reserved message type ranges for future use
/// - Version field for protocol evolution
/// - Optional fields for new features
///

import Foundation
import CoreBluetooth

// MARK: - Message Types

/// Simplified BitChat protocol message types.
/// Reduced from 24 types to just 6 essential ones.
/// All private communication metadata (receipts, status) is embedded in noiseEncrypted payloads.
enum MessageType: UInt8 {
    // Public messages (unencrypted)
    case announce = 0x01        // "I'm here" with nickname
    case message = 0x02         // Public chat message  
    case leave = 0x03           // "I'm leaving"
    case requestSync = 0x21     // GCS filter-based sync request (local-only)
    
    // Noise encryption
    case noiseHandshake = 0x10  // Handshake (init or response determined by payload)
    case noiseEncrypted = 0x11  // All encrypted payloads (messages, receipts, etc.)
    
    // Fragmentation (simplified)
    case fragment = 0x20        // Single fragment type for large messages
    case fileTransfer = 0x22    // Binary file/audio/image payloads
    
    var description: String {
        switch self {
        case .announce: return "announce"
        case .message: return "message"
        case .leave: return "leave"
        case .requestSync: return "requestSync"
        case .noiseHandshake: return "noiseHandshake"
        case .noiseEncrypted: return "noiseEncrypted"
        case .fragment: return "fragment"
        case .fileTransfer: return "fileTransfer"
        }
    }
}

// MARK: - Noise Payload Types

/// Types of payloads embedded within noiseEncrypted messages.
/// The first byte of decrypted Noise payload indicates the type.
/// This provides privacy - observers can't distinguish message types.
enum NoisePayloadType: UInt8 {
    // Messages and status
    case privateMessage = 0x01      // Private chat message
    case readReceipt = 0x02         // Message was read
    case delivered = 0x03           // Message was delivered
    // Verification (QR-based OOB binding)
    case verifyChallenge = 0x10     // Verification challenge
    case verifyResponse  = 0x11     // Verification response
    
    var description: String {
        switch self {
        case .privateMessage: return "privateMessage"
        case .readReceipt: return "readReceipt"
        case .delivered: return "delivered"
        case .verifyChallenge: return "verifyChallenge"
        case .verifyResponse: return "verifyResponse"
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

// MARK: - Delivery Status

// Delivery status for messages
enum DeliveryStatus: Codable, Equatable, Hashable {
    case sending
    case sent  // Left our device
    case delivered(to: String, at: Date)  // Confirmed by recipient
    case read(by: String, at: Date)  // Seen by recipient
    case failed(reason: String)
    case partiallyDelivered(reached: Int, total: Int)  // For rooms
    
    var displayText: String {
        switch self {
        case .sending:
            return "Sending..."
        case .sent:
            return "Sent"
        case .delivered(let nickname, _):
            return "Delivered to \(nickname)"
        case .read(let nickname, _):
            return "Read by \(nickname)"
        case .failed(let reason):
            return "Failed: \(reason)"
        case .partiallyDelivered(let reached, let total):
            return "Delivered to \(reached)/\(total)"
        }
    }
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

    func didReceivePublicMessage(from peerID: PeerID, nickname: String, content: String, timestamp: Date, messageID: String?) {
        // Default empty implementation
    }
}
