//
// WifiBulkMessagesTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation
import Testing
@testable import bitchat

@Suite("WifiBulk offer/response TLV")
struct WifiBulkMessagesTests {
    private func makeOffer(
        fileSize: UInt64 = 300_000,
        serviceName: String = "a1b2c3d4e5f60718a1b2c3d4e5f60718"
    ) -> WifiBulkOffer {
        WifiBulkOffer(
            transferID: Data(repeating: 0xAB, count: WifiBulkWire.transferIDLength),
            fileSize: fileSize,
            payloadHash: Data(repeating: 0xCD, count: WifiBulkWire.hashLength),
            token: Data(repeating: 0xEF, count: WifiBulkWire.tokenLength),
            serviceName: serviceName
        )
    }

    @Test("Offer round-trips through TLV encoding")
    func offerRoundTrip() throws {
        let offer = makeOffer()
        let encoded = try #require(offer.encode())
        let decoded = try #require(WifiBulkOffer.decode(encoded))
        #expect(decoded == offer)
    }

    @Test("Offer encode rejects malformed field lengths")
    func offerEncodeRejectsBadFields() {
        #expect(WifiBulkOffer(
            transferID: Data(repeating: 1, count: 15), // short transferID
            fileSize: 1,
            payloadHash: Data(repeating: 2, count: 32),
            token: Data(repeating: 3, count: 32),
            serviceName: "x"
        ).encode() == nil)

        #expect(makeOffer(serviceName: "").encode() == nil)
        #expect(makeOffer(serviceName: String(repeating: "a", count: 64)).encode() == nil)
    }

    @Test("Offer decode rejects missing or wrong-length fields")
    func offerDecodeRejectsMalformed() throws {
        let encoded = try #require(makeOffer().encode())

        // Truncation anywhere breaks a TLV boundary or drops a required field.
        #expect(WifiBulkOffer.decode(encoded.dropLast(1)) == nil)
        #expect(WifiBulkOffer.decode(encoded.prefix(3)) == nil)
        #expect(WifiBulkOffer.decode(Data()) == nil)

        // A wrong-length transferID TLV is ignored, leaving the field missing.
        var mangled = Data([0x01, 0x00, 0x02, 0xAA, 0xBB]) // transferID of 2 bytes
        mangled.append(encoded.dropFirst(3 + WifiBulkWire.transferIDLength))
        #expect(WifiBulkOffer.decode(mangled) == nil)
    }

    @Test("Offer decode skips unknown TLVs for forward compatibility")
    func offerDecodeSkipsUnknownTLVs() throws {
        var encoded = try #require(makeOffer().encode())
        encoded.append(contentsOf: [0x7F, 0x00, 0x03, 0x01, 0x02, 0x03]) // unknown type 0x7F
        let decoded = try #require(WifiBulkOffer.decode(encoded))
        #expect(decoded == makeOffer())
    }

    @Test("Accept response round-trips with token")
    func acceptResponseRoundTrip() throws {
        let response = WifiBulkResponse.accept(
            transferID: Data(repeating: 0x11, count: WifiBulkWire.transferIDLength),
            token: Data(repeating: 0x22, count: WifiBulkWire.tokenLength)
        )
        let encoded = try #require(response.encode())
        let decoded = try #require(WifiBulkResponse.decode(encoded))
        #expect(decoded == response)
        #expect(decoded.accepted)
        #expect(decoded.token?.count == WifiBulkWire.tokenLength)
    }

    @Test("Decline response round-trips without token")
    func declineResponseRoundTrip() throws {
        let response = WifiBulkResponse.decline(
            transferID: Data(repeating: 0x11, count: WifiBulkWire.transferIDLength)
        )
        let encoded = try #require(response.encode())
        let decoded = try #require(WifiBulkResponse.decode(encoded))
        #expect(decoded == response)
        #expect(!decoded.accepted)
        #expect(decoded.token == nil)
    }

    @Test("Accept response without a token is rejected")
    func acceptWithoutTokenRejected() throws {
        // Hand-build: transferID + accepted=1, no token TLV.
        var data = Data()
        WifiBulkWire.appendTLV(0x01, value: Data(repeating: 0x11, count: 16), into: &data)
        WifiBulkWire.appendTLV(0x02, value: Data([1]), into: &data)
        #expect(WifiBulkResponse.decode(data) == nil)
    }
}
