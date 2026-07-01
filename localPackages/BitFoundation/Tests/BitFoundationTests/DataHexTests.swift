//
// DataHexTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
@testable import BitFoundation

struct DataHexTests {

    // MARK: - Encoding

    @Test func encode_knownVectors() {
        #expect(Data().hexEncodedString() == "")
        #expect(Data([0x00]).hexEncodedString() == "00")
        #expect(Data([0x0f]).hexEncodedString() == "0f")
        #expect(Data([0xf0]).hexEncodedString() == "f0")
        #expect(Data([0xff]).hexEncodedString() == "ff")
        #expect(Data([0xde, 0xad, 0xbe, 0xef]).hexEncodedString() == "deadbeef")
        #expect(Data([0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef]).hexEncodedString() == "0123456789abcdef")
    }

    @Test func encode_allByteValues_matchesFormatReference() {
        let all = Data((0...255).map { UInt8($0) })
        let reference = (0...255).map { String(format: "%02x", $0) }.joined()
        #expect(all.hexEncodedString() == reference)
    }

    @Test func encode_worksOnDataSlices() {
        let data = Data([0xaa, 0xde, 0xad, 0xbe, 0xef, 0xbb])
        let slice = data.dropFirst().dropLast()
        #expect(slice.hexEncodedString() == "deadbeef")
    }

    // MARK: - Decoding

    @Test func decode_knownVectors() {
        #expect(Data(hexString: "deadbeef") == Data([0xde, 0xad, 0xbe, 0xef]))
        #expect(Data(hexString: "DEADBEEF") == Data([0xde, 0xad, 0xbe, 0xef]))
        #expect(Data(hexString: "DeAdBeEf") == Data([0xde, 0xad, 0xbe, 0xef]))
        #expect(Data(hexString: "00") == Data([0x00]))
        #expect(Data(hexString: "0123456789abcdef") == Data([0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef]))
    }

    @Test func decode_handlesPrefixAndWhitespace() {
        #expect(Data(hexString: "0xdeadbeef") == Data([0xde, 0xad, 0xbe, 0xef]))
        #expect(Data(hexString: "0XDEADBEEF") == Data([0xde, 0xad, 0xbe, 0xef]))
        #expect(Data(hexString: "  deadbeef\n") == Data([0xde, 0xad, 0xbe, 0xef]))
        #expect(Data(hexString: "") == Data())
        #expect(Data(hexString: "0x") == Data())
    }

    @Test func decode_rejectsInvalidInput() {
        #expect(Data(hexString: "abc") == nil)        // odd length
        #expect(Data(hexString: "zz") == nil)         // non-hex characters
        #expect(Data(hexString: "0xg1") == nil)       // non-hex after prefix
        #expect(Data(hexString: "+f") == nil)         // sign characters are not hex
        #expect(Data(hexString: "-0") == nil)
        #expect(Data(hexString: "a\u{00e9}") == nil)  // non-ASCII
        #expect(Data(hexString: "de ad") == nil)      // interior whitespace
    }

    // MARK: - Round trip

    @Test func roundTrip_randomLengths() {
        for length in [0, 1, 2, 3, 8, 16, 31, 32, 33, 64, 255, 1024] {
            let data = Data((0..<length).map { _ in UInt8.random(in: .min ... .max) })
            let hex = data.hexEncodedString()
            #expect(hex.count == length * 2)
            #expect(Data(hexString: hex) == data)
            #expect(Data(hexString: hex.uppercased()) == data)
        }
    }
}
