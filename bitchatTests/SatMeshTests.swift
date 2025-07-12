//
// SatMeshTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import XCTest
@testable import bitchat

class SatMeshTests: XCTestCase {
    
    var satMeshService: SatMeshIntegrationService!
    var emergencySystem: EmergencyBroadcastSystem!
    var routingEngine: MultiPathRoutingEngine!
    var bandwidthOptimizer: BandwidthOptimizer!
    var queueService: SatelliteQueueService!
    
    override func setUpWithError() throws {
        super.setUp()
        
        satMeshService = SatMeshIntegrationService.shared
        emergencySystem = EmergencyBroadcastSystem.shared
        routingEngine = MultiPathRoutingEngine.shared
        bandwidthOptimizer = BandwidthOptimizer.shared
        queueService = SatelliteQueueService.shared
    }
    
    override func tearDownWithError() throws {
        // Clean up test data
        satMeshService.clearAllData()
        super.tearDown()
    }
    
    // MARK: - Emergency Broadcasting Tests
    
    func testEmergencySOS() throws {
        // Test SOS functionality
        let expectation = XCTestExpectation(description: "SOS sent")
        
        // Mock delegate to capture SOS
        let mockDelegate = MockSatMeshDelegate()
        mockDelegate.sosSentExpectation = expectation
        satMeshService.delegate = mockDelegate
        
        // Send SOS
        satMeshService.sendSOS()
        
        wait(for: [expectation], timeout: 5.0)
        
        // Verify emergency was created
        let activeEmergencies = satMeshService.getActiveEmergencies()
        XCTAssertEqual(activeEmergencies.count, 1)
        
        let emergency = activeEmergencies.first!
        XCTAssertEqual(emergency.emergencyType, .sos)
        XCTAssertEqual(emergency.content, "SOS - Need immediate assistance")
    }
    
    func testEmergencyMessage() throws {
        // Test custom emergency message
        let emergency = EmergencyMessage(
            emergencyType: .medical,
            senderID: "test-user",
            senderNickname: "TestUser",
            content: "Need medical assistance",
            location: LocationData(
                latitude: 37.7749,
                longitude: -122.4194,
                accuracy: 10.0,
                altitude: nil,
                timestamp: Date()
            )
        )
        
        satMeshService.sendEmergencyMessage(emergency)
        
        // Verify emergency was broadcast
        let activeEmergencies = satMeshService.getActiveEmergencies()
        XCTAssertEqual(activeEmergencies.count, 1)
        
        let broadcastEmergency = activeEmergencies.first!
        XCTAssertEqual(broadcastEmergency.emergencyType, .medical)
        XCTAssertEqual(broadcastEmergency.content, "Need medical assistance")
        XCTAssertNotNil(broadcastEmergency.location)
    }
    
    func testEmergencyContactManagement() throws {
        // Test emergency contact functionality
        let contact = EmergencyContact(
            id: "test-contact",
            name: "Emergency Contact",
            phone: "123-456-7890",
            email: "emergency@test.com",
            relationship: "Family",
            isPrimary: true,
            location: nil,
            lastSeen: nil,
            status: .available
        )
        
        satMeshService.addEmergencyContact(contact)
        
        let contacts = satMeshService.getEmergencyContacts()
        XCTAssertEqual(contacts.count, 1)
        
        let savedContact = contacts.first!
        XCTAssertEqual(savedContact.name, "Emergency Contact")
        XCTAssertEqual(savedContact.phone, "123-456-7890")
        XCTAssertTrue(savedContact.isPrimary)
    }
    
    // MARK: - Global Messaging Tests
    
    func testGlobalMessage() throws {
        // Test global message sending
        let message = BitchatMessage(
            sender: "TestUser",
            content: "Hello world from satellite!",
            timestamp: Date(),
            isRelay: false,
            senderPeerID: "test-user"
        )
        
        satMeshService.sendGlobalMessage(message, priority: 1)
        
        // Verify message was queued
        let queueStatus = satMeshService.getQueueStatus()
        XCTAssertGreaterThan(queueStatus.normal, 0)
    }
    
    func testGlobalMessagePriority() throws {
        // Test different priority levels
        let message = BitchatMessage(
            sender: "TestUser",
            content: "High priority message",
            timestamp: Date(),
            isRelay: false,
            senderPeerID: "test-user"
        )
        
        // High priority
        satMeshService.sendGlobalMessage(message, priority: 2)
        
        let queueStatus = satMeshService.getQueueStatus()
        XCTAssertGreaterThan(queueStatus.high, 0)
        
        // Emergency priority
        satMeshService.sendGlobalMessage(message, priority: 3)
        
        let updatedQueueStatus = satMeshService.getQueueStatus()
        XCTAssertGreaterThan(updatedQueueStatus.emergency, 0)
    }
    
    // MARK: - Routing Tests
    
    func testRoutingDecision() throws {
        // Test routing decision making
        let request = RoutingRequest(
            messageID: "test-message",
            senderID: "test-user",
            recipientID: nil,
            messageType: .global,
            priority: 1,
            size: 100,
            maxLatency: 60.0,
            minReliability: 0.8,
            maxCost: 1.0,
            timestamp: Date()
        )
        
        let decision = routingEngine.routeMessage(request)
        
        // Verify routing decision was made
        XCTAssertNotNil(decision)
        XCTAssertEqual(decision.requestID, "test-message")
        XCTAssertNotNil(decision.routingStrategy)
    }
    
    func testEmergencyRouting() throws {
        // Test emergency routing bypass
        let request = RoutingRequest(
            messageID: "emergency-message",
            senderID: "test-user",
            recipientID: nil,
            messageType: .emergency,
            priority: 3,
            size: 50,
            maxLatency: 10.0,
            minReliability: 0.95,
            maxCost: 10.0,
            timestamp: Date()
        )
        
        let decision = routingEngine.routeMessage(request)
        
        // Verify emergency routing strategy
        XCTAssertEqual(decision.routingStrategy, .emergencyBypass)
        XCTAssertGreaterThan(decision.confidence, 0.8)
    }
    
    // MARK: - Bandwidth Optimization Tests
    
    func testMessageCompression() throws {
        // Test message compression
        let testData = "This is a test message that should be compressed for satellite transmission. It contains repeated patterns and should compress well.".data(using: .utf8)!
        
        let optimizedMessage = bandwidthOptimizer.optimizeMessage(testData, priority: 1)
        
        XCTAssertNotNil(optimizedMessage)
        XCTAssertLessThan(optimizedMessage!.compressedMessage.count, testData.count)
        XCTAssertGreaterThan(optimizedMessage!.compressionStats.compressionRatio, 0.0)
        XCTAssertLessThan(optimizedMessage!.compressionStats.compressionRatio, 1.0)
    }
    
    func testCompressionStrategies() throws {
        // Test different compression strategies
        let testData = "Test message for compression strategy testing".data(using: .utf8)!
        
        // Maximum compression
        bandwidthOptimizer.setOptimizationStrategy(.maximumCompression)
        let maxCompressed = bandwidthOptimizer.optimizeMessage(testData, priority: 1)
        
        // Minimum latency
        bandwidthOptimizer.setOptimizationStrategy(.minimumLatency)
        let minLatency = bandwidthOptimizer.optimizeMessage(testData, priority: 1)
        
        // Both should compress the data
        XCTAssertNotNil(maxCompressed)
        XCTAssertNotNil(minLatency)
    }
    
    // MARK: - Queue Management Tests
    
    func testMessageQueuing() throws {
        // Test message queuing functionality
        let messageData = "Test queued message".data(using: .utf8)!
        
        let queuedMessage = QueuedMessage(
            messageData: messageData,
            priority: .normal,
            senderID: "test-user",
            messageType: "test",
            estimatedCost: 0.01,
            compressionRatio: 0.8,
            isEmergency: false
        )
        
        queueService.enqueueMessage(queuedMessage)
        
        let queueStatus = queueService.getQueueStatus()
        XCTAssertEqual(queueStatus.normal, 1)
    }
    
    func testPriorityQueuing() throws {
        // Test priority-based queuing
        let messageData = "Priority test message".data(using: .utf8)!
        
        // Emergency priority
        let emergencyMessage = QueuedMessage(
            messageData: messageData,
            priority: .emergency,
            senderID: "test-user",
            messageType: "emergency",
            estimatedCost: 0.0,
            compressionRatio: 1.0,
            isEmergency: true
        )
        
        // Normal priority
        let normalMessage = QueuedMessage(
            messageData: messageData,
            priority: .normal,
            senderID: "test-user",
            messageType: "normal",
            estimatedCost: 0.01,
            compressionRatio: 0.8,
            isEmergency: false
        )
        
        queueService.enqueueMessage(emergencyMessage)
        queueService.enqueueMessage(normalMessage)
        
        let queueStatus = queueService.getQueueStatus()
        XCTAssertEqual(queueStatus.emergency, 1)
        XCTAssertEqual(queueStatus.normal, 1)
    }
    
    // MARK: - Configuration Tests
    
    func testConfigurationUpdate() throws {
        // Test configuration management
        let newConfig = SatMeshConfig(
            enableSatellite: true,
            enableEmergencyBroadcast: true,
            enableGlobalRouting: true,
            maxMessageSize: 1000,
            compressionEnabled: true,
            costLimit: 5.0,
            preferredSatellite: "starlink"
        )
        
        satMeshService.updateConfiguration(newConfig)
        
        let currentConfig = satMeshService.config
        XCTAssertEqual(currentConfig.maxMessageSize, 1000)
        XCTAssertEqual(currentConfig.costLimit, 5.0)
        XCTAssertEqual(currentConfig.preferredSatellite, "starlink")
    }
    
    func testConfigurationReset() throws {
        // Test configuration reset
        let originalConfig = satMeshService.config
        
        // Change configuration
        var modifiedConfig = originalConfig
        modifiedConfig.maxMessageSize = 2000
        modifiedConfig.costLimit = 20.0
        satMeshService.updateConfiguration(modifiedConfig)
        
        // Reset to defaults
        satMeshService.config = SatMeshConfig.default
        satMeshService.updateConfiguration(satMeshService.config)
        
        let resetConfig = satMeshService.config
        XCTAssertEqual(resetConfig.maxMessageSize, SatMeshConfig.default.maxMessageSize)
        XCTAssertEqual(resetConfig.costLimit, SatMeshConfig.default.costLimit)
    }
    
    // MARK: - Integration Tests
    
    func testEndToEndEmergencyFlow() throws {
        // Test complete emergency flow
        let expectation = XCTestExpectation(description: "Emergency flow completed")
        
        // Create emergency
        let emergency = EmergencyMessage(
            emergencyType: .medical,
            senderID: "test-user",
            senderNickname: "TestUser",
            content: "Medical emergency test",
            location: LocationData(
                latitude: 37.7749,
                longitude: -122.4194,
                accuracy: 10.0,
                altitude: nil,
                timestamp: Date()
            )
        )
        
        // Send emergency
        satMeshService.sendEmergencyMessage(emergency)
        
        // Verify emergency was created
        let activeEmergencies = satMeshService.getActiveEmergencies()
        XCTAssertEqual(activeEmergencies.count, 1)
        
        // Simulate emergency response
        let responder = EmergencyResponder(
            id: "responder-1",
            responderID: "emergency-services",
            responderNickname: "Emergency Services",
            responderType: .emergencyServices,
            location: nil,
            estimatedArrivalTime: 300.0,
            capabilities: [.medicalAid, .rescue],
            contactInfo: nil,
            timestamp: Date()
        )
        
        emergencySystem.acknowledgeEmergency(emergency, responder: responder)
        
        // Verify acknowledgment
        let updatedEmergencies = satMeshService.getActiveEmergencies()
        XCTAssertEqual(updatedEmergencies.count, 1)
        XCTAssertEqual(updatedEmergencies.first!.acknowledgmentCount, 1)
        
        expectation.fulfill()
        wait(for: [expectation], timeout: 10.0)
    }
    
    func testEndToEndGlobalMessagingFlow() throws {
        // Test complete global messaging flow
        let expectation = XCTestExpectation(description: "Global messaging flow completed")
        
        // Create global message
        let message = BitchatMessage(
            sender: "TestUser",
            content: "Global message test",
            timestamp: Date(),
            isRelay: false,
            senderPeerID: "test-user"
        )
        
        // Send global message
        satMeshService.sendGlobalMessage(message, priority: 1)
        
        // Verify message was queued
        let queueStatus = satMeshService.getQueueStatus()
        XCTAssertGreaterThan(queueStatus.normal, 0)
        
        // Check bandwidth optimization
        let bandwidthStats = satMeshService.getBandwidthStats()
        XCTAssertGreaterThanOrEqual(bandwidthStats.totalBytesSaved, 0)
        
        // Check routing statistics
        let routingStats = satMeshService.getRoutingStats()
        XCTAssertGreaterThanOrEqual(routingStats.totalMessagesRouted, 0)
        
        expectation.fulfill()
        wait(for: [expectation], timeout: 10.0)
    }
}

// MARK: - Mock Delegate

class MockSatMeshDelegate: SatMeshIntegrationServiceDelegate {
    var sosSentExpectation: XCTestExpectation?
    var emergencyReceivedExpectation: XCTestExpectation?
    var globalMessageReceivedExpectation: XCTestExpectation?
    
    func satMeshStatusChanged(_ status: SatMeshStatus) {
        // Handle status changes
    }
    
    func satMeshStatsUpdated(_ stats: SatMeshStats) {
        // Handle stats updates
    }
    
    func didReceiveGlobalMessage(_ message: BitchatMessage) {
        globalMessageReceivedExpectation?.fulfill()
    }
    
    func didReceiveEmergencyBroadcast(_ emergency: EmergencyMessage) {
        emergencyReceivedExpectation?.fulfill()
    }
    
    func satelliteConnectionChanged(_ isConnected: Bool) {
        // Handle connection changes
    }
    
    func routingDecisionMade(_ decision: RoutingDecision) {
        // Handle routing decisions
    }
}

// MARK: - Performance Tests

extension SatMeshTests {
    
    func testCompressionPerformance() throws {
        // Test compression performance
        let largeData = String(repeating: "This is a test message for performance testing. ", count: 1000).data(using: .utf8)!
        
        measure {
            for _ in 0..<100 {
                _ = bandwidthOptimizer.optimizeMessage(largeData, priority: 1)
            }
        }
    }
    
    func testRoutingPerformance() throws {
        // Test routing performance
        let request = RoutingRequest(
            messageID: "perf-test",
            senderID: "test-user",
            recipientID: nil,
            messageType: .global,
            priority: 1,
            size: 100,
            maxLatency: 60.0,
            minReliability: 0.8,
            maxCost: 1.0,
            timestamp: Date()
        )
        
        measure {
            for _ in 0..<1000 {
                _ = routingEngine.routeMessage(request)
            }
        }
    }
    
    func testQueuePerformance() throws {
        // Test queue performance
        let messageData = "Performance test message".data(using: .utf8)!
        
        measure {
            for i in 0..<1000 {
                let message = QueuedMessage(
                    messageData: messageData,
                    priority: .normal,
                    senderID: "test-user-\(i)",
                    messageType: "perf-test",
                    estimatedCost: 0.01,
                    compressionRatio: 0.8,
                    isEmergency: false
                )
                queueService.enqueueMessage(message)
            }
        }
    }
} 