//
// NostrCarrierPacketTests.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Testing
@testable import bitchat

@Suite("Nostr carrier packet TLV")
struct NostrCarrierPacketTests {
    private func makeEvent(geohash: String = "u4pruy", content: String = "hello mesh") throws -> NostrEvent {
        let identity = try NostrIdentity.generate()
        return try NostrProtocol.createEphemeralGeohashEvent(
            content: content,
            geohash: geohash,
            senderIdentity: identity,
            nickname: "tester"
        )
    }

    @Test("round-trips both directions with the signed event intact")
    func roundTrip() throws {
        let event = try makeEvent()
        for direction in [NostrCarrierPacket.Direction.toGateway, .fromGateway] {
            let packet = try #require(NostrCarrierPacket(direction: direction, geohash: "u4pruy", event: event))
            let encoded = try #require(packet.encode())
            let decoded = try #require(NostrCarrierPacket.decode(encoded))

            #expect(decoded == packet)
            #expect(decoded.direction == direction)
            #expect(decoded.geohash == "u4pruy")

            // The carried event survives byte-exact: same ID, and the
            // signature still verifies after the mesh hop.
            let carried = try #require(decoded.event())
            #expect(carried.id == event.id)
            #expect(carried.sig == event.sig)
            #expect(carried.isValidSignature())
        }
    }

    @Test("rejects an oversized event at construction and at decode")
    func oversizedRejected() throws {
        let oversized = Data(repeating: 0x7B, count: NostrCarrierPacket.maxEventJSONBytes + 1)
        #expect(NostrCarrierPacket(direction: .toGateway, geohash: "u4pruy", eventJSON: oversized) == nil)

        // Hand-build the TLV bytes to bypass the initializer's cap.
        var data = Data([0x01, 0x00, 0x01, NostrCarrierPacket.Direction.toGateway.rawValue])
        let geohash = Data("u4pruy".utf8)
        data.append(contentsOf: [0x02, 0x00, UInt8(geohash.count)])
        data.append(geohash)
        data.append(contentsOf: [0x03, UInt8((oversized.count >> 8) & 0xFF), UInt8(oversized.count & 0xFF)])
        data.append(oversized)
        #expect(NostrCarrierPacket.decode(data) == nil)
    }

    @Test("rejects an over-length or empty geohash")
    func geohashBoundsEnforced() throws {
        let event = try makeEvent()
        #expect(NostrCarrierPacket(direction: .toGateway, geohash: "", event: event) == nil)
        #expect(NostrCarrierPacket(direction: .toGateway, geohash: String(repeating: "u", count: 13), event: event) == nil)
        #expect(NostrCarrierPacket(direction: .toGateway, geohash: String(repeating: "u", count: 12), event: event) != nil)
    }

    @Test("skips unknown TLVs for forward compatibility")
    func unknownTLVSkipped() throws {
        let event = try makeEvent()
        let packet = try #require(NostrCarrierPacket(direction: .fromGateway, geohash: "u4pruy", event: event))
        var encoded = try #require(packet.encode())
        // Append an unknown TLV (type 0x7F, 2-byte value).
        encoded.append(contentsOf: [0x7F, 0x00, 0x02, 0xDE, 0xAD])
        let decoded = try #require(NostrCarrierPacket.decode(encoded))
        #expect(decoded == packet)
    }

    @Test("rejects truncated and missing-field payloads")
    func malformedRejected() throws {
        let event = try makeEvent()
        let packet = try #require(NostrCarrierPacket(direction: .toGateway, geohash: "u4pruy", event: event))
        let encoded = try #require(packet.encode())

        // Truncation anywhere inside the last TLV fails cleanly.
        #expect(NostrCarrierPacket.decode(encoded.dropLast(1)) == nil)
        #expect(NostrCarrierPacket.decode(encoded.prefix(4)) == nil)
        #expect(NostrCarrierPacket.decode(Data()) == nil)

        // Direction TLV alone (missing geohash and event) fails.
        #expect(NostrCarrierPacket.decode(Data([0x01, 0x00, 0x01, 0x01])) == nil)
        // Unknown direction value fails.
        #expect(NostrCarrierPacket.decode(Data([0x01, 0x00, 0x01, 0x77])) == nil)
    }
}
