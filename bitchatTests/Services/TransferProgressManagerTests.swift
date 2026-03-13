import Combine
import Testing
@testable import bitchat

@Suite("TransferProgressManager Tests")
struct TransferProgressManagerTests {

    @Test("Start publishes started event and stores snapshot")
    func startPublishesAndStoresSnapshot() async throws {
        let manager = TransferProgressManager()
        let transferID = "transfer-start"
        var cancellable: AnyCancellable?
        var received: [String] = []

        await confirmation("started event") { eventReceived in
            cancellable = manager.publisher.sink { event in
                if case .started(let id, let total) = event {
                    received.append("started:\(id):\(total)")
                    eventReceived()
                }
            }
            manager.start(id: transferID, totalFragments: 3)
            try? await sleep(0.05)
        }

        #expect(received == ["started:\(transferID):3"])
        #expect(manager.snapshot(id: transferID)?.sent == 0)
        #expect(manager.snapshot(id: transferID)?.total == 3)
        _ = cancellable
    }

    @Test("Sending final fragment publishes update and completion then clears snapshot")
    func recordFragmentSentPublishesProgressAndCompletion() async throws {
        let manager = TransferProgressManager()
        let transferID = "transfer-complete"
        var cancellable: AnyCancellable?
        var received: [String] = []

        await confirmation("started, updated, completed", expectedCount: 3) { eventReceived in
            cancellable = manager.publisher.sink { event in
                switch event {
                case .started(let id, let total):
                    received.append("started:\(id):\(total)")
                    eventReceived()
                case .updated(let id, let sent, let total):
                    received.append("updated:\(id):\(sent):\(total)")
                    eventReceived()
                case .completed(let id, let total):
                    received.append("completed:\(id):\(total)")
                    eventReceived()
                case .cancelled:
                    break
                }
            }
            manager.start(id: transferID, totalFragments: 1)
            manager.recordFragmentSent(id: transferID)
            try? await sleep(0.05)
        }

        #expect(received == [
            "started:\(transferID):1",
            "updated:\(transferID):1:1",
            "completed:\(transferID):1"
        ])
        #expect(manager.snapshot(id: transferID) == nil)
        _ = cancellable
    }

    @Test("Cancel publishes cancelled event and clears state")
    func cancelPublishesAndClearsState() async throws {
        let manager = TransferProgressManager()
        let transferID = "transfer-cancel"
        var cancellable: AnyCancellable?
        var received: [String] = []

        await confirmation("started and cancelled", expectedCount: 2) { eventReceived in
            cancellable = manager.publisher.sink { event in
                switch event {
                case .started(let id, let total):
                    received.append("started:\(id):\(total)")
                    eventReceived()
                case .cancelled(let id, let sent, let total):
                    received.append("cancelled:\(id):\(sent):\(total)")
                    eventReceived()
                case .updated, .completed:
                    break
                }
            }
            manager.start(id: transferID, totalFragments: 4)
            manager.recordFragmentSent(id: transferID)
            manager.cancel(id: transferID)
            try? await sleep(0.05)
        }

        #expect(received.contains("started:\(transferID):4"))
        #expect(received.contains("cancelled:\(transferID):1:4"))
        #expect(manager.snapshot(id: transferID) == nil)
        _ = cancellable
    }
}
