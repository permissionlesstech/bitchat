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
/// 4. **Transmission**: Sent via SimplifiedBluetoothService
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
import CryptoKit

// MARK: - Message Padding

/// Provides privacy-preserving message padding to obscure actual content length.
/// Uses PKCS#7-style padding with random bytes to prevent traffic analysis.
struct MessagePadding {
    // Standard block sizes for padding
    static let blockSizes = [256, 512, 1024, 2048]
    
    // Add PKCS#7-style padding to reach target size
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
    
    // Remove padding from data
    static func unpad(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }
        
        // Last byte tells us how much padding to remove
        let lastIndex = data.count - 1
        guard lastIndex >= 0 else { return data }
        
        let paddingLength = Int(data[lastIndex])
        guard paddingLength > 0 && paddingLength <= data.count else { 
            // No valid padding, return original data
            return data 
        }
        
        // Create a new Data object (not a subsequence) for thread safety
        let unpaddedLength = data.count - paddingLength
        guard unpaddedLength >= 0 else { return Data() }
        
        // Return a proper copy, not a subsequence
        return Data(data.prefix(unpaddedLength))
    }
    
    // Find optimal block size for data
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

// MARK: - Message Types

/// Simplified BitChat protocol message types.
/// Reduced from 24 types to just 6 essential ones.
/// All private communication metadata (receipts, status) is embedded in noiseEncrypted payloads.
enum MessageType: UInt8 {
    // Public messages (unencrypted)
    case announce = 0x01        // "I'm here" with nickname
    case message = 0x02         // Public chat message  
    case leave = 0x03           // "I'm leaving"
    
    // Noise encryption
    case noiseHandshake = 0x10  // Handshake (init or response determined by payload)
    case noiseEncrypted = 0x11  // All encrypted payloads (messages, receipts, etc.)
    
    // Fragmentation (simplified)
    case fragment = 0x20        // Single fragment type for large messages
    
    var description: String {
        switch self {
        case .announce: return "announce"
        case .message: return "message"
        case .leave: return "leave"
        case .noiseHandshake: return "noiseHandshake"
        case .noiseEncrypted: return "noiseEncrypted"
        case .fragment: return "fragment"
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
    
    var description: String {
        switch self {
        case .privateMessage: return "privateMessage"
        case .readReceipt: return "readReceipt"
        case .delivered: return "delivered"
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

// MARK: - Special Recipients

/// Defines special recipient identifiers used in the protocol.
/// These magic values indicate broadcast or system-level recipients
/// rather than specific peer IDs.
struct SpecialRecipients {
    static let broadcast = Data(repeating: 0xFF, count: 8)  // All 0xFF = broadcast
}

// MARK: - Core Protocol Structures

/// The core packet structure for all BitChat protocol messages.
/// Encapsulates all data needed for routing through the mesh network,
/// including TTL for hop limiting and optional encryption.
/// - Note: Packets larger than BLE MTU (512 bytes) are automatically fragmented
struct BitchatPacket: Codable {
    let version: UInt8
    let type: UInt8
    let senderID: Data
    let recipientID: Data?
    let timestamp: UInt64
    let payload: Data
    let signature: Data?
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
    
    // Convenience initializer for new binary format
    init(type: UInt8, ttl: UInt8, senderID: String, payload: Data) {
        self.version = 1
        self.type = type
        // Convert hex string peer ID to binary data (8 bytes)
        var senderData = Data()
        var tempID = senderID
        while tempID.count >= 2 {
            let hexByte = String(tempID.prefix(2))
            if let byte = UInt8(hexByte, radix: 16) {
                senderData.append(byte)
            }
            tempID = String(tempID.dropFirst(2))
        }
        self.senderID = senderData
        self.recipientID = nil
        self.timestamp = UInt64(Date().timeIntervalSince1970 * 1000) // milliseconds
        self.payload = payload
        self.signature = nil
        self.ttl = ttl
    }
    
    var data: Data? {
        BinaryProtocol.encode(self)
    }
    
    func toBinaryData() -> Data? {
        BinaryProtocol.encode(self)
    }
    
    static func from(_ data: Data) -> BitchatPacket? {
        BinaryProtocol.decode(data)
    }
}

// MARK: - Delivery Acknowledgments

/// Acknowledgment sent when a message is successfully delivered to a recipient.
/// Provides delivery confirmation for reliable messaging and UI feedback.
/// - Note: Only sent for direct messages, not broadcasts
struct DeliveryAck: Codable {
    let originalMessageID: String
    let ackID: String
    let recipientID: String  // Who received it
    let recipientNickname: String
    let timestamp: Date
    let hopCount: UInt8  // How many hops to reach recipient
    
    init(originalMessageID: String, recipientID: String, recipientNickname: String, hopCount: UInt8) {
        self.originalMessageID = originalMessageID
        self.ackID = UUID().uuidString
        self.recipientID = recipientID
        self.recipientNickname = recipientNickname
        self.timestamp = Date()
        self.hopCount = hopCount
    }
    
    // For binary decoding
    private init(originalMessageID: String, ackID: String, recipientID: String, recipientNickname: String, timestamp: Date, hopCount: UInt8) {
        self.originalMessageID = originalMessageID
        self.ackID = ackID
        self.recipientID = recipientID
        self.recipientNickname = recipientNickname
        self.timestamp = timestamp
        self.hopCount = hopCount
    }
    
    func encode() -> Data? {
        try? JSONEncoder().encode(self)
    }
    
    static func decode(from data: Data) -> DeliveryAck? {
        try? JSONDecoder().decode(DeliveryAck.self, from: data)
    }
    
    // MARK: - Binary Encoding
    
    func toBinaryData() -> Data {
        var data = Data()
        data.appendUUID(originalMessageID)
        data.appendUUID(ackID)
        // RecipientID as 8-byte hex string
        var recipientData = Data()
        var tempID = recipientID
        while tempID.count >= 2 && recipientData.count < 8 {
            let hexByte = String(tempID.prefix(2))
            if let byte = UInt8(hexByte, radix: 16) {
                recipientData.append(byte)
            }
            tempID = String(tempID.dropFirst(2))
        }
        while recipientData.count < 8 {
            recipientData.append(0)
        }
        data.append(recipientData)
        data.appendUInt8(hopCount)
        data.appendDate(timestamp)
        data.appendString(recipientNickname)
        return data
    }
    
    static func fromBinaryData(_ data: Data) -> DeliveryAck? {
        // Create defensive copy
        let dataCopy = Data(data)
        
        // Minimum size: 2 UUIDs (32) + recipientID (8) + hopCount (1) + timestamp (8) + min nickname
        guard dataCopy.count >= 50 else { return nil }
        
        var offset = 0
        
        guard let originalMessageID = dataCopy.readUUID(at: &offset),
              let ackID = dataCopy.readUUID(at: &offset) else { return nil }
        
        guard let recipientIDData = dataCopy.readFixedBytes(at: &offset, count: 8) else { return nil }
        let recipientID = recipientIDData.hexEncodedString()
        guard InputValidator.validatePeerID(recipientID) else { return nil }
        
        guard let hopCount = dataCopy.readUInt8(at: &offset),
              InputValidator.validateHopCount(hopCount),
              let timestamp = dataCopy.readDate(at: &offset),
              InputValidator.validateTimestamp(timestamp),
              let recipientNicknameRaw = dataCopy.readString(at: &offset),
              let recipientNickname = InputValidator.validateNickname(recipientNicknameRaw) else { return nil }
        
        return DeliveryAck(originalMessageID: originalMessageID,
                           ackID: ackID,
                           recipientID: recipientID,
                           recipientNickname: recipientNickname,
                           timestamp: timestamp,
                           hopCount: hopCount)
    }
}

// MARK: - Read Receipts

// Read receipt structure
struct ReadReceipt: Codable {
    let originalMessageID: String
    let receiptID: String
    var readerID: String  // Who read it
    let readerNickname: String
    let timestamp: Date
    
    init(originalMessageID: String, readerID: String, readerNickname: String) {
        self.originalMessageID = originalMessageID
        self.receiptID = UUID().uuidString
        self.readerID = readerID
        self.readerNickname = readerNickname
        self.timestamp = Date()
    }
    
    // For binary decoding
    private init(originalMessageID: String, receiptID: String, readerID: String, readerNickname: String, timestamp: Date) {
        self.originalMessageID = originalMessageID
        self.receiptID = receiptID
        self.readerID = readerID
        self.readerNickname = readerNickname
        self.timestamp = timestamp
    }
    
    func encode() -> Data? {
        try? JSONEncoder().encode(self)
    }
    
    static func decode(from data: Data) -> ReadReceipt? {
        try? JSONDecoder().decode(ReadReceipt.self, from: data)
    }
    
    // MARK: - Binary Encoding
    
    func toBinaryData() -> Data {
        var data = Data()
        data.appendUUID(originalMessageID)
        data.appendUUID(receiptID)
        // ReaderID as 8-byte hex string
        var readerData = Data()
        var tempID = readerID
        while tempID.count >= 2 && readerData.count < 8 {
            let hexByte = String(tempID.prefix(2))
            if let byte = UInt8(hexByte, radix: 16) {
                readerData.append(byte)
            }
            tempID = String(tempID.dropFirst(2))
        }
        while readerData.count < 8 {
            readerData.append(0)
        }
        data.append(readerData)
        data.appendDate(timestamp)
        data.appendString(readerNickname)
        return data
    }
    
    static func fromBinaryData(_ data: Data) -> ReadReceipt? {
        // Create defensive copy
        let dataCopy = Data(data)
        
        // Minimum size: 2 UUIDs (32) + readerID (8) + timestamp (8) + min nickname
        guard dataCopy.count >= 49 else { return nil }
        
        var offset = 0
        
        guard let originalMessageID = dataCopy.readUUID(at: &offset),
              let receiptID = dataCopy.readUUID(at: &offset) else { return nil }
        
        guard let readerIDData = dataCopy.readFixedBytes(at: &offset, count: 8) else { return nil }
        let readerID = readerIDData.hexEncodedString()
        guard InputValidator.validatePeerID(readerID) else { return nil }
        
        guard let timestamp = dataCopy.readDate(at: &offset),
              InputValidator.validateTimestamp(timestamp),
              let readerNicknameRaw = dataCopy.readString(at: &offset),
              let readerNickname = InputValidator.validateNickname(readerNicknameRaw) else { return nil }
        
        return ReadReceipt(originalMessageID: originalMessageID,
                          receiptID: receiptID,
                          readerID: readerID,
                          readerNickname: readerNickname,
                          timestamp: timestamp)
    }
}

// MARK: - Protocol Acknowledgments

// Protocol-level acknowledgment for reliable delivery
struct ProtocolAck: Codable {
    let originalPacketID: String    // ID of the packet being acknowledged
    let ackID: String              // Unique ID for this ACK
    let senderID: String           // Who sent the original packet
    let receiverID: String         // Who received and is acknowledging
    let packetType: UInt8          // Type of packet being acknowledged
    let timestamp: Date            // When ACK was generated
    let hopCount: UInt8            // Hops taken to reach receiver
    
    init(originalPacketID: String, senderID: String, receiverID: String, packetType: UInt8, hopCount: UInt8) {
        self.originalPacketID = originalPacketID
        self.ackID = UUID().uuidString
        self.senderID = senderID
        self.receiverID = receiverID
        self.packetType = packetType
        self.timestamp = Date()
        self.hopCount = hopCount
    }
    
    // Private init for binary decoding
    private init(originalPacketID: String, ackID: String, senderID: String, receiverID: String, 
                 packetType: UInt8, timestamp: Date, hopCount: UInt8) {
        self.originalPacketID = originalPacketID
        self.ackID = ackID
        self.senderID = senderID
        self.receiverID = receiverID
        self.packetType = packetType
        self.timestamp = timestamp
        self.hopCount = hopCount
    }
    
    func toBinaryData() -> Data {
        var data = Data()
        data.appendUUID(originalPacketID)
        data.appendUUID(ackID)
        
        // Sender and receiver IDs as 8-byte hex strings
        data.append(Data(hexString: senderID) ?? Data(repeating: 0, count: 8))
        data.append(Data(hexString: receiverID) ?? Data(repeating: 0, count: 8))
        
        data.appendUInt8(packetType)
        data.appendUInt8(hopCount)
        data.appendDate(timestamp)
        return data
    }
    
    static func fromBinaryData(_ data: Data) -> ProtocolAck? {
        let dataCopy = Data(data)
        guard dataCopy.count >= 50 else { return nil } // 2 UUIDs + 2 IDs + type + hop + timestamp
        
        var offset = 0
        guard let originalPacketID = dataCopy.readUUID(at: &offset),
              let ackID = dataCopy.readUUID(at: &offset),
              let senderIDData = dataCopy.readFixedBytes(at: &offset, count: 8),
              let receiverIDData = dataCopy.readFixedBytes(at: &offset, count: 8),
              let packetType = dataCopy.readUInt8(at: &offset),
              InputValidator.validateMessageType(packetType),
              let hopCount = dataCopy.readUInt8(at: &offset),
              InputValidator.validateHopCount(hopCount),
              let timestamp = dataCopy.readDate(at: &offset),
              InputValidator.validateTimestamp(timestamp) else { return nil }
        
        let senderID = senderIDData.hexEncodedString()
        let receiverID = receiverIDData.hexEncodedString()
        guard InputValidator.validatePeerID(senderID),
              InputValidator.validatePeerID(receiverID) else { return nil }
        
        return ProtocolAck(originalPacketID: originalPacketID,
                          ackID: ackID,
                          senderID: senderID,
                          receiverID: receiverID,
                          packetType: packetType,
                          timestamp: timestamp,
                          hopCount: hopCount)
    }
}

// Protocol-level negative acknowledgment
struct ProtocolNack: Codable {
    let originalPacketID: String    // ID of the packet that failed
    let nackID: String             // Unique ID for this NACK
    let senderID: String           // Who sent the original packet
    let receiverID: String         // Who is reporting the failure
    let packetType: UInt8          // Type of packet that failed
    let timestamp: Date            // When NACK was generated
    let reason: String             // Reason for failure
    let errorCode: UInt8           // Numeric error code
    
    // Error codes
    enum ErrorCode: UInt8 {
        case unknown = 0
        case checksumFailed = 1
        case decryptionFailed = 2
        case malformedPacket = 3
        case unsupportedVersion = 4
        case resourceExhausted = 5
        case routingFailed = 6
        case sessionExpired = 7
    }
    
    init(originalPacketID: String, senderID: String, receiverID: String, 
         packetType: UInt8, reason: String, errorCode: ErrorCode = .unknown) {
        self.originalPacketID = originalPacketID
        self.nackID = UUID().uuidString
        self.senderID = senderID
        self.receiverID = receiverID
        self.packetType = packetType
        self.timestamp = Date()
        self.reason = reason
        self.errorCode = errorCode.rawValue
    }
    
    // Private init for binary decoding
    private init(originalPacketID: String, nackID: String, senderID: String, receiverID: String,
                 packetType: UInt8, timestamp: Date, reason: String, errorCode: UInt8) {
        self.originalPacketID = originalPacketID
        self.nackID = nackID
        self.senderID = senderID
        self.receiverID = receiverID
        self.packetType = packetType
        self.timestamp = timestamp
        self.reason = reason
        self.errorCode = errorCode
    }
    
    func toBinaryData() -> Data {
        var data = Data()
        data.appendUUID(originalPacketID)
        data.appendUUID(nackID)
        
        // Sender and receiver IDs as 8-byte hex strings
        data.append(Data(hexString: senderID) ?? Data(repeating: 0, count: 8))
        data.append(Data(hexString: receiverID) ?? Data(repeating: 0, count: 8))
        
        data.appendUInt8(packetType)
        data.appendUInt8(errorCode)
        data.appendDate(timestamp)
        data.appendString(reason)
        return data
    }
    
    static func fromBinaryData(_ data: Data) -> ProtocolNack? {
        let dataCopy = Data(data)
        guard dataCopy.count >= 52 else { return nil } // Minimum size
        
        var offset = 0
        guard let originalPacketID = dataCopy.readUUID(at: &offset),
              let nackID = dataCopy.readUUID(at: &offset),
              let senderIDData = dataCopy.readFixedBytes(at: &offset, count: 8),
              let receiverIDData = dataCopy.readFixedBytes(at: &offset, count: 8),
              let packetType = dataCopy.readUInt8(at: &offset),
              InputValidator.validateMessageType(packetType),
              let errorCode = dataCopy.readUInt8(at: &offset),
              let timestamp = dataCopy.readDate(at: &offset),
              InputValidator.validateTimestamp(timestamp),
              let reasonRaw = dataCopy.readString(at: &offset),
              let reason = InputValidator.validateReasonString(reasonRaw) else { return nil }
        
        let senderID = senderIDData.hexEncodedString()
        let receiverID = receiverIDData.hexEncodedString()
        guard InputValidator.validatePeerID(senderID),
              InputValidator.validatePeerID(receiverID) else { return nil }
        
        return ProtocolNack(originalPacketID: originalPacketID,
                           nackID: nackID,
                           senderID: senderID,
                           receiverID: receiverID,
                           packetType: packetType,
                           timestamp: timestamp,
                           reason: reason,
                           errorCode: errorCode)
    }
}

// MARK: - Peer Identity Rotation

/// Announces a peer's cryptographic identity to enable secure communication.
/// Contains the peer's Noise static public key and supports identity rotation
/// by binding ephemeral peer IDs to stable cryptographic fingerprints.
/// - Note: Critical for establishing end-to-end encrypted channels
struct NoiseIdentityAnnouncement: Codable {
    let peerID: String               // Current ephemeral peer ID
    let publicKey: Data              // Noise static public key
    let signingPublicKey: Data       // Ed25519 signing public key
    let nickname: String             // Current nickname
    let timestamp: Date              // When this binding was created
    let previousPeerID: String?      // Previous peer ID (for smooth transition)
    let signature: Data              // Signature proving ownership
    
    init(peerID: String, publicKey: Data, signingPublicKey: Data, nickname: String, timestamp: Date, previousPeerID: String? = nil, signature: Data) {
        self.peerID = peerID
        self.publicKey = publicKey
        self.signingPublicKey = signingPublicKey
        // Trim whitespace from nickname
        self.nickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        self.timestamp = timestamp
        self.previousPeerID = previousPeerID
        self.signature = signature
    }
    
    // Custom decoder to ensure nickname is trimmed
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.peerID = try container.decode(String.self, forKey: .peerID)
        self.publicKey = try container.decode(Data.self, forKey: .publicKey)
        self.signingPublicKey = try container.decode(Data.self, forKey: .signingPublicKey)
        // Trim whitespace from decoded nickname
        let rawNickname = try container.decode(String.self, forKey: .nickname)
        self.nickname = rawNickname.trimmingCharacters(in: .whitespacesAndNewlines)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        self.previousPeerID = try container.decodeIfPresent(String.self, forKey: .previousPeerID)
        self.signature = try container.decode(Data.self, forKey: .signature)
    }
    
    func encode() -> Data? {
        return try? JSONEncoder().encode(self)
    }
    
    static func decode(from data: Data) -> NoiseIdentityAnnouncement? {
        return try? JSONDecoder().decode(NoiseIdentityAnnouncement.self, from: data)
    }
    
    // MARK: - Binary Encoding
    
    func toBinaryData() -> Data {
        var data = Data()
        
        // Flags byte: bit 0 = hasPreviousPeerID
        var flags: UInt8 = 0
        if previousPeerID != nil { flags |= 0x01 }
        data.appendUInt8(flags)
        
        // PeerID as 8-byte hex string
        var peerData = Data()
        var tempID = peerID
        while tempID.count >= 2 && peerData.count < 8 {
            let hexByte = String(tempID.prefix(2))
            if let byte = UInt8(hexByte, radix: 16) {
                peerData.append(byte)
            }
            tempID = String(tempID.dropFirst(2))
        }
        while peerData.count < 8 {
            peerData.append(0)
        }
        data.append(peerData)
        
        data.appendData(publicKey)
        data.appendData(signingPublicKey)
        data.appendString(nickname)
        data.appendDate(timestamp)
        
        if let previousPeerID = previousPeerID {
            // Previous PeerID as 8-byte hex string
            var prevData = Data()
            var tempPrevID = previousPeerID
            while tempPrevID.count >= 2 && prevData.count < 8 {
                let hexByte = String(tempPrevID.prefix(2))
                if let byte = UInt8(hexByte, radix: 16) {
                    prevData.append(byte)
                }
                tempPrevID = String(tempPrevID.dropFirst(2))
            }
            while prevData.count < 8 {
                prevData.append(0)
            }
            data.append(prevData)
        }
        
        data.appendData(signature)
        
        return data
    }
    
    static func fromBinaryData(_ data: Data) -> NoiseIdentityAnnouncement? {
        // Create defensive copy
        let dataCopy = Data(data)
        
        // Minimum size check: flags(1) + peerID(8) + min data lengths
        guard dataCopy.count >= 20 else { return nil }
        
        var offset = 0
        
        guard let flags = dataCopy.readUInt8(at: &offset) else { return nil }
        let hasPreviousPeerID = (flags & 0x01) != 0
        
        // Read peerID using safe method
        guard let peerIDBytes = dataCopy.readFixedBytes(at: &offset, count: 8) else { return nil }
        let peerID = peerIDBytes.hexEncodedString()
        guard InputValidator.validatePeerID(peerID) else { return nil }
        
        guard let publicKey = dataCopy.readData(at: &offset),
              InputValidator.validatePublicKey(publicKey),
              let signingPublicKey = dataCopy.readData(at: &offset),
              InputValidator.validatePublicKey(signingPublicKey),
              let rawNickname = dataCopy.readString(at: &offset),
              let nickname = InputValidator.validateNickname(rawNickname),
              let timestamp = dataCopy.readDate(at: &offset),
              InputValidator.validateTimestamp(timestamp) else { return nil }
        
        var previousPeerID: String? = nil
        if hasPreviousPeerID {
            // Read previousPeerID using safe method
            guard let prevIDBytes = dataCopy.readFixedBytes(at: &offset, count: 8) else { return nil }
            let prevID = prevIDBytes.hexEncodedString()
            guard InputValidator.validatePeerID(prevID) else { return nil }
            previousPeerID = prevID
        }
        
        guard let signature = dataCopy.readData(at: &offset),
              InputValidator.validateSignature(signature) else { return nil }
        
        return NoiseIdentityAnnouncement(peerID: peerID,
                                        publicKey: publicKey,
                                        signingPublicKey: signingPublicKey,
                                        nickname: nickname,
                                        timestamp: timestamp,
                                        previousPeerID: previousPeerID,
                                        signature: signature)
    }
}

// Binding between ephemeral peer ID and cryptographic identity
struct PeerIdentityBinding {
    let currentPeerID: String        // Current ephemeral ID
    let fingerprint: String          // Permanent cryptographic identity
    let publicKey: Data              // Noise static public key
    let signingPublicKey: Data       // Ed25519 signing public key
    let nickname: String             // Last known nickname
    let bindingTimestamp: Date       // When this binding was created
    let signature: Data              // Cryptographic proof of binding
    
    // Verify the binding signature
    func verify() -> Bool {
        let bindingData = currentPeerID.data(using: .utf8)! + publicKey + 
                         String(Int64(bindingTimestamp.timeIntervalSince1970 * 1000)).data(using: .utf8)!
        
        do {
            let signingKey = try Curve25519.Signing.PublicKey(rawRepresentation: signingPublicKey)
            return signingKey.isValidSignature(signature, for: bindingData)
        } catch {
            return false
        }
    }
}


// MARK: - Delivery Status

// Delivery status for messages
enum DeliveryStatus: Codable, Equatable {
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

// MARK: - Message Model

/// Represents a user-visible message in the BitChat system.
/// Handles both broadcast messages and private encrypted messages,
/// with support for mentions, replies, and delivery tracking.
/// - Note: This is the primary data model for chat messages
class BitchatMessage: Codable {
    let id: String
    let sender: String
    let content: String
    let timestamp: Date
    let isRelay: Bool
    let originalSender: String?
    let isPrivate: Bool
    let recipientNickname: String?
    let senderPeerID: String?
    let mentions: [String]?  // Array of mentioned nicknames
    var deliveryStatus: DeliveryStatus? // Delivery tracking
    
    // Cached formatted text (not included in Codable)
    private var _cachedFormattedText: [String: AttributedString] = [:]
    
    func getCachedFormattedText(isDark: Bool) -> AttributedString? {
        return _cachedFormattedText["\(isDark)"]
    }
    
    func setCachedFormattedText(_ text: AttributedString, isDark: Bool) {
        _cachedFormattedText["\(isDark)"] = text
    }
    
    // Codable implementation
    enum CodingKeys: String, CodingKey {
        case id, sender, content, timestamp, isRelay, originalSender
        case isPrivate, recipientNickname, senderPeerID, mentions, deliveryStatus
    }
    
    init(id: String? = nil, sender: String, content: String, timestamp: Date, isRelay: Bool, originalSender: String? = nil, isPrivate: Bool = false, recipientNickname: String? = nil, senderPeerID: String? = nil, mentions: [String]? = nil, deliveryStatus: DeliveryStatus? = nil) {
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
        self.deliveryStatus = deliveryStatus ?? (isPrivate ? .sending : nil)
    }
}

// Equatable conformance for BitchatMessage
extension BitchatMessage: Equatable {
    static func == (lhs: BitchatMessage, rhs: BitchatMessage) -> Bool {
        return lhs.id == rhs.id &&
               lhs.sender == rhs.sender &&
               lhs.content == rhs.content &&
               lhs.timestamp == rhs.timestamp &&
               lhs.isRelay == rhs.isRelay &&
               lhs.originalSender == rhs.originalSender &&
               lhs.isPrivate == rhs.isPrivate &&
               lhs.recipientNickname == rhs.recipientNickname &&
               lhs.senderPeerID == rhs.senderPeerID &&
               lhs.mentions == rhs.mentions &&
               lhs.deliveryStatus == rhs.deliveryStatus
    }
}

// MARK: - Delegate Protocol

protocol BitchatDelegate: AnyObject {
    func didReceiveMessage(_ message: BitchatMessage)
    func didConnectToPeer(_ peerID: String)
    func didDisconnectFromPeer(_ peerID: String)
    func didUpdatePeerList(_ peers: [String])
    
    // Optional method to check if a fingerprint belongs to a favorite peer
    func isFavorite(fingerprint: String) -> Bool
    
    // Delivery confirmation methods
    func didReceiveDeliveryAck(_ ack: DeliveryAck)
    func didReceiveReadReceipt(_ receipt: ReadReceipt)
    func didUpdateMessageDeliveryStatus(_ messageID: String, status: DeliveryStatus)
    
    // Peer availability tracking
    func peerAvailabilityChanged(_ peerID: String, available: Bool)
}

// Provide default implementation to make it effectively optional
extension BitchatDelegate {
    func isFavorite(fingerprint: String) -> Bool {
        return false
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
    
    func peerAvailabilityChanged(_ peerID: String, available: Bool) {
        // Default empty implementation
    }
}

// MARK: - Noise Payload Helpers

/// Helper to create typed Noise payloads
struct NoisePayload {
    let type: NoisePayloadType
    let data: Data
    
    /// Encode payload with type prefix
    func encode() -> Data {
        var encoded = Data()
        encoded.append(type.rawValue)
        encoded.append(data)
        return encoded
    }
    
    /// Decode payload from data
    static func decode(_ data: Data) -> NoisePayload? {
        // Ensure we have at least 1 byte for the type
        guard !data.isEmpty else {
            return nil
        }
        
        // Safely get the first byte
        let firstByte = data[data.startIndex]
        guard let type = NoisePayloadType(rawValue: firstByte) else {
            return nil
        }
        
        // Create a proper Data copy (not a subsequence) for thread safety
        let payloadData = data.count > 1 ? Data(data.dropFirst()) : Data()
        return NoisePayload(type: type, data: payloadData)
    }
}
