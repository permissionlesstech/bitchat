//
// MessageDeduplicationService.swift
// bitchat
//
// Handles message deduplication using LRU caches.
// This is free and unencumbered software released into the public domain.
//

import Foundation

// MARK: - LRU Deduplication Cache

/// Generic LRU (Least Recently Used) cache for deduplication.
/// Uses an efficient O(1) lookup with periodic compaction.
/// Thread-safe via @MainActor - all callers are already on main actor.
@MainActor
final class LRUDeduplicationCache<Value> {
    private var map: [String: Value] = [:]
    private var order: [String] = []
    private var head: Int = 0
    private let capacity: Int

    /// Creates a new LRU cache with the specified capacity.
    /// - Parameter capacity: Maximum number of entries before eviction
    init(capacity: Int) {
        precondition(capacity > 0, "LRU cache capacity must be positive")
        self.capacity = capacity
    }

    /// Number of active entries in the cache
    var count: Int {
        order.count - head
    }

    /// Checks if a key exists in the cache
    func contains(_ key: String) -> Bool {
        map[key] != nil
    }

    /// Gets the value for a key, or nil if not present
    func value(for key: String) -> Value? {
        map[key]
    }

    /// Records a key-value pair, updating if exists or inserting if new
    func record(_ key: String, value: Value) {
        if map[key] == nil {
            order.append(key)
        }
        map[key] = value
        trimIfNeeded()
    }

    /// Removes a specific key from the cache
    func remove(_ key: String) {
        map.removeValue(forKey: key)
        // Note: key remains in order array but will be skipped during eviction
    }

    /// Clears all entries from the cache
    func clear() {
        map.removeAll()
        order.removeAll()
        head = 0
    }

    // MARK: - Private

    private func trimIfNeeded() {
        let activeCount = order.count - head
        guard activeCount > capacity else { return }

        let overflow = activeCount - capacity
        for _ in 0..<overflow {
            guard let victim = popOldest() else { break }
            map.removeValue(forKey: victim)
        }
    }

    private func popOldest() -> String? {
        // Skip keys that were already removed from map
        while head < order.count {
            let key = order[head]
            head += 1

            // Periodically compact the backing storage
            if head >= 32 && head * 2 >= order.count {
                order.removeFirst(head)
                head = 0
            }

            // Only return if key is still in map
            if map[key] != nil {
                return key
            }
        }
        return nil
    }
}

// MARK: - Content Normalizer

/// Normalizes message content for near-duplicate detection.
enum ContentNormalizer {

    /// Regex to simplify HTTP URLs by stripping query strings and fragments
    private static let simplifyHTTPURL: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "https?://[^\\s?#]+(?:[?#][^\\s]*)?",
            options: [.caseInsensitive]
        )
    }()

    /// Normalizes content for deduplication comparison.
    /// - Parameters:
    ///   - content: The raw message content
    ///   - prefixLength: Maximum characters to consider (default from TransportConfig)
    /// - Returns: A hash-based key for comparison
    static func normalizedKey(
        _ content: String,
        prefixLength: Int = TransportConfig.contentKeyPrefixLength
    ) -> String {
        // Lowercase for case-insensitive comparison
        let lowered = content.lowercased()
        let ns = lowered as NSString
        let range = NSRange(location: 0, length: ns.length)

        // Simplify URLs by stripping query/fragment
        var simplified = ""
        var last = 0
        for match in simplifyHTTPURL.matches(in: lowered, options: [], range: range) {
            if match.range.location > last {
                simplified += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            }
            let url = ns.substring(with: match.range)
            if let queryIndex = url.firstIndex(where: { $0 == "?" || $0 == "#" }) {
                simplified += String(url[..<queryIndex])
            } else {
                simplified += url
            }
            last = match.range.location + match.range.length
        }
        if last < ns.length {
            simplified += ns.substring(with: NSRange(location: last, length: ns.length - last))
        }

        // Trim and collapse whitespace
        let trimmed = simplified.trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = trimmed.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        // Take prefix and hash
        let prefix = String(collapsed.prefix(prefixLength))
        let hash = prefix.djb2()
        return String(format: "h:%016llx", hash)
    }
}

// MARK: - Message Deduplication Service

/// Service that manages message deduplication using LRU caches.
/// Provides separate caches for content-based dedup and Nostr event ID dedup.
/// Thread-safe via @MainActor - all callers are already on main actor.
@MainActor
final class MessageDeduplicationService {

    /// Cache for content-based near-duplicate detection
    private let contentCache: LRUDeduplicationCache<Date>

    /// Cache for Nostr event ID deduplication
    private let nostrEventCache: LRUDeduplicationCache<Bool>

    /// Cache for Nostr ACK deduplication (messageId:ackType:senderPubkey format)
    private let nostrAckCache: LRUDeduplicationCache<Bool>

    /// Creates a new deduplication service with specified capacities.
    /// - Parameters:
    ///   - contentCapacity: Max entries for content cache
    ///   - nostrEventCapacity: Max entries for Nostr event cache
    init(
        contentCapacity: Int = TransportConfig.contentLRUCap,
        nostrEventCapacity: Int = TransportConfig.uiProcessedNostrEventsCap
    ) {
        self.contentCache = LRUDeduplicationCache(capacity: contentCapacity)
        self.nostrEventCache = LRUDeduplicationCache(capacity: nostrEventCapacity)
        self.nostrAckCache = LRUDeduplicationCache(capacity: nostrEventCapacity)
    }

    // MARK: - Content Deduplication

    /// Records content with its timestamp for near-duplicate detection.
    /// - Parameters:
    ///   - content: The message content
    ///   - timestamp: When the content was received
    func recordContent(_ content: String, timestamp: Date) {
        let key = ContentNormalizer.normalizedKey(content)
        contentCache.record(key, value: timestamp)
    }

    /// Records a pre-normalized content key with its timestamp.
    /// - Parameters:
    ///   - key: The normalized content key
    ///   - timestamp: When the content was received
    func recordContentKey(_ key: String, timestamp: Date) {
        contentCache.record(key, value: timestamp)
    }

    /// Gets the timestamp for previously seen content.
    /// - Parameter content: The message content
    /// - Returns: The timestamp when first seen, or nil if not seen
    func contentTimestamp(for content: String) -> Date? {
        let key = ContentNormalizer.normalizedKey(content)
        return contentCache.value(for: key)
    }

    /// Gets the timestamp for a pre-normalized content key.
    /// - Parameter key: The normalized content key
    /// - Returns: The timestamp when first seen, or nil if not seen
    func contentTimestamp(forKey key: String) -> Date? {
        contentCache.value(for: key)
    }

    /// Normalizes content to a deduplication key.
    /// - Parameter content: The raw content
    /// - Returns: A normalized hash key
    func normalizedContentKey(_ content: String) -> String {
        ContentNormalizer.normalizedKey(content)
    }

    // MARK: - Nostr Event Deduplication

    /// Checks if a Nostr event has already been processed.
    /// - Parameter eventId: The event ID
    /// - Returns: true if already processed
    func hasProcessedNostrEvent(_ eventId: String) -> Bool {
        nostrEventCache.contains(eventId)
    }

    /// Records a Nostr event as processed.
    /// - Parameter eventId: The event ID
    func recordNostrEvent(_ eventId: String) {
        nostrEventCache.record(eventId, value: true)
    }

    // MARK: - Nostr ACK Deduplication

    /// Checks if a Nostr ACK has already been processed.
    /// - Parameter ackKey: The ACK key in format "messageId:ackType:senderPubkey"
    /// - Returns: true if already processed
    func hasProcessedNostrAck(_ ackKey: String) -> Bool {
        nostrAckCache.contains(ackKey)
    }

    /// Records a Nostr ACK as processed.
    /// - Parameter ackKey: The ACK key in format "messageId:ackType:senderPubkey"
    func recordNostrAck(_ ackKey: String) {
        nostrAckCache.record(ackKey, value: true)
    }

    /// Creates an ACK key from components.
    static func ackKey(messageId: String, ackType: String, senderPubkey: String) -> String {
        "\(messageId):\(ackType):\(senderPubkey)"
    }

    // MARK: - Clear

    /// Clears all caches
    func clearAll() {
        contentCache.clear()
        nostrEventCache.clear()
        nostrAckCache.clear()
    }

    /// Clears only the Nostr caches (events and ACKs)
    func clearNostrCaches() {
        nostrEventCache.clear()
        nostrAckCache.clear()
    }
}
