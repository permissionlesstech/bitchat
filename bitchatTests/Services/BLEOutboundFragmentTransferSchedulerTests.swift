import BitFoundation
import Foundation
import Testing
@testable import bitchat

struct BLEOutboundFragmentTransferSchedulerTests {
    @Test
    func submitStartsPublicMessageWithoutTransferReservation() {
        var scheduler = BLEOutboundFragmentTransferScheduler()
        let request = makeRequest(type: MessageType.message.rawValue, transferId: nil)

        let result = scheduler.submit(request, maxConcurrentTransfers: 1)

        if case let .start(_, reservedTransferId) = result {
            #expect(reservedTransferId == nil)
            #expect(scheduler.activeCount == 0)
            #expect(scheduler.pendingCount == 0)
        } else {
            Issue.record("Expected non-file fragments to start without reserving a transfer slot")
        }
    }

    @Test
    func submitQueuesFileTransferWhenSlotsAreFull() {
        var scheduler = BLEOutboundFragmentTransferScheduler()
        let first = makeRequest(type: MessageType.fileTransfer.rawValue, transferId: "first")
        let second = makeRequest(type: MessageType.fileTransfer.rawValue, transferId: "second")

        guard case let .start(_, firstReservation?) = scheduler.submit(first, maxConcurrentTransfers: 1) else {
            Issue.record("Expected first file transfer to reserve a slot")
            return
        }
        #expect(firstReservation == "first")

        let result = scheduler.submit(second, maxConcurrentTransfers: 1)

        if case let .queued(_, transferId, position) = result {
            #expect(transferId == "second")
            #expect(position == .back)
            #expect(scheduler.activeCount == 1)
            #expect(scheduler.pendingCount == 1)
        } else {
            Issue.record("Expected second file transfer to queue while slots are full")
        }
    }

    @Test
    func submitQueuesDuplicateActiveTransferAtFront() {
        var scheduler = BLEOutboundFragmentTransferScheduler()
        let request = makeRequest(type: MessageType.fileTransfer.rawValue, transferId: "same")

        _ = scheduler.submit(request, maxConcurrentTransfers: 2)
        let result = scheduler.submit(request, maxConcurrentTransfers: 2)

        if case let .queued(_, transferId, position) = result {
            #expect(transferId == "same")
            #expect(position == .front)
            #expect(scheduler.activeCount == 1)
            #expect(scheduler.pendingCount == 1)
        } else {
            Issue.record("Expected duplicate active transfer to queue at the front")
        }
    }

    @Test
    func cancelActiveTransferReturnsScheduledWorkItems() {
        var scheduler = BLEOutboundFragmentTransferScheduler()
        let request = makeRequest(type: MessageType.fileTransfer.rawValue, transferId: "active")
        _ = scheduler.submit(request, maxConcurrentTransfers: 1)
        let workItem = DispatchWorkItem {}

        let didActivate = scheduler.activateReservedTransfer(id: "active", totalFragments: 2, workItems: [workItem])
        #expect(didActivate)

        if case let .active(transferId, workItems) = scheduler.cancelTransfer("active") {
            #expect(transferId == "active")
            #expect(workItems.count == 1)
            #expect(scheduler.activeCount == 0)
        } else {
            Issue.record("Expected active transfer cancellation to return its work items")
        }
    }

    @Test
    func completedTransferFreesSlotForPendingTransfer() {
        var scheduler = BLEOutboundFragmentTransferScheduler()
        let first = makeRequest(type: MessageType.fileTransfer.rawValue, transferId: "first")
        let second = makeRequest(type: MessageType.fileTransfer.rawValue, transferId: "second")

        _ = scheduler.submit(first, maxConcurrentTransfers: 1)
        let didActivate = scheduler.activateReservedTransfer(id: "first", totalFragments: 2, workItems: [])
        #expect(didActivate)
        _ = scheduler.submit(second, maxConcurrentTransfers: 1)

        #expect(scheduler.markFragmentSent(transferId: "first") == .progress(sentFragments: 1, totalFragments: 2))
        #expect(scheduler.markFragmentSent(transferId: "first") == .complete(sentFragments: 2, totalFragments: 2))

        let starts = scheduler.reservePendingStarts(maxConcurrentTransfers: 1)
        #expect(starts.count == 1)

        if case let .start(_, reservedTransferId?) = starts.first {
            #expect(reservedTransferId == "second")
            #expect(scheduler.activeCount == 1)
            #expect(scheduler.pendingCount == 0)
        } else {
            Issue.record("Expected pending transfer to reserve the freed slot")
        }
    }

    @Test
    func removeAllReturnsActiveWorkItemsAndDropsPendingTransfers() {
        var scheduler = BLEOutboundFragmentTransferScheduler()
        let active = makeRequest(type: MessageType.fileTransfer.rawValue, transferId: "active")
        let pending = makeRequest(type: MessageType.fileTransfer.rawValue, transferId: "pending")
        let workItem = DispatchWorkItem {}

        _ = scheduler.submit(active, maxConcurrentTransfers: 1)
        let didActivate = scheduler.activateReservedTransfer(id: "active", totalFragments: 1, workItems: [workItem])
        #expect(didActivate)
        _ = scheduler.submit(pending, maxConcurrentTransfers: 1)

        let removed = scheduler.removeAll()

        #expect(removed.count == 1)
        #expect(removed.first?.id == "active")
        #expect(removed.first?.workItems.count == 1)
        #expect(scheduler.activeCount == 0)
        #expect(scheduler.pendingCount == 0)
    }

    private func makeRequest(type: UInt8, transferId: String?) -> BLEOutboundFragmentTransferRequest {
        BLEOutboundFragmentTransferRequest(
            packet: BitchatPacket(
                type: type,
                senderID: Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77]),
                recipientID: nil,
                timestamp: 0x0102030405,
                payload: Data((transferId ?? "payload").utf8),
                signature: nil,
                ttl: 3
            ),
            pad: false,
            maxChunk: nil,
            directedPeer: nil,
            transferId: transferId
        )
    }
}
