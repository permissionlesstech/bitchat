import Foundation

// MARK: - Message Deduplicator (shared)

/// Thread-safe deduplicator with bounded eviction and time-based expiry.
/// Used for both message ID deduplication (network layer) and content key deduplication (UI layer).
final class MessageDeduplicator {
    private var cache: BoundedCache<String, Void>
    private let lock = NSLock()

    /// Initialize with default config from TransportConfig
    convenience init() {
        self.init(
            maxAge: TransportConfig.messageDedupMaxAgeSeconds,
            maxCount: TransportConfig.messageDedupMaxCount
        )
    }

    /// Initialize with custom config for content deduplication
    init(maxAge: TimeInterval, maxCount: Int) {
        self.cache = BoundedCache(capacity: max(1, maxCount), ttl: maxAge)
    }

    /// Check if message is duplicate and add if not.
    /// - Parameter id: The message identifier to check.
    /// - Returns: `true` if the message was already seen, `false` otherwise.
    func isDuplicate(_ id: String) -> Bool {
        lock.withLock {
            let now = Date()
            cache.pruneExpired(now: now)
            if cache.contains(id, now: now) {
                return true
            }
            cache.set(id, value: (), now: now, refreshOrder: false)
            return false
        }
    }

    /// Add an ID without checking (for announce-back tracking)
    func markProcessed(_ id: String) {
        lock.withLock {
            let now = Date()
            if !cache.contains(id, now: now) {
                cache.set(id, value: (), now: now, refreshOrder: false)
            }
        }
    }

    /// Check if ID exists without adding
    func contains(_ id: String) -> Bool {
        lock.withLock { cache.contains(id) }
    }

    /// Clear all entries
    func reset() {
        lock.withLock { cache.removeAll() }
    }

    /// Periodic cleanup of expired entries and memory optimization.
    func cleanup() {
        lock.withLock {
            cache.pruneExpired(now: Date())
            cache.shrinkIfOversized()
        }
    }
}
