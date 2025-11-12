//
// String+Nickname.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

extension String {
    /// Splits a nickname into base and a '#abcd' suffix if present.
    ///
    /// In bitchat, peer nicknames can have a 4-character hexadecimal suffix (e.g., "alice#1a2b")
    /// to differentiate users with the same base nickname. This function parses such nicknames.
    ///
    /// The function:
    /// - Removes any leading '@' character (for mentions)
    /// - Checks if the string ends with a valid '#' followed by 4 hex digits
    /// - Returns a tuple of (base, suffix) where suffix includes the '#' character
    ///
    /// Examples:
    /// ```
    /// "alice#1a2b".splitSuffix() // returns ("alice", "#1a2b")
    /// "bob".splitSuffix()        // returns ("bob", "")
    /// "@charlie#ffff".splitSuffix() // returns ("charlie", "#ffff")
    /// "eve#xyz".splitSuffix()    // returns ("eve#xyz", "") - invalid hex
    /// ```
    ///
    /// - Returns: A tuple containing the base nickname and the suffix (or empty string if no valid suffix)
    func splitSuffix() -> (String, String) {
        let name = self.replacingOccurrences(of: "@", with: "")
        guard name.count >= 5 else { return (name, "") }
        let suffix = String(name.suffix(5))
        if suffix.first == "#", suffix.dropFirst().allSatisfy({ c in
            ("0"..."9").contains(String(c)) || ("a"..."f").contains(String(c)) || ("A"..."F").contains(String(c))
        }) {
            let base = String(name.dropLast(5))
            return (base, suffix)
        }
        return (name, "")
    }
}
