//
// Base64URLCodingTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
@testable import BitFoundation

struct Base64URLCodingTests {
    @Test
    func encodeUsesURLAlphabetWithoutPadding() {
        // 0xFF 0xEF is "/+8=" in standard base64: exercises both
        // substituted characters and padding removal.
        #expect(Base64URLCoding.encode(Data([0xFF, 0xEF])) == "_-8")
        #expect(Base64URLCoding.encode(Data("Man".utf8)) == "TWFu")
        #expect(Base64URLCoding.encode(Data("Ma".utf8)) == "TWE")
        #expect(Base64URLCoding.encode(Data("M".utf8)) == "TQ")
        #expect(Base64URLCoding.encode(Data()) == "")
    }

    @Test
    func decodeAcceptsUnpaddedInput() {
        #expect(Base64URLCoding.decode("_-8") == Data([0xFF, 0xEF]))
        #expect(Base64URLCoding.decode("TWFu") == Data("Man".utf8))
        #expect(Base64URLCoding.decode("TWE") == Data("Ma".utf8))
        #expect(Base64URLCoding.decode("TQ") == Data("M".utf8))
        #expect(Base64URLCoding.decode("") == Data())
    }

    @Test
    func decodeAcceptsPaddedInput() {
        // External producers (e.g. Cashu wallets) emit padded forms too.
        #expect(Base64URLCoding.decode("_-8=") == Data([0xFF, 0xEF]))
        #expect(Base64URLCoding.decode("TWE=") == Data("Ma".utf8))
        #expect(Base64URLCoding.decode("TQ==") == Data("M".utf8))
    }

    @Test
    func decodeRejectsInvalidInput() {
        // Length ≡ 1 (mod 4) can never be valid base64.
        #expect(Base64URLCoding.decode("TQQQQ") == nil)
        // Characters outside the base64url alphabet.
        #expect(Base64URLCoding.decode("!!!") == nil)
        #expect(Base64URLCoding.decode("TW Fu") == nil)
    }

    @Test
    func roundTripsAllPaddingLengths() {
        for length in 0..<16 {
            let data = Data((0..<length).map { UInt8($0 &* 37 &+ 11) })
            let encoded = Base64URLCoding.encode(data)
            #expect(!encoded.contains("+"))
            #expect(!encoded.contains("/"))
            #expect(!encoded.contains("="))
            #expect(Base64URLCoding.decode(encoded) == data)
        }
    }
}
