//
// ComposerAutocorrect.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Token-aware autocorrect policy for the message composer (#969).
///
/// Autocorrect helps with prose but fights `/commands`, `@mentions`, and
/// `#channels`. Disable it while the token under the cursor starts with one
/// of those sigils; leave it on otherwise. The composer TextField only exposes
/// the text (not a live selection), so callers pass the caret — typically the
/// end of the string, matching autocomplete.
enum ComposerAutocorrect {
    /// Sigils that mean "exact token, don't rewrite me".
    static let specialPrefixes: Set<Character> = ["/", "@", "#"]

    /// Whether `.autocorrectionDisabled` should be on for this caret position.
    static func shouldDisable(for text: String, cursorPosition: Int) -> Bool {
        let token = currentToken(in: text, cursorPosition: cursorPosition)
        guard let first = token.first else { return false }
        return specialPrefixes.contains(first)
    }

    /// The whitespace-delimited token containing `cursorPosition` (or ending
    /// at it when the caret sits on a boundary).
    static func currentToken(in text: String, cursorPosition: Int) -> String {
        guard !text.isEmpty else { return "" }
        let clamped = min(max(0, cursorPosition), text.count)
        let end = text.index(text.startIndex, offsetBy: clamped)
        let before = text[..<end]

        let tokenStart: String.Index
        if let ws = before.lastIndex(where: { $0.isWhitespace || $0.isNewline }) {
            tokenStart = before.index(after: ws)
        } else {
            tokenStart = text.startIndex
        }
        return String(before[tokenStart...])
    }
}
