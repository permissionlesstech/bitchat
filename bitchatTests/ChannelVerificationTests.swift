//
// ChannelVerificationTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import XCTest
import CryptoKit
@testable import bitchat

class ChannelVerificationTests: XCTestCase {
    
    var viewModel: ChatViewModel!
    var mockMeshService: MockBluetoothMeshService!
    
    override func setUp() {
        super.setUp()
        viewModel = ChatViewModel()
        mockMeshService = MockBluetoothMeshService()
        viewModel.meshService = mockMeshService
    }
    
    override func tearDown() {
        viewModel = nil
        mockMeshService = nil
        super.tearDown()
    }
    
    // MARK: - Key Derivation Tests
    
    func testChannelKeyDerivation() {
        let password = "testPassword123"
        let channel = "#testchannel"
        
        // Derive key twice with same inputs
        let key1 = viewModel.deriveChannelKey(from: password, channelName: channel)
        let key2 = viewModel.deriveChannelKey(from: password, channelName: channel)
        
        // Keys should be identical for same password/channel
        XCTAssertEqual(key1.withUnsafeBytes { Data($0) }, 
                      key2.withUnsafeBytes { Data($0) })
    }
    
    func testDifferentPasswordsProduceDifferentKeys() {
        let channel = "#testchannel"
        let password1 = "password123"
        let password2 = "password456"
        
        let key1 = viewModel.deriveChannelKey(from: password1, channelName: channel)
        let key2 = viewModel.deriveChannelKey(from: password2, channelName: channel)
        
        // Different passwords should produce different keys
        XCTAssertNotEqual(key1.withUnsafeBytes { Data($0) }, 
                         key2.withUnsafeBytes { Data($0) })
    }
    
    func testKeyCommitmentComputation() {
        let password = "testPassword"
        let channel = "#test"
        
        let key = viewModel.deriveChannelKey(from: password, channelName: channel)
        let commitment1 = viewModel.computeKeyCommitment(for: key)
        let commitment2 = viewModel.computeKeyCommitment(for: key)
        
        // Same key should produce same commitment
        XCTAssertEqual(commitment1, commitment2)
        
        // Commitment should be 64 characters (SHA256 hex)
        XCTAssertEqual(commitment1.count, 64)
    }
    
    // MARK: - Verification Request/Response Tests
    
    func testChannelKeyVerifyRequestHandling() {
        // Setup
        let channel = "#test"
        let password = "secret123"
        let peerID = "peer123"
        
        // Join channel with password
        _ = viewModel.joinChannel(channel, password: password)
        
        // Create verification request with matching key
        let key = viewModel.deriveChannelKey(from: password, channelName: channel)
        let commitment = viewModel.computeKeyCommitment(for: key)
        
        let request = ChannelKeyVerifyRequest(
            channel: channel,
            requesterID: peerID,
            keyCommitment: commitment
        )
        
        // Handle request
        viewModel.didReceiveChannelKeyVerifyRequest(request, from: peerID)
        
        // Should have sent a positive response
        XCTAssertTrue(mockMeshService.sentVerifyResponse)
        XCTAssertTrue(mockMeshService.lastVerifyResponse?.verified ?? false)
    }
    
    func testChannelKeyVerifyResponseHandling() {
        // Setup
        let channel = "#test"
        let peerID = "peer123"
        
        // Set initial verification status
        viewModel.channelVerificationStatus[channel] = .verifying
        viewModel.joinedChannels.insert(channel)
        
        // Create positive response
        let response = ChannelKeyVerifyResponse(
            channel: channel,
            responderID: peerID,
            verified: true
        )
        
        // Handle response
        viewModel.didReceiveChannelKeyVerifyResponse(response, from: peerID)
        
        // Status should be verified
        XCTAssertEqual(viewModel.channelVerificationStatus[channel], .verified)
    }
    
    func testFailedVerificationResponse() {
        // Setup
        let channel = "#test"
        let peerID = "peer123"
        
        viewModel.channelVerificationStatus[channel] = .verifying
        viewModel.joinedChannels.insert(channel)
        
        // Create negative response
        let response = ChannelKeyVerifyResponse(
            channel: channel,
            responderID: peerID,
            verified: false
        )
        
        // Handle response
        viewModel.didReceiveChannelKeyVerifyResponse(response, from: peerID)
        
        // Status should be failed
        XCTAssertEqual(viewModel.channelVerificationStatus[channel], .failed)
    }
    
    // MARK: - Password Update Tests
    
    func testChannelPasswordUpdateHandling() {
        // Setup
        let channel = "#test"
        let ownerID = "owner123"
        let newPassword = "newSecret456"
        
        // Join channel first
        viewModel.joinedChannels.insert(channel)
        viewModel.channelCreators[channel] = ownerID
        
        // Simulate having a Noise session
        mockMeshService.mockNoiseSessionEstablished = true
        
        // Create password update
        let newKey = viewModel.deriveChannelKey(from: newPassword, channelName: channel)
        let newCommitment = viewModel.computeKeyCommitment(for: newKey)
        
        let update = ChannelPasswordUpdate(
            channel: channel,
            ownerID: ownerID,
            ownerFingerprint: "test-fingerprint", // Mock fingerprint
            encryptedPassword: Data(), // Would be encrypted in real scenario
            newKeyCommitment: newCommitment
        )
        
        // Mock decryption to return new password
        mockMeshService.mockDecryptedPassword = newPassword
        
        // Handle update
        viewModel.didReceiveChannelPasswordUpdate(update, from: ownerID)
        
        // Should have updated local key
        XCTAssertNotNil(viewModel.channelKeys[channel])
        XCTAssertEqual(viewModel.channelKeyCommitments[channel], newCommitment)
    }
}

// MARK: - Mock Mesh Service

class MockBluetoothMeshService: BluetoothMeshService {
    var sentVerifyResponse = false
    var lastVerifyResponse: ChannelKeyVerifyResponse?
    var mockNoiseSessionEstablished = false
    var mockDecryptedPassword: String?
    
    // Mock the method without override since it's not overrideable
    func mockSendChannelKeyVerifyResponse(_ response: ChannelKeyVerifyResponse, to peerID: String) {
        sentVerifyResponse = true
        lastVerifyResponse = response
        // Call the real method if needed
        super.sendChannelKeyVerifyResponse(response, to: peerID)
    }
    
    override func getNoiseService() -> NoiseEncryptionService {
        // Return actual noise service - tests should use real crypto
        return super.getNoiseService()
    }
}