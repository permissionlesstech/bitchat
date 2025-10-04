//
// BitchatMessage.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Represents a user-visible message in the BitChat system.
/// Handles both broadcast messages and private encrypted messages,
/// with support for mentions, replies, and delivery tracking.
/// - Note: This is the primary data model for chat messages
final class BitchatMessage: Codable {
    let id: String
    let sender: String
    let content: String
    let timestamp: Date
    let isRelay: Bool
    let originalSender: String?
    let isPrivate: Bool
    let recipientNickname: String?
    let senderPeerID: PeerID?
    let mentions: [String]?  // Array of mentioned nicknames
    var deliveryStatus: DeliveryStatus? // Delivery tracking
    
    // Cached formatted text (not included in Codable)
    private var _cachedFormattedText: [String: AttributedString] = [:]
    
    func getCachedFormattedText(isDark: Bool, isSelf: Bool) -> AttributedString? {
        return _cachedFormattedText["\(isDark)-\(isSelf)"]
    }
    
    func setCachedFormattedText(_ text: AttributedString, isDark: Bool, isSelf: Bool) {
        _cachedFormattedText["\(isDark)-\(isSelf)"] = text
    }
    
    // Codable implementation
    enum CodingKeys: String, CodingKey {
        case id, sender, content, timestamp, isRelay, originalSender
        case isPrivate, recipientNickname, senderPeerID, mentions, deliveryStatus
    }
    
    init(
        id: String? = nil,
        sender: String,
        content: String,
        timestamp: Date,
        isRelay: Bool,
        originalSender: String? = nil,
        isPrivate: Bool = false,
        recipientNickname: String? = nil,
        senderPeerID: PeerID? = nil,
        mentions: [String]? = nil,
        deliveryStatus: DeliveryStatus? = nil
    ) {
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

// MARK: - Equatable Conformance

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

// MARK: - Binary encoding

extension BitchatMessage {
    func toBinaryPayload() -> Data? {
        var data = Data()
        
        // Message format:
        // - Flags: 1 byte (bit 0: isRelay, bit 1: isPrivate, bit 2: hasOriginalSender, bit 3: hasRecipientNickname, bit 4: hasSenderPeerID, bit 5: hasMentions)
        // - Timestamp: 8 bytes (seconds since epoch)
        // - ID length: 1 byte
        // - ID: variable
        // - Sender length: 1 byte
        // - Sender: variable
        // - Content length: 2 bytes
        // - Content: variable
        // Optional fields based on flags:
        // - Original sender length + data
        // - Recipient nickname length + data
        // - Sender peer ID length + data
        // - Mentions array
        
        var flags: UInt8 = 0
        if isRelay { flags |= 0x01 }
        if isPrivate { flags |= 0x02 }
        if originalSender != nil { flags |= 0x04 }
        if recipientNickname != nil { flags |= 0x08 }
        if senderPeerID != nil { flags |= 0x10 }
        if mentions != nil && !mentions!.isEmpty { flags |= 0x20 }
        
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
        
        // Content
        if let contentData = content.data(using: .utf8) {
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
        
        if let peerData = senderPeerID?.id.data(using: .utf8) {
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
        
        
        return data
    }
    
    convenience init?(_ data: Data) {
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
        
        // Timestamp
        guard offset + 8 <= dataCopy.count else {
            return nil
        }
        let timestampData = dataCopy[offset..<offset+8]
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
        guard offset + idLength <= dataCopy.count else {
            return nil
        }
        let id = String(data: dataCopy[offset..<offset+idLength], encoding: .utf8) ?? UUID().uuidString
        offset += idLength
        
        // Sender
        guard offset < dataCopy.count else {
            return nil
        }
        let senderLength = Int(dataCopy[offset]); offset += 1
        guard offset + senderLength <= dataCopy.count else {
            return nil
        }
        let sender = String(data: dataCopy[offset..<offset+senderLength], encoding: .utf8) ?? "unknown"
        offset += senderLength
        
        // Content
        guard offset + 2 <= dataCopy.count else {
            return nil
        }
        let contentLengthData = dataCopy[offset..<offset+2]
        let contentLength = Int(contentLengthData.reduce(0) { result, byte in
            (result << 8) | UInt16(byte)
        })
        offset += 2
        guard offset + contentLength <= dataCopy.count else {
            return nil
        }
        
        let content = String(data: dataCopy[offset..<offset+contentLength], encoding: .utf8) ?? ""
        offset += contentLength
        
        // Optional fields
        var originalSender: String?
        if hasOriginalSender && offset < dataCopy.count {
            let length = Int(dataCopy[offset]); offset += 1
            if offset + length <= dataCopy.count {
                originalSender = String(data: dataCopy[offset..<offset+length], encoding: .utf8)
                offset += length
            }
        }
        
        var recipientNickname: String?
        if hasRecipientNickname && offset < dataCopy.count {
            let length = Int(dataCopy[offset]); offset += 1
            if offset + length <= dataCopy.count {
                recipientNickname = String(data: dataCopy[offset..<offset+length], encoding: .utf8)
                offset += length
            }
        }
        
        var senderPeerID: PeerID?
        if hasSenderPeerID && offset < dataCopy.count {
            let length = Int(dataCopy[offset]); offset += 1
            if offset + length <= dataCopy.count {
                senderPeerID = PeerID(data: dataCopy[offset..<offset+length])
                offset += length
            }
        }
        
        // Mentions array
        var mentions: [String]?
        if hasMentions && offset < dataCopy.count {
            let mentionCount = Int(dataCopy[offset]); offset += 1
            if mentionCount > 0 {
                mentions = []
                for _ in 0..<mentionCount {
                    if offset < dataCopy.count {
                        let length = Int(dataCopy[offset]); offset += 1
                        if offset + length <= dataCopy.count {
                            if let mention = String(data: dataCopy[offset..<offset+length], encoding: .utf8) {
                                mentions?.append(mention)
                            }
                            offset += length
                        }
                    }
                }
            }
        }
        
        self.init(
            id: id,
            sender: sender,
            content: content,
            timestamp: timestamp,
            isRelay: isRelay,
            originalSender: originalSender,
            isPrivate: isPrivate,
            recipientNickname: recipientNickname,
            senderPeerID: senderPeerID,
            mentions: mentions
        )
    }
}

// MARK: - Helpers

extension BitchatMessage {
    
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
    
    var formattedTimestamp: String {
        Self.timestampFormatter.string(from: timestamp)
    }
}

extension Array where Element == BitchatMessage {
    /// Filters out empty ones and deduplicate by ID while preserving order (from oldest to newest)
    func cleanedAndDeduped() -> [Element] {
        let arr = filter { $0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
        guard arr.count > 1 else {
            return arr
        }
        var seen = Set<String>()
        var dedup: [BitchatMessage] = []
        for m in arr.sorted(by: { $0.timestamp < $1.timestamp }) {
            if !seen.contains(m.id) {
                dedup.append(m)
                seen.insert(m.id)
            }
        }
        return dedup
    }
}
