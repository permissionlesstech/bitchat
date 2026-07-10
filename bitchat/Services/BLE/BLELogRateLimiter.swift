import Foundation

final class BLELogRateLimiter {
    private let defaultMinimumInterval: TimeInterval
    private let queue = DispatchQueue(label: "chat.bitchat.ble.log-rate-limiter")
    private var lastLogTimeByKey: [String: Date] = [:]

    init(defaultMinimumInterval: TimeInterval) {
        self.defaultMinimumInterval = defaultMinimumInterval
    }

    func shouldLog(
        key: String,
        now: Date = Date(),
        minimumInterval: TimeInterval? = nil
    ) -> Bool {
        queue.sync {
            let interval = minimumInterval ?? defaultMinimumInterval
            if let lastLogTime = lastLogTimeByKey[key],
               now.timeIntervalSince(lastLogTime) < interval {
                return false
            }
            lastLogTimeByKey[key] = now
            return true
        }
    }

}
