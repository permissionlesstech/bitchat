import Foundation
@testable import bitchat

/// Manually advanced engine scheduler: deferred work runs when the test
/// advances the clock past its deadline, on the real engine queue (deferred
/// bodies touch engine-confined state), and `advance` returns only after
/// the released work has finished — so assertions that follow observe its
/// engine-side effects without polling.
final class BLEEngineManualScheduler: BLEEngineScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var engineQueue: DispatchQueue?
    private var now: TimeInterval = 0
    private var pending: [(deadline: TimeInterval, work: DispatchWorkItem)] = []

    func activate(engineQueue: DispatchQueue) {
        lock.withLock { self.engineQueue = engineQueue }
    }

    func schedule(after delay: TimeInterval, execute work: DispatchWorkItem) {
        lock.withLock { pending.append((now + delay, work)) }
    }

    var pendingCount: Int {
        lock.withLock { pending.count }
    }

    /// The same counter `advance(by:)` moves, exposed as a `Date` so
    /// production code whose decisions are windowed on elapsed time (the
    /// announce throttle) can be driven by test time instead of the
    /// runner's speed. Anchored at a plausible wall-clock instant rather
    /// than the epoch so any timestamp derived from it stays sane.
    var currentDate: Date {
        lock.withLock { Self.epoch.addingTimeInterval(now) }
    }

    private static let epoch = Date(timeIntervalSince1970: 1_780_000_000)

    /// Advances the clock, releasing due work in deadline order.
    /// Cancellation keeps its production semantics: dispatch skips a
    /// cancelled `DispatchWorkItem` at execution.
    func advance(by interval: TimeInterval) {
        let (due, queue): ([DispatchWorkItem], DispatchQueue?) = lock.withLock {
            now += interval
            let cutoff = now
            let released = pending
                .filter { $0.deadline <= cutoff }
                .sorted { $0.deadline < $1.deadline }
                .map(\.work)
            pending.removeAll { $0.deadline <= cutoff }
            return (released, engineQueue)
        }
        guard let queue else { return }
        for work in due {
            queue.async(execute: work)
        }
        // Fence: released work (and anything it enqueued) has run before
        // the test's next assertion.
        queue.sync {}
    }
}
