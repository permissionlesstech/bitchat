import Foundation

/// Bech32 encoding for Nostr (minimal implementation)
enum Bech32 {
    private static let charsetBytes: [UInt8] = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l".utf8)
    private static let decodeTable: [Int8] = {
        var table = [Int8](repeating: -1, count: 128)
        for (i, byte) in charsetBytes.enumerated() {
            table[Int(byte)] = Int8(i)
        }
        return table
    }()

    static func encode(hrp: String, data: Data) throws -> String {
        let values = convertBits(from: 8, to: 5, pad: true, data: data)
        let hrpUTF8 = Array(hrp.utf8)
        let checksum = createChecksum(hrpUTF8: hrpUTF8, values: values)
        let totalLen = hrpUTF8.count + 1 + values.count + 6

        return String(unsafeUninitializedCapacity: totalLen) { buffer in
            var idx = 0
            for b in hrpUTF8 {
                buffer[idx] = b
                idx += 1
            }
            buffer[idx] = UInt8(ascii: "1")
            idx += 1
            for v in values {
                buffer[idx] = charsetBytes[Int(v)]
                idx += 1
            }
            for c in checksum {
                buffer[idx] = charsetBytes[Int(c)]
                idx += 1
            }
            return idx
        }
    }

    static func decode(_ bech32String: String) throws -> (hrp: String, data: Data) {
        let utf8 = Array(bech32String.utf8)
        // Find the last occurrence of '1'
        guard let sepIdx = utf8.lastIndex(of: UInt8(ascii: "1")) else {
            throw Bech32Error.invalidFormat
        }

        // Validate HRP contains only ASCII characters
        for i in 0..<sepIdx {
            guard utf8[i] < 128 else {
                throw Bech32Error.invalidCharacter
            }
        }

        let dataStart = sepIdx + 1
        let dataCount = utf8.count - dataStart
        guard dataCount >= 6 else {
            // Still validate characters before checksum check to preserve error semantics
            for i in dataStart..<utf8.count {
                let b = utf8[i]
                guard b < 128, decodeTable[Int(b)] >= 0 else {
                    throw Bech32Error.invalidCharacter
                }
            }
            throw Bech32Error.invalidChecksum
        }

        var values = [UInt8]()
        values.reserveCapacity(dataCount)
        for i in dataStart..<utf8.count {
            let b = utf8[i]
            guard b < 128 else {
                throw Bech32Error.invalidCharacter
            }
            let val = decodeTable[Int(b)]
            guard val >= 0 else {
                throw Bech32Error.invalidCharacter
            }
            values.append(UInt8(val))
        }

        // Verify checksum directly via polymod without allocating intermediate arrays
        let hrpSlice = utf8[0..<sepIdx]
        guard verifyChecksum(hrpUTF8: hrpSlice, values: values) else {
            throw Bech32Error.invalidChecksum
        }

        let payloadCount = values.count - 6
        let bytes = convertBits(from: 5, to: 8, pad: false, data: values[0..<payloadCount])
        guard let hrp = String(bytes: hrpSlice, encoding: .ascii) else {
            throw Bech32Error.invalidCharacter
        }
        return (hrp: hrp, data: Data(bytes))
    }

    enum Bech32Error: Error {
        case invalidFormat
        case invalidCharacter
        case invalidChecksum
    }

    private static func convertBits<C: Collection>(from: Int, to: Int, pad: Bool, data: C) -> [UInt8] where C.Element == UInt8 {
        var acc = 0
        var bits = 0
        var result = [UInt8]()
        result.reserveCapacity((data.count * from + to - 1) / to)
        let maxv = (1 << to) - 1

        for value in data {
            acc = (acc << from) | Int(value)
            bits += from

            while bits >= to {
                bits -= to
                result.append(UInt8((acc >> bits) & maxv))
            }
        }

        if pad && bits > 0 {
            result.append(UInt8((acc << (to - bits)) & maxv))
        }

        return result
    }

    @inline(__always)
    private static func polymodStep(_ chk: inout Int, _ value: UInt8) {
        let b = chk >> 25
        chk = ((chk & 0x1ffffff) << 5) ^ Int(value)
        if (b & 1) != 0 { chk ^= 0x3b6a57b2 }
        if (b & 2) != 0 { chk ^= 0x26508e6d }
        if (b & 4) != 0 { chk ^= 0x1ea119fa }
        if (b & 8) != 0 { chk ^= 0x3d4233dd }
        if (b & 16) != 0 { chk ^= 0x2a1462b3 }
    }

    private static func hrpPolymod<C: Collection>(_ hrpUTF8: C) -> Int where C.Element == UInt8 {
        var chk = 1
        // Preserve legacy behavior: if HRP contains non-ASCII, hrpExpand returned []
        for b in hrpUTF8 where b >= 128 {
            return chk
        }
        for b in hrpUTF8 {
            polymodStep(&chk, b >> 5)
        }
        polymodStep(&chk, 0)
        for b in hrpUTF8 {
            polymodStep(&chk, b & 31)
        }
        return chk
    }

    private static func createChecksum<C: Collection>(hrpUTF8: C, values: [UInt8]) -> [UInt8] where C.Element == UInt8 {
        var chk = hrpPolymod(hrpUTF8)
        for v in values {
            polymodStep(&chk, v)
        }
        for _ in 0..<6 {
            polymodStep(&chk, 0)
        }
        let polymod = chk ^ 1
        return [
            UInt8((polymod >> 25) & 31),
            UInt8((polymod >> 20) & 31),
            UInt8((polymod >> 15) & 31),
            UInt8((polymod >> 10) & 31),
            UInt8((polymod >> 5) & 31),
            UInt8(polymod & 31)
        ]
    }

    private static func verifyChecksum<C: Collection>(hrpUTF8: C, values: [UInt8]) -> Bool where C.Element == UInt8 {
        var chk = hrpPolymod(hrpUTF8)
        for v in values {
            polymodStep(&chk, v)
        }
        return chk == 1
    }
}
