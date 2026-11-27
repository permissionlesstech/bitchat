//
// BitchatMessage.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import class Foundation.DateFormatter

import struct Foundation.AttributedString
import struct Foundation.Data
import struct Foundation.Date
import struct Foundation.TimeInterval
import struct Foundation.UUID

/// Represents a user-visible message in the BitChat system.
/// Handles both broadcast messages and private encrypted messages,
/// with support for mentions, replies, and delivery tracking.
/// - Note: This is the primary data model for chat messages
public final class BitchatMessage: Codable {
    public let id: String
    public let sender: String
    public let content: String
    public let timestamp: Date
    public let isRelay: Bool
    public let originalSender: String?
    public let isPrivate: Bool
    public let recipientNickname: String?
    public let senderPeerID: PeerID?
    public let mentions: [String]?  // Array of mentioned nicknames
    public var deliveryStatus: DeliveryStatus // Delivery tracking
    /// True when this message reached us across a mesh bridge (signed by its
    /// author for an internet rendezvous) rather than over local radio.
    public let isBridged: Bool

    // Cached formatted text (not included in Codable)
    private var _cachedFormattedText: [String: AttributedString] = [:]
    
    public func getCachedFormattedText(isDark: Bool, isSelf: Bool, variant: String = "") -> AttributedString? {
        return _cachedFormattedText["\(variant)\(isDark)-\(isSelf)"]
    }

    public func setCachedFormattedText(_ text: AttributedString, isDark: Bool, isSelf: Bool, variant: String = "") {
        _cachedFormattedText["\(variant)\(isDark)-\(isSelf)"] = text
    }

    // Cached content scan for row rendering (not included in Codable).
    // `content` is immutable, so a cached scan never goes stale.
    private var _cachedContentScan: ContentScan?

    public func getCachedContentScan() -> ContentScan? {
        _cachedContentScan
    }

    public func setCachedContentScan(_ scan: ContentScan) {
        _cachedContentScan = scan
    }

    // Codable implementation
    enum CodingKeys: String, CodingKey {
        case id, sender, content, timestamp, isRelay, originalSender
        case isPrivate, recipientNickname, senderPeerID, mentions, deliveryStatus
        case isBridged
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sender = try container.decode(String.self, forKey: .sender)
        content = try container.decode(String.self, forKey: .content)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        isRelay = try container.decode(Bool.self, forKey: .isRelay)
        originalSender = try container.decodeIfPresent(String.self, forKey: .originalSender)
        isPrivate = try container.decode(Bool.self, forKey: .isPrivate)
        recipientNickname = try container.decodeIfPresent(String.self, forKey: .recipientNickname)
        senderPeerID = try container.decodeIfPresent(PeerID.self, forKey: .senderPeerID)
        mentions = try container.decodeIfPresent([String].self, forKey: .mentions)
        // Archives written while the field was optional omit it for public
        // messages; absent means the message never entered a send pipeline.
        deliveryStatus = try container.decodeIfPresent(DeliveryStatus.self, forKey: .deliveryStatus) ?? .notSentYet
        // Absent in archives written before bridging existed.
        isBridged = try container.decodeIfPresent(Bool.self, forKey: .isBridged) ?? false
    }

    public init(
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
        deliveryStatus: DeliveryStatus? = nil,
        isBridged: Bool = false
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
        self.deliveryStatus = deliveryStatus ?? (isPrivate ? .sending : .notSentYet)
        self.isBridged = isBridged
    }
}

// MARK: - Content Scan

extension BitchatMessage {
    /// What a message row derives from `content`: the payment links rendered
    /// as chips and whether the text collapses behind "show more". Deriving
    /// them takes several regex passes over the content, so the renderer
    /// computes them once and caches the result on the message.
    public struct ContentScan: Equatable {
        public let cashuLinks: [String]
        public let lightningLinks: [String]
        public let isLongForDisplay: Bool

        public init(cashuLinks: [String], lightningLinks: [String], isLongForDisplay: Bool) {
            self.cashuLinks = cashuLinks
            self.lightningLinks = lightningLinks
            self.isLongForDisplay = isLongForDisplay
        }
    }
}

// MARK: - Equatable Conformance

extension BitchatMessage: Equatable {
    public static func == (lhs: BitchatMessage, rhs: BitchatMessage) -> Bool {
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
               lhs.deliveryStatus == rhs.deliveryStatus &&
               lhs.isBridged == rhs.isBridged
    }
}

// MARK: - Helpers

extension BitchatMessage {
    
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
    
    public var formattedTimestamp: String {
        Self.timestampFormatter.string(from: timestamp)
    }
}
