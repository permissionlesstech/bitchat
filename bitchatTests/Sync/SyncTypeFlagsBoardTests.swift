//
// SyncTypeFlagsBoardTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation
import Testing
@testable import bitchat

/// The board sync flag is the first bit outside the original single byte of
/// type flags. These tests pin down the wire compatibility contract: the
/// types TLV has been a variable-length (1-8 byte) little-endian bitfield
/// since type-aware sync, so widening to two bytes must decode everywhere
/// and unknown bits must be ignored, not rejected.
struct SyncTypeFlagsBoardTests {

    @Test func boardFlagEncodesIntoSecondByte() throws {
        let data = try #require(SyncTypeFlags.board.toData())
        // Little-endian: low byte first, board bit (bit 8) in byte 2.
        #expect(data == Data([0x00, 0x01]))
    }

    @Test func boardFlagRoundTrips() throws {
        let flags = SyncTypeFlags(messageTypes: [.message, .boardPost])
        let data = try #require(flags.toData())
        let decoded = try #require(SyncTypeFlags.decode(data))
        #expect(decoded.contains(.message))
        #expect(decoded.contains(.boardPost))
        #expect(!decoded.contains(.fragment))
        #expect(Set(decoded.toMessageTypes()) == Set([.message, .boardPost]))
    }

    /// An old decoder is modeled by bits it has no mapping for: the shared
    /// decode path accepts the bytes and simply maps unknown bits to no
    /// message type, so a board-only request reads as "nothing I can serve".
    @Test func unknownBitsDecodeToNoTypes() throws {
        // Bits 11-15 are unassigned (bit 8 = board, bit 9 = prekeyBundle,
        // bit 10 = groupMessage); a future (or unknown) two-byte bitfield must
        // decode without error and yield no known types.
        let decoded = try #require(SyncTypeFlags.decode(Data([0x00, 0xF8])))
        #expect(decoded.toMessageTypes().isEmpty)
        for type in [MessageType.announce, .message, .fragment, .fileTransfer, .boardPost, .prekeyBundle, .groupMessage] {
            #expect(!decoded.contains(type))
        }
    }

    @Test func mixedKnownAndUnknownBitsKeepKnownTypes() throws {
        // Known low-byte flags survive alongside unknown high bits (11-15).
        let decoded = try #require(SyncTypeFlags.decode(Data([0x03, 0xF8])))
        #expect(decoded.contains(.announce))
        #expect(decoded.contains(.message))
        #expect(Set(decoded.toMessageTypes()) == Set([.announce, .message]))
    }

    @Test func requestSyncPacketRoundTripsBoardFlag() throws {
        let request = RequestSyncPacket(
            p: 4,
            m: 128,
            data: Data([0xAB, 0xCD]),
            types: SyncTypeFlags(messageTypes: [.boardPost])
        )
        let decoded = try #require(RequestSyncPacket.decode(from: request.encode()))
        let types = try #require(decoded.types)
        #expect(types.contains(.boardPost))
        #expect(!types.contains(.message))
    }

    @Test func singleByteLegacyEncodingStillDecodes() throws {
        // Requests from old clients keep the one-byte bitfield.
        let decoded = try #require(SyncTypeFlags.decode(Data([0x03])))
        #expect(decoded.contains(.announce))
        #expect(decoded.contains(.message))
        #expect(!decoded.contains(.boardPost))
    }
}
