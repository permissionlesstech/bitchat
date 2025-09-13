import Foundation

// Rotating Bloom filter for recently seen packet IDs (16-byte IDs)
final class SeenPacketsBloomFilter {
    struct Snapshot { let mBytes: Int; let k: Int; let bits: Data }

    private struct Filter { var mBits: Int; var k: Int; var bits: [UInt8]; var count: Int }

    private let maxBytes: Int
    private let targetFpr: Double
    private let seed: UInt64 = 0x27d4eb2f165667c5

    private let mBits: Int
    private let kOptimal: Int
    private let capacityOptimal: Int

    private var active: Filter
    private var standby: Filter
    private var usingStandby: Bool = false
    private let lock = NSLock()

    init(maxBytes: Int = 256, targetFpr: Double = 0.01) {
        self.maxBytes = max(1, maxBytes)
        self.targetFpr = targetFpr
        self.mBits = max(8, self.maxBytes * 8)
        let (k, n) = SeenPacketsBloomFilter.deriveParams(mBits: self.mBits, fpr: targetFpr)
        self.kOptimal = max(1, k)
        self.capacityOptimal = max(1, n)
        self.active = Filter(mBits: self.mBits, k: self.kOptimal, bits: [UInt8](repeating: 0, count: self.maxBytes), count: 0)
        self.standby = Filter(mBits: self.mBits, k: self.kOptimal, bits: [UInt8](repeating: 0, count: self.maxBytes), count: 0)
    }

    private static func deriveParams(mBits: Int, fpr: Double) -> (Int, Int) {
        // n ≈ -(m (ln 2)^2) / ln p ; k ≈ (m/n) ln 2
        let ln2 = log(2.0)
        let n = max(1, Int(Double(-mBits) * ln2 * ln2 / log(fpr)))
        let k = max(1, Int(ceil((Double(mBits) / Double(n)) * ln2)))
        return (k, n)
    }

    private func indicesFor(id: Data, mBits: Int, k: Int) -> [Int] {
        var h1: UInt64 = 1469598103934665603 // FNV-1a 64-bit offset
        var h2: UInt64 = seed
        for b in id { // treat as unsigned bytes
            h1 = (h1 ^ UInt64(b)) &* 1099511628211
            h2 = (h2 ^ UInt64(b)) &* 0x100000001B3
        }
        var result = [Int]()
        result.reserveCapacity(k)
        for i in 0..<k {
            let combined = h1 &+ (UInt64(i) &* h2)
            let idx = Int((combined & 0x7fff_ffff_ffff_ffff) % UInt64(mBits))
            result.append(idx)
        }
        return result
    }

    func add(_ id: Data) {
        lock.lock(); defer { lock.unlock() }
        let startStandbyAt = capacityOptimal / 2
        if !usingStandby && active.count >= startStandbyAt {
            standby = Filter(mBits: mBits, k: kOptimal, bits: [UInt8](repeating: 0, count: maxBytes), count: 0)
            usingStandby = true
        }
        insert(into: &active, id: id)
        if usingStandby { insert(into: &standby, id: id) }
        if active.count >= capacityOptimal {
            active = standby
            standby = Filter(mBits: mBits, k: kOptimal, bits: [UInt8](repeating: 0, count: maxBytes), count: 0)
            usingStandby = false
        }
    }

    private func insert(into filter: inout Filter, id: Data) {
        let idxs = indicesFor(id: id, mBits: filter.mBits, k: filter.k)
        for i in idxs {
            let byteIndex = i / 8
            let bitIndex = i % 8
            filter.bits[byteIndex] = UInt8(Int(filter.bits[byteIndex]) | (1 << (7 - bitIndex)))
        }
        filter.count &+= 1
    }

    func mightContain(_ id: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let a = active
        let idx = indicesFor(id: id, mBits: a.mBits, k: a.k)
        var inActive = true
        for i in idx {
            let byteIndex = i / 8
            let bitIndex = i % 8
            let set = ((Int(a.bits[byteIndex]) >> (7 - bitIndex)) & 1) == 1
            if !set { inActive = false; break }
        }
        if inActive { return true }
        if usingStandby {
            let s = standby
            let idx2 = indicesFor(id: id, mBits: s.mBits, k: s.k)
            for i in idx2 {
                let byteIndex = i / 8
                let bitIndex = i % 8
                let set = ((Int(s.bits[byteIndex]) >> (7 - bitIndex)) & 1) == 1
                if !set { return false }
            }
            return true
        }
        return false
    }

    func snapshotActive() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        let a = active
        return Snapshot(mBytes: a.bits.count, k: a.k, bits: Data(a.bits))
    }
}

