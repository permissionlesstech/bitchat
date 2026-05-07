//
// HexStringTests.swift
// bitchatTests
//
// Tests for Data(hexString:) hex parsing
//

import Testing
import Foundation
@testable import bitchat

struct HexStringTests {

    // MARK: - Valid Hex Strings

    @Test func validHexString() {
        let data = Data(hexString: "0102030405")
        #expect(data == Data([0x01, 0x02, 0x03, 0x04, 0x05]))
    }

    @Test func validHexStringUppercase() {
        let data = Data(hexString: "AABBCCDD")
        #expect(data == Data([0xAA, 0xBB, 0xCC, 0xDD]))
    }

    @Test func validHexStringMixedCase() {
        let data = Data(hexString: "aAbBcCdD")
        #expect(data == Data([0xAA, 0xBB, 0xCC, 0xDD]))
    }

    @Test func validHexStringWith0xPrefix() {
        let data = Data(hexString: "0x0102030405")
        #expect(data == Data([0x01, 0x02, 0x03, 0x04, 0x05]))
    }

    @Test func validHexStringWith0XPrefix() {
        let data = Data(hexString: "0XAABBCCDD")
        #expect(data == Data([0xAA, 0xBB, 0xCC, 0xDD]))
    }

    @Test func validHexStringWithWhitespace() {
        let data = Data(hexString: "  0102030405  ")
        #expect(data == Data([0x01, 0x02, 0x03, 0x04, 0x05]))
    }

    @Test func validHexStringWith0xPrefixAndWhitespace() {
        let data = Data(hexString: "  0x0102030405  ")
        #expect(data == Data([0x01, 0x02, 0x03, 0x04, 0x05]))
    }

    @Test func emptyHexString() {
        let data = Data(hexString: "")
        #expect(data == Data())
    }

    @Test func emptyHexStringWithWhitespace() {
        let data = Data(hexString: "   ")
        #expect(data == Data())
    }

    @Test func emptyHexStringWith0xPrefix() {
        let data = Data(hexString: "0x")
        #expect(data == Data())
    }

    // MARK: - Invalid Hex Strings

    @Test func oddLengthHexStringReturnsNil() {
        let data = Data(hexString: "012")
        #expect(data == nil)
    }

    @Test func oddLengthHexStringWith0xPrefixReturnsNil() {
        let data = Data(hexString: "0x012")
        #expect(data == nil)
    }

    @Test func invalidCharactersReturnNil() {
        let data = Data(hexString: "GHIJ")
        #expect(data == nil)
    }

    @Test func mixedValidAndInvalidCharactersReturnNil() {
        let data = Data(hexString: "01GH")
        #expect(data == nil)
    }

    @Test func specialCharactersReturnNil() {
        let data = Data(hexString: "01-02")
        #expect(data == nil)
    }

    // MARK: - Round Trip Tests

    @Test func roundTripConversion() {
        let original = Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
        let hexString = original.hexEncodedString()
        let roundTripped = Data(hexString: hexString)
        #expect(roundTripped == original)
    }

    @Test func roundTripConversionWith0xPrefix() {
        let original = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let hexString = "0x" + original.hexEncodedString()
        let roundTripped = Data(hexString: hexString)
        #expect(roundTripped == original)
    }
}
