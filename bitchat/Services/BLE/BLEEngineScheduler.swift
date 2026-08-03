import Foundation

/// Schedules deferred engine work: relay jitter, announce delays, protocol
/// deadlines (ping, capability proof), notification retry backoff, and
/// fragment pacing.
///
/// This is the transport's only source of engine-side delay. Production
/// wraps the engine queue's `asyncAfter`; tests inject a manually advanced
/// clock so timer-driven behavior is asserted deterministically instead of
/// racing the wall clock — product constants used as deadlines are exactly
/// the hidden-elapsed-deadline flake class the test-timing hygiene rules
/// exist to contain.
protocol BLEEngineScheduling: AnyObject {
    /// Called once by the transport with its engine queue. Scheduled work
    /// always executes there: deferred bodies touch engine-confined state.
    func activate(engineQueue: DispatchQueue)
    /// Runs `work` on the engine queue after `delay`, honoring
    /// `DispatchWorkItem` cancellation.
    func schedule(after delay: TimeInterval, execute work: DispatchWorkItem)
}

extension BLEEngineScheduling {
    func schedule(after delay: TimeInterval, _ body: @escaping () -> Void) {
        schedule(after: delay, execute: DispatchWorkItem(block: body))
    }
}

/// Production scheduler: a thin veneer over the engine queue.
final class BLEEngineDispatchScheduler: BLEEngineScheduling {
    private var queue: DispatchQueue?

    func activate(engineQueue: DispatchQueue) {
        queue = engineQueue
    }

    func schedule(after delay: TimeInterval, execute work: DispatchWorkItem) {
        queue?.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
