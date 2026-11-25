import Foundation

/// Thread-safe announce admission state, plus a record of what we broadcast.
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
    private var broadcasts: UInt64 = 0
    private var claimedNeighbors: Set<Data> = []

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

    /// Announces broadcast so far. Monotonic, never reset: a count seen to
    /// change after a snapshot proves an announce was broadcast after it.
    var broadcastCount: UInt64 {
        lock.withLock { broadcasts }
    }

    /// Records an announce about to go on the wire and the neighbours it
    /// claims. Call it before the broadcast reads link state, so a count
    /// change seen after a link-up snapshot proves the announce saw that
    /// link. Record the neighbour set from before the encoder's 10-entry
    /// cap: a high-degree node must never owe an announce for a neighbour
    /// the cap left out.
    func noteBroadcast(claimingNeighbors neighbors: [Data]) {
        lock.withLock {
            broadcasts &+= 1
            claimedNeighbors = Set(neighbors)
        }
    }

    /// Whether our last broadcast announce left `neighbor` out.
    func lastBroadcastOmits(_ neighbor: Data) -> Bool {
        lock.withLock { !claimedNeighbors.contains(neighbor) }
    }

    /// Forgets the last-sent timestamp. A panic rotation calls this so the
    /// new identity's first announce cannot be swallowed by the old
    /// identity's throttle debt — otherwise a panic within the forced
    /// minimum interval of the last announce leaves the rotated identity
    /// invisible until the next maintenance cycle. The new identity has
    /// claimed no neighbours yet either.
    func reset() {
        lock.withLock {
            lastSent = .distantPast
            claimedNeighbors.removeAll()
        }
    }
}
