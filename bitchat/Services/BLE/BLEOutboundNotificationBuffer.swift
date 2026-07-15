import Foundation

struct BLEPendingNotification<Target> {
    let data: Data
    let targets: [Target]?
}

struct BLEOutboundNotificationBuffer<Target> {
    enum EnqueueResult {
        case enqueued(count: Int)
        case full(count: Int)
    }

    private var notifications: [BLEPendingNotification<Target>] = []

    var count: Int {
        notifications.count
    }

    var isEmpty: Bool {
        notifications.isEmpty
    }

    mutating func removeAll() {
        notifications.removeAll()
    }

    mutating func enqueue(data: Data, targets: [Target]?, capCount: Int) -> EnqueueResult {
        guard notifications.count < capCount else {
            return .full(count: notifications.count)
        }

        notifications.append(BLEPendingNotification(data: data, targets: targets))
        return .enqueued(count: notifications.count)
    }

    mutating func takeAll() -> [BLEPendingNotification<Target>] {
        let pending = notifications
        notifications.removeAll()
        return pending
    }

    mutating func prepend(_ pending: [BLEPendingNotification<Target>]) {
        guard !pending.isEmpty else { return }
        notifications.insert(contentsOf: pending, at: 0)
    }

    /// Removes a disconnected target from target-specific retries. Broadcast
    /// entries (`targets == nil`) remain valid for the surviving subscriber
    /// set; an entry with no targets left is discarded entirely.
    mutating func removeTarget(where matches: (Target) -> Bool) {
        notifications = notifications.compactMap { notification in
            guard let targets = notification.targets else { return notification }
            let remaining = targets.filter { !matches($0) }
            guard !remaining.isEmpty else { return nil }
            return BLEPendingNotification(data: notification.data, targets: remaining)
        }
    }
}
