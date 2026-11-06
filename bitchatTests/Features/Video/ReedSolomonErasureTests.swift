//
// ReedSolomonErasureTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
@testable import bitchat

struct ReedSolomonErasureTests {
    @Test func fieldInverseIsConsistent() {
        for value in 1...255 {
            #expect(ReedSolomonErasure.multiply(value, ReedSolomonErasure.inverse(value)) == 1)
        }
    }

    @Test func fieldUsesPolynomial0x11D() {
        // x^7 * x = x^8 = x^4 + x^3 + x^2 + 1 under 0x11D.
        #expect(ReedSolomonErasure.multiply(0x80, 0x02) == 0x1D)
        #expect(ReedSolomonErasure.multiply(0, 0x53) == 0)
        #expect(ReedSolomonErasure.coefficient(sourceCount: 1, parityRow: 0, sourceIndex: 0) == 1)
    }

    @Test func anyKOfKPlusRSymbolsRebuildTheBlock() throws {
        let random = VideoTestRandom(seed: 1234)
        for k in [1, 2, 5, 12, 32] {
            for r in [1, 2, 4, 16] {
                let sources = (0..<k).map { _ in random.bytes(64) }
                let parity = ReedSolomonErasure.encode(sources, parityCount: r)
                #expect(parity.count == r)
                for _ in 0..<20 {
                    let lostCount = random.int(0..<(min(k, r) + 1))
                    let lost = Set(random.shuffled(Array(0..<k)).prefix(lostCount))
                    var keptParity: [Int: Data] = [:]
                    for row in random.shuffled(Array(0..<r)).prefix(lostCount) {
                        keptParity[row] = parity[row]
                    }
                    let slots: [Data?] = sources.enumerated().map { lost.contains($0.offset) ? nil : $0.element }
                    let rebuilt = try #require(ReedSolomonErasure.reconstruct(slots, parities: keptParity))
                    #expect(rebuilt == sources, "k=\(k) r=\(r) lost=\(lost.sorted())")
                }
            }
        }
    }

    @Test func tooFewSymbolsCannotRebuild() {
        let sources = (0..<4).map { index in Data((0..<8).map { UInt8(index * 8 + $0) }) }
        let parity = ReedSolomonErasure.encode(sources, parityCount: 1)
        let slots: [Data?] = [nil, sources[1], nil, sources[3]]
        #expect(ReedSolomonErasure.reconstruct(slots, parities: [0: parity[0]]) == nil)
    }

    @Test func mismatchedLengthsCannotRebuild() {
        let sources = (0..<2).map { index in Data(repeating: UInt8(index + 1), count: 8) }
        let parity = ReedSolomonErasure.encode(sources, parityCount: 1)
        #expect(ReedSolomonErasure.reconstruct([nil, sources[1]], parities: [0: parity[0].prefix(7)]) == nil)
    }

    @Test func singleSourceParityIsARepetition() throws {
        let source = Data([1, 2, 3, 4])
        let parity = ReedSolomonErasure.encode([source], parityCount: 1)
        #expect(parity[0] == source)
        let rebuilt = try #require(ReedSolomonErasure.reconstruct([nil], parities: [0: parity[0]]))
        #expect(rebuilt[0] == source)
    }
}
