//
// Data+Hex.swift
// BitFoundation
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import struct Foundation.Data

public extension Data {
    /// Lowercase hex, two digits per byte, no separators.
    ///
    /// Table lookup instead of `String(format:)` per byte: Nostr public keys
    /// are re-encoded on hot paths (geochat roster rebuilds touch one per
    /// participant), and the formatted version cost ~14 µs per 32-byte key.
    func hexEncodedString() -> String {
        let byteCount = self.count
        if byteCount == 0 {
            return ""
        }
        return withUnsafeBytes { raw in
            guard let src = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return ""
            }
            return Self.hexEncodeBytes(src, count: byteCount)
        }
    }

    internal static func hexEncodeBytes(_ src: UnsafePointer<UInt8>, count byteCount: Int) -> String {
        String(unsafeUninitializedCapacity: byteCount &* 2) { buffer in
            guard let dst = buffer.baseAddress else { return 0 }
            var outIdx = 0
            var i = 0
            while i < byteCount {
                let byte = src[i]
                let hi = byte &>> 4
                let lo = byte & 0x0F
                dst[outIdx] = hi < 10 ? hi &+ 48 : hi &+ 87
                dst[outIdx &+ 1] = lo < 10 ? lo &+ 48 : lo &+ 87
                outIdx &+= 2
                i &+= 1
            }
            return outIdx
        }
    }

    /// ASCII byte -> nibble value (0...15), or 0xFF for non-hex characters.
    private static let hexNibbleTable: [UInt8] = {
        var table = [UInt8](repeating: 0xFF, count: 256)
        for c in UInt8(ascii: "0")...UInt8(ascii: "9") { table[Int(c)] = c - UInt8(ascii: "0") }
        for c in UInt8(ascii: "a")...UInt8(ascii: "f") { table[Int(c)] = c - UInt8(ascii: "a") + 10 }
        for c in UInt8(ascii: "A")...UInt8(ascii: "F") { table[Int(c)] = c - UInt8(ascii: "A") + 10 }
        return table
    }()

    /// Initialize Data from a hex string.
    /// - Parameter hexString: A hex string, optionally prefixed with "0x" or "0X".
    ///   Whitespace is trimmed. Must have even length after prefix removal.
    /// - Returns: nil if the string has odd length or contains invalid hex characters.
    init?(hexString: String) {
        let trimmed = hexString.trimmed
        guard let decoded = Self.decodeHexUTF8(trimmed) else {
            return nil
        }
        self = decoded
    }

    private static func decodeHexUTF8(_ string: String) -> Data? {
        var utf8 = string.utf8[...]
        if utf8.count >= 2 {
            let first = utf8[utf8.startIndex]
            let secondIdx = utf8.index(after: utf8.startIndex)
            let second = utf8[secondIdx]
            if first == UInt8(ascii: "0") && (second == UInt8(ascii: "x") || second == UInt8(ascii: "X")) {
                utf8 = utf8[utf8.index(after: secondIdx)...]
            }
        }

        let charCount = utf8.count
        guard charCount & 1 == 0 else { return nil }
        if charCount == 0 { return Data() }

        let byteCount = charCount >> 1
        var data = Data(count: byteCount)
        let ok = data.withUnsafeMutableBytes { outRaw -> Bool in
            guard let outBase = outRaw.bindMemory(to: UInt8.self).baseAddress else { return false }
            let table = Self.hexNibbleTable
            var idx = utf8.startIndex
            for i in 0..<byteCount {
                let hi = table[Int(utf8[idx])]
                idx = utf8.index(after: idx)
                let lo = table[Int(utf8[idx])]
                idx = utf8.index(after: idx)
                if (hi | lo) == 0xFF { return false }
                outBase[i] = (hi << 4) | lo
            }
            return true
        }
        return ok ? data : nil
    }
}
