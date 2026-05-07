import Foundation
import Combine
import Testing
@testable import bitchat

@Suite("TransferProgressManager Tests")
struct TransferProgressManagerTests {

    @Test("Start publishes started event and stores snapshot")
    @MainActor
    func startPublishesAndStoresSnapshot() async throws {
        let manager = TransferProgressManager()
        let transferID = "transfer-start"
        var cancellable: AnyCancellable?
        let recorder = EventRecorder()

        cancellable = manager.publisher.sink { event in
            if case .started(let id, let total) = event {
                recorder.append("started:\(id):\(total)")
            }
        }

        manager.start(id: transferID, totalFragments: 3)

        let didReceive = await TestHelpers.waitUntil({
            recorder.values == ["started:\(transferID):3"]
        }, timeout: 0.5)
        #expect(didReceive)

        #expect(recorder.values == ["started:\(transferID):3"])
        #expect(manager.snapshot(id: transferID)?.sent == 0)
        #expect(manager.snapshot(id: transferID)?.total == 3)
        _ = cancellable
    }

    @Test("Sending final fragment publishes update and completion then clears snapshot")
    @MainActor
    func recordFragmentSentPublishesProgressAndCompletion() async throws {
        let manager = TransferProgressManager()
        let transferID = "transfer-complete"
        var cancellable: AnyCancellable?
        let recorder = EventRecorder()

        cancellable = manager.publisher.sink { event in
            switch event {
            case .started(let id, let total):
                recorder.append("started:\(id):\(total)")
            case .updated(let id, let sent, let total):
                recorder.append("updated:\(id):\(sent):\(total)")
            case .completed(let id, let total):
                recorder.append("completed:\(id):\(total)")
            case .cancelled:
                break
            }
        }

        manager.start(id: transferID, totalFragments: 1)
        manager.recordFragmentSent(id: transferID)

        let didReceive = await TestHelpers.waitUntil({
            recorder.values.count == 3
        }, timeout: 0.5)
        #expect(didReceive)

        #expect(recorder.values == [
            "started:\(transferID):1",
            "updated:\(transferID):1:1",
            "completed:\(transferID):1"
        ])
        #expect(manager.snapshot(id: transferID) == nil)
        _ = cancellable
    }

    @Test("Cancel publishes cancelled event and clears state")
    @MainActor
    func cancelPublishesAndClearsState() async throws {
        let manager = TransferProgressManager()
        let transferID = "transfer-cancel"
        var cancellable: AnyCancellable?
        let recorder = EventRecorder()

        cancellable = manager.publisher.sink { event in
            switch event {
            case .started(let id, let total):
                recorder.append("started:\(id):\(total)")
            case .cancelled(let id, let sent, let total):
                recorder.append("cancelled:\(id):\(sent):\(total)")
            case .updated, .completed:
                break
            }
        }

        manager.start(id: transferID, totalFragments: 4)
        manager.recordFragmentSent(id: transferID)
        manager.cancel(id: transferID)

        let didReceive = await TestHelpers.waitUntil({
            recorder.values.contains("started:\(transferID):4") &&
            recorder.values.contains("cancelled:\(transferID):1:4")
        }, timeout: 0.5)
        #expect(didReceive)

        #expect(recorder.values.contains("started:\(transferID):4"))
        #expect(recorder.values.contains("cancelled:\(transferID):1:4"))
        #expect(manager.snapshot(id: transferID) == nil)
        _ = cancellable
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
