import Foundation

struct BLEScheduledRelayStore {
    private struct Entry {
        let workItem: DispatchWorkItem
        let isProtectedFromDuplicateCancellation: Bool
    }

    private var relays: [String: Entry] = [:]

    var count: Int {
        relays.count
    }

    var isEmpty: Bool {
        relays.isEmpty
    }

    mutating func schedule(
        _ workItem: DispatchWorkItem,
        messageID: String,
        isProtectedFromDuplicateCancellation: Bool = false
    ) {
        relays[messageID] = Entry(
            workItem: workItem,
            isProtectedFromDuplicateCancellation: isProtectedFromDuplicateCancellation
        )
    }

    @discardableResult
    mutating func remove(messageID: String) -> DispatchWorkItem? {
        relays.removeValue(forKey: messageID)?.workItem
    }

    @discardableResult
    mutating func cancel(messageID: String) -> Bool {
        guard let entry = relays.removeValue(forKey: messageID) else {
            return false
        }

        entry.workItem.cancel()
        return true
    }

    /// Cancels a scheduled relay on duplicate arrival only when it is an
    /// opportunistic flood relay. MPR-elected hubs are responsible for covering
    /// their own `N2(P)` slice, and conservative-flood packets always relay, so
    /// neither may be cancelled upon hearing a duplicate transmission.
    @discardableResult
    mutating func cancelIfDuplicateCancellable(messageID: String) -> Bool {
        guard let entry = relays[messageID], !entry.isProtectedFromDuplicateCancellation else {
            return false
        }
        relays.removeValue(forKey: messageID)
        entry.workItem.cancel()
        return true
    }

    mutating func cancelAll() {
        relays.values.forEach { $0.workItem.cancel() }
        relays.removeAll()
    }

    mutating func removeAllIfOverCapacity(_ maxCount: Int) {
        if relays.count > maxCount {
            relays.removeAll()
        }
    }
}
