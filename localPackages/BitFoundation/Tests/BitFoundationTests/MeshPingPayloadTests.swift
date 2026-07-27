//
// MeshPingPayloadTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
@testable import BitFoundation

struct MeshPingPayloadTests {

    @Test func encodeDecodeRoundTrip() throws {
        let nonce = Data([0x01, 0x02, 0x03, 0x04, 0xAA, 0xBB, 0xCC, 0xFF])
        let payload = try #require(MeshPingPayload(nonce: nonce, originTTL: 7))

        let encoded = payload.encode()
        #expect(encoded.count == 9)
        #expect(encoded.prefix(8) == nonce)
        #expect(encoded.last == 7)

        let decoded = try #require(MeshPingPayload.decode(encoded))
        #expect(decoded == payload)
    }

    @Test func decodeToleratesTrailingBytes() throws {
        let nonce = Data(repeating: 0x42, count: 8)
        let payload = try #require(MeshPingPayload(nonce: nonce, originTTL: 3))
        var extended = payload.encode()
        extended.append(contentsOf: [0xDE, 0xAD])

        let decoded = try #require(MeshPingPayload.decode(extended))
        #expect(decoded == payload)
    }

    @Test func decodeRespectsSliceIndices() throws {
        // Data slices keep their parent's indices; decoding must not assume
        // startIndex == 0.
        let nonce = Data(repeating: 0x11, count: 8)
        let payload = try #require(MeshPingPayload(nonce: nonce, originTTL: 5))
        let framed = Data([0x00, 0x00]) + payload.encode()
        let slice = framed.dropFirst(2)

        let decoded = try #require(MeshPingPayload.decode(slice))
        #expect(decoded == payload)
    }

    @Test func rejectsTruncatedPayload() {
        #expect(MeshPingPayload.decode(Data(repeating: 0x01, count: 8)) == nil)
        #expect(MeshPingPayload.decode(Data()) == nil)
    }

    @Test func rejectsWrongNonceLength() {
        #expect(MeshPingPayload(nonce: Data(repeating: 0, count: 7), originTTL: 7) == nil)
        #expect(MeshPingPayload(nonce: Data(repeating: 0, count: 9), originTTL: 7) == nil)
    }

    @Test func hopCountMath() {
        // Direct link: no TTL decrement, one hop.
        #expect(MeshPingPayload.hopCount(originTTL: 7, receivedTTL: 7) == 1)
        // One relay in between: two hops.
        #expect(MeshPingPayload.hopCount(originTTL: 7, receivedTTL: 6) == 2)
        // Full TTL consumed.
        #expect(MeshPingPayload.hopCount(originTTL: 7, receivedTTL: 1) == 7)
        // Inconsistent TTLs (received above origin) are rejected.
        #expect(MeshPingPayload.hopCount(originTTL: 3, receivedTTL: 7) == nil)
    }
}
