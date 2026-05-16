import Foundation
import CryptoKit

// Golomb-Coded Set (GCS) filter utilities for sync.
// Hashing:
//  - Packet ID is 16 bytes (see PacketIdUtil). For GCS mapping, use h64 = first 8 bytes of SHA-256 over the 16-byte ID.
//  - Map to [1, M) by computing (h64 % M) and remapping 0 -> 1 to avoid zero-length deltas.
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
        guard !ids.isEmpty else {
            return Params(p: p, m: 1, data: Data())
        }

        let cap = estimateMaxElements(sizeBytes: maxBytes, p: p)
        let selected = Array(ids.prefix(cap))
        let range = max(1, hashRange(count: selected.count, p: p))
        let modulo = UInt64(range)

        var mapped = selected
            .map { h64($0) }
            .map { mapHash($0, modulo: modulo) }
            .sorted()
        mapped = normalizeMappedValues(mapped, modulo: modulo)

        if mapped.isEmpty {
            return Params(p: p, m: range, data: Data())
        }

        var encoded = encode(sorted: mapped, p: p)
        var trimmedCount = mapped.count

        while encoded.count > maxBytes && trimmedCount > 0 {
            if trimmedCount == 1 {
                mapped.removeAll()
                encoded = Data()
                break
            }
            trimmedCount = max(1, (trimmedCount * 9) / 10)
            mapped = Array(mapped.prefix(trimmedCount))
            encoded = encode(sorted: mapped, p: p)
        }

        return Params(p: p, m: range, data: encoded)
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

    static func bucket(for id: Data, modulus m: UInt32) -> UInt64 {
        let modulo = UInt64(max(1, m))
        guard modulo > 1 else { return 0 }
        return mapHash(h64(id), modulo: modulo)
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

    private static func hashRange(count: Int, p: Int) -> UInt32 {
        guard count > 0 else { return 1 }
        if p >= 64 { return UInt32.max }
        let multiplier = UInt64(1) << UInt64(p)
        let (product, overflow) = UInt64(count).multipliedReportingOverflow(by: multiplier)
        if overflow { return UInt32.max }
        if product == 0 { return 1 }
        return product > UInt64(UInt32.max) ? UInt32.max : UInt32(product)
    }

    private static func mapHash(_ hash: UInt64, modulo: UInt64) -> UInt64 {
        guard modulo > 1 else { return 0 }
        let value = hash % modulo
        if value == 0 { return 1 }
        return value
    }

    private static func normalizeMappedValues(_ values: [UInt64], modulo: UInt64) -> [UInt64] {
        guard modulo > 1 else { return [] }
        guard !values.isEmpty else { return [] }
        var result: [UInt64] = []
        result.reserveCapacity(values.count)
        var last: UInt64 = 0
        for value in values {
            let normalized = min(value, modulo - 1)
            if normalized > last {
                result.append(normalized)
                last = normalized
            }
        }
        return result
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
