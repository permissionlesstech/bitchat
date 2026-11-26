//
// ReedSolomonErasure.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Systematic Reed-Solomon erasure code over GF(2^8) with a Cauchy generator.
///
/// Parity row `j` (0-based) for source symbol `i` uses coefficient
/// `1 / (i XOR (k + j))`. Every square submatrix of a Cauchy matrix is
/// invertible, so any `k` of the `k + r` symbols reconstruct the block (MDS).
/// Field polynomial: x^8 + x^4 + x^3 + x^2 + 1 (0x11D).
enum ReedSolomonErasure {
    private static let fieldSize = 256

    private static let tables: (exp: [Int], log: [Int]) = {
        var exp = [Int](repeating: 0, count: fieldSize * 2)
        var log = [Int](repeating: 0, count: fieldSize)
        var value = 1
        for power in 0..<(fieldSize - 1) {
            exp[power] = value
            log[value] = power
            value <<= 1
            if value & 0x100 != 0 { value ^= 0x11D }
        }
        for power in (fieldSize - 1)..<exp.count {
            exp[power] = exp[power - (fieldSize - 1)]
        }
        return (exp, log)
    }()

    private static var exp: [Int] { tables.exp }
    private static var log: [Int] { tables.log }

    static func multiply(_ a: Int, _ b: Int) -> Int {
        (a == 0 || b == 0) ? 0 : exp[log[a] + log[b]]
    }

    static func inverse(_ a: Int) -> Int {
        precondition(a != 0, "zero has no inverse")
        return exp[(fieldSize - 1) - log[a]]
    }

    static func coefficient(sourceCount: Int, parityRow: Int, sourceIndex: Int) -> Int {
        inverse(sourceIndex ^ (sourceCount + parityRow))
    }

    /// Returns `parityCount` symbols, each as long as the (equal-length) `sources`.
    static func encode(_ sources: [Data], parityCount: Int) -> [Data] {
        let k = sources.count
        precondition((1...128).contains(k) && (1...128).contains(parityCount) && k + parityCount <= fieldSize)
        let length = sources[0].count
        precondition(sources.allSatisfy { $0.count == length })
        let sourceBytes = sources.map { [UInt8]($0) }
        return (0..<parityCount).map { row in
            var parity = [UInt8](repeating: 0, count: length)
            for i in 0..<k {
                addScaled(&parity, sourceBytes[i], coefficient(sourceCount: k, parityRow: row, sourceIndex: i))
            }
            return Data(parity)
        }
    }

    /// Rebuilds missing source symbols.
    ///
    /// `sources` holds the `k` source slots (nil where lost) and `parities`
    /// maps a parity row to its symbol. Returns the completed source list, or
    /// nil when fewer than `k` symbols are available or lengths disagree.
    static func reconstruct(_ sources: [Data?], parities: [Int: Data]) -> [Data]? {
        let k = sources.count
        let missing = sources.indices.filter { sources[$0] == nil }
        if missing.isEmpty { return sources.map { $0! } }
        let firstKnown = sources.compactMap { $0 }.first ?? parities.values.first
        guard parities.count >= missing.count, let length = firstKnown?.count else { return nil }
        if sources.contains(where: { $0 != nil && $0!.count != length })
            || parities.values.contains(where: { $0.count != length }) {
            return nil
        }
        let known = sources.map { $0.map { [UInt8]($0) } }
        let rows = Array(parities.keys.sorted().prefix(missing.count))
        // Right-hand side: parity minus the contribution of the symbols we already have.
        let rhs: [[UInt8]] = rows.map { row in
            var value = [UInt8](parities[row]!)
            for i in 0..<k {
                guard let source = known[i] else { continue }
                addScaled(&value, source, coefficient(sourceCount: k, parityRow: row, sourceIndex: i))
            }
            return value
        }
        var matrix = rows.map { row in
            missing.map { coefficient(sourceCount: k, parityRow: row, sourceIndex: $0) }
        }
        guard let solved = solve(&matrix, rhs) else { return nil }
        var output = sources
        for (index, sourceIndex) in missing.enumerated() {
            output[sourceIndex] = Data(solved[index])
        }
        return output.map { $0! }
    }

    /// Gauss-Jordan elimination over GF(256); `rhs` rows are byte vectors.
    private static func solve(_ matrix: inout [[Int]], _ rhs: [[UInt8]]) -> [[UInt8]]? {
        let n = matrix.count
        var values = rhs
        for column in 0..<n {
            guard let pivot = (column..<n).first(where: { matrix[$0][column] != 0 }) else { return nil }
            if pivot != column {
                matrix.swapAt(pivot, column)
                values.swapAt(pivot, column)
            }
            let scale = inverse(matrix[column][column])
            for c in 0..<n { matrix[column][c] = multiply(matrix[column][c], scale) }
            scaleInPlace(&values[column], scale)
            for row in 0..<n where row != column {
                let factor = matrix[row][column]
                if factor == 0 { continue }
                for c in 0..<n { matrix[row][c] ^= multiply(factor, matrix[column][c]) }
                addScaled(&values[row], values[column], factor)
            }
        }
        return values
    }

    private static func addScaled(_ target: inout [UInt8], _ source: [UInt8], _ factor: Int) {
        if factor == 0 { return }
        let exp = self.exp
        let log = self.log
        let logFactor = log[factor]
        for index in target.indices {
            let byte = Int(source[index])
            if byte != 0 {
                target[index] ^= UInt8(exp[log[byte] + logFactor])
            }
        }
    }

    private static func scaleInPlace(_ target: inout [UInt8], _ factor: Int) {
        let exp = self.exp
        let log = self.log
        let logFactor = log[factor]
        for index in target.indices {
            let byte = Int(target[index])
            target[index] = byte == 0 ? 0 : UInt8(exp[log[byte] + logFactor])
        }
    }
}
