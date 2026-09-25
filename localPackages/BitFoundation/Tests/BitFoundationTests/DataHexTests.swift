//
// DataHexTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
import BitFoundation

struct DataHexTests {
    // MARK: - Accepted forms

    @Test func decodes_plain_hex() {
        #expect(Data(hexString: "0a1b2c")?.hexEncodedString() == "0a1b2c")
    }

    @Test func decodes_uppercase_hex() {
        #expect(Data(hexString: "0A1B2C")?.hexEncodedString() == "0a1b2c")
    }

    @Test func decodes_prefixed_and_padded_hex() {
        #expect(Data(hexString: "0x0a1b")?.hexEncodedString() == "0a1b")
        #expect(Data(hexString: "0X0a1b")?.hexEncodedString() == "0a1b")
        #expect(Data(hexString: "  0a1b  ")?.hexEncodedString() == "0a1b")
    }

    @Test func round_trips_encoded_bytes() {
        let bytes = Data((0...255).map { UInt8($0) })
        #expect(Data(hexString: bytes.hexEncodedString()) == bytes)
    }

    // MARK: - Rejected forms

    @Test func rejects_odd_length() {
        #expect(Data(hexString: "0a1") == nil)
    }

    @Test func rejects_non_hex_characters() {
        #expect(Data(hexString: "zz") == nil)
        #expect(Data(hexString: "0a zz") == nil)
    }

    /// UInt8(_:radix:) accepts a leading sign, so "+f" parses as 0x0f unless the
    /// digits are checked first. Two spellings of one identity-bearing hex
    /// string decoding to the same bytes is the whole problem.
    @Test func rejects_signed_byte_pairs() {
        #expect(Data(hexString: "+a") == nil)
        #expect(Data(hexString: "-a") == nil)
        #expect(Data(hexString: "0a+b") == nil)
        #expect(Data(hexString: "+a+b") == nil)
    }

    @Test func a_signed_pair_does_not_alias_a_genuine_key() {
        let genuine = String(repeating: "0b", count: 32)
        let signed = String(repeating: "+b", count: 32)
        #expect(Data(hexString: genuine) != nil)
        #expect(Data(hexString: signed) == nil)
    }
}
