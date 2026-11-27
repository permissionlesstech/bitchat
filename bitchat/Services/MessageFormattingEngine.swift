//
// MessageFormattingEngine.swift
// bitchat
//
// Shared precompiled regex patterns for message content parsing.
// This is free and unencumbered software released into the public domain.
//

import Foundation

/// Shared precompiled regex patterns for message content parsing.
enum MessageFormattingEngine {
    /// Precompiled regex patterns for message content parsing
    enum Patterns {
        static let hashtag = SafeRegex.compile("#([a-zA-Z0-9_]+)")

        static let mention = SafeRegex.compile("@([\\p{L}0-9_]+(?:#[a-fA-F0-9]{4})?)")

        /// Trailing partial `@nickname` at the composer cursor — autocomplete only.
        static let mentionAutocomplete = SafeRegex.compile("@([\\p{L}0-9_]*)$")

        static let cashu = SafeRegex.compile("\\bcashu[AB][A-Za-z0-9._-]{40,}\\b")

        static let bolt11 = SafeRegex.compile("(?i)\\bln(bc|tb|bcrt)[0-9][a-z0-9]{50,}\\b")

        static let lnurl = SafeRegex.compile("(?i)\\blnurl1[a-z0-9]{20,}\\b")

        static let lightningScheme = SafeRegex.compile("(?i)\\blightning:[^\\s]+")

        static let linkDetector: NSDataDetector? = {
            try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        }()
    }
}
