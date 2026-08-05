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
    private struct StoredEntry {
        var value: Value
        let generation: UInt64
    }

    private struct OrderEntry {
        let key: String
        let generation: UInt64
    }

    private var map: [String: StoredEntry] = [:]
    private var order: [OrderEntry] = []
    private var head: Int = 0
    private var staleNodeCount: Int = 0
    private var nextGeneration: UInt64 = 0
    private let capacity: Int

    /// Creates a new LRU cache with the specified capacity.
    /// - Parameter capacity: Maximum number of entries before eviction
    init(capacity: Int) {
        precondition(capacity > 0, "LRU cache capacity must be positive")
        self.capacity = capacity
    }

    /// Number of active entries in the cache
    var count: Int {
        map.count
    }

    #if DEBUG
    /// Order-node storage exposed only for bounded-storage regression tests.
    var _orderStorageCountForTesting: Int { order.count }
    #endif

    /// Checks if a key exists in the cache
    func contains(_ key: String) -> Bool {
        map[key] != nil
    }

    /// Gets the value for a key, or nil if not present
    func value(for key: String) -> Value? {
        map[key]?.value
    }

    /// Records a key-value pair, updating if exists or inserting if new
    func record(_ key: String, value: Value) {
        if let existing = map[key] {
            map[key] = StoredEntry(value: value, generation: existing.generation)
        } else {
            nextGeneration &+= 1
            let generation = nextGeneration
            map[key] = StoredEntry(value: value, generation: generation)
            order.append(OrderEntry(key: key, generation: generation))
        }

        trimIfNeeded()
        compactIfNeeded()
    }

    /// Removes a specific key from the cache
    func remove(_ key: String) {
        guard map.removeValue(forKey: key) != nil else { return }
        staleNodeCount += 1
        compactIfNeeded()
    }

    /// Clears all entries from the cache
    func clear() {
        map.removeAll()
        order.removeAll()
        head = 0
        staleNodeCount = 0
        nextGeneration = 0
    }

    // MARK: - Private

    private func trimIfNeeded() {
        while map.count > capacity {
            guard popOldest() else { break }
        }
    }

    private func popOldest() -> Bool {
        while head < order.count {
            let candidate = order[head]
            head += 1

            guard let liveEntry = map[candidate.key],
                  liveEntry.generation == candidate.generation else {
                if staleNodeCount > 0 {
                    staleNodeCount -= 1
                }
                continue
            }

            map.removeValue(forKey: candidate.key)
            return true
        }
        return false
    }

    private func compactIfNeeded() {
        let unconsumedCount = order.count - head
        let shouldDropConsumedPrefix = head >= 32 && head * 2 >= order.count
        let shouldRemoveStaleNodes = staleNodeCount >= 32 && staleNodeCount * 2 >= unconsumedCount

        guard shouldDropConsumedPrefix || shouldRemoveStaleNodes else { return }

        if shouldRemoveStaleNodes {
            order = order[head...].filter { candidate in
                map[candidate.key]?.generation == candidate.generation
            }
            staleNodeCount = 0
        } else {
            order.removeFirst(head)
        }
        head = 0
    }
}

// MARK: - Content Normalizer

/// Normalizes message content for near-duplicate detection.
enum ContentNormalizer {

    /// Regex to simplify HTTP URLs by stripping query strings and fragments
    private static let simplifyHTTPURL = SafeRegex.compile(
        "https?://[^\\s?#]+(?:[?#][^\\s]*)?",
        options: [.caseInsensitive]
    )

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
        let trimmed = simplified.trimmed
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

    /// Optional cross-launch persistence for the Nostr event cache. BitChat
    /// randomizes private-envelope timestamps, so DM subscriptions look back 24h and
    /// relays redeliver the same events on every launch; without this record
    /// each relaunch reprocesses old PMs and acks. Nil (tests, macOS callers
    /// that don't opt in) keeps the cache purely in-memory.
    private let nostrEventStore: NostrProcessedEventStore?
    private let nostrEventCapacity: Int
    private var persistScheduled = false
    private var pendingPersistIDs: [String] = []

    /// Creates a new deduplication service with specified capacities.
    /// - Parameters:
    ///   - contentCapacity: Max entries for content cache
    ///   - nostrEventCapacity: Max entries for Nostr event cache
    ///   - nostrEventStore: Optional disk store preloading and persisting
    ///     processed Nostr event IDs across launches
    init(
        contentCapacity: Int = TransportConfig.contentLRUCap,
        nostrEventCapacity: Int = TransportConfig.uiProcessedNostrEventsCap,
        nostrEventStore: NostrProcessedEventStore? = nil
    ) {
        self.contentCache = LRUDeduplicationCache(capacity: contentCapacity)
        self.nostrEventCache = LRUDeduplicationCache(capacity: nostrEventCapacity)
        self.nostrAckCache = LRUDeduplicationCache(capacity: nostrEventCapacity)
        self.nostrEventStore = nostrEventStore
        self.nostrEventCapacity = nostrEventCapacity
        if let nostrEventStore {
            for eventID in nostrEventStore.load() {
                nostrEventCache.record(eventID, value: true)
            }
        }
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

    /// Removes the near-duplicate marker for a row that is being replaced,
    /// not merely deleted. Bridge-first/radio-second reconciliation needs the
    /// authenticated radio copy to pass the next pipeline flush after its
    /// unauthenticated bridge alias is removed.
    func forgetContent(_ content: String, ifRecordedAt timestamp: Date) {
        let key = ContentNormalizer.normalizedKey(content)
        guard contentCache.value(for: key) == timestamp else { return }
        contentCache.remove(key)
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
        if nostrEventStore != nil {
            pendingPersistIDs.append(eventId)
            schedulePersistIfNeeded()
        }
    }

    /// Debounced persistence: bursts of inbound events (reconnect redelivery)
    /// collapse into one append. Append-merge rather than snapshot, so a
    /// transient in-memory clear between flushes can't shrink the disk record.
    private func schedulePersistIfNeeded() {
        guard let nostrEventStore, !persistScheduled else { return }
        persistScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self else { return }
            self.persistScheduled = false
            let newIDs = self.pendingPersistIDs
            self.pendingPersistIDs.removeAll()
            nostrEventStore.append(newIDs, cap: self.nostrEventCapacity)
        }
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

    /// Clears all caches. This is the wipe/panic path: the persisted
    /// private-envelope record goes with everything else.
    func clearAll() {
        contentCache.clear()
        nostrEventCache.clear()
        nostrAckCache.clear()
        pendingPersistIDs.removeAll()
        nostrEventStore?.wipe()
    }

    /// Clears only the in-memory Nostr caches (events and ACKs). Runs on
    /// every geohash channel switch, so the disk record deliberately
    /// survives — wiping it here would forfeit cross-launch private-envelope dedup
    /// each time the user changes channels (flagged by Codex on #1398).
    func clearNostrCaches() {
        nostrEventCache.clear()
        nostrAckCache.clear()
    }
}
