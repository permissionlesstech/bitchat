//
// String+DJB2.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

extension String {
    /// Returns a deterministic DJB2 hash for this string.
    ///
    /// DJB2 is a non-cryptographic hash used for stable peer colors and
    /// other UI-related deterministic values. Do not use it for cryptographic
    /// or security-sensitive purposes.
    func djb2() -> UInt64 {
        var hash: UInt64 = 5381
        for b in utf8 { hash = ((hash << 5) &+ hash) &+ UInt64(b) }
        return hash
    }
}
