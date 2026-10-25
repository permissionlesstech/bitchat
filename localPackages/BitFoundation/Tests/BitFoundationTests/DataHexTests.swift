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

    // MARK: - Encoding

    /// Hex strings are identities (Nostr pubkeys, peer IDs) and wire values,
    /// so the encoder must stay byte-identical to the `%02x` formatting it
    /// replaced: lowercase, zero-padded, no separators.
    @Test func encodes_every_byte_like_printf_hex() {
        let bytes = Data((0...255).map { UInt8($0) })
        let expected = bytes.map { String(format: "%02x", $0) }.joined()
        #expect(bytes.hexEncodedString() == expected)
    }

    @Test func encodes_empty_data_as_empty_string() {
        #expect(Data().hexEncodedString() == "")
    }

    @Test func encodes_slices_from_their_own_start_index() {
        let bytes = Data([0x00, 0xde, 0xad, 0xbe, 0xef, 0xff])
        let slice = bytes[1..<5]
        #expect(slice.hexEncodedString() == "deadbeef")
    }

    @Test func encodes_varied_lengths_like_printf_hex() {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for length in 1...96 {
            let bytes = Data((0..<length).map { _ in
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return UInt8(truncatingIfNeeded: state >> 56)
            })
            let expected = bytes.map { String(format: "%02x", $0) }.joined()
            #expect(bytes.hexEncodedString() == expected)
        }
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
