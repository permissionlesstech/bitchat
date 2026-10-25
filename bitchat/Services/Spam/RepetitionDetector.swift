//
// RepetitionDetector.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Character autocorrelation measures for repeated-content spam.
///
/// Text is compared as Unicode scalars after `normalize`, so case, spacing,
/// look-alike letters, accents and invisible characters don't hide a repeat.
enum RepetitionDetector {

    /// Folds a message to what a reader sees, for comparison only (never for
    /// display): NFKD turns fullwidth and math-styled letters into plain ones
    /// and splits off accents, then combining marks and invisible characters
    /// are dropped, whitespace runs become one space and the result is
    /// lowercased and capped to `maxLength` scalars.
    static func normalize(_ text: String, maxLength: Int) -> [Int] {
        // Disguises add at most a few scalars per visible character; bound the work up front.
        let scalars = text.unicodeScalars
        let head = scalars.count > maxLength * 4
            ? String(String.UnicodeScalarView(scalars.prefix(maxLength * 4)))
            : text
        var out: [Int] = []
        out.reserveCapacity(min(maxLength, head.unicodeScalars.count))
        var pendingSpace = false
        for scalar in head.decomposedStringWithCompatibilityMapping.unicodeScalars {
            if out.count >= maxLength { break }
            if isMark(scalar) || isInvisible(scalar) { continue }
            if isWhitespace(scalar) {
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace && out.count < maxLength - 1 { out.append(0x20) }
            pendingSpace = false
            out.append(lowercase(scalar))
        }
        return out
    }

    private static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace
    }

    /// Zero-width and direction controls, soft hyphens and other non-printing characters.
    private static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .format: return true
        case .control: return !isWhitespace(scalar)
        default: return false
        }
    }

    private static func isMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    /// Simple one-to-one lowercase mapping; multi-scalar mappings keep the original.
    private static func lowercase(_ scalar: Unicode.Scalar) -> Int {
        let mapped = scalar.properties.lowercaseMapping.unicodeScalars
        guard mapped.count == 1, let first = mapped.first else { return Int(scalar.value) }
        return Int(first.value)
    }

    /// Highest autocorrelation of `text` with itself over shifts 1...n/2: the
    /// fraction of overlapping positions where `text[i] == text[i + lag]`. A
    /// pattern repeated back to back ("aaaa", "buy now buy now") scores 1.0;
    /// ordinary prose stays well below 0.3.
    static func selfSimilarity(_ text: [Int]) -> Double {
        let n = text.count
        guard n >= 2 else { return 0 }
        var best = 0.0
        for lag in 1...(n / 2) {
            let overlap = n - lag
            var matches = 0
            for i in 0..<overlap where text[i] == text[i + lag] { matches += 1 }
            best = max(best, Double(matches) / Double(overlap))
        }
        return best
    }

    /// Whether `selfSimilarity(text) >= threshold`, giving up on each shift as
    /// soon as its mismatches rule it out. Ordinary text fails within a few
    /// characters per shift, where `selfSimilarity` scans every one.
    static func selfSimilarity(_ text: [Int], reaches threshold: Double) -> Bool {
        let n = text.count
        guard n >= 2 else { return threshold <= 0 }
        // Runs for every incoming message, so it reads the buffer directly.
        return text.withUnsafeBufferPointer { text in
            for lag in 1...(n / 2) {
                let overlap = n - lag
                var mismatches = 0
                var possible = true
                var i = 0
                while i < overlap {
                    if text[i] != text[i + lag] {
                        mismatches += 1
                        // The best this shift can still score, compared as the score itself is.
                        if Double(overlap - mismatches) / Double(overlap) < threshold {
                            possible = false
                            break
                        }
                    }
                    i += 1
                }
                if possible { return true }
            }
            return false
        }
    }

    /// One diagonal of the cross-correlation: `b[j]` lined up under `a[j + shift]`.
    struct Peak: Equatable {
        let shift: Int
    }

    /// How two texts line up: the peaks used and the share of the longer text they cover.
    struct Alignment: Equatable {
        let peaks: [Peak]
        let matches: Int
        let score: Double
    }

    static func crossSimilarity(_ a: [Int], _ b: [Int], maxPeaks: Int = 3, minRun: Int = 3) -> Double {
        align(a, b, maxPeaks: maxPeaks, minRun: minRun).score
    }

    /// Cross-correlation of two texts that tolerates small edits.
    ///
    /// The first peak is the classic correlation maximum, the shift where the
    /// most characters match. An inserted or deleted character moves the rest
    /// of the text onto a neighboring shift, so up to `maxPeaks - 1` further
    /// peaks add matches from other shifts. Those count only runs of at least
    /// `minRun` consecutive characters, so coincidental single letters don't
    /// add up, and no character of either text is used twice. The score is the
    /// matched characters over the longer length: 1.0 for identical texts, and
    /// a short text never matches a long one.
    static func align(_ a: [Int], _ b: [Int], maxPeaks: Int = 3, minRun: Int = 3) -> Alignment {
        guard !a.isEmpty, !b.isEmpty else { return Alignment(peaks: [], matches: 0, score: 0) }
        var usedA = [Bool](repeating: false, count: a.count)
        var usedB = [Bool](repeating: false, count: b.count)
        var peaks: [Peak] = []
        var total = 0
        while peaks.count < maxPeaks {
            let run = peaks.isEmpty ? 1 : minRun
            var bestGain = 0
            var bestShift = 0
            for shift in -(b.count - 1)..<a.count {
                let from = max(0, -shift)
                let to = min(b.count, a.count - shift)
                if to - from <= bestGain { continue }
                let gain = runMatches(a, b, shift: shift, from: from, to: to,
                                      usedA: &usedA, usedB: &usedB, minRun: run, mark: false)
                if gain > bestGain {
                    bestGain = gain
                    bestShift = shift
                }
            }
            if bestGain < run { break }
            let from = max(0, -bestShift)
            let to = min(b.count, a.count - bestShift)
            _ = runMatches(a, b, shift: bestShift, from: from, to: to,
                           usedA: &usedA, usedB: &usedB, minRun: run, mark: true)
            peaks.append(Peak(shift: bestShift))
            total += bestGain
        }
        return Alignment(peaks: peaks, matches: total, score: Double(total) / Double(max(a.count, b.count)))
    }

    /// Unused matches at `shift` that sit in runs of at least `minRun`; `mark` claims them.
    private static func runMatches(
        _ a: [Int],
        _ b: [Int],
        shift: Int,
        from: Int,
        to: Int,
        usedA: inout [Bool],
        usedB: inout [Bool],
        minRun: Int,
        mark: Bool
    ) -> Int {
        var gain = 0
        var runStart = -1
        for j in from...to {
            let hit = j < to && !usedB[j] && !usedA[j + shift] && a[j + shift] == b[j]
            if hit {
                if runStart < 0 { runStart = j }
            } else if runStart >= 0 {
                let length = j - runStart
                if length >= minRun {
                    gain += length
                    if mark {
                        for k in runStart..<j {
                            usedB[k] = true
                            usedA[k + shift] = true
                        }
                    }
                }
                runStart = -1
            }
        }
        return gain
    }

    /// Where each character occurs in a text, for `alignmentUpperBound`.
    static func positions(_ text: [Int]) -> [Int: [Int]] {
        var positions: [Int: [Int]] = [:]
        for (index, point) in text.enumerated() { positions[point, default: []].append(index) }
        return positions
    }

    /// An upper bound on `align(a, b, maxPeaks:).matches`, at a fraction of its cost.
    ///
    /// Every peak sits on a different shift (a claimed shift has nothing left
    /// to claim) and gains at most the matches on its diagonal, so the
    /// `maxPeaks` fullest diagonals bound the total. Counting every diagonal
    /// takes one pass over the character pairs that match, instead of one pass
    /// over the overlap per shift and peak. Pairs whose bound falls short of
    /// the near-copy threshold can skip `align` without changing its verdict.
    static func alignmentUpperBound(_ a: [Int], _ b: [Int], positionsInB: [Int: [Int]], maxPeaks: Int) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        // Diagonal `shift` (a[j + shift] == b[j]) is stored at shift + b.count - 1.
        var diagonals = [Int](repeating: 0, count: a.count + b.count - 1)
        let offset = b.count - 1
        diagonals.withUnsafeMutableBufferPointer { counts in
            for (i, point) in a.enumerated() {
                guard let matches = positionsInB[point] else { continue }
                for j in matches { counts[i - j + offset] += 1 }
            }
        }
        var top = [Int](repeating: 0, count: max(1, maxPeaks))
        for count in diagonals where count > top[top.count - 1] {
            var k = top.count - 1
            while k > 0 && top[k - 1] < count {
                top[k] = top[k - 1]
                k -= 1
            }
            top[k] = count
        }
        return min(top.reduce(0, +), min(a.count, b.count))
    }

    /// Distinct character trigrams as sorted hashes, for a cheap pre-check before `align`.
    static func trigrams(_ text: [Int]) -> [Int] {
        guard text.count >= 3 else { return [] }
        let count = text.count - 2
        var hashes = [Int](unsafeUninitializedCapacity: count) { hashes, initialized in
            text.withUnsafeBufferPointer { text in
                for i in 0..<count {
                    let pair: Int = text[i] &* 31 &+ text[i + 1]
                    hashes[i] = pair &* 31 &+ text[i + 2]
                }
            }
            initialized = count
        }
        // Runs for every incoming message: an insertion sort over the buffer
        // beats the generic sort on chat-length lists, above all in debug builds.
        if count <= 64 {
            hashes.withUnsafeMutableBufferPointer { hashes in
                for i in 1..<max(1, hashes.count) {
                    let value = hashes[i]
                    var j = i - 1
                    while j >= 0 && hashes[j] > value {
                        hashes[j + 1] = hashes[j]
                        j -= 1
                    }
                    hashes[j + 1] = value
                }
            }
        } else {
            hashes.sort()
        }
        // Drop repeats in place; sorting brought them together.
        let unique: Int = hashes.withUnsafeMutableBufferPointer { hashes in
            var unique = 0
            for i in 0..<hashes.count where unique == 0 || hashes[unique - 1] != hashes[i] {
                hashes[unique] = hashes[i]
                unique += 1
            }
            return unique
        }
        hashes.removeLast(hashes.count - unique)
        return hashes
    }

    /// Shared trigrams over the larger trigram set. Near-copies share most of
    /// theirs, unrelated texts few, so pairs below a low bar can skip the
    /// quadratic `align`. Texts too short to have trigrams always pass.
    static func trigramOverlap(_ a: [Int], _ b: [Int]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 1 }
        var i = 0
        var j = 0
        var shared = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] {
                shared += 1
                i += 1
                j += 1
            } else if a[i] < b[j] {
                i += 1
            } else {
                j += 1
            }
        }
        return Double(shared) / Double(max(a.count, b.count))
    }
}
