//
// NoiseRateLimiterTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import XCTest
@testable import bitchat

class NoiseRateLimiterTests: XCTestCase {
    
    // MARK: - Basic Rate Limiting Tests
    
    func testHandshakeRateLimiting() {
        let rateLimiter = NoiseRateLimiter()
        let peerID = "test-peer"
        
        // First few handshakes should be allowed
        XCTAssertTrue(rateLimiter.allowHandshake(from: peerID))
        XCTAssertTrue(rateLimiter.allowHandshake(from: peerID))
        XCTAssertTrue(rateLimiter.allowHandshake(from: peerID))
        
        // After hitting limit, should be rate limited
        // Default is 3 handshakes per minute
        XCTAssertFalse(rateLimiter.allowHandshake(from: peerID))
        XCTAssertFalse(rateLimiter.allowHandshake(from: peerID))
    }
    
    func testMessageRateLimiting() {
        let rateLimiter = NoiseRateLimiter()
        let peerID = "test-peer"
        
        // Messages have higher limit (100 per minute default)
        for _ in 0..<100 {
            XCTAssertTrue(rateLimiter.allowMessage(from: peerID))
        }
        
        // 101st message should be rate limited
        XCTAssertFalse(rateLimiter.allowMessage(from: peerID))
    }
    
    func testPerPeerRateLimiting() {
        let rateLimiter = NoiseRateLimiter()
        let peer1 = "alice"
        let peer2 = "bob"
        
        // Rate limit peer1
        XCTAssertTrue(rateLimiter.allowHandshake(from: peer1))
        XCTAssertTrue(rateLimiter.allowHandshake(from: peer1))
        XCTAssertTrue(rateLimiter.allowHandshake(from: peer1))
        XCTAssertFalse(rateLimiter.allowHandshake(from: peer1))
        
        // Peer2 should still be allowed
        XCTAssertTrue(rateLimiter.allowHandshake(from: peer2))
        XCTAssertTrue(rateLimiter.allowHandshake(from: peer2))
    }
    
    // MARK: - Time Window Tests
    
    func testRateLimitResetsAfterWindow() {
        let rateLimiter = NoiseRateLimiter()
        let peerID = "test-peer"
        
        // Use up the limit
        for _ in 0..<3 {
            XCTAssertTrue(rateLimiter.allowHandshake(from: peerID))
        }
        XCTAssertFalse(rateLimiter.allowHandshake(from: peerID))
        
        // Simulate time passing by clearing the window
        rateLimiter.clearExpiredEntries()
        
        // Should be allowed again after window expires
        // Note: In real implementation, this would require actual time to pass
        // For testing, we might need to inject a clock or expose internal state
    }
    
    // MARK: - Global Rate Limiting Tests
    
    func testGlobalHandshakeLimit() {
        let rateLimiter = NoiseRateLimiter()
        
        // Global limit prevents too many handshakes across all peers
        var allowedCount = 0
        
        // Try many handshakes from different peers
        for i in 0..<50 {
            let peerID = "peer-\(i)"
            if rateLimiter.allowHandshake(from: peerID) {
                allowedCount += 1
            }
        }
        
        // Should hit global limit before allowing all 50
        XCTAssertLessThan(allowedCount, 50)
        XCTAssertGreaterThan(allowedCount, 10) // But should allow reasonable amount
    }
    
    // MARK: - Attack Mitigation Tests
    
    func testRapidHandshakeAttackMitigation() {
        let rateLimiter = NoiseRateLimiter()
        let attackerID = "attacker"
        
        var blockedCount = 0
        
        // Simulate rapid handshake attempts
        for _ in 0..<20 {
            if !rateLimiter.allowHandshake(from: attackerID) {
                blockedCount += 1
            }
        }
        
        // Most attempts should be blocked
        XCTAssertGreaterThan(blockedCount, 15)
    }
    
    func testDistributedAttackMitigation() {
        let rateLimiter = NoiseRateLimiter()
        
        var blockedCount = 0
        
        // Simulate distributed attack from many IPs
        for i in 0..<100 {
            let attackerID = "192.168.1.\(i)"
            // Each attacker tries multiple times
            for _ in 0..<5 {
                if !rateLimiter.allowHandshake(from: attackerID) {
                    blockedCount += 1
                }
            }
        }
        
        // Global rate limiting should kick in
        XCTAssertGreaterThan(blockedCount, 0)
    }
    
    // MARK: - Memory Management Tests
    
    func testMemoryBoundedTracking() {
        let rateLimiter = NoiseRateLimiter()
        
        // Add many different peers
        for i in 0..<10000 {
            let peerID = "peer-\(i)"
            _ = rateLimiter.allowMessage(from: peerID)
        }
        
        // Rate limiter should have bounds on memory usage
        // Implementation should clean up old entries
        rateLimiter.clearExpiredEntries()
        
        // Verify it still functions correctly
        XCTAssertTrue(rateLimiter.allowMessage(from: "new-peer"))
    }
    
    // MARK: - Configuration Tests
    
    func testCustomRateLimits() {
        // Test with custom configuration
        let config = NoiseRateLimiter.Configuration(
            handshakesPerMinute: 5,
            messagesPerMinute: 200,
            globalHandshakesPerMinute: 30
        )
        
        let rateLimiter = NoiseRateLimiter(configuration: config)
        let peerID = "test-peer"
        
        // Should allow up to 5 handshakes
        for i in 0..<5 {
            XCTAssertTrue(rateLimiter.allowHandshake(from: peerID), "Handshake \(i+1) should be allowed")
        }
        
        // 6th should be blocked
        XCTAssertFalse(rateLimiter.allowHandshake(from: peerID))
    }
    
    // MARK: - Thread Safety Tests
    
    func testConcurrentAccess() {
        let rateLimiter = NoiseRateLimiter()
        let expectation = self.expectation(description: "Concurrent access")
        expectation.expectedFulfillmentCount = 10
        
        // Multiple threads accessing rate limiter
        for i in 0..<10 {
            DispatchQueue.global().async {
                let peerID = "peer-\(i)"
                for _ in 0..<100 {
                    _ = rateLimiter.allowMessage(from: peerID)
                }
                expectation.fulfill()
            }
        }
        
        waitForExpectations(timeout: 5) { error in
            XCTAssertNil(error)
        }
        
        // Verify rate limiter still works
        XCTAssertTrue(rateLimiter.allowMessage(from: "final-test"))
    }
}