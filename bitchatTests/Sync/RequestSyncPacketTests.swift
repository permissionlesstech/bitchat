//
// RequestSyncPacketTests.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Testing
import BitFoundation
@testable import bitchat

struct RequestSyncPacketTests {
    @Test func baseFieldsRoundTrip() throws {
        let original = RequestSyncPacket(
            p: 7,
            m: 12_800,
            data: Data([1, 2, 3, 4, 5])
        )

        let decoded = try #require(RequestSyncPacket.decode(from: original.encode()))

        #expect(decoded.p == 7)
        #expect(decoded.m == 12_800)
        #expect(decoded.data == Data([1, 2, 3, 4, 5]))
        #expect(decoded.types == nil)
        #expect(decoded.sinceTimestamp == nil)
    }

    @Test func upgradedFieldsRoundTripAsAndroidWantedTypes() throws {
        let original = RequestSyncPacket(
            p: 8,
            m: 25_600,
            data: Data([10, 20, 30]),
            types: .publicMessages,
            sinceTimestamp: 1_700_000_000_000
        )

        let encoded = original.encode()
        let wantedTypes = try #require(tlvValue(type: 0x04, in: encoded))
        let decoded = try #require(RequestSyncPacket.decode(from: encoded))

        #expect(wantedTypes == Data([MessageType.announce.rawValue, MessageType.message.rawValue]))
        #expect(decoded.p == 8)
        #expect(decoded.m == 25_600)
        #expect(decoded.data == Data([10, 20, 30]))
        #expect(decoded.types?.contains(.announce) == true)
        #expect(decoded.types?.contains(.message) == true)
        #expect(decoded.sinceTimestamp == 1_700_000_000_000)
    }

    @Test func decodesLegacyPayloadWithoutUpgradeFields() throws {
        let payload = Data([
            0x01, 0x00, 0x01, 0x07,
            0x02, 0x00, 0x04, 0x00, 0x00, 0x32, 0x00,
            0x03, 0x00, 0x03, 0x01, 0x02, 0x03
        ])

        let decoded = try #require(RequestSyncPacket.decode(from: payload))

        #expect(decoded.p == 7)
        #expect(decoded.m == 12_800)
        #expect(decoded.data == Data([1, 2, 3]))
        #expect(decoded.types == nil)
        #expect(decoded.sinceTimestamp == nil)
    }

    @Test func decodesAndroidWantedTypesAndMinTimestamp() throws {
        let payload = Data([
            0x01, 0x00, 0x01, 0x08,
            0x02, 0x00, 0x04, 0x00, 0x00, 0x64, 0x00,
            0x03, 0x00, 0x02, 0xAA, 0xBB,
            0x04, 0x00, 0x02, MessageType.announce.rawValue, MessageType.message.rawValue,
            0x05, 0x00, 0x08, 0x00, 0x00, 0x01, 0x8B, 0xCF, 0xE5, 0x68, 0x00
        ])

        let decoded = try #require(RequestSyncPacket.decode(from: payload))

        #expect(decoded.p == 8)
        #expect(decoded.m == 25_600)
        #expect(decoded.data == Data([0xAA, 0xBB]))
        #expect(decoded.types?.contains(.announce) == true)
        #expect(decoded.types?.contains(.message) == true)
        #expect(decoded.sinceTimestamp == 1_700_000_000_000)
    }

    @Test func decodesLegacyIOSPublicMessageBitfield() throws {
        let payload = Data([
            0x01, 0x00, 0x01, 0x08,
            0x02, 0x00, 0x04, 0x00, 0x00, 0x64, 0x00,
            0x03, 0x00, 0x00,
            0x04, 0x00, 0x01, 0x03
        ])

        let decoded = try #require(RequestSyncPacket.decode(from: payload))

        #expect(decoded.types?.contains(.announce) == true)
        #expect(decoded.types?.contains(.message) == true)
    }

    private func tlvValue(type: UInt8, in data: Data) -> Data? {
        var offset = 0
        while offset + 3 <= data.count {
            let currentType = data[offset]
            offset += 1
            let length = (Int(data[offset]) << 8) | Int(data[offset + 1])
            offset += 2
            guard offset + length <= data.count else { return nil }
            let value = data.subdata(in: offset..<(offset + length))
            offset += length
            if currentType == type {
                return value
            }
        }
        return nil
    }
}
