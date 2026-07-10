import Foundation

/// Thread-safe announce admission state.
///
/// Announce requests originate from the Bluetooth delegate queue, the
/// concurrent message queue, and the maintenance timer. Keeping the timestamp
/// behind a lock makes admission and maintenance snapshots atomic when those
/// request sources race.
final class BLEAnnounceThrottle: @unchecked Sendable {
    private let lock = NSLock()
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
        lock.withLock { now.timeIntervalSince(lastSent) }
    }

    func shouldSend(force: Bool, now: Date) -> Bool {
        lock.withLock {
            let minimumInterval = force ? forcedMinimumInterval : normalMinimumInterval
            guard now.timeIntervalSince(lastSent) >= minimumInterval else {
                return false
            }

            lastSent = now
            return true
        }
    }
}
