//
// String+DJB2.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

extension String {
    /// Computes the DJB2 hash of this string.
    ///
    /// DJB2 is a simple, fast non-cryptographic hash function created by Dan Bernstein.
    /// It uses the magic number 5381 as the initial seed and the formula: `hash = hash * 33 + byte`.
    ///
    /// In bitchat, this hash is used to:
    /// - Generate stable, deterministic peer color assignments from nicknames or public keys
    /// - Provide consistent hue values for UI elements that need reproducible colors
    ///
    /// - Note: This is NOT suitable for cryptographic purposes or security-sensitive operations.
    ///         For cryptographic hashing, use SHA-256 instead.
    ///
    /// - Returns: A 64-bit hash value that is deterministic for the same input string
    func djb2() -> UInt64 {
        var hash: UInt64 = 5381
        for b in utf8 { hash = ((hash << 5) &+ hash) &+ UInt64(b) }
        return hash
    }
}
