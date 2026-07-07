import Foundation

/// Remembers recently seen bitchat peripherals (fresh discoveries and dropped
/// links) so the service can arm pending background connections against them
/// when the app leaves the foreground. Generic over the peripheral type so
/// the eviction/expiry logic is testable without CoreBluetooth.
final class BLERecentPeripheralCache<Peripheral> {
    private struct Entry {
        let peripheral: Peripheral
        var lastSeen: Date
    }

    private var entries: [String: Entry] = [:]
    private let capacity: Int
    private let maxAge: TimeInterval

    init(
        capacity: Int = TransportConfig.bleRecentPeripheralCacheCap,
        maxAge: TimeInterval = TransportConfig.bleRecentPeripheralMaxAgeSeconds
    ) {
        self.capacity = capacity
        self.maxAge = maxAge
    }

    var count: Int { entries.count }

    func record(_ peripheral: Peripheral, peripheralID: String, at now: Date) {
        entries[peripheralID] = Entry(peripheral: peripheral, lastSeen: now)
        guard entries.count > capacity else { return }
        // Inserts overshoot capacity by at most one; evict the stalest entry
        if let stalest = entries.min(by: { $0.value.lastSeen < $1.value.lastSeen }) {
            entries.removeValue(forKey: stalest.key)
        }
    }

    /// Most-recently-seen peripherals eligible for a pending background
    /// connect, freshest first, capped at `limit`. Expired entries are
    /// pruned as a side effect.
    func reconnectTargets(
        now: Date,
        limit: Int,
        excluding: (String) -> Bool
    ) -> [(peripheralID: String, peripheral: Peripheral)] {
        let cutoff = now.addingTimeInterval(-maxAge)
        entries = entries.filter { $0.value.lastSeen >= cutoff }
        guard limit > 0 else { return [] }
        return entries
            .filter { !excluding($0.key) }
            .sorted { $0.value.lastSeen > $1.value.lastSeen }
            .prefix(limit)
            .map { (peripheralID: $0.key, peripheral: $0.value.peripheral) }
    }
}
