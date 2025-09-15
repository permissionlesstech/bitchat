import Foundation
import CryptoKit

// Golomb-Coded Set (GCS) filter utilities for sync.
// Hashing:
//  - Packet ID is 16 bytes (see PacketIdUtil). For GCS mapping, use h64 = first 8 bytes of SHA-256 over the 16-byte ID.
//  - Map to [0, M) via (h64 % M).
// Encoding (v1):
//  - Sort mapped values ascending; encode deltas (first is v0, then vi - v{i-1}) as positive integers x >= 1.
//  - Golomb-Rice with parameter P: q = (x - 1) >> P encoded as unary (q ones then a zero), then write P-bit remainder r = (x - 1) & ((1<<P)-1).
//  - Bitstream is MSB-first within each byte.
enum GCSFilter {
    struct Params { let p: Int; let m: UInt32; let data: Data }

    // Derive P from FPR (~ 1 / 2^P)
    static func deriveP(targetFpr: Double) -> Int {
        let f = max(0.000001, min(0.25, targetFpr))
        // ceil(log2(1/f))
        let p = Int(ceil(log2(1.0 / f)))
        return max(1, p)
    }

    // Estimate max elements that fit in size bytes: bits per element ~= P + 2 (approx)
    static func estimateMaxElements(sizeBytes: Int, p: Int) -> Int {
        let bits = max(8, sizeBytes * 8)
        let per = max(3, p + 2)
        return max(1, bits / per)
    }

    static func buildFilter(ids: [Data], maxBytes: Int, targetFpr: Double) -> Params {
        let p = deriveP(targetFpr: targetFpr)
        let cap = estimateMaxElements(sizeBytes: maxBytes, p: p)
        let n = min(ids.count, cap)
        let selected = Array(ids.prefix(n))
        // Map to [0, M)
        let mInit = UInt32(n << p)
        var mapped = selected.map { id16 -> UInt64 in
            let h = h64(id16)
            return UInt64(h % UInt64(max(1, mInit)))
        }.sorted()
        var encoded = encode(sorted: mapped, p: p)
        var trimmedN = n
        // Trim if over budget
        while encoded.count > maxBytes && trimmedN > 0 {
            trimmedN = (trimmedN * 9) / 10 // drop ~10%
            mapped = Array(mapped.prefix(trimmedN))
            encoded = encode(sorted: mapped, p: p)
        }
        let finalM = UInt32(max(1, trimmedN << p))
        return Params(p: p, m: finalM, data: encoded)
    }

    static func decodeToSortedSet(p: Int, m: UInt32, data: Data) -> [UInt64] {
        var values: [UInt64] = []
        let reader = BitReader(data)
        var acc: UInt64 = 0
        while true {
            guard let q = reader.readUnary() else { break }
            guard let r = reader.readBits(count: p) else { break }
            let x = (UInt64(q) << UInt64(p)) + UInt64(r) + 1
            acc &+= x
            if acc >= UInt64(m) { break }
            values.append(acc)
        }
        return values
    }

    static func contains(sortedValues: [UInt64], candidate: UInt64) -> Bool {
        var lo = 0
        var hi = sortedValues.count - 1
        while lo <= hi {
            let mid = (lo + hi) >> 1
            let v = sortedValues[mid]
            if v == candidate { return true }
            if v < candidate { lo = mid + 1 } else { hi = mid - 1 }
        }
        return false
    }

    private static func h64(_ id16: Data) -> UInt64 {
        var hasher = SHA256()
        hasher.update(data: id16)
        let d = hasher.finalize()
        let db = Data(d)
        var x: UInt64 = 0
        let take = min(8, db.count)
        for i in 0..<take { x = (x << 8) | UInt64(db[i]) }
        return x & 0x7fff_ffff_ffff_ffff
    }

    private static func encode(sorted: [UInt64], p: Int) -> Data {
        let writer = BitWriter()
        var prev: UInt64 = 0
        let mask: UInt64 = (p >= 64) ? ~0 : ((1 << UInt64(p)) - 1)
        for v in sorted {
            let delta = v &- prev
            prev = v
            let x = delta
            let q = (x &- 1) >> UInt64(p)
            let r = (x &- 1) & mask
            // unary q ones then zero
            if q > 0 { writer.writeOnes(count: Int(q)) }
            writer.writeBit(0)
            writer.writeBits(value: r, count: p)
        }
        return writer.toData()
    }

    // MARK: - Bit helpers (MSB-first)
    private final class BitWriter {
        private var buf = Data()
        private var cur: UInt8 = 0
        private var nbits: Int = 0
        func writeBit(_ bit: Int) { // 0 or 1
            cur = UInt8((Int(cur) << 1) | (bit & 1))
            nbits += 1
            if nbits == 8 {
                buf.append(cur)
                cur = 0; nbits = 0
            }
        }
        func writeOnes(count: Int) {
            guard count > 0 else { return }
            for _ in 0..<count { writeBit(1) }
        }
        func writeBits(value: UInt64, count: Int) {
            guard count > 0 else { return }
            for i in stride(from: count - 1, through: 0, by: -1) {
                let bit = Int((value >> UInt64(i)) & 1)
                writeBit(bit)
            }
        }
        func toData() -> Data {
            if nbits > 0 {
                let rem = UInt8(Int(cur) << (8 - nbits))
                buf.append(rem)
                cur = 0; nbits = 0
            }
            return buf
        }
    }

    private final class BitReader {
        private let data: Data
        private var idx: Int = 0
        private var cur: UInt8 = 0
        private var left: Int = 0
        init(_ data: Data) {
            self.data = data
            if !data.isEmpty {
                cur = data[0]
                left = 8
            }
        }
        func readBit() -> Int? {
            if idx >= data.count { return nil }
            let bit = (Int(cur) >> 7) & 1
            cur = UInt8((Int(cur) << 1) & 0xFF)
            left -= 1
            if left == 0 {
                idx += 1
                if idx < data.count { cur = data[idx]; left = 8 }
            }
            return bit
        }
        func readUnary() -> Int? {
            var q = 0
            while true {
                guard let b = readBit() else { return nil }
                if b == 1 { q += 1 } else { break }
            }
            return q
        }
        func readBits(count: Int) -> UInt64? {
            var v: UInt64 = 0
            for _ in 0..<count {
                guard let b = readBit() else { return nil }
                v = (v << 1) | UInt64(b)
            }
            return v
        }
    }
}
