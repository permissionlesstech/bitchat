//
// Data+Hex.swift
// BitFoundation
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import struct Foundation.Data

/// Lowercase hex digits used by `hexEncodedString()`.
private let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)

/// Maps an ASCII byte to its hex nibble value, or nil for non-hex characters.
/// Accepts both lowercase and uppercase hex digits.
@inline(__always)
private func hexNibble(_ ascii: UInt8) -> UInt8? {
    switch ascii {
    case UInt8(ascii: "0")...UInt8(ascii: "9"):
        return ascii - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"):
        return ascii - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"):
        return ascii - UInt8(ascii: "A") + 10
    default:
        return nil
    }
}

public extension Data {
    /// Lowercase hex representation of the bytes.
    ///
    /// Lookup-table based: this sits on the hot BLE receive path (it is called
    /// several times per received packet via `PeerID(hexData:)`), where the
    /// previous per-byte `String(format: "%02x", _)` implementation spent most
    /// of its time re-parsing the format string through Foundation.
    func hexEncodedString() -> String {
        if isEmpty {
            return ""
        }
        var output = [UInt8](repeating: 0, count: count * 2)
        var i = 0
        for byte in self {
            output[i] = hexDigits[Int(byte >> 4)]
            output[i + 1] = hexDigits[Int(byte & 0x0F)]
            i += 2
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// Initialize Data from a hex string.
    /// - Parameter hexString: A hex string, optionally prefixed with "0x" or "0X".
    ///   Whitespace is trimmed. Must have even length after prefix removal.
    /// - Returns: nil if the string has odd length or contains invalid hex characters.
    init?(hexString: String) {
        var hex = hexString.trimmed

        // Remove optional 0x prefix
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") {
            hex = String(hex.dropFirst(2))
        }

        let ascii = Array(hex.utf8)

        // Reject odd-length strings
        guard ascii.count % 2 == 0 else {
            return nil
        }

        // Accept empty strings
        guard !ascii.isEmpty else {
            self = Data()
            return
        }

        var data = Data(capacity: ascii.count / 2)
        var index = 0
        while index < ascii.count {
            guard let high = hexNibble(ascii[index]),
                  let low = hexNibble(ascii[index + 1]) else {
                return nil
            }
            data.append((high << 4) | low)
            index += 2
        }

        self = data
    }
}
