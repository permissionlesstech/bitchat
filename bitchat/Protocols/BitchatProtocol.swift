//
// BitchatProtocol.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import CryptoKit

// Privacy-preserving padding utilities
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
        let paddingLength = Int(data[data.count - 1])
        guard paddingLength > 0 && paddingLength <= data.count else { 
            // Debug logging for 243-byte packets
            if data.count == 243 {
            }
            return data 
        }
        
        let result = data.prefix(data.count - paddingLength)
        
        // Debug logging for 243-byte packets
        if data.count == 243 {
        }
        
        return result
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

enum MessageType: UInt8 {
    case announce = 0x01
    case leave = 0x03
    case message = 0x04  // All user messages (private and broadcast)
    case fragmentStart = 0x05
    case fragmentContinue = 0x06
    case fragmentEnd = 0x07
    case channelAnnounce = 0x08  // Announce password-protected channel status
    case deliveryAck = 0x0A  // Acknowledge message received
    case deliveryStatusRequest = 0x0B  // Request delivery status update
    case readReceipt = 0x0C  // Message has been read/viewed
    
    // Noise Protocol messages
    case noiseHandshakeInit = 0x10  // Noise handshake initiation
    case noiseHandshakeResp = 0x11  // Noise handshake response
    case noiseEncrypted = 0x12      // Noise encrypted transport message
    case noiseIdentityAnnounce = 0x13  // Announce static public key for discovery
    case channelKeyVerifyRequest = 0x14  // Request key verification for a channel
    case channelKeyVerifyResponse = 0x15 // Response to key verification request
    case channelPasswordUpdate = 0x16    // Distribute new password to channel members
    case channelMetadata = 0x17         // Announce channel creator and metadata
    
    // Protocol version negotiation
    case versionHello = 0x20            // Initial version announcement
    case versionAck = 0x21              // Version acknowledgment
    
    var description: String {
        switch self {
        case .announce: return "announce"
        case .leave: return "leave"
        case .message: return "message"
        case .fragmentStart: return "fragmentStart"
        case .fragmentContinue: return "fragmentContinue"
        case .fragmentEnd: return "fragmentEnd"
        case .channelAnnounce: return "channelAnnounce"
        case .deliveryAck: return "deliveryAck"
        case .deliveryStatusRequest: return "deliveryStatusRequest"
        case .readReceipt: return "readReceipt"
        case .noiseHandshakeInit: return "noiseHandshakeInit"
        case .noiseHandshakeResp: return "noiseHandshakeResp"
        case .noiseEncrypted: return "noiseEncrypted"
        case .noiseIdentityAnnounce: return "noiseIdentityAnnounce"
        case .channelKeyVerifyRequest: return "channelKeyVerifyRequest"
        case .channelKeyVerifyResponse: return "channelKeyVerifyResponse"
        case .channelPasswordUpdate: return "channelPasswordUpdate"
        case .channelMetadata: return "channelMetadata"
        case .versionHello: return "versionHello"
        case .versionAck: return "versionAck"
        }
    }
}

// Special recipient ID for broadcast messages
struct SpecialRecipients {
    static let broadcast = Data(repeating: 0xFF, count: 8)  // All 0xFF = broadcast
}

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

// Delivery acknowledgment structure
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
        
        guard let hopCount = dataCopy.readUInt8(at: &offset),
              let timestamp = dataCopy.readDate(at: &offset),
              let recipientNickname = dataCopy.readString(at: &offset) else { return nil }
        
        return DeliveryAck(originalMessageID: originalMessageID,
                           ackID: ackID,
                           recipientID: recipientID,
                           recipientNickname: recipientNickname,
                           timestamp: timestamp,
                           hopCount: hopCount)
    }
}

// Read receipt structure
struct ReadReceipt: Codable {
    let originalMessageID: String
    let receiptID: String
    let readerID: String  // Who read it
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
        
        guard let timestamp = dataCopy.readDate(at: &offset),
              let readerNickname = dataCopy.readString(at: &offset) else { return nil }
        
        return ReadReceipt(originalMessageID: originalMessageID,
                          receiptID: receiptID,
                          readerID: readerID,
                          readerNickname: readerNickname,
                          timestamp: timestamp)
    }
}

// Channel key verification request
struct ChannelKeyVerifyRequest: Codable {
    let channel: String
    let requesterID: String
    let keyCommitment: String  // SHA256 hash of the key they have
    let timestamp: Date
    
    init(channel: String, requesterID: String, keyCommitment: String) {
        self.channel = channel
        self.requesterID = requesterID
        self.keyCommitment = keyCommitment
        self.timestamp = Date()
    }
    
    // For binary decoding
    private init(channel: String, requesterID: String, keyCommitment: String, timestamp: Date) {
        self.channel = channel
        self.requesterID = requesterID
        self.keyCommitment = keyCommitment
        self.timestamp = timestamp
    }
    
    func encode() -> Data? {
        return try? JSONEncoder().encode(self)
    }
    
    static func decode(from data: Data) -> ChannelKeyVerifyRequest? {
        try? JSONDecoder().decode(ChannelKeyVerifyRequest.self, from: data)
    }
    
    // MARK: - Binary Encoding
    
    func toBinaryData() -> Data {
        var data = Data()
        data.appendString(channel)
        // RequesterID as 8-byte hex string
        var requesterData = Data()
        var tempID = requesterID
        while tempID.count >= 2 && requesterData.count < 8 {
            let hexByte = String(tempID.prefix(2))
            if let byte = UInt8(hexByte, radix: 16) {
                requesterData.append(byte)
            }
            tempID = String(tempID.dropFirst(2))
        }
        while requesterData.count < 8 {
            requesterData.append(0)
        }
        data.append(requesterData)
        data.appendString(keyCommitment)
        data.appendDate(timestamp)
        return data
    }
    
    static func fromBinaryData(_ data: Data) -> ChannelKeyVerifyRequest? {
        // Create defensive copy
        let dataCopy = Data(data)
        
        var offset = 0
        
        guard let channel = dataCopy.readString(at: &offset) else { return nil }
        
        guard let requesterIDData = dataCopy.readFixedBytes(at: &offset, count: 8) else { return nil }
        let requesterID = requesterIDData.hexEncodedString()
        
        guard let keyCommitment = dataCopy.readString(at: &offset),
              let timestamp = dataCopy.readDate(at: &offset) else { return nil }
        
        return ChannelKeyVerifyRequest(channel: channel,
                                       requesterID: requesterID,
                                       keyCommitment: keyCommitment,
                                       timestamp: timestamp)
    }
}

// Channel key verification response
struct ChannelKeyVerifyResponse: Codable {
    let channel: String
    let responderID: String
    let verified: Bool  // Whether the key commitment matches
    let timestamp: Date
    
    init(channel: String, responderID: String, verified: Bool) {
        self.channel = channel
        self.responderID = responderID
        self.verified = verified
        self.timestamp = Date()
    }
    
    // For binary decoding
    private init(channel: String, responderID: String, verified: Bool, timestamp: Date) {
        self.channel = channel
        self.responderID = responderID
        self.verified = verified
        self.timestamp = timestamp
    }
    
    func encode() -> Data? {
        return try? JSONEncoder().encode(self)
    }
    
    static func decode(from data: Data) -> ChannelKeyVerifyResponse? {
        try? JSONDecoder().decode(ChannelKeyVerifyResponse.self, from: data)
    }
    
    // MARK: - Binary Encoding
    
    func toBinaryData() -> Data {
        var data = Data()
        data.appendString(channel)
        // ResponderID as 8-byte hex string
        var responderData = Data()
        var tempID = responderID
        while tempID.count >= 2 && responderData.count < 8 {
            let hexByte = String(tempID.prefix(2))
            if let byte = UInt8(hexByte, radix: 16) {
                responderData.append(byte)
            }
            tempID = String(tempID.dropFirst(2))
        }
        while responderData.count < 8 {
            responderData.append(0)
        }
        data.append(responderData)
        data.appendUInt8(verified ? 1 : 0)
        data.appendDate(timestamp)
        return data
    }
    
    static func fromBinaryData(_ data: Data) -> ChannelKeyVerifyResponse? {
        // Create defensive copy
        let dataCopy = Data(data)
        
        var offset = 0
        
        guard let channel = dataCopy.readString(at: &offset) else { return nil }
        
        guard let responderIDData = dataCopy.readFixedBytes(at: &offset, count: 8) else { return nil }
        let responderID = responderIDData.hexEncodedString()
        
        guard let verifiedByte = dataCopy.readUInt8(at: &offset),
              let timestamp = dataCopy.readDate(at: &offset) else { return nil }
        
        let verified = verifiedByte != 0
        
        return ChannelKeyVerifyResponse(channel: channel,
                                        responderID: responderID,
                                        verified: verified,
                                        timestamp: timestamp)
    }
}

// Channel password update (sent by owner to members)
struct ChannelPasswordUpdate: Codable {
    let channel: String
    let ownerID: String  // Deprecated, kept for backward compatibility
    let ownerFingerprint: String  // Noise protocol fingerprint of owner
    let encryptedPassword: Data  // New password encrypted with recipient's Noise session
    let newKeyCommitment: String  // SHA256 of new key for verification
    let timestamp: Date
    
    init(channel: String, ownerID: String, ownerFingerprint: String, encryptedPassword: Data, newKeyCommitment: String) {
        self.channel = channel
        self.ownerID = ownerID
        self.ownerFingerprint = ownerFingerprint
        self.encryptedPassword = encryptedPassword
        self.newKeyCommitment = newKeyCommitment
        self.timestamp = Date()
    }
    
    // For binary decoding
    private init(channel: String, ownerID: String, ownerFingerprint: String, encryptedPassword: Data, newKeyCommitment: String, timestamp: Date) {
        self.channel = channel
        self.ownerID = ownerID
        self.ownerFingerprint = ownerFingerprint
        self.encryptedPassword = encryptedPassword
        self.newKeyCommitment = newKeyCommitment
        self.timestamp = timestamp
    }
    
    func encode() -> Data? {
        return try? JSONEncoder().encode(self)
    }
    
    static func decode(from data: Data) -> ChannelPasswordUpdate? {
        try? JSONDecoder().decode(ChannelPasswordUpdate.self, from: data)
    }
    
    // MARK: - Binary Encoding
    
    func toBinaryData() -> Data {
        var data = Data()
        data.appendString(channel)
        // OwnerID as 8-byte hex string
        var ownerData = Data()
        var tempID = ownerID
        while tempID.count >= 2 && ownerData.count < 8 {
            let hexByte = String(tempID.prefix(2))
            if let byte = UInt8(hexByte, radix: 16) {
                ownerData.append(byte)
            }
            tempID = String(tempID.dropFirst(2))
        }
        while ownerData.count < 8 {
            ownerData.append(0)
        }
        data.append(ownerData)
        data.appendString(ownerFingerprint)
        data.appendData(encryptedPassword)
        data.appendString(newKeyCommitment)
        data.appendDate(timestamp)
        return data
    }
    
    static func fromBinaryData(_ data: Data) -> ChannelPasswordUpdate? {
        // Create defensive copy
        let dataCopy = Data(data)
        
        var offset = 0
        
        guard let channel = dataCopy.readString(at: &offset) else { return nil }
        
        guard let ownerIDData = dataCopy.readFixedBytes(at: &offset, count: 8) else { return nil }
        let ownerID = ownerIDData.hexEncodedString()
        
        guard let ownerFingerprint = dataCopy.readString(at: &offset),
              let encryptedPassword = dataCopy.readData(at: &offset),
              let newKeyCommitment = dataCopy.readString(at: &offset),
              let timestamp = dataCopy.readDate(at: &offset) else { return nil }
        
        return ChannelPasswordUpdate(channel: channel,
                                     ownerID: ownerID,
                                     ownerFingerprint: ownerFingerprint,
                                     encryptedPassword: encryptedPassword,
                                     newKeyCommitment: newKeyCommitment,
                                     timestamp: timestamp)
    }
}

// Channel metadata announcement
struct ChannelMetadata: Codable {
    let channel: String
    let creatorID: String
    let creatorFingerprint: String  // Noise protocol fingerprint
    let createdAt: Date
    let isPasswordProtected: Bool
    let keyCommitment: String?  // SHA256 of channel key if password-protected
    
    init(channel: String, creatorID: String, creatorFingerprint: String, isPasswordProtected: Bool, keyCommitment: String?) {
        self.channel = channel
        self.creatorID = creatorID
        self.creatorFingerprint = creatorFingerprint
        self.createdAt = Date()
        self.isPasswordProtected = isPasswordProtected
        self.keyCommitment = keyCommitment
    }
    
    // For binary decoding
    private init(channel: String, creatorID: String, creatorFingerprint: String, createdAt: Date, isPasswordProtected: Bool, keyCommitment: String?) {
        self.channel = channel
        self.creatorID = creatorID
        self.creatorFingerprint = creatorFingerprint
        self.createdAt = createdAt
        self.isPasswordProtected = isPasswordProtected
        self.keyCommitment = keyCommitment
    }
    
    func encode() -> Data? {
        return try? JSONEncoder().encode(self)
    }
    
    static func decode(from data: Data) -> ChannelMetadata? {
        try? JSONDecoder().decode(ChannelMetadata.self, from: data)
    }
    
    // MARK: - Binary Encoding
    
    func toBinaryData() -> Data {
        var data = Data()
        
        // Flags byte: bit 0 = hasKeyCommitment
        var flags: UInt8 = 0
        if keyCommitment != nil { flags |= 0x01 }
        data.appendUInt8(flags)
        
        data.appendString(channel)
        // CreatorID as 8-byte hex string
        var creatorData = Data()
        var tempID = creatorID
        while tempID.count >= 2 && creatorData.count < 8 {
            let hexByte = String(tempID.prefix(2))
            if let byte = UInt8(hexByte, radix: 16) {
                creatorData.append(byte)
            }
            tempID = String(tempID.dropFirst(2))
        }
        while creatorData.count < 8 {
            creatorData.append(0)
        }
        data.append(creatorData)
        data.appendString(creatorFingerprint)
        data.appendDate(createdAt)
        data.appendUInt8(isPasswordProtected ? 1 : 0)
        
        if let keyCommitment = keyCommitment {
            data.appendString(keyCommitment)
        }
        
        return data
    }
    
    static func fromBinaryData(_ data: Data) -> ChannelMetadata? {
        // Create defensive copy
        let dataCopy = Data(data)
        
        var offset = 0
        
        guard let flags = dataCopy.readUInt8(at: &offset) else { return nil }
        let hasKeyCommitment = (flags & 0x01) != 0
        
        guard let channel = dataCopy.readString(at: &offset) else { return nil }
        
        guard let creatorIDData = dataCopy.readFixedBytes(at: &offset, count: 8) else { return nil }
        let creatorID = creatorIDData.hexEncodedString()
        
        guard let creatorFingerprint = dataCopy.readString(at: &offset),
              let createdAt = dataCopy.readDate(at: &offset),
              let isPasswordProtectedByte = dataCopy.readUInt8(at: &offset) else { return nil }
        
        let isPasswordProtected = isPasswordProtectedByte != 0
        
        var keyCommitment: String? = nil
        if hasKeyCommitment {
            keyCommitment = dataCopy.readString(at: &offset)
        }
        
        return ChannelMetadata(channel: channel,
                              creatorID: creatorID,
                              creatorFingerprint: creatorFingerprint,
                              createdAt: createdAt,
                              isPasswordProtected: isPasswordProtected,
                              keyCommitment: keyCommitment)
    }
}

// MARK: - Peer Identity Rotation

// Enhanced identity announcement with rotation support
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
        self.nickname = nickname
        self.timestamp = timestamp
        self.previousPeerID = previousPeerID
        self.signature = signature
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
        
        guard let publicKey = dataCopy.readData(at: &offset),
              let signingPublicKey = dataCopy.readData(at: &offset),
              let nickname = dataCopy.readString(at: &offset),
              let timestamp = dataCopy.readDate(at: &offset) else { return nil }
        
        var previousPeerID: String? = nil
        if hasPreviousPeerID {
            // Read previousPeerID using safe method
            guard let prevIDBytes = dataCopy.readFixedBytes(at: &offset, count: 8) else { return nil }
            previousPeerID = prevIDBytes.hexEncodedString()
        }
        
        guard let signature = dataCopy.readData(at: &offset) else { return nil }
        
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

// MARK: - Protocol Version Negotiation

// Protocol version constants
struct ProtocolVersion {
    static let current: UInt8 = 1
    static let minimum: UInt8 = 1
    static let maximum: UInt8 = 1
    
    // Future versions can be added here
    static let supportedVersions: Set<UInt8> = [1]
    
    static func isSupported(_ version: UInt8) -> Bool {
        return supportedVersions.contains(version)
    }
    
    static func negotiateVersion(clientVersions: [UInt8], serverVersions: [UInt8]) -> UInt8? {
        // Find the highest common version
        let clientSet = Set(clientVersions)
        let serverSet = Set(serverVersions)
        let common = clientSet.intersection(serverSet)
        
        return common.max()
    }
}

// Version negotiation hello message
struct VersionHello: Codable {
    let supportedVersions: [UInt8]  // List of supported protocol versions
    let preferredVersion: UInt8     // Preferred version (usually the latest)
    let clientVersion: String       // App version string (e.g., "1.0.0")
    let platform: String            // Platform identifier (e.g., "iOS", "macOS")
    let capabilities: [String]?     // Optional capability flags for future extensions
    
    init(supportedVersions: [UInt8] = Array(ProtocolVersion.supportedVersions), 
         preferredVersion: UInt8 = ProtocolVersion.current,
         clientVersion: String,
         platform: String,
         capabilities: [String]? = nil) {
        self.supportedVersions = supportedVersions
        self.preferredVersion = preferredVersion
        self.clientVersion = clientVersion
        self.platform = platform
        self.capabilities = capabilities
    }
    
    func encode() -> Data? {
        return try? JSONEncoder().encode(self)
    }
    
    static func decode(from data: Data) -> VersionHello? {
        try? JSONDecoder().decode(VersionHello.self, from: data)
    }
    
    // MARK: - Binary Encoding
    
    func toBinaryData() -> Data {
        var data = Data()
        
        // Flags byte: bit 0 = hasCapabilities
        var flags: UInt8 = 0
        if capabilities != nil { flags |= 0x01 }
        data.appendUInt8(flags)
        
        // Supported versions array
        data.appendUInt8(UInt8(supportedVersions.count))
        for version in supportedVersions {
            data.appendUInt8(version)
        }
        
        data.appendUInt8(preferredVersion)
        data.appendString(clientVersion)
        data.appendString(platform)
        
        if let capabilities = capabilities {
            data.appendUInt8(UInt8(capabilities.count))
            for capability in capabilities {
                data.appendString(capability)
            }
        }
        
        return data
    }
    
    static func fromBinaryData(_ data: Data) -> VersionHello? {
        // Create defensive copy
        let dataCopy = Data(data)
        
        // Minimum size check: flags(1) + versionCount(1) + at least one version(1) + preferredVersion(1) + min strings
        guard dataCopy.count >= 4 else { return nil }
        
        var offset = 0
        
        guard let flags = dataCopy.readUInt8(at: &offset) else { return nil }
        let hasCapabilities = (flags & 0x01) != 0
        
        guard let versionCount = dataCopy.readUInt8(at: &offset) else { return nil }
        var supportedVersions: [UInt8] = []
        for _ in 0..<versionCount {
            guard let version = dataCopy.readUInt8(at: &offset) else { return nil }
            supportedVersions.append(version)
        }
        
        guard let preferredVersion = dataCopy.readUInt8(at: &offset),
              let clientVersion = dataCopy.readString(at: &offset),
              let platform = dataCopy.readString(at: &offset) else { return nil }
        
        var capabilities: [String]? = nil
        if hasCapabilities {
            guard let capCount = dataCopy.readUInt8(at: &offset) else { return nil }
            capabilities = []
            for _ in 0..<capCount {
                guard let capability = dataCopy.readString(at: &offset) else { return nil }
                capabilities?.append(capability)
            }
        }
        
        return VersionHello(supportedVersions: supportedVersions,
                           preferredVersion: preferredVersion,
                           clientVersion: clientVersion,
                           platform: platform,
                           capabilities: capabilities)
    }
}

// Version negotiation acknowledgment
struct VersionAck: Codable {
    let agreedVersion: UInt8        // The version both peers will use
    let serverVersion: String       // Responder's app version
    let platform: String            // Responder's platform
    let capabilities: [String]?     // Responder's capabilities
    let rejected: Bool              // True if no compatible version found
    let reason: String?             // Reason for rejection if applicable
    
    init(agreedVersion: UInt8,
         serverVersion: String,
         platform: String,
         capabilities: [String]? = nil,
         rejected: Bool = false,
         reason: String? = nil) {
        self.agreedVersion = agreedVersion
        self.serverVersion = serverVersion
        self.platform = platform
        self.capabilities = capabilities
        self.rejected = rejected
        self.reason = reason
    }
    
    func encode() -> Data? {
        return try? JSONEncoder().encode(self)
    }
    
    static func decode(from data: Data) -> VersionAck? {
        try? JSONDecoder().decode(VersionAck.self, from: data)
    }
    
    // MARK: - Binary Encoding
    
    func toBinaryData() -> Data {
        var data = Data()
        
        // Flags byte: bit 0 = hasCapabilities, bit 1 = hasReason
        var flags: UInt8 = 0
        if capabilities != nil { flags |= 0x01 }
        if reason != nil { flags |= 0x02 }
        data.appendUInt8(flags)
        
        data.appendUInt8(agreedVersion)
        data.appendString(serverVersion)
        data.appendString(platform)
        data.appendUInt8(rejected ? 1 : 0)
        
        if let capabilities = capabilities {
            data.appendUInt8(UInt8(capabilities.count))
            for capability in capabilities {
                data.appendString(capability)
            }
        }
        
        if let reason = reason {
            data.appendString(reason)
        }
        
        return data
    }
    
    static func fromBinaryData(_ data: Data) -> VersionAck? {
        // Create defensive copy
        let dataCopy = Data(data)
        
        // Minimum size: flags(1) + version(1) + rejected(1) + min strings
        guard dataCopy.count >= 5 else { return nil }
        
        var offset = 0
        
        guard let flags = dataCopy.readUInt8(at: &offset) else { return nil }
        let hasCapabilities = (flags & 0x01) != 0
        let hasReason = (flags & 0x02) != 0
        
        guard let agreedVersion = dataCopy.readUInt8(at: &offset),
              let serverVersion = dataCopy.readString(at: &offset),
              let platform = dataCopy.readString(at: &offset),
              let rejectedByte = dataCopy.readUInt8(at: &offset) else { return nil }
        
        let rejected = rejectedByte != 0
        
        var capabilities: [String]? = nil
        if hasCapabilities {
            guard let capCount = dataCopy.readUInt8(at: &offset) else { return nil }
            capabilities = []
            for _ in 0..<capCount {
                guard let capability = dataCopy.readString(at: &offset) else { return nil }
                capabilities?.append(capability)
            }
        }
        
        var reason: String? = nil
        if hasReason {
            reason = dataCopy.readString(at: &offset)
        }
        
        return VersionAck(agreedVersion: agreedVersion,
                         serverVersion: serverVersion,
                         platform: platform,
                         capabilities: capabilities,
                         rejected: rejected,
                         reason: reason)
    }
}

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

struct BitchatMessage: Codable, Equatable {
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
    let channel: String?  // Channel hashtag (e.g., "#general")
    let encryptedContent: Data?  // For password-protected rooms
    let isEncrypted: Bool  // Flag to indicate if content is encrypted
    var deliveryStatus: DeliveryStatus? // Delivery tracking
    
    init(id: String? = nil, sender: String, content: String, timestamp: Date, isRelay: Bool, originalSender: String? = nil, isPrivate: Bool = false, recipientNickname: String? = nil, senderPeerID: String? = nil, mentions: [String]? = nil, channel: String? = nil, encryptedContent: Data? = nil, isEncrypted: Bool = false, deliveryStatus: DeliveryStatus? = nil) {
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
        self.channel = channel
        self.encryptedContent = encryptedContent
        self.isEncrypted = isEncrypted
        self.deliveryStatus = deliveryStatus ?? (isPrivate ? .sending : nil)
    }
}

protocol BitchatDelegate: AnyObject {
    func didReceiveMessage(_ message: BitchatMessage)
    func didConnectToPeer(_ peerID: String)
    func didDisconnectFromPeer(_ peerID: String)
    func didUpdatePeerList(_ peers: [String])
    func didReceiveChannelLeave(_ channel: String, from peerID: String)
    func didReceivePasswordProtectedChannelAnnouncement(_ channel: String, isProtected: Bool, creatorID: String?, keyCommitment: String?)
    func didReceiveChannelRetentionAnnouncement(_ channel: String, enabled: Bool, creatorID: String?)
    func decryptChannelMessage(_ encryptedContent: Data, channel: String) -> String?
    
    // Optional method to check if a fingerprint belongs to a favorite peer
    func isFavorite(fingerprint: String) -> Bool
    
    // Delivery confirmation methods
    func didReceiveDeliveryAck(_ ack: DeliveryAck)
    func didReceiveReadReceipt(_ receipt: ReadReceipt)
    func didUpdateMessageDeliveryStatus(_ messageID: String, status: DeliveryStatus)
    
    // Channel key verification methods
    func didReceiveChannelKeyVerifyRequest(_ request: ChannelKeyVerifyRequest, from peerID: String)
    func didReceiveChannelKeyVerifyResponse(_ response: ChannelKeyVerifyResponse, from peerID: String)
    func didReceiveChannelPasswordUpdate(_ update: ChannelPasswordUpdate, from peerID: String)
    
    // Channel metadata methods
    func didReceiveChannelMetadata(_ metadata: ChannelMetadata, from peerID: String)
}

// Provide default implementation to make it effectively optional
extension BitchatDelegate {
    func isFavorite(fingerprint: String) -> Bool {
        return false
    }
    
    func didReceiveChannelLeave(_ channel: String, from peerID: String) {
        // Default empty implementation
    }
    
    func didReceivePasswordProtectedChannelAnnouncement(_ channel: String, isProtected: Bool, creatorID: String?, keyCommitment: String?) {
        // Default empty implementation
    }
    
    func didReceiveChannelRetentionAnnouncement(_ channel: String, enabled: Bool, creatorID: String?) {
        // Default empty implementation
    }
    
    func decryptChannelMessage(_ encryptedContent: Data, channel: String) -> String? {
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
    
    func didReceiveChannelKeyVerifyRequest(_ request: ChannelKeyVerifyRequest, from peerID: String) {
        // Default empty implementation
    }
    
    func didReceiveChannelKeyVerifyResponse(_ response: ChannelKeyVerifyResponse, from peerID: String) {
        // Default empty implementation
    }
    
    func didReceiveChannelPasswordUpdate(_ update: ChannelPasswordUpdate, from peerID: String) {
        // Default empty implementation
    }
    
    func didReceiveChannelMetadata(_ metadata: ChannelMetadata, from peerID: String) {
        // Default empty implementation
    }
}