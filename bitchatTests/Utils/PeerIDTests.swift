//
// PeerIDTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
@testable import bitchat

struct PeerIDTests {
    private let hex16 = "0011223344556677"
    private let hex64 = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
    
    private let encoder: JSONEncoder = {
        var encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    
    // MARK: - Empty prefix
    
    @Test func empty_prefix_with16() {
        let peerID = PeerID(str: hex16)
        #expect(peerID.id == hex16)
        #expect(peerID.bare == hex16)
        #expect(peerID.prefix == .empty)
    }
    
    @Test func empty_prefix_with64() {
        let peerID = PeerID(str: hex64)
        #expect(peerID.id == hex64)
        #expect(peerID.bare == hex64)
        #expect(peerID.prefix == .empty)
    }
    
    // MARK: - Mesh prefix
    
    @Test func mesh_prefix_with16() {
        let str = "mesh:" + hex16
        let peerID = PeerID(str: str)
        #expect(peerID.id == str)
        #expect(peerID.bare == hex16)
        #expect(peerID.prefix == .mesh)
    }
    
    @Test func mesh_prefix_with64() {
        let str = "mesh:" + hex64
        let peerID = PeerID(str: str)
        #expect(peerID.id == str)
        #expect(peerID.bare == hex64)
        #expect(peerID.prefix == .mesh)
    }
    
    // MARK: - Name prefix
    
    @Test func name_prefix() {
        let str = "name:some_name"
        let peerID = PeerID(str: str)
        #expect(peerID.id == str)
        #expect(peerID.bare == "some_name")
        #expect(peerID.prefix == .name)
    }
    
    // MARK: - Noise prefix
    
    @Test func noise_prefix_with16() {
        let str = "noise:" + hex16
        let peerID = PeerID(str: str)
        #expect(peerID.id == str)
        #expect(peerID.bare == hex16)
        #expect(peerID.prefix == .noise)
    }
    
    @Test func noise_prefix_with64() {
        let str = "noise:" + hex64
        let peerID = PeerID(str: str)
        #expect(peerID.id == str)
        #expect(peerID.bare == hex64)
        #expect(peerID.prefix == .noise)
    }
    
    // MARK: - GeoDM prefix
    
    @Test func geoDM_prefix_with16() {
        let str = "nostr_" + hex16
        let peerID = PeerID(str: str)
        #expect(peerID.id == str)
        #expect(peerID.bare == hex16)
        #expect(peerID.prefix == .geoDM)
    }
    
    @Test func geoDM_prefix_with64() {
        let str = "nostr_" + hex64
        let peerID = PeerID(str: str)
        #expect(peerID.id == str)
        #expect(peerID.bare == hex64)
        #expect(peerID.prefix == .geoDM)
    }
    
    // MARK: - GeoChat prefix
    
    @Test func geoChat_prefix_with16() {
        let str = "nostr:" + hex16
        let peerID = PeerID(str: str)
        #expect(peerID.id == str)
        #expect(peerID.bare == hex16)
        #expect(peerID.prefix == .geoChat)
    }
    
    @Test func geoChat_prefix_with64() {
        let str = "nostr:" + hex64
        let peerID = PeerID(str: str)
        #expect(peerID.id == str)
        #expect(peerID.bare == hex64)
        #expect(peerID.prefix == .geoChat)
    }
    
    // MARK: - Edge cases
    
    @Test func with_unknown_prefix() {
        let str = "unknown:" + hex16
        let peerID = PeerID(str: str)
        // Falls back to .empty
        #expect(peerID.id == str)
        #expect(peerID.bare == str)
        #expect(peerID.prefix == .empty)
    }
    
    @Test func with_only_prefix_no_bare() {
        let str = "mesh:"
        let peerID = PeerID(str: str)
        #expect(peerID.id == str)
        #expect(peerID.bare == "")
        #expect(peerID.prefix == .mesh)
    }
    
    // MARK: - init?(data:)
    
    @Test func data_valid_utf8() {
        let peerID = PeerID(data: Data(hex16.utf8))
        #expect(peerID != nil)
        #expect(peerID?.bare == hex16)
        #expect(peerID?.prefix == .empty)
    }
    
    @Test func data_invalid_utf8() {
        // Random invalid UTF8
        let bytes: [UInt8] = [0xFF, 0xFE, 0xFA]
        let peerID = PeerID(data: Data(bytes))
        #expect(peerID == nil)
    }
    
    // MARK: - init(str: Substring)
    
    @Test func substring() {
        let substring = hex64.prefix(16)
        let peerID = PeerID(str: substring)
        #expect(peerID.id == String(substring))
        #expect(peerID.bare == String(substring))
        #expect(peerID.prefix == .empty)
    }
    
    // MARK: - init(nostr_ pubKey:)
    
    @Test func nostrUnderscore_pubKey() {
        let pubKey = hex64
        let peerID = PeerID(nostr_: pubKey)
        #expect(peerID.id == "nostr_\(pubKey.prefix(TransportConfig.nostrConvKeyPrefixLength))")
        #expect(peerID.bare == String(pubKey.prefix(TransportConfig.nostrConvKeyPrefixLength)))
        #expect(peerID.prefix == .geoDM)
    }
    
    // MARK: - init(nostr pubKey:)
    
    @Test func nostr_pubKey() {
        let pubKey = hex64
        let peerID = PeerID(nostr: pubKey)
        #expect(peerID.id == "nostr:\(pubKey.prefix(TransportConfig.nostrShortKeyDisplayLength))")
        #expect(peerID.bare == String(pubKey.prefix(TransportConfig.nostrShortKeyDisplayLength)))
        #expect(peerID.prefix == .geoChat)
    }
    
    // MARK: - init(publicKey:)
    
    @Test func publicKey_derivesFingerprint() {
        let publicKey = Data(hex64.utf8)
        let expected = publicKey.sha256Fingerprint().prefix(16)
        let peerID = PeerID(publicKey: publicKey)
        #expect(peerID.bare == String(expected))
        #expect(peerID.prefix == .empty)
    }
    
    // MARK: - toShort()
    
    @Test func toShort_whenNoiseKeyExists() {
        let peerID = PeerID(str: hex64)
        let short = peerID.toShort()
        let expected = Data(hexString: hex64)!.sha256Fingerprint().prefix(16)
        #expect(short.bare == String(expected))
        #expect(short.prefix == .empty)
    }
    
    @Test func toShort_whenNoiseKeyExists_withNoisePrefix() {
        let peerID = PeerID(str: "noise:" + hex64)
        let short = peerID.toShort()
        let expected = Data(hexString: hex64)!.sha256Fingerprint().prefix(16)
        #expect(short.bare == String(expected))
        #expect(short.prefix == .empty)
        #expect(peerID.prefix == .noise)
    }
    
    @Test func toShort_whenNoNoiseKey() {
        let peerID = PeerID(str: "some_random_key")
        let short = peerID.toShort()
        #expect(short == peerID)
    }

    @Test func routingData_fromShortID() throws {
        let peerID = PeerID(str: hex16)
        let routing = try #require(peerID.routingData)
        #expect(routing.count == 8)
        #expect(routing == Data(hexString: hex16))
    }

    @Test func routingData_fromNoiseKey() throws {
        let peerID = PeerID(str: hex64)
        let routing = try #require(peerID.routingData)
        let expectedShort = peerID.toShort()
        #expect(routing == Data(hexString: expectedShort.id))
    }

    @Test func routingPeerRoundTrip() throws {
        let raw = try #require(Data(hexString: hex16))
        let peerID = try #require(PeerID(routingData: raw))
        #expect(peerID.routingData == raw)
    }

    // MARK: - Codable

    @Test func codable_emptyPrefix() throws {
        struct Dummy: Codable, Equatable {
            let name: String
            let peerID: PeerID
        }
        
        let str = "aabbccddeeff0011"
        let jsonString = "{\"name\":\"some name\",\"peerID\":\"\(str)\"}"
        
        let decoded = try JSONDecoder().decode(Dummy.self, from: Data(jsonString.utf8))
        #expect(decoded.peerID == PeerID(str: str))
        
        let encoded = try encoder.encode(decoded)
        #expect(String(data: encoded, encoding: .utf8) == jsonString)
    }

    @Test func codable_withPrefix() throws {
        struct Dummy: Codable, Equatable {
            let peerID: PeerID
        }
        
        let str = "nostr_\(hex16)"
        let jsonString = "{\"peerID\":\"\(str)\"}"
        
        let decoded = try JSONDecoder().decode(Dummy.self, from: Data(jsonString.utf8))
        #expect(decoded.peerID == PeerID(str: str))
        #expect(decoded.peerID.bare == hex16)
        #expect(decoded.peerID.prefix == .geoDM)
        
        let encoded = try encoder.encode(decoded)
        #expect(String(data: encoded, encoding: .utf8) == jsonString)
    }

    @Test func codable_multiplePrefixes() throws {
        // Loop across all Prefix cases (except .empty since already tested)
        for prefix in PeerID.Prefix.allCases where prefix != .empty {
            let bare = hex16
            let str = prefix.rawValue + bare
            
            let decoded = try JSONDecoder().decode(PeerID.self, from: Data("\"\(str)\"".utf8))
            #expect(decoded.prefix == prefix)
            #expect(decoded.bare == bare)
            
            let encoded = try encoder.encode(decoded)
            #expect(String(data: encoded, encoding: .utf8) == "\"\(str)\"")
        }
    }
    
    // MARK: - Comparable
    
    @Test func comparable_sorting_and_equality() {
        let p1 = PeerID(str: "aaa")
        let p2 = PeerID(str: "bbb")
        let p3 = PeerID(str: "BBB")
        
        #expect(p1 < p2)
        #expect(p2 >= p1)
        #expect(p2 == p3)
        
        let sorted = [p2, p1].sorted()
        #expect(sorted == [p1, p2])
    }
    
    @Test func equality() {
        let peerID = PeerID(str: "aaa")
        
        // Regular PeerID <> PeerID
        #expect(peerID == PeerID(str: "AAA"))
        #expect(peerID == Optional(PeerID(str: "AAA")))
        #expect(PeerID(str: "AAA") == peerID)
        #expect(Optional(PeerID(str: "AAA")) == Optional(peerID))
        
        #expect(peerID != PeerID(str: "BBB"))
        #expect(peerID != Optional(PeerID(str: "BBB")))
        #expect(PeerID(str: "BBB") != peerID)
        #expect(Optional(PeerID(str: "BBB")) != Optional(peerID))
    }
    
    // MARK: - Computed properties
    
    @Test func isEmpty_true_and_false() {
        #expect(PeerID(str: "").isEmpty)
        #expect(!PeerID(str: "abc").isEmpty)
    }
    
    @Test func isGeoChat() {
        #expect(PeerID(str: "nostr:abcdef").isGeoChat)
        #expect(!PeerID(str: "nostr_abcdef").isGeoChat)
    }
    
    @Test func isGeoDM() {
        #expect(PeerID(str: "nostr_abcdef").isGeoDM)
        #expect(!PeerID(str: "nostr:abcdef").isGeoDM)
    }
    
    @Test func toPercentEncoded() {
        let peerID = PeerID(str: "name:some value/with spaces?")
        let encoded = peerID.toPercentEncoded()
        // spaces and ? should be percent-encoded in urlPathAllowed
        #expect(encoded == "name%3Asome%20value/with%20spaces%3F")
    }
    
    // MARK: - Validation
    
    @Test func accepts_short_hex_peer_id() {
        #expect(PeerID(str: "0011223344556677").isValid)
        #expect(PeerID(str: "aabbccddeeff0011").isValid)
    }
    
    @Test func accepts_full_noise_key_hex() {
        let hex64 = String(repeating: "ab", count: 32) // 64 hex chars
        #expect(PeerID(str: hex64).isValid)
    }
    
    @Test func accepts_internal_alnum_dash_underscore() {
        #expect(PeerID(str: "peer_123-ABC").isValid)
        #expect(PeerID(str: "nostr_user_01").isValid)
    }
    
    @Test func rejects_invalid_characters() {
        #expect(!PeerID(str: "peer!@#").isValid)
        #expect(!PeerID(str: "gggggggggggggggg").isValid) // not hex for short form
    }
    
    @Test func rejects_too_long() {
        let tooLong = String(repeating: "a", count: 65)
        #expect(!PeerID(str: tooLong).isValid)
    }
    
    @Test func isShort() {
        #expect(PeerID(str: hex16).isShort)
        #expect(!PeerID(str: "abcd").isShort) // wrong length
    }
    
    @Test func isNoiseKeyHex_and_noiseKey() {
        let hex64 = String(repeating: "ab", count: 32) // 64 chars valid hex
        let peerID = PeerID(str: hex64)
        #expect(peerID.isNoiseKeyHex)
        #expect(peerID.noiseKey != nil)
        
        let prefixedPeerID = PeerID(str: "noise:" + hex64)
        #expect(prefixedPeerID.isNoiseKeyHex)
        #expect(prefixedPeerID.noiseKey != nil)
        
        let bad = String(repeating: "z", count: 64) // invalid hex
        let badPeerID = PeerID(str: bad)
        #expect(!badPeerID.isNoiseKeyHex)
        #expect(badPeerID.noiseKey == nil)
    }
    
    @Test func prefixes() {
        let hex64 = String(repeating: "a", count: 64)
        #expect(PeerID(str: "noise:\(hex64)").isValid)
        #expect(PeerID(str: "nostr:\(hex64)").isValid)
        #expect(PeerID(str: "nostr_\(hex64)").isValid)

        let hex63 = String(repeating: "a", count: 63)
        #expect(PeerID(str: "noise:\(hex63)").isValid)
        #expect(PeerID(str: "nostr:\(hex63)").isValid)
        #expect(PeerID(str: "nostr_\(hex63)").isValid)

        let hex16 = String(repeating: "a", count: 16)
        #expect(PeerID(str: "noise:\(hex16)").isValid)
        #expect(PeerID(str: "nostr:\(hex16)").isValid)
        #expect(PeerID(str: "nostr_\(hex16)").isValid)

        let hex8 = String(repeating: "a", count: 8)
        #expect(PeerID(str: "noise:\(hex8)").isValid)
        #expect(PeerID(str: "nostr:\(hex8)").isValid)
        #expect(PeerID(str: "nostr_\(hex8)").isValid)

        let mesh = "mesh:abcdefg"
        #expect(PeerID(str: "name:\(mesh)").isValid)

        let name = "name:some_name"
        #expect(PeerID(str: "name:\(name)").isValid)

        let badName = "name:bad:name"
        #expect(!PeerID(str: "name:\(badName)").isValid)

        // Too long
        let hex65 = String(repeating: "a", count: 65)
        #expect(!PeerID(str: "noise:\(hex65)").isValid)
        #expect(!PeerID(str: "nostr:\(hex65)").isValid)
        #expect(!PeerID(str: "nostr_\(hex65)").isValid)
    }
}
