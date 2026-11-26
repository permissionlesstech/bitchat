import Foundation

struct BLEOutboundWritePriority: Comparable {
    let level: Int
    let suborder: Int

    static let high = BLEOutboundWritePriority(level: 0, suborder: 0)

    static func fragment(totalFragments: Int) -> BLEOutboundWritePriority {
        BLEOutboundWritePriority(level: 1, suborder: max(1, min(totalFragments, Int(UInt16.max))))
    }

    static let fileTransfer = BLEOutboundWritePriority(level: 2, suborder: Int.max - 1)
    static let low = BLEOutboundWritePriority(level: 2, suborder: Int.max)

    static func < (lhs: BLEOutboundWritePriority, rhs: BLEOutboundWritePriority) -> Bool {
        if lhs.level != rhs.level { return lhs.level < rhs.level }
        return lhs.suborder < rhs.suborder
    }
}

struct BLEPendingWrite {
    let priority: BLEOutboundWritePriority
    let data: Data
}

struct BLEOutboundWriteBuffer {
    enum EnqueueResult {
        case enqueued(trimmedBytes: Int, remainingBytes: Int)
        case oversized(bytes: Int)
    }

    private struct PeripheralWriteQueue {
        var items: [BLEPendingWrite] = []
        var totalBytes: Int = 0
    }

    private var queuesByPeripheralID: [String: PeripheralWriteQueue] = [:]

    var isEmpty: Bool {
        queuesByPeripheralID.isEmpty
    }

    var peripheralIDs: [String] {
        Array(queuesByPeripheralID.keys)
    }

    mutating func removeAll() {
        queuesByPeripheralID.removeAll()
    }

    mutating func enqueue(
        data: Data,
        for peripheralID: String,
        priority: BLEOutboundWritePriority,
        capBytes: Int
    ) -> EnqueueResult {
        enqueueReportingAcceptance(
            data: data,
            for: peripheralID,
            priority: priority,
            capBytes: capBytes
        ).result
    }

    /// Enqueues while also reporting whether the newly offered write survived
    /// priority trimming. `EnqueueResult.enqueued` alone cannot express that:
    /// a full queue may immediately trim the new lowest-priority item.
    mutating func enqueueReportingAcceptance(
        data: Data,
        for peripheralID: String,
        priority: BLEOutboundWritePriority,
        capBytes: Int
    ) -> (result: EnqueueResult, accepted: Bool) {
        guard data.count <= capBytes else {
            return (.oversized(bytes: data.count), false)
        }

        var entry = queuesByPeripheralID[peripheralID] ?? PeripheralWriteQueue()
        let item = BLEPendingWrite(priority: priority, data: data)
        let insertIndex = entry.items.firstIndex { item.priority < $0.priority } ?? entry.items.count
        entry.items.insert(item, at: insertIndex)
        entry.totalBytes += data.count

        var trimmedBytes = 0
        while entry.totalBytes > capBytes && !entry.items.isEmpty {
            let removed = entry.items.removeLast()
            trimmedBytes += removed.data.count
            entry.totalBytes -= removed.data.count
        }

        if entry.items.isEmpty {
            queuesByPeripheralID[peripheralID] = nil
        } else {
            queuesByPeripheralID[peripheralID] = entry
        }
        let accepted = insertIndex < entry.items.count
        return (.enqueued(trimmedBytes: trimmedBytes, remainingBytes: entry.totalBytes), accepted)
    }

    mutating func takeAll(for peripheralID: String) -> [BLEPendingWrite] {
        queuesByPeripheralID.removeValue(forKey: peripheralID)?.items ?? []
    }

    /// Drops link-specific ciphertext when that physical link is gone. Keeping
    /// the dictionary entry would let rotating peripheral UUIDs accumulate a
    /// fresh per-link byte cap indefinitely.
    mutating func discardAll(for peripheralID: String) {
        queuesByPeripheralID[peripheralID] = nil
    }

    mutating func prepend(_ items: [BLEPendingWrite], for peripheralID: String) {
        guard !items.isEmpty else { return }
        var entry = queuesByPeripheralID[peripheralID] ?? PeripheralWriteQueue()
        let addedBytes = items.reduce(0) { $0 + $1.data.count }
        entry.items.insert(contentsOf: items, at: 0)
        entry.totalBytes += addedBytes
        queuesByPeripheralID[peripheralID] = entry
    }
}
