import Foundation

final class BLELogRateLimiter {
    private static let maxTrackedKeys = 256
    private let defaultMinimumInterval: TimeInterval
    private let lock = NSLock()
    private var lastLogTimeByKey = BoundedCache<String, Date>(capacity: maxTrackedKeys)

    init(defaultMinimumInterval: TimeInterval) {
        self.defaultMinimumInterval = defaultMinimumInterval
    }

    func shouldLog(
        key: String,
        now: Date = Date(),
        minimumInterval: TimeInterval? = nil
    ) -> Bool {
        lock.withLock {
            let interval = minimumInterval ?? defaultMinimumInterval
            if let lastLogTime = lastLogTimeByKey.value(for: key),
               now.timeIntervalSince(lastLogTime) < interval {
                return false
            }
            lastLogTimeByKey.set(key, value: now, refreshOrder: true)
            return true
        }
    }
}
