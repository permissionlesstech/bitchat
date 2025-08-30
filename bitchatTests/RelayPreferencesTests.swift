//
// RelayPreferencesTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import XCTest
@testable import bitchat

final class RelayPreferencesTests: XCTestCase {
    
    func testRelayCategories() {
        // Test that all relay categories have proper display names and descriptions
        for category in NostrRelayManager.RelayCategory.allCases {
            XCTAssertFalse(category.displayName.isEmpty)
            XCTAssertFalse(category.description.isEmpty)
        }
    }
    
    func testRelaySelectionModes() {
        // Test that all relay selection modes have proper display names and descriptions
        for mode in NostrRelayManager.RelaySelectionMode.allCases {
            XCTAssertFalse(mode.displayName.isEmpty)
            XCTAssertFalse(mode.description.isEmpty)
        }
    }
    
    func testRelayPreferencesPersistence() {
        // Test that relay preferences can be saved and loaded
        let preferences = RelayPreferences(
            selectionMode: .privateOnly,
            trustedRelays: ["wss://test1.com", "wss://test2.com"]
        )
        
        // Encode
        let encoder = JSONEncoder()
        let data = try? encoder.encode(preferences)
        XCTAssertNotNil(data)
        
        // Decode
        let decoder = JSONDecoder()
        let decoded = try? decoder.decode(RelayPreferences.self, from: data!)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.selectionMode, .privateOnly)
        XCTAssertEqual(decoded?.trustedRelays.count, 2)
    }
    
    func testRelayManagement() {
        let relayManager = NostrRelayManager()
        
        // Test adding trusted relay
        relayManager.addTrustedRelay("wss://test.com")
        XCTAssertTrue(relayManager.userTrustedRelays.contains("wss://test.com"))
        
        // Test removing trusted relay
        relayManager.removeTrustedRelay("wss://test.com")
        XCTAssertFalse(relayManager.userTrustedRelays.contains("wss://test.com"))
        
        // Test duplicate prevention
        relayManager.addTrustedRelay("wss://test.com")
        relayManager.addTrustedRelay("wss://test.com")
        XCTAssertEqual(relayManager.userTrustedRelays.count, 1)
    }
    
    func testRelaySelectionModeChanges() {
        let relayManager = NostrRelayManager()
        
        // Test mode changes
        relayManager.relaySelectionMode = .privateOnly
        XCTAssertEqual(relayManager.relaySelectionMode, .privateOnly)
        
        relayManager.relaySelectionMode = .trustedOnly
        XCTAssertEqual(relayManager.relaySelectionMode, .trustedOnly)
        
        relayManager.relaySelectionMode = .all
        XCTAssertEqual(relayManager.relaySelectionMode, .all)
    }
    
    func testGetAvailableRelays() {
        let relayManager = NostrRelayManager()
        
        // Test all mode
        relayManager.relaySelectionMode = .all
        let allRelays = relayManager.getAvailableRelays()
        XCTAssertGreaterThan(allRelays.count, 0)
        
        // Test private only mode
        relayManager.relaySelectionMode = .privateOnly
        let privateRelays = relayManager.getAvailableRelays()
        XCTAssertGreaterThanOrEqual(privateRelays.count, 0)
        
        // Test trusted only mode (should be empty initially)
        relayManager.relaySelectionMode = .trustedOnly
        let trustedRelays = relayManager.getAvailableRelays()
        XCTAssertEqual(trustedRelays.count, 0)
        
        // Add a trusted relay and test again
        relayManager.addTrustedRelay("wss://test.com")
        let trustedRelaysAfter = relayManager.getAvailableRelays()
        XCTAssertEqual(trustedRelaysAfter.count, 1)
    }
    
    func testRelayStructure() {
        let relay = NostrRelayManager.Relay(
            url: "wss://test.com",
            category: .trusted
        )
        
        XCTAssertEqual(relay.url, "wss://test.com")
        XCTAssertEqual(relay.category, .trusted)
        XCTAssertFalse(relay.isConnected)
        XCTAssertEqual(relay.messagesSent, 0)
        XCTAssertEqual(relay.messagesReceived, 0)
    }
}
