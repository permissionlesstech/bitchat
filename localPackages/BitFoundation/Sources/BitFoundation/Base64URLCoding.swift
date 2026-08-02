//
// Base64URLCoding.swift
// BitFoundation
//
// Single implementation of base64url (RFC 4648 §5) used across the app —
// Nostr embeddings, Cashu tokens, and verification QR payloads all share
// these helpers so padding and alphabet handling cannot drift per call site.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

public enum Base64URLCoding {
    /// Encode data as base64url without padding.
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decode a base64url string, accepting both padded and unpadded forms
    /// (external producers, e.g. Cashu wallets, emit both).
    public static func decode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Normalize padding: strip any '=' then re-pad to a multiple of 4.
        base64 = base64.replacingOccurrences(of: "=", with: "")
        let remainder = base64.count % 4
        // No valid base64 payload has length ≡ 1 (mod 4).
        if remainder == 1 { return nil }
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }
}
