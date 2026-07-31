//
// SafeRegex.swift
// bitchat
//
// Non-trapping construction for the app's compiled-in regex patterns.
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import Foundation

enum SafeRegex {
    /// Compiles a bundled pattern. On failure it logs and returns a regex
    /// that can never match, so a bad pattern degrades that one feature
    /// instead of crashing at startup.
    static func compile(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            SecureLogger.error("Regex pattern failed to compile, matching disabled: \(pattern) (\(error))", category: .session)
            return neverMatching
        }
    }

    /// `(?!)` — an empty negative lookahead — always compiles and can never match.
    private static let neverMatching: NSRegularExpression = {
        if let regex = try? NSRegularExpression(pattern: "(?!)", options: []) {
            return regex
        }
        // Unreachable: "(?!)" is a valid ICU pattern. The inherited plain
        // initializer (empty pattern) is the least-bad non-trapping fallback
        // if ICU itself were ever broken.
        return NSRegularExpression()
    }()
}
