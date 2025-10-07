//
// Base64URL.swift
// bitchat
//
// Utilities for Base64URL encoding/decoding
// This is free and unencumbered software released into the public domain.
//

import Foundation

/// Base64URL encoding/decoding utilities
enum Base64URL {

    /// Decode a Base64URL-encoded string to Data
    /// - Parameter string: Base64URL-encoded string
    /// - Returns: Decoded data, or nil if invalid
    static func decode(_ s: String) -> Data? {
        var str = s.replacingOccurrences(of: "-", with: "+")
                    .replacingOccurrences(of: "_", with: "/")
        // Add padding if needed
        let rem = str.count % 4
        if rem > 0 { str.append(String(repeating: "=", count: 4 - rem)) }
        return Data(base64Encoded: str)
    }
}
