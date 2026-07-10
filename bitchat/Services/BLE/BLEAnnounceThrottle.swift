import Foundation

struct BLEAnnounceThrottle {
    private var lastSent: Date
    private let normalMinimumInterval: TimeInterval
    private let forcedMinimumInterval: TimeInterval

    init(
        lastSent: Date = .distantPast,
        normalMinimumInterval: TimeInterval = TransportConfig.bleAnnounceMinInterval,
        forcedMinimumInterval: TimeInterval = TransportConfig.bleForceAnnounceMinIntervalSeconds
    ) {
        self.lastSent = lastSent
        self.normalMinimumInterval = normalMinimumInterval
        self.forcedMinimumInterval = forcedMinimumInterval
    }

    func elapsed(since now: Date) -> TimeInterval {
        now.timeIntervalSince(lastSent)
    }

    mutating func shouldSend(force: Bool, now: Date) -> Bool {
        let minimumInterval = force ? forcedMinimumInterval : normalMinimumInterval
        guard elapsed(since: now) >= minimumInterval else {
            return false
        }

        lastSent = now
        return true
    }
}
