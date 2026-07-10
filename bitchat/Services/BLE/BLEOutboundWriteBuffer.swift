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

    private var writesByPeripheralID: [String: [BLEPendingWrite]] = [:]

    var peripheralIDs: [String] {
        Array(writesByPeripheralID.keys)
    }

    mutating func removeAll() {
        writesByPeripheralID.removeAll()
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

        var queue = writesByPeripheralID[peripheralID] ?? []
        let item = BLEPendingWrite(priority: priority, data: data)
        let insertIndex = queue.firstIndex { item.priority < $0.priority } ?? queue.count
        queue.insert(item, at: insertIndex)

        var total = queue.reduce(0) { $0 + $1.data.count }
        var trimmedBytes = 0

        while total > capBytes && !queue.isEmpty {
            let removed = queue.removeLast()
            trimmedBytes += removed.data.count
            total -= removed.data.count
        }

        writesByPeripheralID[peripheralID] = queue.isEmpty ? nil : queue
        let accepted = insertIndex < queue.count
        return (.enqueued(trimmedBytes: trimmedBytes, remainingBytes: total), accepted)
    }

    mutating func takeAll(for peripheralID: String) -> [BLEPendingWrite] {
        let items = writesByPeripheralID[peripheralID] ?? []
        writesByPeripheralID[peripheralID] = nil
        return items
    }

    /// Drops link-specific ciphertext when that physical link is gone. Keeping
    /// the dictionary entry would let rotating peripheral UUIDs accumulate a
    /// fresh per-link byte cap indefinitely.
    mutating func discardAll(for peripheralID: String) {
        writesByPeripheralID[peripheralID] = nil
    }

    mutating func prepend(_ items: [BLEPendingWrite], for peripheralID: String) {
        guard !items.isEmpty else { return }
        var existing = writesByPeripheralID[peripheralID] ?? []
        existing.insert(contentsOf: items, at: 0)
        writesByPeripheralID[peripheralID] = existing
    }
}
