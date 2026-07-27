//
// SyncTypeFlagsGroupTests.swift
// bitchat
//
// Wire-compat proof for the groupMessage sync bit (bit 10): the types
// bitfield widens from 1 to 2 bytes, and clients that don't know the bit
// simply ignore it.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Testing
import BitFoundation
@testable import bitchat

struct SyncTypeFlagsGroupTests {

    @Test func groupMessageOccupiesBitTen() {
        #expect(SyncTypeFlags.groupMessage.rawValue == 1 << 10)
        #expect(SyncTypeFlags.groupMessage.contains(.groupMessage))
        #expect(!SyncTypeFlags.publicMessages.contains(.groupMessage))
    }

    @Test func extendedBitfieldWidensToTwoBytes() throws {
        // Legacy flags fit one byte…
        #expect(SyncTypeFlags.publicMessages.toData() == Data([0x03]))

        // …the group bit widens the little-endian encoding to two bytes.
        let combined = SyncTypeFlags.publicMessages.union(.groupMessage)
        let encoded = try #require(combined.toData())
        #expect(encoded == Data([0x03, 0x04]))

        let decoded = try #require(SyncTypeFlags.decode(encoded))
        #expect(decoded == combined)
        #expect(Set(decoded.toMessageTypes()) == Set([.announce, .message, .groupMessage]))
    }

    @Test func unknownBitsAreIgnoredNotRejected() throws {
        // An "old client" reading a 2-byte field keeps the raw bits but maps
        // unknown bit indices to no message type — it answers with the types
        // it knows instead of dropping the request.
        let futuristic = try #require(SyncTypeFlags.decode(Data([0x03, 0xFC])))
        #expect(Set(futuristic.toMessageTypes()) == Set([.announce, .message, .groupMessage]))
        #expect(futuristic.contains(.announce))
        #expect(futuristic.contains(.message))
    }

    @Test func requestSyncPacketRoundTripsGroupFlag() throws {
        let types = SyncTypeFlags.publicMessages.union(.groupMessage)
        let packet = RequestSyncPacket(p: 8, m: 1024, data: Data([0xAB, 0xCD]), types: types)
        let encoded = packet.encode()

        let decoded = try #require(RequestSyncPacket.decode(from: encoded))
        #expect(decoded.types == types)
        #expect(decoded.types?.contains(.groupMessage) == true)
        #expect(decoded.p == 8)
        #expect(decoded.m == 1024)
        #expect(decoded.data == Data([0xAB, 0xCD]))
    }
}
