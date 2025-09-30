//
// PeerIDTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import XCTest
@testable import bitchat

final class PeerIDTests: XCTestCase {
    
    private let hex16 = "0011223344556677"
    private let hex64 = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
    
    private let encoder: JSONEncoder = {
        var encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    
    // MARK: - Empty prefix
    
    func test_init_empty_prefix_with16() {
        let peerID = PeerID(str: hex16)
        XCTAssertEqual(peerID.id, hex16)
        XCTAssertEqual(peerID.bare, hex16)
        XCTAssertEqual(peerID.prefix, .empty)
    }
    
    func test_init_empty_prefix_with64() {
        let peerID = PeerID(str: hex64)
        XCTAssertEqual(peerID.id, hex64)
        XCTAssertEqual(peerID.bare, hex64)
        XCTAssertEqual(peerID.prefix, .empty)
    }
    
    // MARK: - Mesh prefix
    
    func test_init_mesh_prefix_with16() {
        let str = "mesh:" + hex16
        let peerID = PeerID(str: str)
        XCTAssertEqual(peerID.id, str)
        XCTAssertEqual(peerID.bare, hex16)
        XCTAssertEqual(peerID.prefix, .mesh)
    }
    
    func test_init_mesh_prefix_with64() {
        let str = "mesh:" + hex64
        let peerID = PeerID(str: str)
        XCTAssertEqual(peerID.id, str)
        XCTAssertEqual(peerID.bare, hex64)
        XCTAssertEqual(peerID.prefix, .mesh)
    }
    
    // MARK: - Name prefix
    
    func test_init_name_prefix() {
        let str = "name:some_name"
        let peerID = PeerID(str: str)
        XCTAssertEqual(peerID.id, str)
        XCTAssertEqual(peerID.bare, "some_name")
        XCTAssertEqual(peerID.prefix, .name)
    }
    
    // MARK: - Noise prefix
    
    func test_init_noise_prefix_with16() {
        let str = "noise:" + hex16
        let peerID = PeerID(str: str)
        XCTAssertEqual(peerID.id, str)
        XCTAssertEqual(peerID.bare, hex16)
        XCTAssertEqual(peerID.prefix, .noise)
    }
    
    func test_init_noise_prefix_with64() {
        let str = "noise:" + hex64
        let peerID = PeerID(str: str)
        XCTAssertEqual(peerID.id, str)
        XCTAssertEqual(peerID.bare, hex64)
        XCTAssertEqual(peerID.prefix, .noise)
    }
    
    // MARK: - GeoDM prefix
    
    func test_init_geoDM_prefix_with16() {
        let str = "nostr_" + hex16
        let peerID = PeerID(str: str)
        XCTAssertEqual(peerID.id, str)
        XCTAssertEqual(peerID.bare, hex16)
        XCTAssertEqual(peerID.prefix, .geoDM)
    }
    
    func test_init_geoDM_prefix_with64() {
        let str = "nostr_" + hex64
        let peerID = PeerID(str: str)
        XCTAssertEqual(peerID.id, str)
        XCTAssertEqual(peerID.bare, hex64)
        XCTAssertEqual(peerID.prefix, .geoDM)
    }
    
    // MARK: - GeoChat prefix
    
    func test_init_geoChat_prefix_with16() {
        let str = "nostr:" + hex16
        let peerID = PeerID(str: str)
        XCTAssertEqual(peerID.id, str)
        XCTAssertEqual(peerID.bare, hex16)
        XCTAssertEqual(peerID.prefix, .geoChat)
    }
    
    func test_init_geoChat_prefix_with64() {
        let str = "nostr:" + hex64
        let peerID = PeerID(str: str)
        XCTAssertEqual(peerID.id, str)
        XCTAssertEqual(peerID.bare, hex64)
        XCTAssertEqual(peerID.prefix, .geoChat)
    }
    
    // MARK: - Edge cases
    
    func test_init_with_unknown_prefix() {
        let str = "unknown:" + hex16
        let peerID = PeerID(str: str)
        // Falls back to .empty
        XCTAssertEqual(peerID.id, str)
        XCTAssertEqual(peerID.bare, str)
        XCTAssertEqual(peerID.prefix, .empty)
    }
    
    func test_init_with_only_prefix_no_bare() {
        let str = "mesh:"
        let peerID = PeerID(str: str)
        XCTAssertEqual(peerID.id, str)
        XCTAssertEqual(peerID.bare, "")
        XCTAssertEqual(peerID.prefix, .mesh)
    }
    
    // MARK: - init?(data:)
    
    func test_init_data_valid_utf8() {
        let peerID = PeerID(data: Data(hex16.utf8))
        XCTAssertNotNil(peerID)
        XCTAssertEqual(peerID?.bare, hex16)
        XCTAssertEqual(peerID?.prefix, .empty)
    }
    
    func test_init_data_invalid_utf8() {
        // Random invalid UTF8
        let bytes: [UInt8] = [0xFF, 0xFE, 0xFA]
        let peerID = PeerID(data: Data(bytes))
        XCTAssertNil(peerID)
    }
    
    // MARK: - init(str: Substring)
    
    func test_init_substring() {
        let substring = hex64.prefix(16)
        let peerID = PeerID(str: substring)
        XCTAssertEqual(peerID.id, String(substring))
        XCTAssertEqual(peerID.bare, String(substring))
        XCTAssertEqual(peerID.prefix, .empty)
    }
    
    // MARK: - init(nostr_ pubKey:)
    
    func test_init_nostrUnderscore_pubKey() {
        let pubKey = hex64
        let peerID = PeerID(nostr_: pubKey)
        XCTAssertEqual(peerID.id, "nostr_\(pubKey.prefix(TransportConfig.nostrConvKeyPrefixLength))")
        XCTAssertEqual(peerID.bare, String(pubKey.prefix(TransportConfig.nostrConvKeyPrefixLength)))
        XCTAssertEqual(peerID.prefix, .geoDM)
    }
    
    // MARK: - init(nostr pubKey:)
    
    func test_init_nostr_pubKey() {
        let pubKey = hex64
        let peerID = PeerID(nostr: pubKey)
        XCTAssertEqual(peerID.id, "nostr:\(pubKey.prefix(TransportConfig.nostrShortKeyDisplayLength))")
        XCTAssertEqual(peerID.bare, String(pubKey.prefix(TransportConfig.nostrShortKeyDisplayLength)))
        XCTAssertEqual(peerID.prefix, .geoChat)
    }
    
    // MARK: - init(publicKey:)
    
    func test_init_publicKey_derivesFingerprint() {
        let publicKey = Data(hex64.utf8)
        let expected = publicKey.sha256Fingerprint().prefix(16)
        let peerID = PeerID(publicKey: publicKey)
        XCTAssertEqual(peerID.bare, String(expected))
        XCTAssertEqual(peerID.prefix, .empty)
    }
    
    // MARK: - toShort()
    
    func test_toShort_whenNoiseKeyExists() {
        let peerID = PeerID(str: hex64)
        let short = peerID.toShort()
        
        // `toShort()` should derive 16-hex peerID
        let expected = Data(hexString: hex64)!.sha256Fingerprint().prefix(16)
        
        XCTAssertEqual(short.bare, String(expected))
        XCTAssertEqual(short.prefix, .empty)
    }
    
    func test_toShort_whenNoNoiseKey() {
        let peerID = PeerID(str: "some_random_key")
        let short = peerID.toShort()
        XCTAssertEqual(short, peerID) // unchanged
    }

    
    // MARK: - Codable

    func test_codable_emptyPrefix() throws {
        struct Dummy: Codable, Equatable {
            let name: String
            let peerID: PeerID
        }
        
        let str = "aabbccddeeff0011"
        let jsonString = "{\"name\":\"some name\",\"peerID\":\"\(str)\"}"
        
        let decoded = try JSONDecoder().decode(Dummy.self, from: Data(jsonString.utf8))
        XCTAssertEqual(decoded.peerID, PeerID(str: str))
        
        let encoded = try encoder.encode(decoded)
        XCTAssertEqual(String(data: encoded, encoding: .utf8), jsonString)
    }

    func test_codable_withPrefix() throws {
        struct Dummy: Codable, Equatable {
            let peerID: PeerID
        }
        
        let str = "nostr_\(hex16)"
        let jsonString = "{\"peerID\":\"\(str)\"}"
        
        let decoded = try JSONDecoder().decode(Dummy.self, from: Data(jsonString.utf8))
        XCTAssertEqual(decoded.peerID, PeerID(str: str))
        XCTAssertEqual(decoded.peerID.bare, hex16)
        XCTAssertEqual(decoded.peerID.prefix, .geoDM)
        
        let encoded = try encoder.encode(decoded)
        XCTAssertEqual(String(data: encoded, encoding: .utf8), jsonString)
    }

    func test_codable_multiplePrefixes() throws {
        // Loop across all Prefix cases (except .empty since already tested)
        for prefix in PeerID.Prefix.allCases where prefix != .empty {
            let bare = hex16
            let str = prefix.rawValue + bare
            
            let decoded = try JSONDecoder().decode(PeerID.self, from: Data("\"\(str)\"".utf8))
            XCTAssertEqual(decoded.prefix, prefix)
            XCTAssertEqual(decoded.bare, bare)
            
            let encoded = try encoder.encode(decoded)
            XCTAssertEqual(String(data: encoded, encoding: .utf8), "\"\(str)\"")
        }
    }
    
    // MARK: - Comparable
    
    func test_comparable_sorting_and_equality() {
        let p1 = PeerID(str: "aaa")
        let p2 = PeerID(str: "bbb")
        let p3 = PeerID(str: "bbb")
        
        XCTAssertTrue(p1 < p2)
        XCTAssertFalse(p2 < p1)
        XCTAssertEqual(p2, p3)
        
        let sorted = [p2, p1].sorted()
        XCTAssertEqual(sorted, [p1, p2])
    }
    
    // MARK: - Computed properties
    
    func test_isEmpty_true_and_false() {
        XCTAssertTrue(PeerID(str: "").isEmpty)
        XCTAssertFalse(PeerID(str: "abc").isEmpty)
    }
    
    func test_isGeoChat() {
        XCTAssertTrue(PeerID(str: "nostr:abcdef").isGeoChat)
        XCTAssertFalse(PeerID(str: "nostr_abcdef").isGeoChat) // different prefix
    }
    
    func test_isGeoDM() {
        XCTAssertTrue(PeerID(str: "nostr_abcdef").isGeoDM)
        XCTAssertFalse(PeerID(str: "nostr:abcdef").isGeoDM)
    }
    
    func test_toPercentEncoded() {
        let peerID = PeerID(str: "name:some value/with spaces?")
        let encoded = peerID.toPercentEncoded()
        // spaces and ? should be percent-encoded in urlPathAllowed
        XCTAssertEqual(encoded, "name%3Asome%20value/with%20spaces%3F")
    }
    
    // MARK: - Validation
    
    func test_accepts_short_hex_peer_id() {
        XCTAssertTrue(PeerID(str: "0011223344556677").isValid)
        XCTAssertTrue(PeerID(str: "aabbccddeeff0011").isValid)
    }
    
    func test_accepts_full_noise_key_hex() {
        let hex64 = String(repeating: "ab", count: 32) // 64 hex chars
        XCTAssertTrue(PeerID(str: hex64).isValid)
    }
    
    func test_accepts_internal_alnum_dash_underscore() {
        XCTAssertTrue(PeerID(str: "peer_123-ABC").isValid)
        XCTAssertTrue(PeerID(str: "nostr_user_01").isValid)
    }
    
    func test_rejects_invalid_characters() {
        XCTAssertFalse(PeerID(str: "peer!@#").isValid)
        XCTAssertFalse(PeerID(str: "gggggggggggggggg").isValid) // not hex for short form
    }
    
    func test_rejects_too_long() {
        let tooLong = String(repeating: "a", count: 65)
        XCTAssertFalse(PeerID(str: tooLong).isValid)
    }
    
    func test_isShort() {
        XCTAssertTrue(PeerID(str: hex16).isShort)
        XCTAssertFalse(PeerID(str: "abcd").isShort) // wrong length
    }
    
    func test_isNoiseKeyHex_and_noiseKey() {
        let hex64 = String(repeating: "ab", count: 32) // 64 chars valid hex
        let peerID = PeerID(str: hex64)
        XCTAssertTrue(peerID.isNoiseKeyHex)
        XCTAssertNotNil(peerID.noiseKey)
        
        let bad = String(repeating: "z", count: 64) // invalid hex
        let badPeerID = PeerID(str: bad)
        XCTAssertFalse(badPeerID.isNoiseKeyHex)
        XCTAssertNil(badPeerID.noiseKey)
    }
    
    func test_prefixes() {
        let hex64 = String(repeating: "a", count: 64)
        XCTAssertTrue(PeerID(str: "noise:\(hex64)").isValid)
        XCTAssertTrue(PeerID(str: "nostr:\(hex64)").isValid)
        XCTAssertTrue(PeerID(str: "nostr_\(hex64)").isValid)

        let hex63 = String(repeating: "a", count: 63)
        XCTAssertTrue(PeerID(str: "noise:\(hex63)").isValid)
        XCTAssertTrue(PeerID(str: "nostr:\(hex63)").isValid)
        XCTAssertTrue(PeerID(str: "nostr_\(hex63)").isValid)

        let hex16 = String(repeating: "a", count: 16)
        XCTAssertTrue(PeerID(str: "noise:\(hex16)").isValid)
        XCTAssertTrue(PeerID(str: "nostr:\(hex16)").isValid)
        XCTAssertTrue(PeerID(str: "nostr_\(hex16)").isValid)

        let hex8 = String(repeating: "a", count: 8)
        XCTAssertTrue(PeerID(str: "noise:\(hex8)").isValid)
        XCTAssertTrue(PeerID(str: "nostr:\(hex8)").isValid)
        XCTAssertTrue(PeerID(str: "nostr_\(hex8)").isValid)

        let mesh = "mesh:abcdefg"
        XCTAssertTrue(PeerID(str: "name:\(mesh)").isValid)

        let name = "name:some_name"
        XCTAssertTrue(PeerID(str: "name:\(name)").isValid)

        let badName = "name:bad:name"
        XCTAssertFalse(PeerID(str: "name:\(badName)").isValid)

        // Too long
        let hex65 = String(repeating: "a", count: 65)
        XCTAssertFalse(PeerID(str: "noise:\(hex65)").isValid)
        XCTAssertFalse(PeerID(str: "nostr:\(hex65)").isValid)
        XCTAssertFalse(PeerID(str: "nostr_\(hex65)").isValid)
    }
}

