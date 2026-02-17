//
// BitchatProtocol.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import CryptoKit

/// Privacy-preserving padding utilities that obscure true message sizes.
///
/// Uses PKCS#7-style padding with random fill bytes to prevent traffic analysis
/// from inferring message content based on ciphertext length.
struct MessagePadding {
    /// Standard block sizes (in bytes) used as padding targets.
    static let blockSizes = [256, 512, 1024, 2048]

    /// Pads `data` to `targetSize` using PKCS#7-style padding with random fill.
    ///
    /// The last byte of the padded output encodes the number of padding bytes added,
    /// so padding is limited to a maximum of 255 bytes. If padding exceeds 255 bytes
    /// or `data` is already at least `targetSize`, the original data is returned unmodified.
    ///
    /// - Parameters:
    ///   - data: The plaintext data to pad.
    ///   - targetSize: The desired output length in bytes.
    /// - Returns: Padded data of exactly `targetSize` bytes, or the original data if padding is not possible.
    static func pad(_ data: Data, toSize targetSize: Int) -> Data {
        guard data.count < targetSize else { return data }
        
        let paddingNeeded = targetSize - data.count
        
        // PKCS#7 only supports padding up to 255 bytes
        // If we need more padding than that, don't pad - return original data
        guard paddingNeeded <= 255 else { return data }
        
        var padded = data
        
        // Standard PKCS#7 padding
        var randomBytes = [UInt8](repeating: 0, count: paddingNeeded - 1)
        _ = SecRandomCopyBytes(kSecRandomDefault, paddingNeeded - 1, &randomBytes)
        padded.append(contentsOf: randomBytes)
        padded.append(UInt8(paddingNeeded))
        
        return padded
    }
    
    /// Removes PKCS#7-style padding previously applied by ``pad(_:toSize:)``.
    ///
    /// Reads the last byte to determine how many padding bytes to strip.
    /// Returns the original data unchanged if it is empty or the padding length is invalid.
    static func unpad(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }
        
        // Last byte tells us how much padding to remove
        let paddingLength = Int(data[data.count - 1])
        guard paddingLength > 0 && paddingLength <= data.count else { return data }
        
        return data.prefix(data.count - paddingLength)
    }
    
    /// Returns the smallest standard block size that can hold `dataSize` plus AES-GCM overhead (~16 bytes).
    ///
    /// For very large messages that exceed all standard block sizes, returns `dataSize` unchanged
    /// since the message will be fragmented anyway.
    static func optimalBlockSize(for dataSize: Int) -> Int {
        // Account for encryption overhead (~16 bytes for AES-GCM tag)
        let totalSize = dataSize + 16
        
        // Find smallest block that fits
        for blockSize in blockSizes {
            if totalSize <= blockSize {
                return blockSize
            }
        }
        
        // For very large messages, just use the original size
        // (will be fragmented anyway)
        return dataSize
    }
}

/// On-the-wire message type identifiers carried in ``BitchatPacket/type``.
///
/// Values are encoded as a single byte in the binary protocol header.
enum MessageType: UInt8 {
    /// Peer presence announcement (broadcast on join and periodically).
    case announce = 0x01
    /// Curve25519 public-key exchange for establishing encrypted channels.
    case keyExchange = 0x02
    /// Notification that a peer is leaving the network.
    case leave = 0x03
    /// User-generated message, both private (encrypted) and broadcast.
    case message = 0x04
    /// First fragment of a multi-part message; contains fragment metadata.
    case fragmentStart = 0x05
    /// Intermediate fragment of a multi-part message.
    case fragmentContinue = 0x06
    /// Final fragment of a multi-part message.
    case fragmentEnd = 0x07
    /// Announces a password-protected room's status to the mesh.
    case roomAnnounce = 0x08
    /// Announces whether message retention is enabled for a room.
    case roomRetention = 0x09
    /// Delivery acknowledgment confirming a message reached its recipient.
    case deliveryAck = 0x0A
    /// Request for an updated delivery status of a previously sent message.
    case deliveryStatusRequest = 0x0B
    /// Read receipt indicating the recipient has viewed the message.
    case readReceipt = 0x0C
}

/// Well-known recipient identifiers for non-unicast messages.
struct SpecialRecipients {
    /// Broadcast address (8 bytes of `0xFF`). Messages sent to this recipient are delivered to all peers.
    static let broadcast = Data(repeating: 0xFF, count: 8)
}

/// Low-level network packet transmitted over the BLE mesh.
///
/// Every message on the wire — including user chat, key exchanges, announcements,
/// and delivery receipts — is wrapped in a `BitchatPacket`. The packet is serialized
/// to and from binary via ``BinaryProtocol``.
struct BitchatPacket: Codable {
    /// Protocol version (currently always `1`).
    let version: UInt8
    /// Message type tag; corresponds to a ``MessageType`` raw value.
    let type: UInt8
    /// 8-byte sender identifier (UTF-8 encoded peer ID, zero-padded).
    let senderID: Data
    /// 8-byte recipient identifier, or `nil` for broadcasts.
    let recipientID: Data?
    /// Milliseconds since the Unix epoch when the packet was created.
    let timestamp: UInt64
    /// Type-specific payload (e.g., serialized ``BitchatMessage``, public key data, or ACK).
    let payload: Data
    /// Optional Ed25519 signature over the payload.
    let signature: Data?
    /// Time-to-live hop counter, decremented on each relay. Packets with TTL 0 are not forwarded.
    var ttl: UInt8
    
    init(type: UInt8, senderID: Data, recipientID: Data?, timestamp: UInt64, payload: Data, signature: Data?, ttl: UInt8) {
        self.version = 1
        self.type = type
        self.senderID = senderID
        self.recipientID = recipientID
        self.timestamp = timestamp
        self.payload = payload
        self.signature = signature
        self.ttl = ttl
    }
    
    /// Convenience initializer that accepts a `String` sender ID and auto-generates a millisecond timestamp.
    init(type: UInt8, ttl: UInt8, senderID: String, payload: Data) {
        self.version = 1
        self.type = type
        self.senderID = senderID.data(using: .utf8)!
        self.recipientID = nil
        self.timestamp = UInt64(Date().timeIntervalSince1970 * 1000) // milliseconds
        self.payload = payload
        self.signature = nil
        self.ttl = ttl
    }
    
    /// Serializes this packet to the bitchat binary wire format via ``BinaryProtocol/encode(_:)``.
    var data: Data? {
        BinaryProtocol.encode(self)
    }

    /// Serializes this packet to the bitchat binary wire format via ``BinaryProtocol/encode(_:)``.
    func toBinaryData() -> Data? {
        BinaryProtocol.encode(self)
    }

    /// Deserializes a ``BitchatPacket`` from raw binary data via ``BinaryProtocol/decode(_:)``.
    static func from(_ data: Data) -> BitchatPacket? {
        BinaryProtocol.decode(data)
    }
}

/// Delivery acknowledgment sent back to the original sender to confirm receipt.
///
/// When a peer receives a private or room message, it generates a `DeliveryAck`
/// containing the original message ID and sends it back through the mesh.
struct DeliveryAck: Codable {
    /// The ``BitchatMessage/id`` of the message being acknowledged.
    let originalMessageID: String
    /// Unique identifier for this acknowledgment (auto-generated UUID).
    let ackID: String
    /// Peer ID of the recipient who received the message.
    let recipientID: String
    /// Human-readable nickname of the recipient.
    let recipientNickname: String
    /// Time at which the acknowledgment was created.
    let timestamp: Date
    /// Number of mesh hops the original message traversed to reach the recipient.
    let hopCount: UInt8
    
    init(originalMessageID: String, recipientID: String, recipientNickname: String, hopCount: UInt8) {
        self.originalMessageID = originalMessageID
        self.ackID = UUID().uuidString
        self.recipientID = recipientID
        self.recipientNickname = recipientNickname
        self.timestamp = Date()
        self.hopCount = hopCount
    }
    
    /// JSON-encodes this acknowledgment for transmission in a packet payload.
    func encode() -> Data? {
        try? JSONEncoder().encode(self)
    }

    /// Decodes a `DeliveryAck` from JSON data.
    static func decode(from data: Data) -> DeliveryAck? {
        try? JSONDecoder().decode(DeliveryAck.self, from: data)
    }
}

/// Read receipt indicating the recipient has viewed a message.
///
/// Distinct from ``DeliveryAck``, which only confirms network delivery.
/// A `ReadReceipt` signals that the message content was displayed to the user.
struct ReadReceipt: Codable {
    /// The ``BitchatMessage/id`` of the message that was read.
    let originalMessageID: String
    /// Unique identifier for this receipt (auto-generated UUID).
    let receiptID: String
    /// Peer ID of the reader.
    let readerID: String
    /// Human-readable nickname of the reader.
    let readerNickname: String
    /// Time at which the message was read.
    let timestamp: Date
    
    init(originalMessageID: String, readerID: String, readerNickname: String) {
        self.originalMessageID = originalMessageID
        self.receiptID = UUID().uuidString
        self.readerID = readerID
        self.readerNickname = readerNickname
        self.timestamp = Date()
    }
    
    /// JSON-encodes this receipt for transmission in a packet payload.
    func encode() -> Data? {
        try? JSONEncoder().encode(self)
    }

    /// Decodes a `ReadReceipt` from JSON data.
    static func decode(from data: Data) -> ReadReceipt? {
        try? JSONDecoder().decode(ReadReceipt.self, from: data)
    }
}

/// Lifecycle state of a sent message, from initial send through delivery confirmation.
///
/// Used by ``DeliveryTracker`` to drive UI indicators (e.g., single-check, double-check).
enum DeliveryStatus: Codable, Equatable {
    /// The message is queued locally and has not yet left the device.
    case sending
    /// The message has been transmitted to at least one BLE peer.
    case sent
    /// A ``DeliveryAck`` was received confirming the message reached the named recipient.
    case delivered(to: String, at: Date)
    /// A ``ReadReceipt`` was received confirming the recipient viewed the message.
    case read(by: String, at: Date)
    /// Delivery failed (e.g., timeout with no acknowledgment).
    case failed(reason: String)
    /// For room messages: acknowledged by some but not all expected recipients.
    case partiallyDelivered(reached: Int, total: Int)
    
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

/// Application-level chat message exchanged between peers.
///
/// A `BitchatMessage` is serialized into the ``BitchatPacket/payload`` using
/// ``BitchatMessage/toBinaryPayload()`` and deserialized with
/// ``BitchatMessage/fromBinaryPayload(_:)``.
struct BitchatMessage: Codable, Equatable {
    /// Unique message identifier (UUID string).
    let id: String
    /// Display name of the message author.
    let sender: String
    /// Plaintext message body (empty when ``isEncrypted`` is `true`).
    let content: String
    /// Creation time of the message.
    let timestamp: Date
    /// `true` if this message was relayed through an intermediate peer.
    let isRelay: Bool
    /// Original author's nickname when the message was relayed.
    let originalSender: String?
    /// `true` for end-to-end encrypted direct messages.
    let isPrivate: Bool
    /// Nickname of the intended recipient (private messages only).
    let recipientNickname: String?
    /// BLE peer identifier of the sender.
    let senderPeerID: String?
    /// Nicknames mentioned in the message (e.g., via `@nick`).
    let mentions: [String]?
    /// Room hashtag this message belongs to (e.g., `"#general"`), or `nil` for DMs/broadcasts.
    let room: String?
    /// Ciphertext for password-protected room messages.
    let encryptedContent: Data?
    /// `true` when `encryptedContent` carries the message body instead of `content`.
    let isEncrypted: Bool
    /// Current delivery lifecycle state, updated by ``DeliveryTracker``.
    var deliveryStatus: DeliveryStatus?
    
    init(id: String? = nil, sender: String, content: String, timestamp: Date, isRelay: Bool, originalSender: String? = nil, isPrivate: Bool = false, recipientNickname: String? = nil, senderPeerID: String? = nil, mentions: [String]? = nil, room: String? = nil, encryptedContent: Data? = nil, isEncrypted: Bool = false, deliveryStatus: DeliveryStatus? = nil) {
        self.id = id ?? UUID().uuidString
        self.sender = sender
        self.content = content
        self.timestamp = timestamp
        self.isRelay = isRelay
        self.originalSender = originalSender
        self.isPrivate = isPrivate
        self.recipientNickname = recipientNickname
        self.senderPeerID = senderPeerID
        self.mentions = mentions
        self.room = room
        self.encryptedContent = encryptedContent
        self.isEncrypted = isEncrypted
        self.deliveryStatus = deliveryStatus ?? (isPrivate ? .sending : nil)
    }
}

/// Delegate protocol for receiving mesh network events from ``BluetoothMeshService``.
///
/// All methods have default (no-op) implementations via a protocol extension,
/// so conforming types only need to implement the callbacks they care about.
protocol BitchatDelegate: AnyObject {
    /// Called when a new chat message is received (broadcast, private, or room).
    func didReceiveMessage(_ message: BitchatMessage)
    /// Called when a BLE connection to a new peer is established and keys are exchanged.
    func didConnectToPeer(_ peerID: String)
    /// Called when a previously connected peer disconnects or is pruned as stale.
    func didDisconnectFromPeer(_ peerID: String)
    /// Called when the set of active peers changes; `peers` contains all currently known peer IDs.
    func didUpdatePeerList(_ peers: [String])
    /// Called when a peer sends a leave notification for a room.
    func didReceiveRoomLeave(_ room: String, from peerID: String)
    /// Called when a room's password-protection status is announced on the mesh.
    func didReceivePasswordProtectedRoomAnnouncement(_ room: String, isProtected: Bool, creatorID: String?, keyCommitment: String?)
    /// Called when a room's retention policy is announced on the mesh.
    func didReceiveRoomRetentionAnnouncement(_ room: String, enabled: Bool, creatorID: String?)
    /// Asks the delegate to decrypt an encrypted room message payload. Return `nil` if the room key is unavailable.
    func decryptRoomMessage(_ encryptedContent: Data, room: String) -> String?
    /// Returns `true` if the given public-key fingerprint belongs to a favorited peer.
    func isFavorite(fingerprint: String) -> Bool
    /// Called when a ``DeliveryAck`` is received for a previously sent message.
    func didReceiveDeliveryAck(_ ack: DeliveryAck)
    /// Called when a ``ReadReceipt`` is received for a previously sent message.
    func didReceiveReadReceipt(_ receipt: ReadReceipt)
    /// Called when the delivery status of a sent message changes.
    func didUpdateMessageDeliveryStatus(_ messageID: String, status: DeliveryStatus)
}

// Provide default implementation to make it effectively optional
extension BitchatDelegate {
    func isFavorite(fingerprint: String) -> Bool {
        return false
    }
    
    func didReceiveRoomLeave(_ room: String, from peerID: String) {
        // Default empty implementation
    }
    
    func didReceivePasswordProtectedRoomAnnouncement(_ room: String, isProtected: Bool, creatorID: String?, keyCommitment: String?) {
        // Default empty implementation
    }
    
    func didReceiveRoomRetentionAnnouncement(_ room: String, enabled: Bool, creatorID: String?) {
        // Default empty implementation
    }
    
    func decryptRoomMessage(_ encryptedContent: Data, room: String) -> String? {
        // Default returns nil (unable to decrypt)
        return nil
    }
    
    func didReceiveDeliveryAck(_ ack: DeliveryAck) {
        // Default empty implementation
    }
    
    func didReceiveReadReceipt(_ receipt: ReadReceipt) {
        // Default empty implementation
    }
    
    func didUpdateMessageDeliveryStatus(_ messageID: String, status: DeliveryStatus) {
        // Default empty implementation
    }
}