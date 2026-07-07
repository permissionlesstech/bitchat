//
// RequestSyncPacketFragmentFilterTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
import BitFoundation
@testable import bitchat

struct RequestSyncPacketFragmentFilterTests {

    @Test func fragmentIdFilterRoundTripsThroughWireEncoding() throws {
        let id1 = try #require(Data(hexString: "00112233445566aa"))
        let id2 = try #require(Data(hexString: "ffeeddccbbaa9988"))
        let filter = try #require(RequestSyncPacket.encodeFragmentIdFilter([id1, id2]))

        let packet = RequestSyncPacket(p: 7, m: 128, data: Data([0x01]), types: .fragment, fragmentIdFilter: filter)
        let decoded = try #require(RequestSyncPacket.decode(from: packet.encode()))

        #expect(decoded.fragmentIdFilter == filter)
        let ids = try #require(RequestSyncPacket.decodeFragmentIdFilter(decoded.fragmentIdFilter))
        #expect(ids == Set([id1, id2]))
    }

    @Test func encodeCapsFilterAtMaxCountWithinDecoderBudget() throws {
        let ids = (0..<100).map { i -> Data in
            var id = Data(repeating: 0, count: 8)
            id[7] = UInt8(i)
            return id
        }
        let filter = try #require(RequestSyncPacket.encodeFragmentIdFilter(ids))

        let tokens = filter.split(separator: ",")
        #expect(tokens.count == RequestSyncPacket.maxFragmentIdFilterCount)
        // 60 IDs * 17 bytes ("<16 hex>,") - 1 = 1019 ≤ the 1024-byte cap.
        #expect(filter.utf8.count == 1019)
        #expect(filter.utf8.count <= 1024)
    }

    @Test func encodeDropsMalformedIDs() throws {
        let good = try #require(Data(hexString: "0011223344556677"))
        let short = Data([0x01, 0x02])
        let filter = try #require(RequestSyncPacket.encodeFragmentIdFilter([short, good]))
        #expect(filter == good.hexEncodedString())
        #expect(RequestSyncPacket.encodeFragmentIdFilter([short]) == nil)
        #expect(RequestSyncPacket.encodeFragmentIdFilter([]) == nil)
    }

    @Test func decodeIgnoresMalformedTokens() throws {
        let good = try #require(Data(hexString: "0011223344556677"))
        let ids = try #require(
            RequestSyncPacket.decodeFragmentIdFilter("zzzz,0011,0011223344556677,")
        )
        #expect(ids == Set([good]))
        #expect(RequestSyncPacket.decodeFragmentIdFilter(nil) == nil)
        #expect(RequestSyncPacket.decodeFragmentIdFilter("not-hex") == nil)
    }

    @Test func decoderIgnoresOversizedFilterValue() throws {
        // Hand-roll a payload whose 0x06 TLV exceeds the acceptance cap; the
        // request must still decode, with the filter dropped.
        var payload = RequestSyncPacket(p: 7, m: 128, data: Data([0x01])).encode()
        let oversized = Data(repeating: UInt8(ascii: "a"), count: 1025)
        payload.append(0x06)
        payload.append(UInt8((oversized.count >> 8) & 0xFF))
        payload.append(UInt8(oversized.count & 0xFF))
        payload.append(oversized)

        let decoded = try #require(RequestSyncPacket.decode(from: payload))
        #expect(decoded.fragmentIdFilter == nil)
    }
}
