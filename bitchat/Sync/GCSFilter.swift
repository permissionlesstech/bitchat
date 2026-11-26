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
    // `includedCount` is how many of the input `ids` (in input order) the
    // returned filter actually encodes. It can be below `ids.count` when the
    // Golomb-Rice encoding overflows the byte budget and the tail is trimmed.
    // Callers that derive a since-cursor need this: trimming drops from the
    // input tail, so the first `includedCount` inputs are exactly what the
    // filter covers.
    struct Params { let p: Int; let m: UInt32; let data: Data; let includedCount: Int }

    // Highest Golomb-Rice parameter we accept from the wire. P maps to an FPR
    // of ~1/2^P; beyond 32 the remainder width exceeds any practical filter
    // and shifts in decode would silently overflow to garbage values.
    static let maxP = 32

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
            return Params(p: p, m: 1, data: Data(), includedCount: 0)
        }

        let cap = estimateMaxElements(sizeBytes: maxBytes, p: p)
        let initialCount = min(ids.count, cap)
        var hashes = [UInt64]()
        hashes.reserveCapacity(initialCount)
        for i in 0..<initialCount {
            hashes.append(hash64(ids[i]))
        }
        return buildFilter(precomputedHashes: hashes, maxBytes: maxBytes, targetFpr: targetFpr)
    }

    static func buildFilter(precomputedHashes hashes: [UInt64], maxBytes: Int, targetFpr: Double) -> Params {
        let p = deriveP(targetFpr: targetFpr)
        guard !hashes.isEmpty else {
            return Params(p: p, m: 1, data: Data(), includedCount: 0)
        }

        let cap = estimateMaxElements(sizeBytes: maxBytes, p: p)
        let initialCount = min(hashes.count, cap)
        // Modulus is fixed to the initial candidate count so `m` stays stable
        // as the tail is trimmed to fit the byte budget below.
        let range = max(1, hashRange(count: initialCount, p: p))
        let modulo = UInt64(range)

        // Pre-map the initial candidate prefix once so budget-trimming retries
        // never re-hash IDs. Input order is newest-first, so slicing the prefix
        // always retains a contiguous newest-prefix for an exact since-cursor.
        var allMapped = [UInt64]()
        allMapped.reserveCapacity(initialCount)
        for i in 0..<initialCount {
            allMapped.append(mapHash(hashes[i], modulo: modulo))
        }

        var scratch = [UInt64]()
        scratch.reserveCapacity(initialCount)

        func encodeFirst(_ count: Int) -> Data {
            scratch.removeAll(keepingCapacity: true)
            scratch.append(contentsOf: allMapped[0..<count])
            scratch.sort()
            let uniqueCount = normalizeMappedValuesInPlace(&scratch, modulo: modulo)
            guard uniqueCount > 0 else { return Data() }
            return encode(sorted: scratch[0..<uniqueCount], p: p, estimatedBytes: maxBytes)
        }

        var count = initialCount
        var encoded = encodeFirst(count)
        while encoded.count > maxBytes && count > 1 {
            count = max(1, (count * 9) / 10)
            encoded = encodeFirst(count)
        }
        // A single element that still overflows can't be represented.
        if encoded.count > maxBytes {
            return Params(p: p, m: range, data: Data(), includedCount: 0)
        }

        return Params(p: p, m: range, data: encoded, includedCount: encoded.isEmpty ? 0 : count)
    }

    static func decodeToSortedSet(p: Int, m: UInt32, data: Data) -> [UInt64] {
        // Reject out-of-range parameters rather than decoding garbage: callers
        // treat the result as "peer has nothing" and fall back to sending data.
        guard p >= 1, p <= maxP, m > 1, !data.isEmpty else { return [] }
        return data.withUnsafeBytes { raw -> [UInt64] in
            let bytes = raw.bindMemory(to: UInt8.self)
            var values: [UInt64] = []
            values.reserveCapacity(max(1, (bytes.count * 8) / max(3, p + 2)))
            var reader = BitReader(bytes)
            var acc: UInt64 = 0
            let limit = UInt64(m)
            let pShift = UInt64(p)
            while true {
                guard let q = reader.readUnary() else { break }
                guard let r = reader.readBits(count: p) else { break }
                let x = (UInt64(q) << pShift) + r + 1
                acc &+= x
                if acc >= limit { break }
                values.append(acc)
            }
            return values
        }
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
        bucket(forHash64: hash64(id), modulus: m)
    }

    static func bucket(forHash64 h: UInt64, modulus m: UInt32) -> UInt64 {
        let modulo = UInt64(max(1, m))
        guard modulo > 1 else { return 0 }
        return mapHash(h, modulo: modulo)
    }

    static func hash64(_ id16: Data) -> UInt64 {
        let digest = SHA256.hash(data: id16)
        return digest.withUnsafeBytes { raw -> UInt64 in
            let bytes = raw.bindMemory(to: UInt8.self)
            let hi = (UInt64(bytes[0]) << 56) | (UInt64(bytes[1]) << 48) | (UInt64(bytes[2]) << 40) | (UInt64(bytes[3]) << 32)
            let lo = (UInt64(bytes[4]) << 24) | (UInt64(bytes[5]) << 16) | (UInt64(bytes[6]) << 8) | UInt64(bytes[7])
            return (hi | lo) & 0x7fff_ffff_ffff_ffff
        }
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
        return value == 0 ? 1 : value
    }

    private static func normalizeMappedValuesInPlace(_ values: inout [UInt64], modulo: UInt64) -> Int {
        guard modulo > 1, !values.isEmpty else { return 0 }
        let maxVal = modulo - 1
        var writeIdx = 0
        var last: UInt64 = 0
        for readIdx in 0..<values.count {
            let normalized = min(values[readIdx], maxVal)
            if normalized > last {
                values[writeIdx] = normalized
                writeIdx += 1
                last = normalized
            }
        }
        return writeIdx
    }

    private static func encode(sorted: ArraySlice<UInt64>, p: Int, estimatedBytes: Int) -> Data {
        var writer = BitWriter(capacity: estimatedBytes + 16)
        var prev: UInt64 = 0
        let pShift = UInt64(p)
        let mask: UInt64 = (p >= 64) ? ~0 : ((UInt64(1) << pShift) - 1)
        let canCombineZeroAndRem = p <= 32
        for v in sorted {
            let delta = v &- prev
            prev = v
            let xMinus1 = delta &- 1
            let q = xMinus1 >> pShift
            let r = xMinus1 & mask
            if q > 0 { writer.writeOnes(count: Int(q)) }
            if canCombineZeroAndRem {
                // Bit `p` of `r` is 0, so writing `p + 1` bits emits the unary
                // terminating 0 followed immediately by the `p`-bit remainder.
                writer.writeBits(value: r, count: p + 1)
            } else {
                writer.writeBit(0)
                writer.writeBits(value: r, count: p)
            }
        }
        return writer.toData()
    }

    // MARK: - Bit helpers (MSB-first)
    private struct BitWriter {
        private var bytes: [UInt8]
        private var acc: UInt64 = 0
        private var nbits: Int = 0

        init(capacity: Int) {
            bytes = []
            bytes.reserveCapacity(capacity)
        }

        @inline(__always)
        private mutating func flushBytes() {
            while nbits >= 8 {
                nbits -= 8
                bytes.append(UInt8((acc >> UInt64(nbits)) & 0xFF))
            }
        }

        @inline(__always)
        mutating func writeBit(_ bit: Int) {
            acc = (acc << 1) | UInt64(bit & 1)
            nbits += 1
            if nbits >= 8 { flushBytes() }
        }

        @inline(__always)
        mutating func writeOnes(count: Int) {
            var remaining = count
            while remaining > 0 {
                let chunk = min(remaining, 32)
                let ones = (UInt64(1) << UInt64(chunk)) &- 1
                acc = (acc << UInt64(chunk)) | ones
                nbits += chunk
                flushBytes()
                remaining -= chunk
            }
        }

        @inline(__always)
        mutating func writeBits(value: UInt64, count: Int) {
            guard count > 0 else { return }
            if count <= 33 {
                let mask = (UInt64(1) << UInt64(count)) &- 1
                acc = (acc << UInt64(count)) | (value & mask)
                nbits += count
                flushBytes()
            } else {
                for i in stride(from: count - 1, through: 0, by: -1) {
                    writeBit(Int((value >> UInt64(i)) & 1))
                }
            }
        }

        mutating func toData() -> Data {
            if nbits > 0 {
                let rem = UInt8((acc << UInt64(8 - nbits)) & 0xFF)
                bytes.append(rem)
                nbits = 0
                acc = 0
            }
            return Data(bytes)
        }
    }

    private struct BitReader {
        private let bytes: UnsafeBufferPointer<UInt8>
        private var byteIndex: Int = 0
        private var acc: UInt64 = 0
        private var bitsAvailable: Int = 0

        init(_ bytes: UnsafeBufferPointer<UInt8>) {
            self.bytes = bytes
            refill()
        }

        @inline(__always)
        private mutating func refill() {
            let count = bytes.count
            while bitsAvailable <= 56 && byteIndex < count {
                acc = (acc << 8) | UInt64(bytes[byteIndex])
                byteIndex += 1
                bitsAvailable += 8
            }
        }

        @inline(__always)
        mutating func readUnary() -> Int? {
            var q = 0
            while true {
                if bitsAvailable == 0 {
                    refill()
                    if bitsAvailable == 0 { return nil }
                }
                let aligned = acc << UInt64(64 - bitsAvailable)
                let ones = (~aligned).leadingZeroBitCount
                if ones < bitsAvailable {
                    bitsAvailable -= (ones + 1)
                    return q + ones
                }
                q += bitsAvailable
                bitsAvailable = 0
            }
        }

        @inline(__always)
        mutating func readBits(count: Int) -> UInt64? {
            if bitsAvailable < count {
                refill()
                guard bitsAvailable >= count else { return nil }
            }
            bitsAvailable -= count
            let mask = (UInt64(1) << UInt64(count)) &- 1
            return (acc >> UInt64(bitsAvailable)) & mask
        }
    }
}
