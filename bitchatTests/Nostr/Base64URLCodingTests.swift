import Foundation
import Testing
@testable import bitchat

struct Base64URLCodingTests {
    @Test
    func encodesWithoutPaddingOrURLUnsafeCharacters() {
        let encoded = Base64URLCoding.encode(Data([0xff, 0xee, 0xdd, 0xcc]))

        #expect(!encoded.contains("="))
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
    }

    @Test
    func decodesUnpaddedValue() throws {
        let data = try #require(Base64URLCoding.decode("_-7dzA"))

        #expect(data == Data([0xff, 0xee, 0xdd, 0xcc]))
    }

    @Test
    func roundTripsData() throws {
        let original = Data("hello bitchat".utf8)

        let decoded = try #require(Base64URLCoding.decode(Base64URLCoding.encode(original)))

        #expect(decoded == original)
    }
}

    @Test
    func matchesLegacyNostrEmbeddedBitChatEncoder() {
        // Character-identical to the deleted private helper in NostrEmbeddedBitChat.
        let data = Data([0x00, 0x01, 0x02, 0xfd, 0xfe, 0xff])
        let legacy = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        #expect(Base64URLCoding.encode(data) == legacy)
    }

