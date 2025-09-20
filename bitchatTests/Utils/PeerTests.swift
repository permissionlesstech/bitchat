//
// PeerTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
//

import XCTest
@testable import bitchat

// MARK: - Validation

final class PeerTests: XCTestCase {
    func test_accepts_short_hex_peer_id() {
        XCTAssertTrue(Peer(str: "0011223344556677").isValid)
        XCTAssertTrue(Peer(str: "aabbccddeeff0011").isValid)
    }

    func test_accepts_full_noise_key_hex() {
        let hex64 = String(repeating: "ab", count: 32) // 64 hex chars
        XCTAssertTrue(Peer(str: hex64).isValid)
    }

    func test_accepts_internal_alnum_dash_underscore() {
        XCTAssertTrue(Peer(str: "peer_123-ABC").isValid)
        XCTAssertTrue(Peer(str: "nostr_user_01").isValid)
    }

    func test_rejects_invalid_characters() {
        XCTAssertFalse(Peer(str: "peer!@#").isValid)
        XCTAssertFalse(Peer(str: "gggggggggggggggg").isValid) // not hex for short form
    }

    func test_rejects_too_long() {
        let tooLong = String(repeating: "a", count: 65)
        XCTAssertFalse(Peer(str: tooLong).isValid)
    }
}

