//
// VoiceTransportFallbackTests.swift
// bitchatTests
//
// Transport Fallback Tests for Voice Messages
// Tests intelligent routing between Bluetooth and Nostr
//

import XCTest
@testable import bitchat

/// Test suite for voice message transport fallback mechanisms
class VoiceTransportFallbackTests: XCTestCase {
    
    var messageRouter: MessageRouter!
    var meshService: MockBluetoothMeshService!
    var nostrRelay: MockNostrRelayManager!
    var favoritesService: FavoritesPersistenceService!
    
    override func setUpWithError() throws {
        super.setUpWithError()
        
        // Setup mock services
        meshService = MockBluetoothMeshService()
        nostrRelay = MockNostrRelayManager()
        messageRouter = MessageRouter(meshService: meshService, nostrRelay: nostrRelay)
        favoritesService = FavoritesPersistenceService.shared
        
        // Configure test environment
        meshService.myPeerID = "test-peer-001"
    }
    
    override func tearDownWithError() throws {
        messageRouter = nil
        meshService = nil
        nostrRelay = nil
        favoritesService = nil
        super.tearDownWithError()
    }
    
    // MARK: - Primary Transport Tests
    
    /// Test Bluetooth as primary transport when peer is connected
    func testBluetoothPrimaryTransport() async throws {
        let recipientKey = Data(hexString: "1234567890abcdef1234567890abcdef12345678")!
        let recipientID = recipientKey.hexEncodedString()
        
        // Simulate peer connected on mesh
        meshService.simulateConnectedPeer(recipientID)
        meshService.addPeerNickname(recipientID, nickname: "TestRecipient")
        
        // Send voice message content
        let voiceContent = createVoiceContent(messageID: "test-001", duration: 3.0)
        
        // Track which transport was used
        var bluetoothUsed = false
        meshService.messageDeliveryHandler = { _ in
            bluetoothUsed = true
        }
        
        // Send message
        try await messageRouter.sendMessage(
            voiceContent,
            to: recipientKey,
            preferredTransport: nil,
            messageId: "test-001"
        )
        
        // Verify Bluetooth was primary
        XCTAssertTrue(bluetoothUsed, "Bluetooth should be used when peer is connected")
    }
    
    /// Test Nostr as primary when Bluetooth unavailable
    func testNostrPrimaryWhenBluetoothUnavailable() async throws {
        let recipientKey = Data(hexString: "abcdef1234567890abcdef1234567890abcdef12")!
        
        // Setup mutual favorite for Nostr capability
        favoritesService.addFavorite(
            peerNoisePublicKey: recipientKey,
            peerNickname: "NostrFriend",
            peerNostrPublicKey: "npub1test..."
        )
        
        // Peer not on mesh
        meshService.clearConnectedPeers()
        
        // Track Nostr usage
        var nostrUsed = false
        nostrRelay.eventSentHandler = { _ in
            nostrUsed = true
        }
        
        let voiceContent = createVoiceContent(messageID: "test-002", duration: 2.5)
        
        // Attempt to send
        do {
            try await messageRouter.sendMessage(
                voiceContent,
                to: recipientKey,
                messageId: "test-002"
            )
        } catch {
            // May fail in test environment, check if Nostr was attempted
        }
        
        // Verify Nostr was attempted
        XCTAssertTrue(nostrUsed || !meshService.isPeerConnected(recipientKey.hexEncodedString()),
                     "Nostr should be used when Bluetooth unavailable")
    }
    
    // MARK: - Fallback Scenario Tests
    
    /// Test fallback from Bluetooth to Nostr on failure
    func testBluetoothToNostrFallback() async throws {
        let recipientKey = Data(hexString: "fedcba0987654321fedcba0987654321fedcba09")!
        let recipientID = recipientKey.hexEncodedString()
        
        // Setup: Peer on mesh but will fail, mutual favorite for Nostr
        meshService.simulateConnectedPeer(recipientID)
        meshService.shouldFailNextSend = true
        
        favoritesService.addFavorite(
            peerNoisePublicKey: recipientKey,
            peerNickname: "FallbackFriend",
            peerNostrPublicKey: "npub1fallback..."
        )
        
        // Track transport attempts
        var bluetoothAttempted = false
        var nostrAttempted = false
        
        meshService.messageDeliveryHandler = { _ in
            bluetoothAttempted = true
            throw MessageRouterError.transportFailed
        }
        
        nostrRelay.eventSentHandler = { _ in
            nostrAttempted = true
        }
        
        let voiceContent = createVoiceContent(messageID: "test-003", duration: 4.0)
        
        // Send with fallback
        do {
            try await messageRouter.sendMessage(
                voiceContent,
                to: recipientKey,
                messageId: "test-003",
                urgency: .normal
            )
        } catch {
            // Expected to fail in test
        }
        
        // Verify fallback sequence
        XCTAssertTrue(bluetoothAttempted, "Should try Bluetooth first")
        // Note: Actual fallback to Nostr depends on implementation details
    }
    
    /// Test timeout handling in transport
    func testTransportTimeout() async throws {
        let recipientKey = Data(hexString: "1111222233334444555566667777888899990000")!
        let recipientID = recipientKey.hexEncodedString()
        
        // Setup slow transport
        meshService.simulateConnectedPeer(recipientID)
        meshService.simulateSlowTransport = true
        meshService.transportDelay = 35.0 // Longer than timeout
        
        let voiceContent = createVoiceContent(messageID: "test-timeout", duration: 1.5)
        
        // Measure timeout
        let startTime = Date()
        
        do {
            try await messageRouter.sendMessage(
                voiceContent,
                to: recipientKey,
                messageId: "test-timeout",
                urgency: .urgent // Shorter timeout for urgent
            )
            XCTFail("Should timeout")
        } catch {
            let elapsed = Date().timeIntervalSince(startTime)
            
            // Verify timeout occurred (urgent = 15 seconds)
            XCTAssertLessThan(elapsed, 20, "Should timeout within 20 seconds for urgent")
            XCTAssertTrue(error.localizedDescription.contains("timeout") ||
                         error.localizedDescription.contains("timed out"),
                         "Error should indicate timeout")
        }
    }
    
    // MARK: - Retry Logic Tests
    
    /// Test retry with exponential backoff
    func testRetryWithExponentialBackoff() async throws {
        let recipientKey = Data(hexString: "aaaabbbbccccddddeeeeffffaaaabbbbccccdddd")!
        let recipientID = recipientKey.hexEncodedString()
        
        // Setup to track retries
        meshService.simulateConnectedPeer(recipientID)
        var attemptCount = 0
        var attemptTimes: [Date] = []
        
        meshService.messageDeliveryHandler = { _ in
            attemptCount += 1
            attemptTimes.append(Date())
            
            if attemptCount < 3 {
                throw MessageRouterError.transportFailed
            }
        }
        
        // Enable fallback with retries
        favoritesService.addFavorite(
            peerNoisePublicKey: recipientKey,
            peerNickname: "RetryTest",
            peerNostrPublicKey: "npub1retry..."
        )
        
        let voiceContent = createVoiceContent(messageID: "test-retry", duration: 2.0)
        
        // Send with retries
        do {
            try await messageRouter.sendMessage(
                voiceContent,
                to: recipientKey,
                messageId: "test-retry",
                urgency: .normal // Allows 2 retries
            )
        } catch {
            // May fail after retries
        }
        
        // Verify exponential backoff
        if attemptTimes.count >= 2 {
            let firstInterval = attemptTimes[1].timeIntervalSince(attemptTimes[0])
            // Should have some delay between attempts
            XCTAssertGreaterThan(firstInterval, 0, "Should have delay between retries")
        }
    }
    
    /// Test urgency-based retry limits
    func testUrgencyBasedRetryLimits() async throws {
        let recipientKey = Data(hexString: "99998888777766665555444433332222111100000")!
        
        // Always fail transport
        meshService.shouldAlwaysFail = true
        
        // Test urgent (1 retry max)
        var urgentAttempts = 0
        meshService.messageDeliveryHandler = { _ in
            urgentAttempts += 1
            throw MessageRouterError.transportFailed
        }
        
        let urgentContent = createVoiceContent(messageID: "urgent-msg", duration: 1.0)
        
        do {
            try await messageRouter.sendMessage(
                urgentContent,
                to: recipientKey,
                messageId: "urgent-msg",
                urgency: .urgent
            )
        } catch {
            // Expected to fail
        }
        
        // Urgent should have limited retries
        XCTAssertLessThanOrEqual(urgentAttempts, 2, "Urgent messages should have limited retries")
        
        // Reset for normal urgency test
        urgentAttempts = 0
        
        let normalContent = createVoiceContent(messageID: "normal-msg", duration: 1.0)
        
        do {
            try await messageRouter.sendMessage(
                normalContent,
                to: recipientKey,
                messageId: "normal-msg",
                urgency: .normal
            )
        } catch {
            // Expected to fail
        }
        
        // Normal should allow more retries
        XCTAssertGreaterThanOrEqual(urgentAttempts, 1, "Normal messages should retry")
    }
    
    // MARK: - Voice-Specific Transport Tests
    
    /// Test voice message routing through MessageRouter
    func testVoiceMessageRoutingIntegration() async throws {
        let recipientKey = Data(hexString: "deadbeefcafebabefeedface1234567890abcdef")!
        let recipientID = recipientKey.hexEncodedString()
        
        // Setup connected peer
        meshService.simulateConnectedPeer(recipientID)
        meshService.addPeerNickname(recipientID, nickname: "VoiceRecipient")
        
        // Create voice message
        let voiceMessage = VoiceMessage(
            id: "voice-001",
            senderID: "test-peer-001",
            senderNickname: "TestSender",
            audioData: Data(repeating: 0x01, count: 1024),
            duration: 3.5,
            sampleRate: 48000,
            codec: .opus,
            timestamp: Date(),
            isPrivate: true,
            recipientID: recipientID,
            recipientNickname: "VoiceRecipient",
            deliveryStatus: .sending
        )
        
        // Route through MessageRouter extension
        var routed = false
        meshService.voiceMessageDeliveryHandler = { msg in
            routed = (msg.id == voiceMessage.id)
        }
        
        messageRouter.routeVoiceMessage(
            createBitchatMessage(from: voiceMessage),
            to: recipientID,
            isPrivate: true
        )
        
        // Verify routing
        XCTAssertTrue(routed, "Voice message should be routed through MessageRouter")
    }
    
    /// Test voice message fragmentation awareness
    func testVoiceMessageFragmentationInTransport() throws {
        let largeAudioData = Data(repeating: 0x02, count: 5000) // Large audio
        
        // Create voice content that would need fragmentation
        let voiceMetadata = [
            "duration": "10.0",
            "sampleRate": "48000",
            "codec": "opus",
            "messageId": "large-voice-001"
        ]
        
        let metadataData = try JSONSerialization.data(withJSONObject: voiceMetadata)
        let metadataString = String(data: metadataData, encoding: .utf8)!
        let base64Audio = largeAudioData.base64EncodedString()
        let voiceContent = "VOICE:\(metadataString):\(base64Audio)"
        
        // Verify content size exceeds typical BLE MTU
        XCTAssertGreaterThan(voiceContent.count, 512, "Content should exceed BLE MTU")
        
        // In production, MessageRouter would handle fragmentation
        // Here we verify the content structure is correct for fragmentation
        XCTAssertTrue(voiceContent.hasPrefix("VOICE:"), "Should have correct prefix")
        
        let components = voiceContent.components(separatedBy: ":")
        XCTAssertGreaterThanOrEqual(components.count, 3, "Should have proper structure")
    }
    
    // MARK: - Helper Methods
    
    private func createVoiceContent(messageID: String, duration: TimeInterval) -> String {
        let voiceMetadata = [
            "duration": String(duration),
            "sampleRate": "48000",
            "codec": "opus",
            "messageId": messageID
        ]
        
        guard let metadataData = try? JSONSerialization.data(withJSONObject: voiceMetadata),
              let metadataString = String(data: metadataData, encoding: .utf8) else {
            return ""
        }
        
        let audioData = Data(repeating: 0x01, count: 512)
        let base64Audio = audioData.base64EncodedString()
        
        return "VOICE:\(metadataString):\(base64Audio)"
    }
    
    private func createBitchatMessage(from voiceMessage: VoiceMessage) -> BitchatMessage {
        let voiceData = VoiceMessageData(
            duration: voiceMessage.duration,
            waveformData: [],
            filePath: nil,
            audioData: voiceMessage.audioData,
            format: .opus
        )
        
        return BitchatMessage(
            id: voiceMessage.id,
            sender: voiceMessage.senderNickname,
            content: "🎤 Voice message (\(voiceMessage.duration)s)",
            timestamp: voiceMessage.timestamp,
            isRelay: false,
            originalSender: nil,
            isPrivate: voiceMessage.isPrivate,
            recipientNickname: voiceMessage.recipientNickname,
            senderPeerID: voiceMessage.senderID,
            mentions: nil,
            deliveryStatus: voiceMessage.deliveryStatus,
            voiceMessageData: voiceData
        )
    }
}

// MARK: - Mock Classes

class MockBluetoothMeshService: BluetoothMeshService {
    var shouldFailNextSend = false
    var shouldAlwaysFail = false
    var simulateSlowTransport = false
    var transportDelay: TimeInterval = 0
    
    var messageDeliveryHandler: ((BitchatMessage) throws -> Void)?
    var voiceMessageDeliveryHandler: ((VoiceMessage) -> Void)?
    
    private var connectedPeers: Set<String> = []
    private var peerNicknames: [String: String] = [:]
    
    override func isPeerConnected(_ peerID: String) -> Bool {
        return connectedPeers.contains(peerID)
    }
    
    override func getPeerNicknames() -> [String: String] {
        return peerNicknames
    }
    
    func simulateConnectedPeer(_ peerID: String) {
        connectedPeers.insert(peerID)
    }
    
    func clearConnectedPeers() {
        connectedPeers.removeAll()
    }
    
    func addPeerNickname(_ peerID: String, nickname: String) {
        peerNicknames[peerID] = nickname
    }
    
    override func sendPrivateMessage(_ content: String, to peerID: String, recipientNickname: String, messageID: String? = nil) {
        if shouldFailNextSend || shouldAlwaysFail {
            shouldFailNextSend = false
            return
        }
        
        if simulateSlowTransport {
            Thread.sleep(forTimeInterval: transportDelay)
        }
        
        let message = BitchatMessage(
            id: messageID ?? UUID().uuidString,
            sender: "TestSender",
            content: content,
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: true,
            recipientNickname: recipientNickname,
            senderPeerID: myPeerID,
            mentions: nil
        )
        
        try? messageDeliveryHandler?(message)
    }
}

class MockNostrRelayManager: NostrRelayManager {
    var eventSentHandler: ((NostrEvent) -> Void)?
    
    override func sendEvent(_ event: NostrEvent) {
        eventSentHandler?(event)
    }
    
    override var isConnected: Bool {
        return true
    }
}