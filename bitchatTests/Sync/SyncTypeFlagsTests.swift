import Foundation
import Testing
import BitFoundation
@testable import bitchat

struct SyncTypeFlagsTests {

    @Test func knownTypesRoundTripThroughData() throws {
        let flags: SyncTypeFlags = [.announce, .message, .fragment, .fileTransfer]
        let data = try #require(flags.toData())
        let decoded = try #require(SyncTypeFlags.decode(data))
        #expect(decoded == flags)
    }

    @Test func decodeDropsPhantomBits() {
        // Bits 9+ map to no message type (bit 8 is boardPost). They must not
        // survive decode as phantom membership.
        let phantom = Data([0x00, 0xFE]) // bits 9..15 set, no known type
        let decoded = SyncTypeFlags.decode(phantom)
        #expect(decoded?.rawValue == 0)
        #expect(decoded?.toMessageTypes().isEmpty == true)
    }

    @Test func boardBitSurvivesDecode() {
        // Bit 8 maps to boardPost and spills the field into a second byte;
        // it must survive decode while the phantom high bits are stripped.
        let mixed = Data([0x00, 0xFF]) // bit 8 (board) known, bits 9..15 phantom
        let decoded = SyncTypeFlags.decode(mixed)
        #expect(decoded?.contains(.board) == true)
        #expect(decoded?.rawValue == 0b1_0000_0000)
    }

    @Test func phantomBitsAreStrippedButKnownBitsSurvive() {
        // Low byte = announce(0) + message(1); high byte bits 9+ are phantom.
        let mixed = Data([0b0000_0011, 0xFE])
        let decoded = SyncTypeFlags.decode(mixed)
        #expect(decoded?.contains(.announce) == true)
        #expect(decoded?.contains(.message) == true)
        // Only the two known bits remain; phantom high bits are gone.
        #expect(decoded?.rawValue == 0b0000_0011)
    }

    @Test func rawValueInitNormalizesPhantomBits() {
        let flags = SyncTypeFlags(rawValue: 0xFFFF_FFFF_FFFF_FFFF)
        // Every known type bit is set; nothing above them survives. boardPost
        // occupies bit 8, so the known set spills into a second byte.
        #expect(flags.contains(.announce))
        #expect(flags.contains(.fileTransfer))
        #expect(flags.contains(.board))
        let data = flags.toData()
        #expect(data?.count == 2)
    }
}
