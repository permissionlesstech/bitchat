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
    // Verification (QR-based OOB binding)
    case verifyChallenge = 0x10     // Verification challenge
    case verifyResponse  = 0x11     // Verification response
    // Bitcoin payments (structured packets — not raw text)
    case lightningPaymentRequest = 0x20  // BOLT11 invoice request
    case cashuToken = 0x21               // Cashu eCash bearer token (offline-redeemable)
    // AI mesh bridge (gateway nodes with internet relay AI queries to Nostr DVMs)
    case dvmQuery = 0x30                 // NIP-90 DVM job request routed over mesh
    case dvmResult = 0x31               // DVM job result returned through mesh

    var description: String {
        switch self {
        case .privateMessage: return "privateMessage"
        case .readReceipt: return "readReceipt"
        case .delivered: return "delivered"
        case .verifyChallenge: return "verifyChallenge"
        case .verifyResponse: return "verifyResponse"
        case .lightningPaymentRequest: return "lightningPaymentRequest"
        case .cashuToken: return "cashuToken"
        case .dvmQuery: return "dvmQuery"
        case .dvmResult: return "dvmResult"
        }
    }
}

// MARK: - Bitcoin Payment Delegate Extensions

extension BitchatDelegate {
    /// Called when a peer sends a Lightning payment request over the Bluetooth mesh.
    /// The invoice should be presented as a tappable payment action in the chat UI.
    func didReceiveLightningPaymentRequest(_ request: LightningPaymentRequestPacket, from peerID: PeerID, timestamp: Date) {
        // Default empty implementation — override to handle payment requests
    }

    /// Called when a peer sends a Cashu eCash bearer token over the Bluetooth mesh.
    /// The token can be redeemed at the mint whenever the device has internet access.
    /// This enables true offline Bitcoin transfers — no internet required at send time.
    func didReceiveCashuToken(_ token: CashuTokenPacket, from peerID: PeerID, timestamp: Date) {
        // Default empty implementation — override to handle eCash tokens
    }

    /// Called when a peer sends a DVM (Data Vending Machine) query over the mesh.
    /// Gateway nodes with internet access should forward this to Nostr DVMs and return
    /// the result via `didReceiveDVMResult`. This enables mesh-connected devices to
    /// access AI services without direct internet access.
    func didReceiveDVMQuery(_ query: DVMQueryPacket, from peerID: PeerID, timestamp: Date) {
        // Default empty implementation — override in gateway nodes to bridge to Nostr DVMs
    }

    /// Called when a DVM result arrives through the mesh in response to a prior query.
    func didReceiveDVMResult(_ result: DVMResultPacket, from peerID: PeerID, timestamp: Date) {
        // Default empty implementation — override to display AI results in the chat UI
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
