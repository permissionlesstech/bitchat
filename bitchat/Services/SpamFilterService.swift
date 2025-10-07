//
// SpamFilterService.swift
// bitchat
//
// Rate limiting service using token bucket algorithm to prevent spam
// This is free and unencumbered software released into the public domain.
//

import Foundation
import BitLogger

/// Service that implements token bucket rate limiting to prevent spam
/// Tracks both per-sender and per-content rate limits
final class SpamFilterService {

    // MARK: - Token Bucket Implementation

    private struct TokenBucket {
        var capacity: Double
        var tokens: Double
        var refillPerSec: Double
        var lastRefill: Date

        mutating func allow(cost: Double = 1.0, now: Date = Date()) -> Bool {
            let dt = now.timeIntervalSince(lastRefill)
            if dt > 0 {
                tokens = min(capacity, tokens + dt * refillPerSec)
                lastRefill = now
            }
            if tokens >= cost {
                tokens -= cost
                return true
            }
            return false
        }
    }

    // MARK: - Properties

    private var rateBucketsBySender: [String: TokenBucket] = [:]
    private var rateBucketsByContent: [String: TokenBucket] = [:]

    private let senderBucketCapacity: Double
    private let senderBucketRefill: Double
    private let contentBucketCapacity: Double
    private let contentBucketRefill: Double

    // Content key normalization cache (LRU)
    private var contentLRUMap: [String: Date] = [:]
    private var contentLRUOrder: [String] = []
    private let contentLRUCap: Int

    // MARK: - Initialization

    init(
        senderCapacity: Double = TransportConfig.uiSenderRateBucketCapacity,
        senderRefill: Double = TransportConfig.uiSenderRateBucketRefillPerSec,
        contentCapacity: Double = TransportConfig.uiContentRateBucketCapacity,
        contentRefill: Double = TransportConfig.uiContentRateBucketRefillPerSec,
        contentLRUCap: Int = TransportConfig.contentLRUCap
    ) {
        self.senderBucketCapacity = senderCapacity
        self.senderBucketRefill = senderRefill
        self.contentBucketCapacity = contentCapacity
        self.contentBucketRefill = contentRefill
        self.contentLRUCap = contentLRUCap
    }

    // MARK: - Public API

    /// Check if a message should be allowed through the spam filter
    /// - Parameters:
    ///   - message: The message to check
    ///   - nostrKeyMapping: Mapping of Nostr sender IDs to full keys
    ///   - getNoiseKeyForShortID: Closure to resolve full Noise keys from short IDs
    /// - Returns: true if message is allowed, false if rate limited
    func shouldAllow(
        message: BitchatMessage,
        nostrKeyMapping: [String: String],
        getNoiseKeyForShortID: (String) -> String?
    ) -> Bool {
        // System messages always allowed
        guard message.sender != "system" else { return true }

        let senderKey = normalizedSenderKey(
            for: message,
            nostrKeyMapping: nostrKeyMapping,
            getNoiseKeyForShortID: getNoiseKeyForShortID
        )
        let contentKey = normalizedContentKey(message.content)
        let now = Date()

        // Check sender rate limit
        var sBucket = rateBucketsBySender[senderKey] ?? TokenBucket(
            capacity: senderBucketCapacity,
            tokens: senderBucketCapacity,
            refillPerSec: senderBucketRefill,
            lastRefill: now
        )
        let senderAllowed = sBucket.allow(now: now)
        rateBucketsBySender[senderKey] = sBucket

        // Check content rate limit
        var cBucket = rateBucketsByContent[contentKey] ?? TokenBucket(
            capacity: contentBucketCapacity,
            tokens: contentBucketCapacity,
            refillPerSec: contentBucketRefill,
            lastRefill: now
        )
        let contentAllowed = cBucket.allow(now: now)
        rateBucketsByContent[contentKey] = cBucket

        // Record content for near-duplicate detection
        if senderAllowed && contentAllowed {
            recordContentKey(contentKey, timestamp: message.timestamp)
        } else {
            SecureLogger.warning(
                "Rate limited message from \(senderKey) (sender:\(senderAllowed) content:\(contentAllowed))",
                category: .session
            )
        }

        return senderAllowed && contentAllowed
    }

    /// Check if we've seen very similar content recently (near-duplicate detection)
    func isNearDuplicate(content: String, withinSeconds: TimeInterval = 5.0) -> Bool {
        let key = normalizedContentKey(content)
        guard let lastSeen = contentLRUMap[key] else { return false }
        return Date().timeIntervalSince(lastSeen) < withinSeconds
    }

    // MARK: - Private Helpers

    private func normalizedSenderKey(
        for message: BitchatMessage,
        nostrKeyMapping: [String: String],
        getNoiseKeyForShortID: (String) -> String?
    ) -> String {
        if let spid = message.senderPeerID?.id {
            if spid.hasPrefix("nostr:") || spid.hasPrefix("nostr_") {
                let bare: String = {
                    if spid.hasPrefix("nostr:") { return String(spid.dropFirst(6)) }
                    if spid.hasPrefix("nostr_") { return String(spid.dropFirst(6)) }
                    return spid
                }()
                let full = (nostrKeyMapping[spid] ?? bare).lowercased()
                return "nostr:" + full
            } else if spid.count == 16, let full = getNoiseKeyForShortID(spid)?.lowercased() {
                return "noise:" + full
            } else {
                return "mesh:" + spid.lowercased()
            }
        }
        return "name:" + message.sender.lowercased()
    }

    private func normalizedContentKey(_ content: String) -> String {
        // Lowercase, simplify URLs (strip query/fragment), collapse whitespace, bound length
        let lowered = content.lowercased()
        let ns = lowered as NSString
        let range = NSRange(location: 0, length: ns.length)
        var simplified = ""
        var last = 0

        // Precompiled regex for URL simplification
        let simplifyHTTPURL = try! NSRegularExpression(
            pattern: "https?://[^\\s?#]+(?:[?#][^\\s]*)?",
            options: [.caseInsensitive]
        )

        for m in simplifyHTTPURL.matches(in: lowered, options: [], range: range) {
            if m.range.location > last {
                simplified += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            }
            let url = ns.substring(with: m.range)
            if let q = url.firstIndex(where: { $0 == "?" || $0 == "#" }) {
                simplified += String(url[..<q])
            } else {
                simplified += url
            }
            last = m.range.location + m.range.length
        }
        if last < ns.length { simplified += ns.substring(with: NSRange(location: last, length: ns.length - last)) }

        let trimmed = simplified.trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = trimmed.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let prefix = String(collapsed.prefix(TransportConfig.contentKeyPrefixLength))

        // Fast djb2 hash
        let h = prefix.djb2()
        return String(format: "h:%016llx", h)
    }

    private func recordContentKey(_ key: String, timestamp: Date) {
        if contentLRUMap[key] == nil {
            contentLRUOrder.append(key)
        }
        contentLRUMap[key] = timestamp

        // Evict oldest entries if over capacity
        if contentLRUOrder.count > contentLRUCap {
            let overflow = contentLRUOrder.count - contentLRUCap
            for _ in 0..<overflow {
                if let victim = contentLRUOrder.first {
                    contentLRUOrder.removeFirst()
                    contentLRUMap.removeValue(forKey: victim)
                }
            }
        }
    }

    // MARK: - Cleanup

    /// Clear all rate limiting state (useful for testing or reset)
    func reset() {
        rateBucketsBySender.removeAll()
        rateBucketsByContent.removeAll()
        contentLRUMap.removeAll()
        contentLRUOrder.removeAll()
    }
}
