//
// InputValidatorTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
//

import XCTest
@testable import bitchat

final class InputValidatorTests: XCTestCase {
    func test_accepts_short_hex_peer_id() {
        XCTAssertTrue(InputValidator.validatePeerID("0011223344556677"))
        XCTAssertTrue(InputValidator.validatePeerID("aabbccddeeff0011"))
    }

    func test_accepts_full_noise_key_hex() {
        let hex64 = String(repeating: "ab", count: 32) // 64 hex chars
        XCTAssertTrue(InputValidator.validatePeerID(hex64))
    }

    func test_accepts_internal_alnum_dash_underscore() {
        XCTAssertTrue(InputValidator.validatePeerID("peer_123-ABC"))
        XCTAssertTrue(InputValidator.validatePeerID("nostr_user_01"))
    }

    func test_rejects_invalid_characters() {
        XCTAssertFalse(InputValidator.validatePeerID("peer!@#"))
        XCTAssertFalse(InputValidator.validatePeerID("gggggggggggggggg")) // not hex for short form
    }

    func test_rejects_too_long() {
        let tooLong = String(repeating: "a", count: 65)
        XCTAssertFalse(InputValidator.validatePeerID(tooLong))
    }

    func test_valid_prefixes() {
        let hex64 = String(repeating: "a", count: 64)
        XCTAssertTrue(InputValidator.validatePeerID("noise:\(hex64)"))
        XCTAssertTrue(InputValidator.validatePeerID("nostr:\(hex64)"))
        XCTAssertTrue(InputValidator.validatePeerID("nostr_\(hex64)"))
        
        let hex63 = String(repeating: "a", count: 63)
        XCTAssertTrue(InputValidator.validatePeerID("noise:\(hex63)"))
        XCTAssertTrue(InputValidator.validatePeerID("nostr:\(hex63)"))
        XCTAssertTrue(InputValidator.validatePeerID("nostr_\(hex63)"))
        
        let hex16 = String(repeating: "a", count: 16)
        XCTAssertTrue(InputValidator.validatePeerID("noise:\(hex16)"))
        XCTAssertTrue(InputValidator.validatePeerID("nostr:\(hex16)"))
        XCTAssertTrue(InputValidator.validatePeerID("nostr_\(hex16)"))
        
        let hex8 = String(repeating: "a", count: 8)
        XCTAssertTrue(InputValidator.validatePeerID("noise:\(hex8)"))
        XCTAssertTrue(InputValidator.validatePeerID("nostr:\(hex8)"))
        XCTAssertTrue(InputValidator.validatePeerID("nostr_\(hex8)"))
        
        let mesh = "mesh:abcdefg"
        XCTAssertTrue(InputValidator.validatePeerID("name:\(mesh)"))
        
        let name = "name:some_name"
        XCTAssertTrue(InputValidator.validatePeerID("name:\(name)"))
        
        let badName = "name:bad:name"
        XCTAssertFalse(InputValidator.validatePeerID("name:\(badName)"))
        
        // Too long
        let hex65 = String(repeating: "a", count: 65)
        XCTAssertFalse(InputValidator.validatePeerID("noise:\(hex65)"))
        XCTAssertFalse(InputValidator.validatePeerID("nostr:\(hex65)"))
        XCTAssertFalse(InputValidator.validatePeerID("nostr_\(hex65)"))
    }
}

