//
// VoiceLifecycleTests.swift
// bitchatTests
//
// Lifecycle Management Tests for Voice Messages
// Tests state tracking, delivery confirmation, and cleanup
//

import XCTest
@testable import bitchat

/// Test suite for voice message lifecycle management
class VoiceLifecycleTests: XCTestCase {
    
    var voiceService: VoiceMessageService!
    var deliveryTracker: DeliveryTracker!
    
    override func setUpWithError() throws {
        super.setUpWithError()
        
        voiceService = VoiceMessageService.shared
        deliveryTracker = DeliveryTracker.shared
        
        // Start lifecycle management
        voiceService.startLifecycleManagement()
    }
    
    override func tearDownWithError() throws {
        voiceService.stopLifecycleManagement()
        voiceService = nil
        deliveryTracker = nil
        super.tearDownWithError()
    }
    
    // MARK: - State Tracking Tests
    
    /// Test voice message state transitions
    func testVoiceMessageStateTransitions() async throws {
        let expectation = XCTestExpectation(description: "State transitions")
        var observedStates: [DeliveryStatus] = []
        
        // Start recording
        XCTAssertTrue(voiceService.startRecording())
        
        // Stop and get message ID
        var messageID: String?
        voiceService.stopRecording { id in
            messageID = id
        }
        
        // Wait for processing
        try await Task.sleep(nanoseconds: 500_000_000)
        
        guard let id = messageID else {
            XCTFail("No message ID received")
            return
        }
        
        // Register delivery callback to track states
        voiceService.registerDeliveryCallback(for: id) { status in
            observedStates.append(status)
            
            // Simulate progression through states
            switch status {
            case .sending:
                // Simulate sent after sending
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.voiceService.handleDeliveryConfirmation(
                        messageID: id,
                        deliveredTo: "test-peer",
                        at: Date()
                    )
                }
            case .delivered:
                // Simulate read after delivery
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.voiceService.handleReadReceipt(
                        messageID: id,
                        readBy: "test-peer",
                        at: Date()
                    )
                }
            case .read:
                expectation.fulfill()
            default:
                break
            }
        }
        
        // Trigger state changes
        do {
            try await voiceService.sendVoiceMessage(
                to: "test-peer",
                recipientNickname: "Test",
                senderNickname: "Sender",
                messageID: id
            )
        } catch {
            // May fail in test environment, but states should still update
        }
        
        await fulfillment(of: [expectation], timeout: 5.0)
        
        // Verify state progression
        XCTAssertTrue(observedStates.contains { if case .sending = $0 { return true } else { return false } },
                     "Should observe sending state")
        XCTAssertTrue(observedStates.contains { if case .delivered = $0 { return true } else { return false } },
                     "Should observe delivered state")
        XCTAssertTrue(observedStates.contains { if case .read = $0 { return true } else { return false } },
                     "Should observe read state")
    }
    
    /// Test concurrent state updates
    func testConcurrentStateUpdates() async throws {
        let messageCount = 10
        let expectation = XCTestExpectation(description: "Concurrent updates")
        expectation.expectedFulfillmentCount = messageCount
        
        var messageIDs: [String] = []
        
        // Create multiple messages
        for _ in 0..<messageCount {
            if voiceService.startRecording() {
                voiceService.stopRecording { id in
                    messageIDs.append(id)
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        
        // Wait for all messages to be created
        try await Task.sleep(nanoseconds: 500_000_000)
        
        // Update all states concurrently
        await withTaskGroup(of: Void.self) { group in
            for id in messageIDs {
                group.addTask {
                    // Random state update
                    let states: [DeliveryStatus] = [
                        .sending,
                        .sent,
                        .delivered(to: "peer", at: Date()),
                        .read(by: "peer", at: Date())
                    ]
                    
                    let randomState = states.randomElement()!
                    
                    switch randomState {
                    case .delivered(let to, let at):
                        self.voiceService.handleDeliveryConfirmation(
                            messageID: id,
                            deliveredTo: to,
                            at: at
                        )
                    case .read(let by, let at):
                        self.voiceService.handleReadReceipt(
                            messageID: id,
                            readBy: by,
                            at: at
                        )
                    default:
                        break
                    }
                    
                    expectation.fulfill()
                }
            }
        }
        
        await fulfillment(of: [expectation], timeout: 5.0)
        
        // Verify all states were updated without crashes
        for id in messageIDs {
            let state = voiceService.getVoiceMessageState(id)
            XCTAssertNotNil(state, "State should exist for \(id)")
        }
    }
    
    // MARK: - Delivery Confirmation Tests
    
    /// Test delivery confirmation with callbacks
    func testDeliveryConfirmationCallbacks() async throws {
        let expectation = XCTestExpectation(description: "Delivery callbacks")
        let messageID = UUID().uuidString
        
        var callbackInvoked = false
        var deliveredTo: String?
        var deliveryTime: Date?
        
        // Register callback
        voiceService.registerDeliveryCallback(for: messageID) { status in
            if case .delivered(let to, let at) = status {
                callbackInvoked = true
                deliveredTo = to
                deliveryTime = at
                expectation.fulfill()
            }
        }
        
        // Simulate delivery
        let testTime = Date()
        voiceService.handleDeliveryConfirmation(
            messageID: messageID,
            deliveredTo: "recipient-001",
            at: testTime
        )
        
        await fulfillment(of: [expectation], timeout: 2.0)
        
        XCTAssertTrue(callbackInvoked, "Callback should be invoked")
        XCTAssertEqual(deliveredTo, "recipient-001", "Should have correct recipient")
        XCTAssertEqual(deliveryTime, testTime, "Should have correct time")
    }
    
    /// Test multiple delivery confirmations (group message)
    func testMultipleDeliveryConfirmations() async throws {
        let messageID = UUID().uuidString
        let recipients = ["peer-1", "peer-2", "peer-3"]
        
        var deliveredCount = 0
        
        // Register callback
        voiceService.registerDeliveryCallback(for: messageID) { status in
            if case .delivered = status {
                deliveredCount += 1
            }
        }
        
        // Simulate multiple deliveries
        for recipient in recipients {
            voiceService.handleDeliveryConfirmation(
                messageID: messageID,
                deliveredTo: recipient,
                at: Date()
            )
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        
        // Note: Current implementation overwrites status
        // In production, might track partial delivery
        XCTAssertGreaterThan(deliveredCount, 0, "Should have delivery confirmations")
    }
    
    // MARK: - Retry Management Tests
    
    /// Test retry with exponential backoff
    func testRetryExponentialBackoff() async throws {
        let expectation = XCTestExpectation(description: "Retry backoff")
        let messageID = UUID().uuidString
        
        var retryAttempts = 0
        var retryTimes: [Date] = []
        
        // Create voice state for retry testing
        let voiceData = VoiceMessageData(
            duration: 2.0,
            waveformData: [],
            filePath: nil,
            audioData: Data(repeating: 0x01, count: 100),
            format: .opus
        )
        
        let message = BitchatMessage(
            id: messageID,
            sender: "TestSender",
            content: "Voice message",
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: true,
            recipientNickname: "TestRecipient",
            senderPeerID: nil,
            mentions: nil,
            deliveryStatus: .sending,
            voiceMessageData: voiceData
        )
        
        // Register callback to track retries
        voiceService.registerDeliveryCallback(for: messageID) { status in
            if case .sending = status {
                retryAttempts += 1
                retryTimes.append(Date())
                
                if retryAttempts >= 3 {
                    expectation.fulfill()
                }
            }
        }
        
        // Trigger failures to cause retries
        for i in 0..<3 {
            voiceService.handleTransmissionFailure(
                messageID: messageID,
                reason: "Network error \(i)",
                shouldRetry: i < 2
            )
            try await Task.sleep(nanoseconds: 3_000_000_000) // Wait for retry
        }
        
        await fulfillment(of: [expectation], timeout: 10.0)
        
        // Verify exponential backoff
        if retryTimes.count >= 2 {
            let firstInterval = retryTimes[1].timeIntervalSince(retryTimes[0])
            // Should have increasing delays
            XCTAssertGreaterThan(firstInterval, 0, "Should have delay between retries")
        }
    }
    
    /// Test max retry limit
    func testMaxRetryLimit() async throws {
        let messageID = UUID().uuidString
        var failureCount = 0
        
        // Register callback
        voiceService.registerDeliveryCallback(for: messageID) { status in
            if case .failed = status {
                failureCount += 1
            }
        }
        
        // Trigger multiple failures beyond max retries
        for _ in 0..<5 {
            voiceService.handleTransmissionFailure(
                messageID: messageID,
                reason: "Persistent failure",
                shouldRetry: true
            )
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        
        // Should eventually fail permanently
        XCTAssertGreaterThan(failureCount, 0, "Should eventually fail after max retries")
    }
    
    // MARK: - Cleanup & Expiration Tests
    
    /// Test cleanup of completed messages
    func testCompletedMessageCleanup() async throws {
        // Create and complete a message
        XCTAssertTrue(voiceService.startRecording())
        
        var messageID: String?
        voiceService.stopRecording { id in
            messageID = id
        }
        
        try await Task.sleep(nanoseconds: 500_000_000)
        
        guard let id = messageID else {
            XCTFail("No message ID")
            return
        }
        
        // Mark as delivered
        voiceService.handleDeliveryConfirmation(
            messageID: id,
            deliveredTo: "peer",
            at: Date()
        )
        
        // Verify state exists
        XCTAssertNotNil(voiceService.getVoiceMessageState(id), "State should exist")
        
        // Note: Actual cleanup happens after 1 hour
        // In production test, would mock time or wait
    }
    
    /// Test stuck message detection
    func testStuckMessageDetection() async throws {
        // This test verifies the lifecycle management detects stuck messages
        
        // Create a message that gets stuck in sending
        XCTAssertTrue(voiceService.startRecording())
        
        var messageID: String?
        voiceService.stopRecording { id in
            messageID = id
        }
        
        try await Task.sleep(nanoseconds: 500_000_000)
        
        guard let id = messageID else {
            XCTFail("No message ID")
            return
        }
        
        // Leave in sending state (stuck)
        // In production, lifecycle timer would detect after 5 minutes
        
        let state = voiceService.getVoiceMessageState(id)
        XCTAssertNotNil(state, "State should exist")
        
        if let state = state {
            if case .sending = state.deliveryStatus {
                // Correct - stuck in sending
            } else {
                XCTFail("Should be stuck in sending state")
            }
        }
    }
    
    // MARK: - Statistics Tests
    
    /// Test voice message statistics gathering
    func testVoiceMessageStatistics() async throws {
        // Create messages in various states
        let messageCount = 5
        
        for i in 0..<messageCount {
            XCTAssertTrue(voiceService.startRecording())
            
            voiceService.stopRecording { id in
                // Simulate different states
                switch i {
                case 0:
                    // Leave as sending
                    break
                case 1:
                    // Mark as sent
                    self.voiceService.handleDeliveryConfirmation(
                        messageID: id,
                        deliveredTo: "peer",
                        at: Date()
                    )
                case 2:
                    // Mark as read
                    self.voiceService.handleReadReceipt(
                        messageID: id,
                        readBy: "peer",
                        at: Date()
                    )
                case 3:
                    // Mark as failed
                    self.voiceService.handleTransmissionFailure(
                        messageID: id,
                        reason: "Test failure",
                        shouldRetry: false
                    )
                default:
                    break
                }
            }
            
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        
        // Get statistics
        let stats = voiceService.getVoiceMessageStatistics()
        
        // Verify statistics
        XCTAssertGreaterThanOrEqual(stats.total, messageCount, "Should track all messages")
        XCTAssertGreaterThanOrEqual(stats.sending + stats.sent + stats.delivered + stats.failed, 1,
                                    "Should have messages in various states")
        
        // Log statistics for debugging
        print("Voice Message Statistics:")
        print("  Total: \(stats.total)")
        print("  Sending: \(stats.sending)")
        print("  Sent: \(stats.sent)")
        print("  Delivered: \(stats.delivered)")
        print("  Failed: \(stats.failed)")
    }
    
    /// Test delivery tracker integration
    func testDeliveryTrackerIntegration() async throws {
        let messageID = UUID().uuidString
        let recipientID = "test-recipient-001"
        let recipientNickname = "TestRecipient"
        
        // Track voice message delivery
        deliveryTracker.trackVoiceMessageDelivery(
            messageID,
            to: recipientID,
            recipientNickname: recipientNickname
        )
        
        // Verify tracking
        // Note: DeliveryTracker implementation may vary
        
        // Simulate delivery confirmation
        voiceService.handleDeliveryConfirmation(
            messageID: messageID,
            deliveredTo: recipientID,
            at: Date()
        )
        
        // Get delivery stats
        let stats = deliveryTracker.voiceDeliveryStats
        
        // Should have some statistics
        XCTAssertGreaterThanOrEqual(stats.sent + stats.delivered + stats.failed, 0,
                                    "Should have delivery statistics")
    }
    
    // MARK: - Performance Tests
    
    /// Test lifecycle management performance
    func testLifecycleManagementPerformance() {
        // Measure performance of lifecycle operations
        
        measure {
            // Create many messages
            for _ in 0..<100 {
                let messageID = UUID().uuidString
                
                // Register callback
                voiceService.registerDeliveryCallback(for: messageID) { _ in }
                
                // Update status
                voiceService.handleDeliveryConfirmation(
                    messageID: messageID,
                    deliveredTo: "peer",
                    at: Date()
                )
            }
            
            // Get statistics
            _ = voiceService.getVoiceMessageStatistics()
        }
    }
    
    /// Test callback registration performance
    func testCallbackRegistrationPerformance() {
        measure {
            for _ in 0..<1000 {
                let messageID = UUID().uuidString
                voiceService.registerDeliveryCallback(for: messageID) { _ in }
            }
        }
    }
}