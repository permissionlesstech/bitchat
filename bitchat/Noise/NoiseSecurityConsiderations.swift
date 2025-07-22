//
// NoiseSecurityConsiderations.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import CryptoKit

// MARK: - Security Constants

enum NoiseSecurityConstants {
    // Maximum message size to prevent memory exhaustion
    static let maxMessageSize = 65535 // 64KB as per Noise spec
    
    // Maximum handshake message size
    static let maxHandshakeMessageSize = 2048 // 2KB to accommodate XX pattern
    
    // Session timeout - sessions older than this should be renegotiated
    static let sessionTimeout: TimeInterval = 86400 // 24 hours
    
    // Maximum number of messages before rekey (2^64 - 1 is the nonce limit)
    static let maxMessagesPerSession: UInt64 = 1_000_000_000 // 1 billion messages
    
    // Handshake timeout - abandon incomplete handshakes
    static let handshakeTimeout: TimeInterval = 60 // 1 minute
    
    // Maximum concurrent sessions per peer
    static let maxSessionsPerPeer = 3
    
    // Rate limiting
    static let maxHandshakesPerMinute = 10
    static let maxMessagesPerSecond = 100
    
    // Global rate limiting (across all peers)
    static let maxGlobalHandshakesPerMinute = 30
    static let maxGlobalMessagesPerSecond = 500
}

// MARK: - Security Validations

struct NoiseSecurityValidator {
    
    /// Validate message size
    static func validateMessageSize(_ data: Data) -> Bool {
        return data.count <= NoiseSecurityConstants.maxMessageSize
    }
    
    /// Validate handshake message size
    static func validateHandshakeMessageSize(_ data: Data) -> Bool {
        return data.count <= NoiseSecurityConstants.maxHandshakeMessageSize
    }
    
    /// Validate peer ID format
    static func validatePeerID(_ peerID: String) -> Bool {
        // Peer ID should be reasonable length and contain valid characters
        let validCharset = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return peerID.count > 0 && 
               peerID.count <= 64 && 
               peerID.rangeOfCharacter(from: validCharset.inverted) == nil
    }
}

// MARK: - Enhanced Noise Session with Security

class SecureNoiseSession: NoiseSession {
    private(set) var messageCount: UInt64 = 0
    private let sessionStartTime = Date()
    private(set) var lastActivityTime = Date()
    
    override func encrypt(_ plaintext: Data) throws -> Data {
        // Check session age
        if Date().timeIntervalSince(sessionStartTime) > NoiseSecurityConstants.sessionTimeout {
            throw NoiseSecurityError.sessionExpired
        }
        
        // Check message count
        if messageCount >= NoiseSecurityConstants.maxMessagesPerSession {
            throw NoiseSecurityError.sessionExhausted
        }
        
        // Validate message size
        guard NoiseSecurityValidator.validateMessageSize(plaintext) else {
            throw NoiseSecurityError.messageTooLarge
        }
        
        let encrypted = try super.encrypt(plaintext)
        messageCount += 1
        lastActivityTime = Date()
        
        return encrypted
    }
    
    override func decrypt(_ ciphertext: Data) throws -> Data {
        // Check session age
        if Date().timeIntervalSince(sessionStartTime) > NoiseSecurityConstants.sessionTimeout {
            throw NoiseSecurityError.sessionExpired
        }
        
        // Validate message size
        guard NoiseSecurityValidator.validateMessageSize(ciphertext) else {
            throw NoiseSecurityError.messageTooLarge
        }
        
        let decrypted = try super.decrypt(ciphertext)
        lastActivityTime = Date()
        
        return decrypted
    }
    
    func needsRenegotiation() -> Bool {
        // Check if we've used more than 90% of message limit
        let messageThreshold = UInt64(Double(NoiseSecurityConstants.maxMessagesPerSession) * 0.9)
        if messageCount >= messageThreshold {
            return true
        }
        
        // Check if last activity was more than 30 minutes ago
        if Date().timeIntervalSince(lastActivityTime) > NoiseSecurityConstants.sessionTimeout {
            return true
        }
        
        return false
    }
    
    // MARK: - Testing Support
    #if DEBUG
    func setLastActivityTimeForTesting(_ date: Date) {
        lastActivityTime = date
    }
    
    func setMessageCountForTesting(_ count: UInt64) {
        messageCount = count
    }
    #endif
}

// MARK: - Rate Limiter

class NoiseRateLimiter {
    private var handshakeTimestamps: [String: [Date]] = [:] // peerID -> timestamps
    private var messageTimestamps: [String: [Date]] = [:] // peerID -> timestamps
    
    // Global rate limiting
    private var globalHandshakeTimestamps: [Date] = []
    private var globalMessageTimestamps: [Date] = []
    
    private let queue = DispatchQueue(label: "chat.bitchat.noise.ratelimit", attributes: .concurrent)
    
    func allowHandshake(from peerID: String) -> Bool {
        return queue.sync(flags: .barrier) {
            let now = Date()
            let oneMinuteAgo = now.addingTimeInterval(-60)
            
            // Check global rate limit first
            globalHandshakeTimestamps = globalHandshakeTimestamps.filter { $0 > oneMinuteAgo }
            if globalHandshakeTimestamps.count >= NoiseSecurityConstants.maxGlobalHandshakesPerMinute {
                SecureLogger.log("Global handshake rate limit exceeded: \(globalHandshakeTimestamps.count)/\(NoiseSecurityConstants.maxGlobalHandshakesPerMinute) per minute", category: SecureLogger.security, level: .warning)
                return false
            }
            
            // Check per-peer rate limit
            var timestamps = handshakeTimestamps[peerID] ?? []
            timestamps = timestamps.filter { $0 > oneMinuteAgo }
            
            if timestamps.count >= NoiseSecurityConstants.maxHandshakesPerMinute {
                SecureLogger.log("Per-peer handshake rate limit exceeded for \(peerID): \(timestamps.count)/\(NoiseSecurityConstants.maxHandshakesPerMinute) per minute", category: SecureLogger.security, level: .warning)
                return false
            }
            
            // Record new handshake
            timestamps.append(now)
            handshakeTimestamps[peerID] = timestamps
            globalHandshakeTimestamps.append(now)
            return true
        }
    }
    
    func allowMessage(from peerID: String) -> Bool {
        return queue.sync(flags: .barrier) {
            let now = Date()
            let oneSecondAgo = now.addingTimeInterval(-1)
            
            // Check global rate limit first
            globalMessageTimestamps = globalMessageTimestamps.filter { $0 > oneSecondAgo }
            if globalMessageTimestamps.count >= NoiseSecurityConstants.maxGlobalMessagesPerSecond {
                SecureLogger.log("Global message rate limit exceeded: \(globalMessageTimestamps.count)/\(NoiseSecurityConstants.maxGlobalMessagesPerSecond) per second", category: SecureLogger.security, level: .warning)
                return false
            }
            
            // Check per-peer rate limit
            var timestamps = messageTimestamps[peerID] ?? []
            timestamps = timestamps.filter { $0 > oneSecondAgo }
            
            if timestamps.count >= NoiseSecurityConstants.maxMessagesPerSecond {
                SecureLogger.log("Per-peer message rate limit exceeded for \(peerID): \(timestamps.count)/\(NoiseSecurityConstants.maxMessagesPerSecond) per second", category: SecureLogger.security, level: .warning)
                return false
            }
            
            // Record new message
            timestamps.append(now)
            messageTimestamps[peerID] = timestamps
            globalMessageTimestamps.append(now)
            return true
        }
    }
    
    func reset(for peerID: String) {
        queue.async(flags: .barrier) {
            self.handshakeTimestamps.removeValue(forKey: peerID)
            self.messageTimestamps.removeValue(forKey: peerID)
        }
    }
}

// MARK: - Security Errors

enum NoiseSecurityError: Error {
    case sessionExpired
    case sessionExhausted
    case messageTooLarge
    case invalidPeerID
    case rateLimitExceeded
    case handshakeTimeout
}
