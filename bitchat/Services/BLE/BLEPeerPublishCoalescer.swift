import Foundation

enum BLEPeerPublishDecision: Equatable {
    case publishNow
    case schedule(delay: TimeInterval)
    case skip
}

struct BLEPeerPublishCoalescer {
    private var lastPublishAt: Date
    private var publishPending: Bool
    private let minimumInterval: TimeInterval

    init(
        lastPublishAt: Date = .distantPast,
        publishPending: Bool = false,
        minimumInterval: TimeInterval = 0.1
    ) {
        self.lastPublishAt = lastPublishAt
        self.publishPending = publishPending
        self.minimumInterval = minimumInterval
    }

    mutating func requestPublish(now: Date) -> BLEPeerPublishDecision {
        let elapsed = now.timeIntervalSince(lastPublishAt)
        if elapsed >= minimumInterval {
            lastPublishAt = now
            return .publishNow
        }

        guard !publishPending else {
            return .skip
        }

        publishPending = true
        return .schedule(delay: minimumInterval - elapsed)
    }

    mutating func scheduledPublishFired(now: Date) {
        lastPublishAt = now
        publishPending = false
    }
}
