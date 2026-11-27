//
// MessageFormattingEngine.swift
// bitchat
//
// Shared precompiled regex patterns and content hint scanner for message parsing.
// This is free and unencumbered software released into the public domain.
//

import Foundation

/// Shared precompiled regex patterns and hint scanner for message content parsing.
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

    struct ContentHints {
        var hasMentions = false
        var hasHashtags = false
        var hasURLs = false
        var hasLightning = false
        var hasCashu = false

        var any: Bool {
            hasMentions || hasHashtags || hasURLs || hasLightning || hasCashu
        }
    }

    /// Single-pass UTF-8 scanner that detects candidate rich tokens without
    /// allocating lowercased copies or bridging to NSString.
    static func scanContentHints(in content: String) -> ContentHints {
        if let hints = content.utf8.withContiguousStorageIfAvailable({ scanContentHintsBuffer($0) }) {
            return hints
        }
        return Array(content.utf8).withUnsafeBufferPointer { scanContentHintsBuffer($0) }
    }

    private static func scanContentHintsBuffer(_ utf8: UnsafeBufferPointer<UInt8>) -> ContentHints {
        var hints = ContentHints()
        let count = utf8.count
        var i = 0
        while i < count {
            let b = utf8[i]
            switch b {
            case UInt8(ascii: "@"):
                hints.hasMentions = true
            case UInt8(ascii: "#"):
                hints.hasHashtags = true
            case UInt8(ascii: ":"):
                if !hints.hasURLs && i + 2 < count
                    && utf8[i + 1] == UInt8(ascii: "/")
                    && utf8[i + 2] == UInt8(ascii: "/") {
                    hints.hasURLs = true
                }
            case UInt8(ascii: "w"):
                if !hints.hasURLs && i + 3 < count
                    && utf8[i + 1] == UInt8(ascii: "w")
                    && utf8[i + 2] == UInt8(ascii: "w")
                    && utf8[i + 3] == UInt8(ascii: ".") {
                    hints.hasURLs = true
                }
            case UInt8(ascii: "h"):
                if !hints.hasURLs && i + 3 < count
                    && utf8[i + 1] == UInt8(ascii: "t")
                    && utf8[i + 2] == UInt8(ascii: "t")
                    && utf8[i + 3] == UInt8(ascii: "p") {
                    hints.hasURLs = true
                }
            case UInt8(ascii: "l"), UInt8(ascii: "L"):
                if !hints.hasLightning {
                    if i + 1 < count && (utf8[i + 1] | 0x20) == UInt8(ascii: "n") {
                        hints.hasLightning = true
                    } else if i + 9 < count
                        && (utf8[i + 1] | 0x20) == UInt8(ascii: "i")
                        && (utf8[i + 2] | 0x20) == UInt8(ascii: "g")
                        && (utf8[i + 3] | 0x20) == UInt8(ascii: "h")
                        && (utf8[i + 4] | 0x20) == UInt8(ascii: "t")
                        && (utf8[i + 5] | 0x20) == UInt8(ascii: "n")
                        && (utf8[i + 6] | 0x20) == UInt8(ascii: "i")
                        && (utf8[i + 7] | 0x20) == UInt8(ascii: "n")
                        && (utf8[i + 8] | 0x20) == UInt8(ascii: "g")
                        && utf8[i + 9] == UInt8(ascii: ":") {
                        hints.hasLightning = true
                    }
                }
            case UInt8(ascii: "c"), UInt8(ascii: "C"):
                if !hints.hasCashu && i + 4 < count
                    && (utf8[i + 1] | 0x20) == UInt8(ascii: "a")
                    && (utf8[i + 2] | 0x20) == UInt8(ascii: "s")
                    && (utf8[i + 3] | 0x20) == UInt8(ascii: "h")
                    && (utf8[i + 4] | 0x20) == UInt8(ascii: "u") {
                    hints.hasCashu = true
                }
            default:
                break
            }
            i += 1
        }
        return hints
    }
}
