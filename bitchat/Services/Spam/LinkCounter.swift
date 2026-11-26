//
// LinkCounter.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Counts links: scheme URLs, `www.` hosts and bare domains such as
/// `example.com/path`. Email addresses and abbreviations like `e.g.` don't
/// count. Same pattern as Android, so both apps rate-limit the same messages.
enum LinkCounter {
    private static let link: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(?<![\w@.\-])(?:https?://[^\s<>]+|www\.[^\s<>]+|[a-z0-9\-]+(?:\.[a-z0-9\-]+)*\.[a-z]{2,}(?:/[^\s<>]*)?)(?![\w@])"#,
        options: [.caseInsensitive]
    )

    static func count(_ text: String) -> Int {
        guard let link else { return 0 }
        return link.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }
}
