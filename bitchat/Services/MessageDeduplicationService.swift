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

        // Fast path: skip NSString bridging + URL regex when no scheme separator is present
        let simplified: String
        if lowered.contains("://") {
            let ns = lowered as NSString
            let range = NSRange(location: 0, length: ns.length)
            var out = ""
            out.reserveCapacity(lowered.count)
            var last = 0
            for match in simplifyHTTPURL.matches(in: lowered, options: [], range: range) {
                if match.range.location > last {
                    out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
                }
                let url = ns.substring(with: match.range)
                if let queryIndex = url.firstIndex(where: { $0 == "?" || $0 == "#" }) {
                    out += url[..<queryIndex]
                } else {
                    out += url
                }
                last = match.range.location + match.range.length
            }
            if last < ns.length {
                out += ns.substring(with: NSRange(location: last, length: ns.length - last))
            }
            simplified = out
        } else {
            simplified = lowered
        }

        // Preserve exact Foundation boundary trimming (including U+200B), then
        // collapse interior whitespace over Unicode scalars (`\s+` parity without
        // compiling NSRegularExpression) before grapheme-cluster prefix truncation.
        let trimmed = simplified.trimmed
        var collapsedScalars = String.UnicodeScalarView()
        collapsedScalars.reserveCapacity(trimmed.unicodeScalars.count)
        var hasContent = false
        var pendingSpace = false
        for scalar in trimmed.unicodeScalars {
            if scalar.properties.isWhitespace {
                if hasContent {
                    pendingSpace = true
                }
                continue
            }
            if pendingSpace {
                collapsedScalars.append(" ")
                pendingSpace = false
            }
            collapsedScalars.append(scalar)
            hasContent = true
        }

        let collapsed = String(collapsedScalars)
        let prefix = prefixLength > 0 ? String(collapsed.prefix(prefixLength)) : ""
        let hash = prefix.djb2()
        return formatHashKey(hash)
    }

    private static func formatHashKey(_ hash: UInt64) -> String {
        String(unsafeUninitializedCapacity: 18) { buffer in
            guard let dst = buffer.baseAddress else { return 0 }
            dst[0] = UInt8(ascii: "h")
            dst[1] = UInt8(ascii: ":")
            var value = hash
            var i = 17
            while i >= 2 {
                let nibble = UInt8(value & 0x0f)
                dst[i] = nibble < 10 ? nibble &+ 48 : nibble &+ 87
                value >>= 4
                i &-= 1
            }
            return 18
        }
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
    private var persistTask: Task<Void, Never>?
    private var pendingPersistIDs: [String] = []
    private var clearAllGeneration: UInt64 = 0

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
            let generation = clearAllGeneration
            nostrEventStore.loadAsync { [weak self] eventIDs in
                guard !eventIDs.isEmpty else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.clearAllGeneration == generation else { return }
                    for eventID in eventIDs where !self.nostrEventCache.contains(eventID) {
                        self.nostrEventCache.record(eventID, value: true)
                    }
                }
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
    /// - Parameters:
    ///   - eventId: The event ID
    ///   - persist: Whether to persist the ID across launches (true for
    ///     private-envelope kind 1059 DMs; false for ephemeral geohash
    ///     chat/presence kinds 20000/20001).
    func recordNostrEvent(_ eventId: String, persist: Bool = true) {
        nostrEventCache.record(eventId, value: true)
        if persist, nostrEventStore != nil {
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
        persistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.persistScheduled = false
            self.persistTask = nil
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
        clearAllGeneration &+= 1
        persistTask?.cancel()
        persistTask = nil
        persistScheduled = false
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
