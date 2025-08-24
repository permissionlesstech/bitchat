//
// MessageTextHelpers.swift
// Shared text parsing helpers for message rendering.
//

import Foundation

private enum RegexCache {
    static let cashu: NSRegularExpression = {
        try! NSRegularExpression(pattern: "\\bcashu[AB][A-Za-z0-9._-]{40,}\\b", options: [])
    }()
    static let lightningScheme: NSRegularExpression = {
        try! NSRegularExpression(pattern: "(?i)\\blightning:[^\\s]+", options: [])
    }()
    static let bolt11: NSRegularExpression = {
        try! NSRegularExpression(pattern: "(?i)\\bln(bc|tb|bcrt)[0-9][a-z0-9]{50,}\\b", options: [])
    }()
    static let lnurl: NSRegularExpression = {
        try! NSRegularExpression(pattern: "(?i)\\blnurl1[a-z0-9]{20,}\\b", options: [])
    }()
}

extension String {
    // Detect if there is an extremely long token (no whitespace/newlines) that could break layout
    func hasVeryLongToken(threshold: Int) -> Bool {
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

    // Extract up to `max` Cashu tokens (cashuA/cashuB). Allow dot '.' and shorter lengths.
    func extractCashuTokens(max: Int = 3) -> [String] {
        let regex = RegexCache.cashu
        let ns = self as NSString
        let range = NSRange(location: 0, length: ns.length)
        var found: [String] = []
        for m in regex.matches(in: self, options: [], range: range) {
            if m.numberOfRanges > 0 {
                let token = ns.substring(with: m.range(at: 0))
                found.append(token)
                if found.count >= max { break }
            }
        }
        return found
    }

    // Extract Lightning payloads (scheme, BOLT11, LNURL). Returned as lightning:<payload>
    func extractLightningLinks(max: Int = 3) -> [String] {
        var results: [String] = []
        let ns = self as NSString
        let full = NSRange(location: 0, length: ns.length)
        // lightning: scheme
        for m in RegexCache.lightningScheme.matches(in: self, options: [], range: full) {
            let s = ns.substring(with: m.range(at: 0))
            results.append(s)
            if results.count >= max { return results }
        }
        // BOLT11
        for m in RegexCache.bolt11.matches(in: self, options: [], range: full) {
            let s = ns.substring(with: m.range(at: 0))
            results.append("lightning:\(s)")
            if results.count >= max { return results }
        }
        // LNURL bech32
        for m in RegexCache.lnurl.matches(in: self, options: [], range: full) {
            let s = ns.substring(with: m.range(at: 0))
            results.append("lightning:\(s)")
            if results.count >= max { return results }
        }
        return results
    }
}
