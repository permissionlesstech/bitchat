//
// BinaryProtocol.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

extension Data {
    func trimmingNullBytes() -> Data {
        // Find the first null byte
        if let nullIndex = self.firstIndex(of: 0) {
            return self.prefix(nullIndex)
        }
        return self
    }
    
    /// Safely extract a subrange from Data with bounds checking
    func safeSubdata(in range: Range<Int>) -> Data? {
        guard range.lowerBound >= 0,
              range.upperBound <= self.count,
              range.lowerBound < range.upperBound else {
            return nil
        }
        return self[range]
    }
    
    /// Safely extract bytes at a specific offset with length
    func safeSubdata(from offset: Int, length: Int) -> Data? {
        guard offset >= 0,
              length >= 0,
              offset + length <= self.count else {
            return nil
        }
        return self[offset..<(offset + length)]
    }
}

// Binary Protocol Format:
// Header (Fixed 13 bytes):
// - Version: 1 byte
// - Type: 1 byte  
// - TTL: 1 byte
// - Timestamp: 8 bytes (UInt64)
// - Flags: 1 byte (bit 0: hasRecipient, bit 1: hasSignature)
// - PayloadLength: 2 bytes (UInt16)
//
// Variable sections:
// - SenderID: 8 bytes (fixed)
// - RecipientID: 8 bytes (if hasRecipient flag set)
// - Payload: Variable length
// - Signature: 64 bytes (if hasSignature flag set)

struct BinaryProtocol {
    static let headerSize = 13
    static let senderIDSize = 8
    static let recipientIDSize = 8
    static let signatureSize = 64
    
    // Maximum size limits for security
    static let maxPayloadSize = 1024 * 1024 // 1MB
    static let maxStringFieldSize = 65535
    static let maxMentionsCount = 100
    static let maxChannelLength = 255
    
    struct Flags {
        static let hasRecipient: UInt8 = 0x01
        static let hasSignature: UInt8 = 0x02
        static let isCompressed: UInt8 = 0x04
    }
    
    // Encode BitchatPacket to binary format
    static func encode(_ packet: BitchatPacket) -> Data? {
        var data = Data()
        
        // Try to compress payload if beneficial
        var payload = packet.payload
        var originalPayloadSize: UInt16? = nil
        var isCompressed = false
        
        if CompressionUtil.shouldCompress(payload),
           let compressedPayload = CompressionUtil.compress(payload) {
            // Store original size for decompression (2 bytes after payload)
            originalPayloadSize = UInt16(payload.count)
            payload = compressedPayload
            isCompressed = true
        }
        
        // Header
        data.append(packet.version)
        data.append(packet.type)
        data.append(packet.ttl)
        
        // Timestamp (8 bytes, big-endian)
        for i in (0..<8).reversed() {
            data.append(UInt8((packet.timestamp >> (i * 8)) & 0xFF))
        }
        
        // Flags
        var flags: UInt8 = 0
        if packet.recipientID != nil {
            flags |= Flags.hasRecipient
        }
        if packet.signature != nil {
            flags |= Flags.hasSignature
        }
        if isCompressed {
            flags |= Flags.isCompressed
        }
        data.append(flags)
        
        // Payload length (2 bytes, big-endian) - includes original size if compressed
        let payloadDataSize = payload.count + (isCompressed ? 2 : 0)
        let payloadLength = UInt16(payloadDataSize)
        data.append(UInt8((payloadLength >> 8) & 0xFF))
        data.append(UInt8(payloadLength & 0xFF))
        
        // SenderID (exactly 8 bytes)
        let senderBytes = packet.senderID.prefix(senderIDSize)
        data.append(senderBytes)
        if senderBytes.count < senderIDSize {
            data.append(Data(repeating: 0, count: senderIDSize - senderBytes.count))
        }
        
        // RecipientID (if present)
        if let recipientID = packet.recipientID {
            let recipientBytes = recipientID.prefix(recipientIDSize)
            data.append(recipientBytes)
            if recipientBytes.count < recipientIDSize {
                data.append(Data(repeating: 0, count: recipientIDSize - recipientBytes.count))
            }
        }
        
        // Payload (with original size prepended if compressed)
        if isCompressed, let originalSize = originalPayloadSize {
            // Prepend original size (2 bytes, big-endian)
            data.append(UInt8((originalSize >> 8) & 0xFF))
            data.append(UInt8(originalSize & 0xFF))
        }
        data.append(payload)
        
        // Signature (if present)
        if let signature = packet.signature {
            data.append(signature.prefix(signatureSize))
        }
        
        return data
    }
    
    // Decode binary data to BitchatPacket
    static func decode(_ data: Data) -> BitchatPacket? {
        guard data.count >= headerSize + senderIDSize else { return nil }
        
        var offset = 0
        
        // Header
        let version = data[offset]; offset += 1
        // Only support version 1
        guard version == 1 else { return nil }
        let type = data[offset]; offset += 1
        let ttl = data[offset]; offset += 1
        
        // Timestamp
        guard let timestampData = data.safeSubdata(from: offset, length: 8) else { return nil }
        let timestamp = timestampData.reduce(0) { result, byte in
            (result << 8) | UInt64(byte)
        }
        offset += 8
        
        // Flags
        let flags = data[offset]; offset += 1
        let hasRecipient = (flags & Flags.hasRecipient) != 0
        let hasSignature = (flags & Flags.hasSignature) != 0
        let isCompressed = (flags & Flags.isCompressed) != 0
        
        // Payload length
        guard let payloadLengthData = data.safeSubdata(from: offset, length: 2) else { return nil }
        let payloadLength = payloadLengthData.reduce(0) { result, byte in
            (result << 8) | UInt16(byte)
        }
        offset += 2
        
        // Validate payload size
        guard payloadLength <= maxPayloadSize else { return nil }
        
        // Calculate expected total size
        var expectedSize = headerSize + senderIDSize + Int(payloadLength)
        if hasRecipient {
            expectedSize += recipientIDSize
        }
        if hasSignature {
            expectedSize += signatureSize
        }
        
        guard data.count >= expectedSize else { return nil }
        
        // SenderID
        guard let senderID = data.safeSubdata(from: offset, length: senderIDSize) else { return nil }
        offset += senderIDSize
        
        // RecipientID
        var recipientID: Data?
        if hasRecipient {
            guard let rid = data.safeSubdata(from: offset, length: recipientIDSize) else { return nil }
            recipientID = rid
            offset += recipientIDSize
        }
        
        // Payload
        let payload: Data
        if isCompressed {
            // First 2 bytes are original size
            guard Int(payloadLength) >= 2 else { return nil }
            guard let originalSizeData = data.safeSubdata(from: offset, length: 2) else { return nil }
            let originalSize = Int(originalSizeData.reduce(0) { result, byte in
                (result << 8) | UInt16(byte)
            })
            offset += 2
            
            // Validate original size
            guard originalSize > 0 && originalSize <= maxPayloadSize else { return nil }
            
            // Compressed payload
            let compressedLength = Int(payloadLength) - 2
            guard compressedLength > 0 else { return nil }
            guard let compressedPayload = data.safeSubdata(from: offset, length: compressedLength) else { return nil }
            offset += compressedLength
            
            // Decompress
            guard let decompressedPayload = CompressionUtil.decompress(compressedPayload, originalSize: originalSize) else {
                return nil
            }
            payload = decompressedPayload
        } else {
            guard let payloadData = data.safeSubdata(from: offset, length: Int(payloadLength)) else { return nil }
            payload = payloadData
            offset += Int(payloadLength)
        }
        
        // Signature
        var signature: Data?
        if hasSignature {
            guard let sig = data.safeSubdata(from: offset, length: signatureSize) else { return nil }
            signature = sig
        }
        
        return BitchatPacket(
            type: type,
            senderID: senderID,
            recipientID: recipientID,
            timestamp: timestamp,
            payload: payload,
            signature: signature,
            ttl: ttl
        )
    }
}

// Binary encoding for BitchatMessage
extension BitchatMessage {
    func toBinaryPayload() -> Data? {
        var data = Data()
        
        // Message format:
        // - Flags: 1 byte (bit 0: isRelay, bit 1: isPrivate, bit 2: hasOriginalSender, bit 3: hasRecipientNickname, bit 4: hasSenderPeerID, bit 5: hasMentions, bit 6: hasChannel, bit 7: isEncrypted)
        // - Timestamp: 8 bytes (seconds since epoch)
        // - ID length: 1 byte
        // - ID: variable
        // - Sender length: 1 byte
        // - Sender: variable
        // - Content length: 2 bytes
        // - Content: variable (or encrypted content if isEncrypted)
        // Optional fields based on flags:
        // - Original sender length + data
        // - Recipient nickname length + data
        // - Sender peer ID length + data
        // - Mentions array
        // - Channel hashtag
        
        var flags: UInt8 = 0
        if isRelay { flags |= 0x01 }
        if isPrivate { flags |= 0x02 }
        if originalSender != nil { flags |= 0x04 }
        if recipientNickname != nil { flags |= 0x08 }
        if senderPeerID != nil { flags |= 0x10 }
        if mentions != nil && !mentions!.isEmpty { flags |= 0x20 }
        if channel != nil { flags |= 0x40 }
        if isEncrypted { flags |= 0x80 }
        
        data.append(flags)
        
        // Timestamp (in milliseconds)
        let timestampMillis = UInt64(timestamp.timeIntervalSince1970 * 1000)
        // Encode as 8 bytes, big-endian
        for i in (0..<8).reversed() {
            data.append(UInt8((timestampMillis >> (i * 8)) & 0xFF))
        }
        
        // ID
        if let idData = id.data(using: .utf8) {
            data.append(UInt8(min(idData.count, 255)))
            data.append(idData.prefix(255))
        } else {
            data.append(0)
        }
        
        // Sender
        if let senderData = sender.data(using: .utf8) {
            data.append(UInt8(min(senderData.count, 255)))
            data.append(senderData.prefix(255))
        } else {
            data.append(0)
        }
        
        // Content or encrypted content
        if isEncrypted, let encryptedContent = encryptedContent {
            let length = UInt16(min(encryptedContent.count, 65535))
            // Encode length as 2 bytes, big-endian
            data.append(UInt8((length >> 8) & 0xFF))
            data.append(UInt8(length & 0xFF))
            data.append(encryptedContent.prefix(Int(length)))
        } else if let contentData = content.data(using: .utf8) {
            let length = UInt16(min(contentData.count, 65535))
            // Encode length as 2 bytes, big-endian
            data.append(UInt8((length >> 8) & 0xFF))
            data.append(UInt8(length & 0xFF))
            data.append(contentData.prefix(Int(length)))
        } else {
            data.append(contentsOf: [0, 0])
        }
        
        // Optional fields
        if let originalSender = originalSender, let origData = originalSender.data(using: .utf8) {
            data.append(UInt8(min(origData.count, 255)))
            data.append(origData.prefix(255))
        }
        
        if let recipientNickname = recipientNickname, let recipData = recipientNickname.data(using: .utf8) {
            data.append(UInt8(min(recipData.count, 255)))
            data.append(recipData.prefix(255))
        }
        
        if let senderPeerID = senderPeerID, let peerData = senderPeerID.data(using: .utf8) {
            data.append(UInt8(min(peerData.count, 255)))
            data.append(peerData.prefix(255))
        }
        
        // Mentions array
        if let mentions = mentions {
            data.append(UInt8(min(mentions.count, 255))) // Number of mentions
            for mention in mentions.prefix(255) {
                if let mentionData = mention.data(using: .utf8) {
                    data.append(UInt8(min(mentionData.count, 255)))
                    data.append(mentionData.prefix(255))
                } else {
                    data.append(0)
                }
            }
        }
        
        // Channel hashtag
        if let channel = channel, let channelData = channel.data(using: .utf8) {
            data.append(UInt8(min(channelData.count, 255)))
            data.append(channelData.prefix(255))
        }
        
        return data
    }
    
    static func fromBinaryPayload(_ data: Data) -> BitchatMessage? {
        // Create an immutable copy to prevent threading issues
        let dataCopy = Data(data)
        
        
        guard dataCopy.count >= 13 else { 
            return nil 
        }
        
        var offset = 0
        
        // Flags
        guard offset < dataCopy.count else { 
            return nil 
        }
        let flags = dataCopy[offset]; offset += 1
        let isRelay = (flags & 0x01) != 0
        let isPrivate = (flags & 0x02) != 0
        let hasOriginalSender = (flags & 0x04) != 0
        let hasRecipientNickname = (flags & 0x08) != 0
        let hasSenderPeerID = (flags & 0x10) != 0
        let hasMentions = (flags & 0x20) != 0
        let hasChannel = (flags & 0x40) != 0
        let isEncrypted = (flags & 0x80) != 0
        
        // Timestamp
        guard let timestampData = dataCopy.safeSubdata(from: offset, length: 8) else { 
            return nil 
        }
        let timestampMillis = timestampData.reduce(0) { result, byte in
            (result << 8) | UInt64(byte)
        }
        offset += 8
        let timestamp = Date(timeIntervalSince1970: TimeInterval(timestampMillis) / 1000.0)
        
        // ID
        guard offset < dataCopy.count else { 
            return nil 
        }
        let idLength = Int(dataCopy[offset]); offset += 1
        guard idLength <= maxStringFieldSize else { return nil }
        guard let idData = dataCopy.safeSubdata(from: offset, length: idLength) else { 
            return nil 
        }
        let id = String(data: idData, encoding: .utf8) ?? UUID().uuidString
        offset += idLength
        
        // Sender
        guard offset < dataCopy.count else { 
            return nil 
        }
        let senderLength = Int(dataCopy[offset]); offset += 1
        guard senderLength <= maxStringFieldSize else { return nil }
        guard let senderData = dataCopy.safeSubdata(from: offset, length: senderLength) else { 
            return nil 
        }
        let sender = String(data: senderData, encoding: .utf8) ?? "unknown"
        offset += senderLength
        
        // Content
        guard let contentLengthData = dataCopy.safeSubdata(from: offset, length: 2) else { 
            return nil 
        }
        let contentLength = Int(contentLengthData.reduce(0) { result, byte in
            (result << 8) | UInt16(byte)
        })
        offset += 2
        guard contentLength <= maxStringFieldSize else { return nil }
        guard contentLength >= 0 else { return nil }
        
        let content: String
        let encryptedContent: Data?
        
        if isEncrypted {
            // Content is encrypted, store as Data
            guard let encData = dataCopy.safeSubdata(from: offset, length: contentLength) else { return nil }
            encryptedContent = encData
            content = ""  // Empty placeholder
        } else {
            // Normal string content
            guard let contentData = dataCopy.safeSubdata(from: offset, length: contentLength) else { return nil }
            content = String(data: contentData, encoding: .utf8) ?? ""
            encryptedContent = nil
        }
        offset += contentLength
        
        // Optional fields
        var originalSender: String?
        if hasOriginalSender && offset < dataCopy.count {
            let length = Int(dataCopy[offset]); offset += 1
            guard length <= maxStringFieldSize else { return nil }
            if let origData = dataCopy.safeSubdata(from: offset, length: length) {
                originalSender = String(data: origData, encoding: .utf8)
                offset += length
            } else {
                return nil
            }
        }
        
        var recipientNickname: String?
        if hasRecipientNickname && offset < dataCopy.count {
            let length = Int(dataCopy[offset]); offset += 1
            guard length <= maxStringFieldSize else { return nil }
            if let recipData = dataCopy.safeSubdata(from: offset, length: length) {
                recipientNickname = String(data: recipData, encoding: .utf8)
                offset += length
            } else {
                return nil
            }
        }
        
        var senderPeerID: String?
        if hasSenderPeerID && offset < dataCopy.count {
            let length = Int(dataCopy[offset]); offset += 1
            guard length <= maxStringFieldSize else { return nil }
            if let peerData = dataCopy.safeSubdata(from: offset, length: length) {
                senderPeerID = String(data: peerData, encoding: .utf8)
                offset += length
            } else {
                return nil
            }
        }
        
        // Mentions array
        var mentions: [String]?
        if hasMentions && offset < dataCopy.count {
            let mentionCount = Int(dataCopy[offset]); offset += 1
            guard mentionCount <= maxMentionsCount else { return nil }
            if mentionCount > 0 {
                mentions = []
                for _ in 0..<mentionCount {
                    guard offset < dataCopy.count else { return nil }
                    let length = Int(dataCopy[offset]); offset += 1
                    guard length <= maxStringFieldSize else { return nil }
                    if let mentionData = dataCopy.safeSubdata(from: offset, length: length) {
                        if let mention = String(data: mentionData, encoding: .utf8) {
                            mentions?.append(mention)
                        }
                        offset += length
                    } else {
                        return nil
                    }
                }
            }
        }
        
        // Channel
        var channel: String? = nil
        if hasChannel && offset < dataCopy.count {
            let length = Int(dataCopy[offset]); offset += 1
            guard length <= maxChannelLength else { return nil }
            if let channelData = dataCopy.safeSubdata(from: offset, length: length) {
                channel = String(data: channelData, encoding: .utf8)
                offset += length
            } else {
                return nil
            }
        }
        
        let message = BitchatMessage(
            id: id,
            sender: sender,
            content: content,
            timestamp: timestamp,
            isRelay: isRelay,
            originalSender: originalSender,
            isPrivate: isPrivate,
            recipientNickname: recipientNickname,
            senderPeerID: senderPeerID,
            mentions: mentions,
            channel: channel,
            encryptedContent: encryptedContent,
            isEncrypted: isEncrypted
        )
        return message
    }
}