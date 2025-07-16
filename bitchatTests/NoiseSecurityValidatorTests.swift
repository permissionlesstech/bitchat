//
// NoiseSecurityValidatorTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import XCTest
@testable import bitchat

class NoiseSecurityValidatorTests: XCTestCase {
    
    // MARK: - Peer ID Validation Tests
    
    func testValidPeerIDAccepted() {
        // Valid peer IDs
        XCTAssertTrue(NoiseSecurityValidator.validatePeerID("user123"))
        XCTAssertTrue(NoiseSecurityValidator.validatePeerID("alice"))
        XCTAssertTrue(NoiseSecurityValidator.validatePeerID("bob_2024"))
        XCTAssertTrue(NoiseSecurityValidator.validatePeerID("test-user"))
        XCTAssertTrue(NoiseSecurityValidator.validatePeerID("192.168.1.1:8080")) // IP:port format
    }
    
    func testInvalidPeerIDRejected() {
        // Empty
        XCTAssertFalse(NoiseSecurityValidator.validatePeerID(""))
        
        // Too long (over 255 chars)
        let longID = String(repeating: "a", count: 256)
        XCTAssertFalse(NoiseSecurityValidator.validatePeerID(longID))
        
        // Control characters
        XCTAssertFalse(NoiseSecurityValidator.validatePeerID("user\0null"))
        XCTAssertFalse(NoiseSecurityValidator.validatePeerID("user\nline"))
        XCTAssertFalse(NoiseSecurityValidator.validatePeerID("user\ttab"))
        
        // Path traversal attempts
        XCTAssertFalse(NoiseSecurityValidator.validatePeerID("../../../etc/passwd"))
        XCTAssertFalse(NoiseSecurityValidator.validatePeerID("user/../admin"))
    }
    
    // MARK: - Message Size Validation Tests
    
    func testValidMessageSizeAccepted() {
        // Small message
        let smallData = Data(repeating: 0x42, count: 100)
        XCTAssertTrue(NoiseSecurityValidator.validateMessageSize(smallData))
        
        // Medium message (1MB)
        let mediumData = Data(repeating: 0x42, count: 1024 * 1024)
        XCTAssertTrue(NoiseSecurityValidator.validateMessageSize(mediumData))
        
        // Just under limit (10MB - 1 byte)
        let nearLimitData = Data(repeating: 0x42, count: 10 * 1024 * 1024 - 1)
        XCTAssertTrue(NoiseSecurityValidator.validateMessageSize(nearLimitData))
    }
    
    func testOversizedMessageRejected() {
        // Exactly at limit (10MB)
        let limitData = Data(repeating: 0x42, count: 10 * 1024 * 1024)
        XCTAssertFalse(NoiseSecurityValidator.validateMessageSize(limitData))
        
        // Over limit
        let overData = Data(repeating: 0x42, count: 11 * 1024 * 1024)
        XCTAssertFalse(NoiseSecurityValidator.validateMessageSize(overData))
    }
    
    func testHandshakeMessageSizeValidation() {
        // Valid handshake size
        let validHandshake = Data(repeating: 0x42, count: 500)
        XCTAssertTrue(NoiseSecurityValidator.validateHandshakeMessageSize(validHandshake))
        
        // Too large for handshake (over 64KB)
        let largeHandshake = Data(repeating: 0x42, count: 65 * 1024)
        XCTAssertFalse(NoiseSecurityValidator.validateHandshakeMessageSize(largeHandshake))
    }
    
    // MARK: - Channel Name Validation Tests
    
    func testValidChannelNameAccepted() {
        XCTAssertTrue(NoiseSecurityValidator.validateChannelName("#general"))
        XCTAssertTrue(NoiseSecurityValidator.validateChannelName("#test-channel"))
        XCTAssertTrue(NoiseSecurityValidator.validateChannelName("#channel_123"))
        XCTAssertTrue(NoiseSecurityValidator.validateChannelName("#🎉party"))
        XCTAssertTrue(NoiseSecurityValidator.validateChannelName("#2024"))
    }
    
    func testInvalidChannelNameRejected() {
        // Missing # prefix
        XCTAssertFalse(NoiseSecurityValidator.validateChannelName("general"))
        
        // Empty or just #
        XCTAssertFalse(NoiseSecurityValidator.validateChannelName(""))
        XCTAssertFalse(NoiseSecurityValidator.validateChannelName("#"))
        
        // Too long (over 50 chars)
        let longName = "#" + String(repeating: "a", count: 51)
        XCTAssertFalse(NoiseSecurityValidator.validateChannelName(longName))
        
        // Invalid characters
        XCTAssertFalse(NoiseSecurityValidator.validateChannelName("#channel\nwith\nnewlines"))
        XCTAssertFalse(NoiseSecurityValidator.validateChannelName("#../../etc"))
        XCTAssertFalse(NoiseSecurityValidator.validateChannelName("#channel<script>"))
    }
    
    // MARK: - Encryption Parameters Validation
    
    func testValidateEncryptionNonce() {
        // Valid 12-byte nonce for ChaCha20
        let validNonce = Data(repeating: 0x42, count: 12)
        XCTAssertTrue(NoiseSecurityValidator.validateNonce(validNonce))
        
        // Invalid sizes
        let shortNonce = Data(repeating: 0x42, count: 8)
        XCTAssertFalse(NoiseSecurityValidator.validateNonce(shortNonce))
        
        let longNonce = Data(repeating: 0x42, count: 16)
        XCTAssertFalse(NoiseSecurityValidator.validateNonce(longNonce))
        
        // Empty
        XCTAssertFalse(NoiseSecurityValidator.validateNonce(Data()))
    }
    
    func testValidateKeyMaterial() {
        // Valid 32-byte key
        let validKey = Data(repeating: 0x42, count: 32)
        XCTAssertTrue(NoiseSecurityValidator.validateKeyMaterial(validKey))
        
        // Invalid sizes
        XCTAssertFalse(NoiseSecurityValidator.validateKeyMaterial(Data(repeating: 0x42, count: 16)))
        XCTAssertFalse(NoiseSecurityValidator.validateKeyMaterial(Data(repeating: 0x42, count: 64)))
        XCTAssertFalse(NoiseSecurityValidator.validateKeyMaterial(Data()))
    }
    
    // MARK: - Input Sanitization Tests
    
    func testSanitizePeerID() {
        // Normal case
        XCTAssertEqual(NoiseSecurityValidator.sanitizePeerID("alice123"), "alice123")
        
        // Remove control characters
        XCTAssertEqual(NoiseSecurityValidator.sanitizePeerID("alice\0bob"), "alicebob")
        XCTAssertEqual(NoiseSecurityValidator.sanitizePeerID("user\n\r\t"), "user")
        
        // Truncate long IDs
        let longID = String(repeating: "a", count: 300)
        let sanitized = NoiseSecurityValidator.sanitizePeerID(longID)
        XCTAssertEqual(sanitized.count, 255)
        
        // Empty becomes placeholder
        XCTAssertEqual(NoiseSecurityValidator.sanitizePeerID(""), "unknown")
    }
    
    func testSanitizeChannelName() {
        // Normal case
        XCTAssertEqual(NoiseSecurityValidator.sanitizeChannelName("#general"), "#general")
        
        // Add # prefix if missing
        XCTAssertEqual(NoiseSecurityValidator.sanitizeChannelName("general"), "#general")
        
        // Remove invalid characters
        XCTAssertEqual(NoiseSecurityValidator.sanitizeChannelName("#test\nchannel"), "#testchannel")
        
        // Truncate long names
        let longName = String(repeating: "a", count: 100)
        let sanitized = NoiseSecurityValidator.sanitizeChannelName(longName)
        XCTAssertTrue(sanitized.hasPrefix("#"))
        XCTAssertLessThanOrEqual(sanitized.count, 50)
    }
    
    // MARK: - Security Pattern Detection Tests
    
    func testDetectSuspiciousPatterns() {
        // Path traversal
        XCTAssertTrue(NoiseSecurityValidator.containsSuspiciousPattern("../../../etc/passwd"))
        XCTAssertTrue(NoiseSecurityValidator.containsSuspiciousPattern("..\\..\\windows\\system32"))
        
        // Script injection
        XCTAssertTrue(NoiseSecurityValidator.containsSuspiciousPattern("<script>alert('xss')</script>"))
        XCTAssertTrue(NoiseSecurityValidator.containsSuspiciousPattern("javascript:void(0)"))
        
        // SQL injection patterns
        XCTAssertTrue(NoiseSecurityValidator.containsSuspiciousPattern("'; DROP TABLE users; --"))
        XCTAssertTrue(NoiseSecurityValidator.containsSuspiciousPattern("1' OR '1'='1"))
        
        // Normal text should pass
        XCTAssertFalse(NoiseSecurityValidator.containsSuspiciousPattern("Hello, this is a normal message!"))
        XCTAssertFalse(NoiseSecurityValidator.containsSuspiciousPattern("Meeting at 3:00 PM"))
    }
}