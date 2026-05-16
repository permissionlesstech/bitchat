import Foundation

// MARK: - Message Deduplicator (shared)

/// Thread-safe deduplicator with LRU eviction and time-based expiry.
/// Used for both message ID deduplication (network layer) and content key deduplication (UI layer).
final class MessageDeduplicator {
    private struct Entry: Equatable {
        let id: String
        let timestamp: Date
    }

    private var entries: [Entry] = []
    private var head: Int = 0
    private var lookup: [String: Date] = [:]  // id -> timestamp for O(1) lookup
    private let lock = NSLock()
    private let maxAge: TimeInterval
    private let maxCount: Int

    /// Initialize with default config from TransportConfig
    convenience init() {
        self.init(
            maxAge: TransportConfig.messageDedupMaxAgeSeconds,
            maxCount: TransportConfig.messageDedupMaxCount
        )
    }

    /// Initialize with custom config for content deduplication
    init(maxAge: TimeInterval, maxCount: Int) {
        self.maxAge = maxAge
        self.maxCount = maxCount
    }

    /// Check if message is duplicate and add if not.
    /// - Parameter id: The message identifier to check.
    /// - Returns: `true` if the message was already seen, `false` otherwise.
    func isDuplicate(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        cleanupOldEntries(before: now.addingTimeInterval(-maxAge))

        if lookup[id] != nil {
            return true
        }

        entries.append(Entry(id: id, timestamp: now))
        lookup[id] = now
        trimIfNeeded()

        return false
    }

    /// Record an ID with a specific timestamp (for content key tracking)
    func record(_ id: String, timestamp: Date) {
        lock.lock()
        defer { lock.unlock() }

        if lookup[id] == nil {
            entries.append(Entry(id: id, timestamp: timestamp))
        }
        lookup[id] = timestamp
        trimIfNeeded()
    }

    /// Add an ID without checking (for announce-back tracking)
    func markProcessed(_ id: String) {
        lock.lock()
        defer { lock.unlock() }

        if lookup[id] == nil {
            let now = Date()
            entries.append(Entry(id: id, timestamp: now))
            lookup[id] = now
        }
    }

    /// Check if ID exists without adding
    func contains(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return lookup[id] != nil
    }

    /// Get timestamp for an ID (for content deduplication time-window checks)
    func timestampFor(_ id: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return lookup[id]
    }

    private func trimIfNeeded() {
        let activeCount = entries.count - head
        guard activeCount > maxCount else { return }

        // Remove down to 75% of maxCount for better amortization
        let targetCount = (maxCount * 3) / 4
        let removeCount = activeCount - targetCount

        for i in head..<(head + removeCount) {
            lookup.removeValue(forKey: entries[i].id)
        }
        head += removeCount

        // Compact when head exceeds half the array to reclaim memory
        if head > entries.count / 2 {
            entries.removeFirst(head)
            head = 0
        }
    }

    /// Clear all entries
    func reset() {
        lock.lock()
        defer { lock.unlock() }

        entries.removeAll()
        head = 0
        lookup.removeAll()
    }

    /// Periodic cleanup of expired entries and memory optimization.
    func cleanup() {
        lock.lock()
        defer { lock.unlock() }

        cleanupOldEntries(before: Date().addingTimeInterval(-maxAge))

        // Shrink capacity if significantly oversized
        if entries.capacity > maxCount * 2 && entries.count < maxCount {
            entries.reserveCapacity(maxCount)
        }
    }

    private func cleanupOldEntries(before cutoff: Date) {
        while head < entries.count, entries[head].timestamp < cutoff {
            lookup.removeValue(forKey: entries[head].id)
            head += 1
        }
        // Compact when head exceeds half the array
        if head > 0 && head > entries.count / 2 {
            entries.removeFirst(head)
            head = 0
        }
    }
}
