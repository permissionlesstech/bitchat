import Testing
import Foundation
@testable import Nostr

@Suite("Bech32")
struct Bech32Tests {
    @Test("Round-trip encode/decode")
    func roundTrip() throws {
        let original = Data([0xde, 0xad, 0xbe, 0xef, 0xca, 0xfe])
        let encoded = try Bech32.encode(hrp: "test", data: original)
        let decoded = try Bech32.decode(encoded)
        #expect(decoded.hrp == "test")
        #expect(decoded.data == original)
    }

    @Test("HRP is preserved")
    func hrpPreserved() throws {
        let data = Data(repeating: 0x42, count: 32)
        let encoded = try Bech32.encode(hrp: "npub", data: data)
        #expect(encoded.hasPrefix("npub1"))
        let decoded = try Bech32.decode(encoded)
        #expect(decoded.hrp == "npub")
    }

    @Test("Decoding invalid checksum throws")
    func invalidChecksum() throws {
        var encoded = try Bech32.encode(hrp: "test", data: Data([1, 2, 3]))
        // Corrupt the last character
        encoded = String(encoded.dropLast()) + (encoded.last == "q" ? "p" : "q")
        #expect(throws: Bech32.Bech32Error.self) {
            try Bech32.decode(encoded)
        }
    }

    @Test("Decoding string without separator throws")
    func missingSeparator() {
        #expect(throws: Bech32.Bech32Error.self) {
            try Bech32.decode("noseparatorhere")
        }
    }
}
