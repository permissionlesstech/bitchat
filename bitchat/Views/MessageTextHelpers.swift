//
// MessageTextHelpers.swift
// Shared text parsing helpers for message rendering.
//

import BitFoundation
import Foundation

extension BitchatMessage {
    /// The row's payment chips and collapse decision, scanned on first use
    /// and cached on the message: a row re-renders far more often than its
    /// immutable `content` could change.
    var contentScan: ContentScan {
        if let cached = getCachedContentScan() {
            return cached
        }
        // Single-pass UTF-8 hint scan skips all four payment regexes on the
        // vast majority of plain chat lines.
        let hints = MessageFormattingEngine.scanContentHints(in: content)
        let scan = ContentScan(
            cashuLinks: hints.hasCashu ? content.extractCashuLinks() : [],
            lightningLinks: hints.hasLightning ? content.extractLightningLinks() : [],
            isLongForDisplay: content.isLongForDisplay()
        )
        setCachedContentScan(scan)
        return scan
    }
}

extension String {
    /// Zero-allocation check matching `!trimmed.isEmpty`: returns `true` on the
    /// first non-whitespace, non-newline character.
    var hasNonWhitespaceContent: Bool {
        contains { !$0.isWhitespace && !$0.isNewline }
    }

    // Detect if there is an extremely long token (no whitespace/newlines) that could break layout
    func hasVeryLongToken(threshold: Int) -> Bool {
        if utf8.count < threshold { return false }
        var current = 0
        for ch in self {
            if ch.isWhitespace || ch.isNewline {
                if current >= threshold { return true }
                current = 0
            } else {
                current += 1
                if current >= threshold { return true }
            }
        }
        return current >= threshold
    }

    /// True when the message should collapse behind Show more in the UI.
    /// Length alone decides this — embedding a Cashu-looking token must not
    /// disable the guard (remote DoS via unbounded layout).
    func isLongForDisplay(
        lengthThreshold: Int = TransportConfig.uiLongMessageLengthThreshold,
        tokenThreshold: Int = TransportConfig.uiVeryLongTokenThreshold
    ) -> Bool {
        if utf8.count < min(lengthThreshold, tokenThreshold) { return false }
        return count > lengthThreshold || hasVeryLongToken(threshold: tokenThreshold)
    }

    /// True when rich formatting (regex / link detectors) should be skipped.
    /// Cashu presence used to exempt oversized content from the plain path;
    /// that let untrusted input force expensive formatting work.
    func isOversizedForRichFormatting(
        lengthThreshold: Int = 4000,
        tokenThreshold: Int = 1024
    ) -> Bool {
        if utf8.count < min(lengthThreshold, tokenThreshold) { return false }
        return count > lengthThreshold || hasVeryLongToken(threshold: tokenThreshold)
    }

    // Extract up to `max` distinct Cashu tokens (cashuA/cashuB), as the bare
    // bearer strings. Allow dot '.' and shorter lengths. The `cashu:` URI
    // form matches too — the token embedded after the scheme is the match.
    func extractCashuLinks(max: Int = 3) -> [String] {
        guard utf8.count >= 46, MessageFormattingEngine.scanContentHints(in: self).hasCashu else {
            return []
        }
        let regex = MessageFormattingEngine.Patterns.cashu
        let ns = self as NSString
        let range = NSRange(location: 0, length: ns.length)
        var found: [String] = []
        for m in regex.matches(in: self, range: range) where m.numberOfRanges > 0 {
            let token = ns.substring(with: m.range(at: 0))
            // Dedup: repeated tokens are one bearer instrument (and duplicate
            // ForEach IDs) — one chip is enough.
            if !found.contains(token) {
                found.append(token)
                if found.count >= max { break }
            }
        }
        return found
    }

    // Extract Lightning payloads (scheme, BOLT11, LNURL). Returned as lightning:<payload>
    func extractLightningLinks(max: Int = 3) -> [String] {
        guard MessageFormattingEngine.scanContentHints(in: self).hasLightning else {
            return []
        }
        var results: [String] = []
        let ns = self as NSString
        let full = NSRange(location: 0, length: ns.length)
        // lightning: scheme
        for m in MessageFormattingEngine.Patterns.lightningScheme.matches(in: self, range: full) {
            let s = ns.substring(with: m.range(at: 0))
            results.append(s)
            if results.count >= max { return results }
        }
        // BOLT11
        for m in MessageFormattingEngine.Patterns.bolt11.matches(in: self, range: full) {
            let s = ns.substring(with: m.range(at: 0))
            results.append("lightning:\(s)")
            if results.count >= max { return results }
        }
        // LNURL bech32
        for m in MessageFormattingEngine.Patterns.lnurl.matches(in: self, range: full) {
            let s = ns.substring(with: m.range(at: 0))
            results.append("lightning:\(s)")
            if results.count >= max { return results }
        }
        return results
    }
}
