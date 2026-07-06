//
// PeerCapabilitiesTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
@testable import BitFoundation

struct PeerCapabilitiesTests {
    @Test
    func encodingIsMinimalAndRoundTrips() {
        #expect(PeerCapabilities([]).encoded() == Data([0x00]))
        #expect(PeerCapabilities.prekeys.encoded() == Data([0x01]))
        #expect(PeerCapabilities.meshDiagnostics.encoded() == Data([0x40]))

        let high = PeerCapabilities(rawValue: 1 << 9)
        #expect(high.encoded() == Data([0x00, 0x02]))

        let all: PeerCapabilities = [.prekeys, .wifiBulk, .gateway, .groups, .board, .vouch, .meshDiagnostics]
        #expect(PeerCapabilities(encoded: all.encoded()) == all)
        #expect(PeerCapabilities(encoded: high.encoded()) == high)
        #expect(PeerCapabilities(encoded: PeerCapabilities([]).encoded()) == [])
    }

    @Test
    func decodingToleratesUnknownBitsAndOversizedFields() {
        // Unknown bits survive a round-trip untouched.
        let unknown = PeerCapabilities(encoded: Data([0xFF, 0xFF]))
        #expect(unknown.rawValue == 0xFFFF)
        #expect(unknown.contains(.gateway))

        // Fields longer than 8 bytes keep the low 64 bits and ignore the rest.
        let oversized = Data([0x01] + [UInt8](repeating: 0x00, count: 7) + [0xAA, 0xBB])
        #expect(PeerCapabilities(encoded: oversized) == .prekeys)

        // Empty value decodes to no capabilities.
        #expect(PeerCapabilities(encoded: Data()) == [])
    }
}
