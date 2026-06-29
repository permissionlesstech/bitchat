//
// String+Nickname.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

extension String {
    /// Splits a nickname into base and `#abcd` suffix when present.
    ///
    /// Mention `@` characters are removed before parsing.
    ///
    /// Examples:
    /// - `"alice#1a2b"` returns `("alice", "#1a2b")`
    /// - `"@charlie#ffff"` returns `("charlie", "#ffff")`
    /// - `"bob"` returns `("bob", "")`
    /// - `"test##1234"` returns `("test##1234", "")`
    func splitSuffix() -> (String, String) {
        let name = self.replacingOccurrences(of: "@", with: "")
        guard name.count >= 5 else { return (name, "") }
        let suffix = String(name.suffix(5))
        let base = String(name.dropLast(5))
        let hasValidSuffix = suffix.first == "#" && suffix.dropFirst().allSatisfy { character in
            guard character.unicodeScalars.count == 1,
                  let scalar = character.unicodeScalars.first else {
                return false
            }
            return (48...57).contains(scalar.value)
                || (65...70).contains(scalar.value)
                || (97...102).contains(scalar.value)
        }
        if hasValidSuffix, !base.contains("#") {
            return (base, suffix)
        }
        return (name, "")
    }
}
