//
// Data+Hex.swift
// BitFoundation
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import struct Foundation.Data

public extension Data {
    func hexEncodedString() -> String {
        if self.isEmpty {
            return ""
        }
        return self.map { String(format: "%02x", $0) }.joined()
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

        // Reject odd-length strings
        guard hex.count % 2 == 0 else {
            return nil
        }

        // Reject empty strings
        guard !hex.isEmpty else {
            self = Data()
            return
        }

        let len = hex.count / 2
        var data = Data(capacity: len)
        var index = hex.startIndex

        for _ in 0..<len {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(String(hex[index..<nextIndex]), radix: 16) else {
                return nil
            }
            data.append(byte)
            index = nextIndex
        }

        self = data
    }
}
