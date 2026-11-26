//
// SecureNoiseSession.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

final class SecureNoiseSession: NoiseSession {
    private let stateLock = NSLock()
    private var _messageCount: UInt64 = 0
    private var _sessionStartTime = Date()
    private var _lastActivityTime = Date()

    override func encrypt(_ plaintext: Data) throws -> Data {
        let now = Date()
        stateLock.lock()
        let startTime = _sessionStartTime
        let count = _messageCount
        stateLock.unlock()

        // Check session age
        if now.timeIntervalSince(startTime) > NoiseSecurityConstants.sessionTimeout {
            throw NoiseSecurityError.sessionExpired
        }

        // Check message count
        if count >= NoiseSecurityConstants.maxMessagesPerSession {
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
        stateLock.lock()
        _messageCount += 1
        _lastActivityTime = Date()
        stateLock.unlock()

        return encrypted
    }

    override func decrypt(_ ciphertext: Data) throws -> Data {
        let now = Date()
        stateLock.lock()
        let startTime = _sessionStartTime
        stateLock.unlock()

        // Check session age
        if now.timeIntervalSince(startTime) > NoiseSecurityConstants.sessionTimeout {
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
        stateLock.lock()
        _lastActivityTime = Date()
        stateLock.unlock()

        return decrypted
    }

    func needsRenegotiation() -> Bool {
        let now = Date()
        stateLock.lock()
        let count = _messageCount
        let lastActivity = _lastActivityTime
        let startTime = _sessionStartTime
        stateLock.unlock()

        // Check if we've used more than 90% of message limit
        let messageThreshold = UInt64(Double(NoiseSecurityConstants.maxMessagesPerSession) * 0.9)
        if count >= messageThreshold {
            return true
        }

        // Check if last activity exceeded sessionTimeout
        if now.timeIntervalSince(lastActivity) > NoiseSecurityConstants.sessionTimeout {
            return true
        }

        // A session that never goes idle (a long-lived conversation with
        // steady traffic) keeps refreshing lastActivityTime forever, so the
        // check above never fires -- only sessionStartTime tracks how close
        // encrypt/decrypt are to the hard sessionExpired cutoff above. Firing
        // at 90% of sessionTimeout leaves the rekey timer's polling interval
        // (checked every 60s, see NoiseEncryptionService.rekeyCheckInterval)
        // room to complete a full handshake well before the old session
        // starts throwing sessionExpired on every call.
        if now.timeIntervalSince(startTime) > NoiseSecurityConstants.sessionTimeout * 0.9 {
            return true
        }

        return false
    }

    // MARK: - Testing Support
    #if DEBUG
    func setLastActivityTimeForTesting(_ date: Date) {
        stateLock.lock()
        _lastActivityTime = date
        stateLock.unlock()
    }

    func setMessageCountForTesting(_ count: UInt64) {
        stateLock.lock()
        _messageCount = count
        stateLock.unlock()
    }

    func setSessionStartTimeForTesting(_ date: Date) {
        stateLock.lock()
        _sessionStartTime = date
        stateLock.unlock()
    }
    #endif
}
