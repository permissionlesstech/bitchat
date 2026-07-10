import BitFoundation
import Foundation

struct BLEOutboundFragmentTransferRequest {
    let packet: BitchatPacket
    let pad: Bool
    let maxChunk: Int?
    let directedPeer: PeerID?
    let transferId: String?
    let requireDirectPeerLink: Bool
    let requireNoiseAuthenticatedPeerLink: Bool

    init(
        packet: BitchatPacket,
        pad: Bool,
        maxChunk: Int?,
        directedPeer: PeerID?,
        transferId: String?,
        requireDirectPeerLink: Bool = false,
        requireNoiseAuthenticatedPeerLink: Bool = false
    ) {
        self.packet = packet
        self.pad = pad
        self.maxChunk = maxChunk
        self.directedPeer = directedPeer
        self.transferId = transferId
        self.requireDirectPeerLink = requireDirectPeerLink
        self.requireNoiseAuthenticatedPeerLink = requireNoiseAuthenticatedPeerLink
    }

    var resolvedTransferId: String? {
        guard packet.type == MessageType.fileTransfer.rawValue else { return nil }
        return transferId ?? packet.payload.sha256Hex()
    }

    /// Content identity independent of the caller-chosen transfer ID: the
    /// same file resent through another path (gossip-sync replay, retry)
    /// arrives with a different explicit transferId but identical payload.
    var contentKey: String? {
        guard packet.type == MessageType.fileTransfer.rawValue else { return nil }
        return packet.payload.sha256Hex()
    }
}

/// Transactional admission for strict fragment trains. Durable callers may
/// commit only when every fragment was accepted; the first rejection stops
/// the train and reports failure so the original remains retryable.
enum BLEStrictFragmentAdmission {
    static func admitAll<Fragment>(
        _ fragments: [Fragment],
        accepting: (Fragment) -> Bool
    ) -> Bool {
        for fragment in fragments where !accepting(fragment) {
            return false
        }
        return true
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
        /// Strict direct-link requests are transactional: returning false to
        /// their durable owner must mean no process-local copy remains that
        /// can transmit later. They are therefore start-or-reject, never
        /// admitted to `pendingTransfers`.
        case rejectedStrict(request: BLEOutboundFragmentTransferRequest, transferId: String?)
        /// The same file is already being (or waiting to be) fragmented out
        /// to an audience covering this request; sending it again would just
        /// double the airtime (field-verified: one 41KB voice file went out
        /// as two complete fragment streams).
        case droppedDuplicate(request: BLEOutboundFragmentTransferRequest, activeTransferId: String?)
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
        var totalFragments: Int
        var sentFragments: Int
        var workItems: [DispatchWorkItem]
        var contentKey: String?
        var directedPeer: PeerID?
    }

    private var activeTransfers: [String: ActiveTransferState] = [:]
    private var pendingTransfers: [BLEOutboundFragmentTransferRequest] = []

    /// A transfer of the same content whose audience covers `directedPeer`:
    /// a broadcast covers every peer; a directed transfer covers only its
    /// recipient. A directed resend to a peer NOT covered by what's in
    /// flight (different recipient of a private file) is never a duplicate.
    private func coveringDuplicate(contentKey: String, directedPeer: PeerID?) -> String? {
        for (transferId, state) in activeTransfers where state.contentKey == contentKey {
            if state.directedPeer == nil || state.directedPeer == directedPeer {
                return transferId
            }
        }
        for request in pendingTransfers where request.contentKey == contentKey {
            if request.directedPeer == nil || request.directedPeer == directedPeer {
                return request.resolvedTransferId
            }
        }
        return nil
    }

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

        // Only requests without an explicit transferId are dropped as
        // duplicates: those are resend paths (gossip-sync replay, directed
        // spool) with no UI waiting on them. An app-initiated send carries a
        // transferId whose progress events the UI tracks, so it always runs.
        if request.transferId == nil,
           let contentKey = request.contentKey,
           let coveringId = coveringDuplicate(contentKey: contentKey, directedPeer: request.directedPeer) {
            return .droppedDuplicate(request: request, activeTransferId: coveringId)
        }

        guard activeTransfers.count < maxConcurrentTransfers else {
            if request.requireDirectPeerLink {
                return .rejectedStrict(request: request, transferId: transferId)
            }
            pendingTransfers.append(request)
            return .queued(request: request, transferId: transferId, position: .back)
        }

        guard activeTransfers[transferId] == nil else {
            if request.requireDirectPeerLink {
                return .rejectedStrict(request: request, transferId: transferId)
            }
            pendingTransfers.insert(request, at: 0)
            return .queued(request: request, transferId: transferId, position: .front)
        }

        activeTransfers[transferId] = ActiveTransferState(
            totalFragments: 0,
            sentFragments: 0,
            workItems: [],
            contentKey: request.contentKey,
            directedPeer: request.directedPeer
        )
        return .start(request: request, reservedTransferId: transferId)
    }

    mutating func activateReservedTransfer(
        id transferId: String,
        totalFragments: Int,
        workItems: [DispatchWorkItem]
    ) -> Bool {
        guard var state = activeTransfers[transferId] else { return false }
        state.totalFragments = totalFragments
        state.sentFragments = 0
        state.workItems = workItems
        activeTransfers[transferId] = state
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

            guard let transferId = request.resolvedTransferId else {
                availableSlots -= 1
                results.append(.start(request: request, reservedTransferId: nil))
                continue
            }

            // A queued duplicate of content that started while it waited
            // must not resend the whole file once the slot frees up (same
            // explicit-transferId exemption as submit).
            if request.transferId == nil,
               let contentKey = request.contentKey,
               let coveringId = coveringDuplicate(contentKey: contentKey, directedPeer: request.directedPeer) {
                results.append(.droppedDuplicate(request: request, activeTransferId: coveringId))
                continue
            }

            availableSlots -= 1

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

            activeTransfers[transferId] = ActiveTransferState(
                totalFragments: 0,
                sentFragments: 0,
                workItems: [],
                contentKey: request.contentKey,
                directedPeer: request.directedPeer
            )
            results.append(.start(request: request, reservedTransferId: transferId))
        }

        if !blockedFront.isEmpty {
            pendingTransfers.insert(contentsOf: blockedFront, at: 0)
        }

        return results
    }
}
