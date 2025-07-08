//
// RelayStatisticsTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import XCTest
@testable import bitchat

class RelayStatisticsTests: XCTestCase {
    
    var meshService: BluetoothMeshService!
    
    override func setUp() {
        super.setUp()
        meshService = BluetoothMeshService()
        
        // Clear any existing statistics
        meshService.resetRelayStatistics()
        
        // Clear UserDefaults for clean test state
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "bitchat.relayStats")
    }
    
    override func tearDown() {
        // Clean up UserDefaults after tests
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "bitchat.relayStats")
        
        meshService = nil
        super.tearDown()
    }
    
    // MARK: - Basic Statistics Tests
    
    func testInitialStatistics() {
        let stats = meshService.getRelayStatistics()
        
        XCTAssertEqual(stats.totalMessages, 0)
        XCTAssertEqual(stats.totalPeers, 0)
        XCTAssertEqual(stats.sessionMessages, 0)
        XCTAssertEqual(stats.sessionPeers, 0)
        XCTAssertGreaterThan(stats.sessionDuration, 0)
    }
    
    func testSessionReset() {
        // Simulate some relay activity first
        let initialStats = meshService.getRelayStatistics()
        
        // Reset statistics
        meshService.resetRelayStatistics()
        
        let resetStats = meshService.getRelayStatistics()
        XCTAssertEqual(resetStats.totalMessages, 0)
        XCTAssertEqual(resetStats.totalPeers, 0)
        XCTAssertEqual(resetStats.sessionMessages, 0)
        XCTAssertEqual(resetStats.sessionPeers, 0)
        XCTAssertLessThan(resetStats.sessionDuration, initialStats.sessionDuration)
    }
    
    // MARK: - Statistics Persistence Tests
    
    func testStatisticsPersistence() {
        // Create a new service instance to test loading
        let service1 = BluetoothMeshService()
        
        // Get initial stats (should be 0)
        let initialStats = service1.getRelayStatistics()
        XCTAssertEqual(initialStats.totalMessages, 0)
        XCTAssertEqual(initialStats.totalPeers, 0)
        
        // Simulate saving some statistics by manually setting UserDefaults
        // (since we can't easily trigger actual relay events in unit tests)
        let defaults = UserDefaults.standard
        defaults.set(5, forKey: "bitchat.relayStats.totalMessages")
        defaults.set(3, forKey: "bitchat.relayStats.totalPeers")
        
        // Create a new service instance to test loading
        let service2 = BluetoothMeshService()
        let loadedStats = service2.getRelayStatistics()
        
        XCTAssertEqual(loadedStats.totalMessages, 5)
        XCTAssertEqual(loadedStats.totalPeers, 3)
    }
    
    // MARK: - Integration Test
    
    func testRelayStatisticsIntegration() {
        // Test that the /stats command works
        let chatViewModel = ChatViewModel()
        
        // Simulate sending /stats command
        let initialMessageCount = chatViewModel.messages.count
        chatViewModel.sendMessage("/stats")
        
        // Check that a system message was added
        XCTAssertEqual(chatViewModel.messages.count, initialMessageCount + 1)
        
        let lastMessage = chatViewModel.messages.last
        XCTAssertNotNil(lastMessage)
        XCTAssertEqual(lastMessage?.sender, "system")
        XCTAssertTrue(lastMessage?.content.contains("Relay statistics:") ?? false)
        XCTAssertTrue(lastMessage?.content.contains("total messages relayed:") ?? false)
        XCTAssertTrue(lastMessage?.content.contains("messages relayed:") ?? false)
    }
}
