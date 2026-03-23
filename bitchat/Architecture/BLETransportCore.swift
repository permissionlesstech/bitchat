import Foundation

actor BLETransportCore {
    private var subscribers: [UUID: AsyncStream<TransportEvent>.Continuation] = [:]
    private var pendingEvents: [TransportEvent] = []

    func subscribe() -> AsyncStream<TransportEvent> {
        let id = UUID()

        return AsyncStream { continuation in
            subscribers[id] = continuation
            if !pendingEvents.isEmpty {
                let buffered = pendingEvents
                pendingEvents.removeAll()
                for event in buffered {
                    continuation.yield(event)
                }
            }
            continuation.onTermination = { [id] _ in
                Task {
                    await self.removeSubscriber(id)
                }
            }
        }
    }

    func emit(_ event: TransportEvent) {
        guard !subscribers.isEmpty else {
            pendingEvents.append(event)
            return
        }
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }
}
