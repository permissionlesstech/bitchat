import Foundation

/// Walks Swift sources and collects localization keys passed to
/// `String(localized:)` (with or without an explicit `defaultValue:`).
enum LocalizationKeyScanner {
    struct Reference: Hashable {
        let key: String
        let file: String
        let line: Int
    }

    /// Keys passed to `String(localized: "…")` in production sources.
    static func scanProductionSources(repoRoot: URL) throws -> [Reference] {
        let roots = [
            repoRoot.appendingPathComponent("bitchat"),
            repoRoot.appendingPathComponent("bitchatShareExtension"),
        ]
        var refs: [Reference] = []
        for root in roots {
            refs.append(contentsOf: try scanDirectory(root, repoRoot: repoRoot))
        }
        return refs.sorted { lhs, rhs in
            if lhs.key != rhs.key { return lhs.key < rhs.key }
            if lhs.file != rhs.file { return lhs.file < rhs.file }
            return lhs.line < rhs.line
        }
    }

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
            let relative = fileURL.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
            let lines = try String(contentsOf: fileURL, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            for (index, lineSub) in lines.enumerated() {
                let line = String(lineSub)
                for key in keys(in: line) {
                    refs.append(Reference(key: key, file: relative, line: index + 1))
                }
            }
        }
        return refs
    }

    /// Extracts the first string literal argument to `String(localized:` on a line.
    static func keys(in line: String) -> [String] {
        guard line.contains("String(localized:") else { return [] }
        var keys: [String] = []
        var searchStart = line.startIndex
        while let range = line.range(of: "String(localized:", range: searchStart..<line.endIndex) {
            var index = range.upperBound
            while index < line.endIndex, line[index].isWhitespace {
                index = line.index(after: index)
            }
            guard index < line.endIndex, line[index] == "\"" else {
                searchStart = range.upperBound
                continue
            }
            index = line.index(after: index)
            var key = ""
            var escaped = false
            while index < line.endIndex {
                let ch = line[index]
                if escaped {
                    key.append(ch)
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    if !key.isEmpty { keys.append(key) }
                    break
                } else {
                    key.append(ch)
                }
                index = line.index(after: index)
            }
            searchStart = range.upperBound
        }
        return keys
    }
}
