import Foundation

/// Source-level audit for `String(localized:)` usage.
///
/// `LocalizationCoverageTests` already checks that every key *already in* an
/// `.xcstrings` catalog has a string for every locale. That still leaves a gap:
/// a call site can ship with only `defaultValue:` and never appear in the
/// catalog at all — CI stays green, every non-English locale falls back to
/// English. This scanner closes that gap by walking production Swift and
/// collecting the literal keys those call sites pass.
///
/// Kept in the test target (not the app) so the audit has no shipping cost and
/// can use `FileManager` freely against the repo checkout.
enum LocalizationKeyScanner {
    /// One `String(localized: "key")` occurrence, with enough location info for
    /// a useful failure message when the catalog is missing the key.
    struct Reference: Hashable {
        /// Catalog key, e.g. `board.empty_title`.
        let key: String
        /// Path relative to the repo root, e.g. `bitchat/Views/Foo.swift`.
        let file: String
        /// 1-based line number in `file`.
        let line: Int
    }

    /// Roots we treat as production UI. Tests and scripts are intentionally
    /// excluded — a key that only exists in a unit test should not force a
    /// catalog entry.
    private static let productionRoots = [
        "bitchat",
        "bitchatShareExtension",
    ]

    /// Preview helpers are compile-only fixtures; scanning them would flag
    /// throwaway keys that never ship.
    private static let skippedPathFragments = [
        "/_PreviewHelpers/",
    ]

    /// Walks production Swift under `repoRoot` and returns every localized-key
    /// reference, sorted so failure output is stable across runs.
    static func scanProductionSources(repoRoot: URL) throws -> [Reference] {
        var refs: [Reference] = []
        for relativeRoot in productionRoots {
            let root = repoRoot.appendingPathComponent(relativeRoot)
            refs.append(contentsOf: try scanDirectory(root, repoRoot: repoRoot))
        }
        return refs.sorted { lhs, rhs in
            if lhs.key != rhs.key { return lhs.key < rhs.key }
            if lhs.file != rhs.file { return lhs.file < rhs.file }
            return lhs.line < rhs.line
        }
    }

    /// Recursively enumerates `.swift` files under `directory`.
    private static func scanDirectory(_ directory: URL, repoRoot: URL) throws -> [Reference] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var refs: [Reference] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "swift" else { continue }

            let relative = relativePath(for: fileURL, repoRoot: repoRoot)
            if shouldSkip(relativePath: relative) { continue }

            let lines = try String(contentsOf: fileURL, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
            for (index, lineSub) in lines.enumerated() {
                for key in keys(in: String(lineSub)) {
                    refs.append(Reference(key: key, file: relative, line: index + 1))
                }
            }
        }
        return refs
    }

    /// Path of `fileURL` relative to `repoRoot`, using `/` separators.
    private static func relativePath(for fileURL: URL, repoRoot: URL) -> String {
        fileURL.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
    }

    /// Returns true when `relativePath` lives under a skipped tree (previews).
    private static func shouldSkip(relativePath: String) -> Bool {
        skippedPathFragments.contains { relativePath.contains($0) }
    }

    /// Extracts string-literal keys from every `String(localized:` call on a
    /// single source line.
    ///
    /// Handles both shapes used in this repo:
    /// - `String(localized: "key", defaultValue: "…")`
    /// - `String(localized: "key", comment: "…")`
    ///
    /// Limitations (accepted for CI):
    /// - Keys must be string *literals* on the same line as `String(localized:`.
    ///   Interpolated / computed keys are invisible to this scanner.
    /// - Only the first `"…"` after `String(localized:` is treated as the key;
    ///   `defaultValue:` / `comment:` literals that follow are ignored because
    ///   the parser advances past the opening call site each match.
    static func keys(in line: String) -> [String] {
        guard line.contains("String(localized:") else { return [] }

        var keys: [String] = []
        var searchStart = line.startIndex

        while let callSite = line.range(of: "String(localized:", range: searchStart..<line.endIndex) {
            if let key = firstStringLiteral(after: callSite.upperBound, in: line) {
                keys.append(key)
            }
            // Advance past this call site so a line with two localized strings
            // (rare, but legal) still yields both keys.
            searchStart = callSite.upperBound
        }

        return keys
    }

    /// Reads the next `"…"` string literal starting at `start`, honoring
    /// backslash escapes. Returns nil when the next non-whitespace character
    /// is not an opening quote (e.g. a non-literal key expression).
    private static func firstStringLiteral(after start: String.Index, in line: String) -> String? {
        var index = start
        while index < line.endIndex, line[index].isWhitespace {
            index = line.index(after: index)
        }
        guard index < line.endIndex, line[index] == "\"" else { return nil }

        // Consume the opening quote, then read until the unescaped closer.
        index = line.index(after: index)
        var literal = ""
        var escaped = false
        while index < line.endIndex {
            let ch = line[index]
            if escaped {
                // Keep the escaped character as-is; catalog keys almost never
                // need escapes, but we must not treat `\"` as a terminator.
                literal.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "\"" {
                return literal.isEmpty ? nil : literal
            } else {
                literal.append(ch)
            }
            index = line.index(after: index)
        }
        // Unterminated literal — treat as no key rather than a partial match.
        return nil
    }
}
