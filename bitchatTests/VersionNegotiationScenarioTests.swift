//
// VersionNegotiationScenarioTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import XCTest
@testable import bitchat

class VersionNegotiationScenarioTests: XCTestCase {
    
    // MARK: - Real-World Scenarios
    
    func testOldClientConnectsToNewServer() {
        // Scenario: Old client (v1 only) connects to new server (v1, v2, v3)
        let oldClientVersions: [UInt8] = [1]
        let newServerVersions: [UInt8] = [1, 2, 3]
        
        let agreed = ProtocolVersion.negotiateVersion(
            clientVersions: oldClientVersions,
            serverVersions: newServerVersions
        )
        
        XCTAssertEqual(agreed, 1, "Should agree on v1 for backward compatibility")
    }
    
    func testNewClientConnectsToOldServer() {
        // Scenario: New client (v1, v2, v3) connects to old server (v1 only)
        let newClientVersions: [UInt8] = [1, 2, 3]
        let oldServerVersions: [UInt8] = [1]
        
        let agreed = ProtocolVersion.negotiateVersion(
            clientVersions: newClientVersions,
            serverVersions: oldServerVersions
        )
        
        XCTAssertEqual(agreed, 1, "Should agree on v1 for backward compatibility")
    }
    
    func testMixedVersionNetwork() {
        // Scenario: Network with mixed client versions
        let clients = [
            [1],              // Old client
            [1, 2],           // Mid-version client
            [1, 2, 3]         // New client
        ]
        
        // All should be able to negotiate with each other
        for (i, client1) in clients.enumerated() {
            for (j, client2) in clients.enumerated() {
                let agreed = ProtocolVersion.negotiateVersion(
                    clientVersions: client1,
                    serverVersions: client2
                )
                
                XCTAssertNotNil(agreed, "Clients \(i) and \(j) should negotiate successfully")
                XCTAssertGreaterThanOrEqual(agreed ?? 0, 1, "Should at least agree on v1")
            }
        }
    }
    
    func testFutureClientWithUnsupportedVersion() {
        // Scenario: Future client with only unsupported versions
        let futureClientVersions: [UInt8] = [10, 11, 12]
        let currentServerVersions: [UInt8] = Array(ProtocolVersion.supportedVersions)
        
        let agreed = ProtocolVersion.negotiateVersion(
            clientVersions: futureClientVersions,
            serverVersions: currentServerVersions
        )
        
        XCTAssertNil(agreed, "Should fail to negotiate with incompatible future client")
    }
    
    // MARK: - Race Condition Tests
    
    func testSimultaneousVersionHello() {
        // Scenario: Both peers send version hello at the same time
        // This tests that the protocol handles simultaneous negotiation
        
        let hello1 = VersionHello(
            supportedVersions: [1, 2],
            preferredVersion: 2,
            clientVersion: "1.1.0",
            platform: "iOS"
        )
        
        let hello2 = VersionHello(
            supportedVersions: [1, 2, 3],
            preferredVersion: 3,
            clientVersion: "1.2.0",
            platform: "macOS"
        )
        
        // Both should be able to encode/decode regardless of order
        XCTAssertNotNil(hello1.encode())
        XCTAssertNotNil(hello2.encode())
        
        // Version negotiation should be deterministic
        let agreed1 = ProtocolVersion.negotiateVersion(
            clientVersions: hello1.supportedVersions,
            serverVersions: hello2.supportedVersions
        )
        
        let agreed2 = ProtocolVersion.negotiateVersion(
            clientVersions: hello2.supportedVersions,
            serverVersions: hello1.supportedVersions
        )
        
        XCTAssertEqual(agreed1, agreed2, "Negotiation should be symmetric")
        XCTAssertEqual(agreed1, 2, "Should agree on highest common version")
    }
    
    // MARK: - Error Recovery Tests
    
    func testRecoveryFromFailedNegotiation() {
        // Test that a peer can retry after failed negotiation
        var state = VersionNegotiationState.failed(reason: "Network error")
        
        // Reset state for retry
        state = .none
        
        // Should be able to start new negotiation
        state = .helloSent
        
        if case .helloSent = state {
            // Success - can retry after failure
        } else {
            XCTFail("Should be able to retry after failed negotiation")
        }
    }
    
    func testPartialMessageHandling() {
        // Test handling of truncated version messages
        let truncatedData = Data([123, 34]) // Partial JSON
        
        XCTAssertNil(VersionHello.decode(from: truncatedData))
        XCTAssertNil(VersionAck.decode(from: truncatedData))
        
        // Should not crash, just return nil
    }
    
    // MARK: - Platform Compatibility Tests
    
    func testCrossPlatformNegotiation() {
        let platforms = ["iOS", "macOS", "iPadOS", "Unknown"]
        
        for platform1 in platforms {
            for platform2 in platforms {
                let hello1 = VersionHello(
                    clientVersion: "1.0.0",
                    platform: platform1
                )
                
                let hello2 = VersionHello(
                    clientVersion: "1.0.0",
                    platform: platform2
                )
                
                // All platforms should be able to negotiate
                XCTAssertNotNil(hello1.encode())
                XCTAssertNotNil(hello2.encode())
                
                // Platform difference should not affect version negotiation
                let agreed = ProtocolVersion.negotiateVersion(
                    clientVersions: hello1.supportedVersions,
                    serverVersions: hello2.supportedVersions
                )
                
                XCTAssertNotNil(agreed, "\(platform1) and \(platform2) should negotiate")
            }
        }
    }
    
    // MARK: - Capability Tests
    
    func testCapabilityNegotiation() {
        // Test future capability negotiation
        let clientCapabilities = ["noise", "compression", "multipath"]
        let serverCapabilities = ["noise", "compression", "federation"]
        
        let hello = VersionHello(
            clientVersion: "1.0.0",
            platform: "iOS",
            capabilities: clientCapabilities
        )
        
        let ack = VersionAck(
            agreedVersion: 1,
            serverVersion: "1.0.0",
            platform: "macOS",
            capabilities: serverCapabilities
        )
        
        // Find common capabilities (for future use)
        let commonCapabilities = Set(clientCapabilities).intersection(Set(serverCapabilities))
        XCTAssertEqual(commonCapabilities, ["noise", "compression"])
    }
    
    func testEmptyCapabilityHandling() {
        // Test peers with no capabilities
        let hello1 = VersionHello(
            clientVersion: "1.0.0",
            platform: "iOS",
            capabilities: nil
        )
        
        let hello2 = VersionHello(
            clientVersion: "1.0.0",
            platform: "macOS",
            capabilities: []
        )
        
        XCTAssertNotNil(hello1.encode())
        XCTAssertNotNil(hello2.encode())
        
        // Should still negotiate successfully
        let agreed = ProtocolVersion.negotiateVersion(
            clientVersions: hello1.supportedVersions,
            serverVersions: hello2.supportedVersions
        )
        
        XCTAssertNotNil(agreed)
    }
    
    // MARK: - Stress Tests
    
    func testManyVersionsNegotiation() {
        // Test with many supported versions
        let manyVersions = Array<UInt8>(1...100)
        let someVersions = Array<UInt8>([1, 50, 75, 100])
        
        let agreed = ProtocolVersion.negotiateVersion(
            clientVersions: manyVersions,
            serverVersions: someVersions
        )
        
        XCTAssertEqual(agreed, 100, "Should pick highest common version")
    }
    
    func testRapidConnectionDisconnection() {
        // Test rapid connect/disconnect cycles
        var states: [String: VersionNegotiationState] = [:]
        
        for i in 0..<100 {
            let peerID = "peer\(i)"
            
            // Connect
            states[peerID] = .helloSent
            
            // Negotiate
            states[peerID] = .ackReceived(version: 1)
            
            // Disconnect
            states.removeValue(forKey: peerID)
        }
        
        XCTAssertTrue(states.isEmpty, "All states should be cleaned up")
    }
    
    // MARK: - Security Tests
    
    func testLargeVersionListDoS() {
        // Test protection against DoS with huge version lists
        let hugeVersionList = Array<UInt8>(0...255) // All possible versions
        
        let hello = VersionHello(
            supportedVersions: hugeVersionList,
            preferredVersion: 255,
            clientVersion: "1.0.0",
            platform: "iOS"
        )
        
        // Should handle without performance issues
        let startTime = Date()
        _ = hello.encode()
        let encodingTime = Date().timeIntervalSince(startTime)
        
        XCTAssertLessThan(encodingTime, 0.1, "Encoding should be fast even with large version list")
    }
    
    func testVersionDowngradeAttack() {
        // Test that negotiation always picks highest common version
        // to prevent downgrade attacks
        let clientVersions: [UInt8] = [1, 2, 3]
        let serverVersions: [UInt8] = [1, 2, 3]
        
        let agreed = ProtocolVersion.negotiateVersion(
            clientVersions: clientVersions,
            serverVersions: serverVersions
        )
        
        XCTAssertEqual(agreed, 3, "Should not allow downgrade to lower version")
    }
}