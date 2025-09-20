import Foundation
import Combine

// Transfer progress events and cancellation
final class TransferProgressManager: ObservableObject {
    static let shared = TransferProgressManager()

    struct Progress: Equatable {
        var sent: Int
        var total: Int
        var completed: Bool { sent >= total && total > 0 }
    }

    @Published private(set) var progresses: [String: Progress] = [:] // id -> progress
    private var cancelled: Set<String> = []
    private let lock = NSLock()

    func start(_ id: String, total: Int) {
        update(id) { _ in Progress(sent: 0, total: total) }
    }

    func step(_ id: String) {
        update(id) { p in
            var np = p ?? Progress(sent: 0, total: 1)
            np.sent = min(np.sent + 1, max(1, np.total))
            return np
        }
    }

    func complete(_ id: String) {
        update(id) { p in
            var np = p ?? Progress(sent: 1, total: 1)
            np.sent = max(np.total, np.sent)
            return np
        }
        clearCancel(id)
    }

    func cancel(_ id: String) {
        lock.lock(); cancelled.insert(id); lock.unlock()
    }

    func isCancelled(_ id: String) -> Bool {
        lock.lock(); let c = cancelled.contains(id); lock.unlock(); return c
    }

    private func clearCancel(_ id: String) {
        lock.lock(); _ = cancelled.remove(id); lock.unlock()
    }

    private func update(_ id: String, mutate: @escaping (Progress?) -> Progress) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let current = self.progresses[id]
            let next = mutate(current)
            self.progresses[id] = next
        }
    }
}
