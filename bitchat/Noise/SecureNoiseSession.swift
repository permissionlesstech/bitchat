//
// SecureNoiseSession.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

final class SecureNoiseSession: NoiseSession {
    private(set) var messageCount: UInt64 = 0
    private var sessionStartTime = Date()
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
        
        // Ordinary Noise messages keep the protocol ceiling. Finalized media
        // is the sole typed-payload extension and remains under the framed-file
        // cap enforced again at the service and file-decoder layers.
        let isPrivateFile = NoisePayloadType.isPrivateFile(rawValue: plaintext.first)
            && NoiseSecurityValidator.validatePrivateFileMessageSize(plaintext)
        guard NoiseSecurityValidator.validateMessageSize(plaintext) || isPrivateFile else {
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
        
        // The payload type is encrypted, so a large candidate can only be
        // bounded here; `NoiseEncryptionService.decrypt` authenticates it and
        // then requires the resulting type to be `.privateFile`.
        guard NoiseSecurityValidator.validateCiphertextSize(ciphertext)
                || NoiseSecurityValidator.validatePrivateFileCiphertextSize(ciphertext) else {
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

    func setSessionStartTimeForTesting(_ date: Date) {
        sessionStartTime = date
    }
    #endif
}
