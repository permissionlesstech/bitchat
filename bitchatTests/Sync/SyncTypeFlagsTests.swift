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
        // Bits 8+ map to no message type. They must not survive decode as
        // phantom membership.
        let phantom = Data([0x00, 0xFF]) // bits 8..15 set, no known type
        let decoded = SyncTypeFlags.decode(phantom)
        #expect(decoded?.rawValue == 0)
        #expect(decoded?.toMessageTypes().isEmpty == true)
    }

    @Test func phantomBitsAreStrippedButKnownBitsSurvive() {
        // Low byte = announce(0) + message(1); high byte = phantom.
        let mixed = Data([0b0000_0011, 0xFF])
        let decoded = SyncTypeFlags.decode(mixed)
        #expect(decoded?.contains(.announce) == true)
        #expect(decoded?.contains(.message) == true)
        // Only the two known bits remain; phantom high byte is gone.
        #expect(decoded?.rawValue == 0b0000_0011)
    }

    @Test func rawValueInitNormalizesPhantomBits() {
        let flags = SyncTypeFlags(rawValue: 0xFFFF_FFFF_FFFF_FFFF)
        // Every known type bit is set; nothing above them survives, so the
        // field serializes to a single byte.
        #expect(flags.contains(.announce))
        #expect(flags.contains(.fileTransfer))
        let data = flags.toData()
        #expect(data?.count == 1)
    }
}
