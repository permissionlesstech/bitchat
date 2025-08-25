import Foundation

// MARK: - Message Deduplicator (shared)

final class MessageDeduplicator {
    private struct Entry {
        let messageID: String
        let timestamp: Date
    }

    private var entries: [Entry] = []
    private var lookup = Set<String>()
    private let lock = NSLock()
    private let maxAge: TimeInterval = TransportConfig.messageDedupMaxAgeSeconds  // 5 minutes
    private let maxCount = TransportConfig.messageDedupMaxCount

    /// Check if message is duplicate and add if not
    func isDuplicate(_ messageID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        cleanupOldEntries()

        if lookup.contains(messageID) {
            return true
        }

        entries.append(Entry(messageID: messageID, timestamp: Date()))
        lookup.insert(messageID)

        if entries.count > maxCount {
            let toRemove = entries.prefix(100)
            toRemove.forEach { lookup.remove($0.messageID) }
            entries.removeFirst(100)
        }

        return false
    }

    /// Add an ID without checking (for announce-back tracking)
    func markProcessed(_ messageID: String) {
        lock.lock()
        defer { lock.unlock() }

        if !lookup.contains(messageID) {
            entries.append(Entry(messageID: messageID, timestamp: Date()))
            lookup.insert(messageID)
        }
    }

    /// Check if ID exists without adding
    func contains(_ messageID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return lookup.contains(messageID)
    }

    /// Clear all entries
    func reset() {
        lock.lock()
        defer { lock.unlock() }

        entries.removeAll()
        lookup.removeAll()
    }

    /// Periodic cleanup
    func cleanup() {
        lock.lock()
        defer { lock.unlock() }

        cleanupOldEntries()

        if entries.capacity > maxCount * 2 {
            entries.reserveCapacity(maxCount)
        }
    }

    private func cleanupOldEntries() {
        let cutoff = Date().addingTimeInterval(-maxAge)
        while let first = entries.first, first.timestamp < cutoff {
            lookup.remove(first.messageID)
            entries.removeFirst()
        }
    }
}
