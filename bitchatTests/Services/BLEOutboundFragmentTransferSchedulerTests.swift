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
    func strictDirectTransferIsRejectedWithoutBeingQueuedWhenSlotsAreFull() {
        var scheduler = BLEOutboundFragmentTransferScheduler()
        let active = makeRequest(type: MessageType.fileTransfer.rawValue, transferId: "active")
        let strict = makeRequest(
            type: MessageType.fileTransfer.rawValue,
            transferId: "strict",
            requireDirectPeerLink: true
        )

        guard case .start = scheduler.submit(active, maxConcurrentTransfers: 1) else {
            Issue.record("Expected active transfer to reserve the only slot")
            return
        }

        let result = scheduler.submit(strict, maxConcurrentTransfers: 1)

        if case let .rejectedStrict(request, transferId) = result {
            #expect(request.requireDirectPeerLink)
            #expect(transferId == "strict")
            #expect(scheduler.activeCount == 1)
            #expect(scheduler.pendingCount == 0)
        } else {
            Issue.record("Expected strict transfer to reject instead of entering the pending queue")
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
    func resendWithoutTransferIdOfActiveBroadcastContentIsDropped() {
        // Field bug: a gossip-sync replay re-fragmented a 41KB voice file
        // that was still being broadcast, sending two complete fragment
        // streams. The resend path has no explicit transferId; drop it while
        // a covering transfer of the same bytes is in flight.
        var scheduler = BLEOutboundFragmentTransferScheduler()
        let original = makeRequest(type: MessageType.fileTransfer.rawValue, transferId: "app-id", payload: "voice-file")
        let resend = makeRequest(type: MessageType.fileTransfer.rawValue, transferId: nil, payload: "voice-file")

        _ = scheduler.submit(original, maxConcurrentTransfers: 2)
        let result = scheduler.submit(resend, maxConcurrentTransfers: 2)

        if case let .droppedDuplicate(_, activeTransferId) = result {
            #expect(activeTransferId == "app-id")
            #expect(scheduler.activeCount == 1)
            #expect(scheduler.pendingCount == 0)
        } else {
            Issue.record("Expected the transferId-less resend of in-flight broadcast content to be dropped")
        }
    }

    @Test
    func directedResendToAnUncoveredAudienceStillRuns() {
        // The in-flight copy is directed to one peer; a resend of the same
        // bytes to a different peer is not redundant.
        var scheduler = BLEOutboundFragmentTransferScheduler()
        let toFirstPeer = makeRequest(
            type: MessageType.fileTransfer.rawValue,
            transferId: "app-id",
            payload: "shared-file",
            directedPeer: PeerID(str: "1122334455667788")
        )
        let toSecondPeer = makeRequest(
            type: MessageType.fileTransfer.rawValue,
            transferId: nil,
            payload: "shared-file",
            directedPeer: PeerID(str: "8877665544332211")
        )

        _ = scheduler.submit(toFirstPeer, maxConcurrentTransfers: 2)
        let result = scheduler.submit(toSecondPeer, maxConcurrentTransfers: 2)

        if case .start = result {
            #expect(scheduler.activeCount == 2)
        } else {
            Issue.record("Expected a resend directed at an uncovered peer to start")
        }
    }

    @Test
    func explicitTransferIdSendIsNeverDroppedAsDuplicate() {
        // App-initiated sends carry a transferId the progress UI tracks;
        // only transferId-less resend paths are deduplicated.
        var scheduler = BLEOutboundFragmentTransferScheduler()
        let first = makeRequest(type: MessageType.fileTransfer.rawValue, transferId: "send-1", payload: "same-bytes")
        let second = makeRequest(type: MessageType.fileTransfer.rawValue, transferId: "send-2", payload: "same-bytes")

        _ = scheduler.submit(first, maxConcurrentTransfers: 2)
        let result = scheduler.submit(second, maxConcurrentTransfers: 2)

        if case let .start(_, reservedTransferId?) = result {
            #expect(reservedTransferId == "send-2")
        } else {
            Issue.record("Expected an explicit-transferId send to run despite identical content")
        }
    }

    @Test
    func duplicateOfPendingContentIsDroppedAtSubmit() {
        // A duplicate must not queue behind a pending copy of the same
        // content and resend the whole file when the slot frees.
        var scheduler = BLEOutboundFragmentTransferScheduler()
        let active = makeRequest(type: MessageType.fileTransfer.rawValue, transferId: "active", payload: "file-a")
        let queuedContent = makeRequest(type: MessageType.fileTransfer.rawValue, transferId: "waiting", payload: "file-b")
        let queuedDuplicate = makeRequest(type: MessageType.fileTransfer.rawValue, transferId: nil, payload: "file-b")

        _ = scheduler.submit(active, maxConcurrentTransfers: 1)
        _ = scheduler.submit(queuedContent, maxConcurrentTransfers: 1)

        if case .droppedDuplicate = scheduler.submit(queuedDuplicate, maxConcurrentTransfers: 1) {
            // Dropped immediately: the pending "waiting" transfer covers it.
        } else {
            Issue.record("Expected the duplicate of pending content to be dropped at submit")
        }
        #expect(scheduler.pendingCount == 1)
    }

    @Test
    func resendAfterCompletionIsAllowed() {
        // Duplicate suppression only covers in-flight transfers: a peer that
        // requests the file after the stream completed must get a resend.
        var scheduler = BLEOutboundFragmentTransferScheduler()
        let original = makeRequest(type: MessageType.fileTransfer.rawValue, transferId: "app-id", payload: "voice-file")
        let resend = makeRequest(type: MessageType.fileTransfer.rawValue, transferId: nil, payload: "voice-file")

        _ = scheduler.submit(original, maxConcurrentTransfers: 1)
        let didActivate = scheduler.activateReservedTransfer(id: "app-id", totalFragments: 1, workItems: [])
        #expect(didActivate)
        #expect(scheduler.markFragmentSent(transferId: "app-id") == .complete(sentFragments: 1, totalFragments: 1))

        if case .start = scheduler.submit(resend, maxConcurrentTransfers: 1) {
            #expect(scheduler.activeCount == 1)
        } else {
            Issue.record("Expected a resend after completion to start")
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

    private func makeRequest(
        type: UInt8,
        transferId: String?,
        payload: String? = nil,
        directedPeer: PeerID? = nil,
        requireDirectPeerLink: Bool = false
    ) -> BLEOutboundFragmentTransferRequest {
        BLEOutboundFragmentTransferRequest(
            packet: BitchatPacket(
                type: type,
                senderID: Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77]),
                recipientID: nil,
                timestamp: 0x0102030405,
                payload: Data((payload ?? transferId ?? "payload").utf8),
                signature: nil,
                ttl: 3
            ),
            pad: false,
            maxChunk: nil,
            directedPeer: directedPeer,
            transferId: transferId,
            requireDirectPeerLink: requireDirectPeerLink
        )
    }
}
