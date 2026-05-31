import BitFoundation
import Foundation

struct BLEOutboundFragmentTransferRequest {
    let packet: BitchatPacket
    let pad: Bool
    let maxChunk: Int?
    let directedPeer: PeerID?
    let transferId: String?

    var resolvedTransferId: String? {
        guard packet.type == MessageType.fileTransfer.rawValue else { return nil }
        return transferId ?? packet.payload.sha256Hex()
    }
}

struct BLEOutboundFragmentTransferScheduler {
    enum QueuePosition {
        case front
        case back
    }

    enum SubmitResult {
        case start(request: BLEOutboundFragmentTransferRequest, reservedTransferId: String?)
        case queued(request: BLEOutboundFragmentTransferRequest, transferId: String?, position: QueuePosition)
    }

    enum CancelResult {
        case active(transferId: String, workItems: [DispatchWorkItem])
        case pending(transferId: String)
        case missing
    }

    enum SentResult: Equatable {
        case progress(sentFragments: Int, totalFragments: Int)
        case complete(sentFragments: Int, totalFragments: Int)
        case missing
    }

    private struct ActiveTransferState {
        let totalFragments: Int
        var sentFragments: Int
        var workItems: [DispatchWorkItem]
    }

    private var activeTransfers: [String: ActiveTransferState] = [:]
    private var pendingTransfers: [BLEOutboundFragmentTransferRequest] = []

    var activeCount: Int {
        activeTransfers.count
    }

    var pendingCount: Int {
        pendingTransfers.count
    }

    mutating func removeAll() -> [(id: String, workItems: [DispatchWorkItem])] {
        let active = activeTransfers.map { ($0.key, $0.value.workItems) }
        activeTransfers.removeAll()
        pendingTransfers.removeAll()
        return active
    }

    mutating func submit(
        _ request: BLEOutboundFragmentTransferRequest,
        maxConcurrentTransfers: Int
    ) -> SubmitResult {
        guard let transferId = request.resolvedTransferId else {
            return .start(request: request, reservedTransferId: nil)
        }

        guard activeTransfers.count < maxConcurrentTransfers else {
            pendingTransfers.append(request)
            return .queued(request: request, transferId: transferId, position: .back)
        }

        guard activeTransfers[transferId] == nil else {
            pendingTransfers.insert(request, at: 0)
            return .queued(request: request, transferId: transferId, position: .front)
        }

        activeTransfers[transferId] = ActiveTransferState(totalFragments: 0, sentFragments: 0, workItems: [])
        return .start(request: request, reservedTransferId: transferId)
    }

    mutating func activateReservedTransfer(
        id transferId: String,
        totalFragments: Int,
        workItems: [DispatchWorkItem]
    ) -> Bool {
        guard activeTransfers[transferId] != nil else { return false }
        activeTransfers[transferId] = ActiveTransferState(
            totalFragments: totalFragments,
            sentFragments: 0,
            workItems: workItems
        )
        return true
    }

    mutating func updateWorkItems(_ workItems: [DispatchWorkItem], for transferId: String) -> Bool {
        guard var state = activeTransfers[transferId] else { return false }
        state.workItems = workItems
        activeTransfers[transferId] = state
        return true
    }

    mutating func releaseReservation(_ transferId: String) -> [DispatchWorkItem]? {
        activeTransfers.removeValue(forKey: transferId)?.workItems
    }

    func isActive(_ transferId: String) -> Bool {
        activeTransfers[transferId] != nil
    }

    mutating func cancelTransfer(_ transferId: String) -> CancelResult {
        if let active = activeTransfers.removeValue(forKey: transferId) {
            return .active(transferId: transferId, workItems: active.workItems)
        }

        if let pendingIndex = pendingTransfers.firstIndex(where: { $0.resolvedTransferId == transferId || $0.transferId == transferId }) {
            pendingTransfers.remove(at: pendingIndex)
            return .pending(transferId: transferId)
        }

        return .missing
    }

    mutating func markFragmentSent(transferId: String) -> SentResult {
        guard var state = activeTransfers[transferId] else { return .missing }

        state.sentFragments = min(state.sentFragments + 1, state.totalFragments)
        let isComplete = state.sentFragments >= state.totalFragments

        if isComplete {
            activeTransfers.removeValue(forKey: transferId)
            return .complete(sentFragments: state.sentFragments, totalFragments: state.totalFragments)
        }

        activeTransfers[transferId] = state
        return .progress(sentFragments: state.sentFragments, totalFragments: state.totalFragments)
    }

    mutating func reservePendingStarts(maxConcurrentTransfers: Int) -> [SubmitResult] {
        var availableSlots = max(0, maxConcurrentTransfers - activeTransfers.count)
        guard availableSlots > 0, !pendingTransfers.isEmpty else { return [] }

        var results: [SubmitResult] = []
        var blockedFront: [BLEOutboundFragmentTransferRequest] = []

        while availableSlots > 0, !pendingTransfers.isEmpty {
            let request = pendingTransfers.removeFirst()
            availableSlots -= 1

            guard let transferId = request.resolvedTransferId else {
                results.append(.start(request: request, reservedTransferId: nil))
                continue
            }

            guard activeTransfers.count < maxConcurrentTransfers else {
                pendingTransfers.insert(request, at: 0)
                results.append(.queued(request: request, transferId: transferId, position: .front))
                break
            }

            guard activeTransfers[transferId] == nil else {
                blockedFront.append(request)
                results.append(.queued(request: request, transferId: transferId, position: .front))
                continue
            }

            activeTransfers[transferId] = ActiveTransferState(totalFragments: 0, sentFragments: 0, workItems: [])
            results.append(.start(request: request, reservedTransferId: transferId))
        }

        if !blockedFront.isEmpty {
            pendingTransfers.insert(contentsOf: blockedFront, at: 0)
        }

        return results
    }
}
