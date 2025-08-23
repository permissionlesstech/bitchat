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
}

