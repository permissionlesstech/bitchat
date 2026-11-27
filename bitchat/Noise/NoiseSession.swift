//
// NoiseSession.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import Foundation
import CryptoKit
import BitFoundation

enum NoiseSessionState: Equatable {
    case uninitialized
    case handshaking
    case established
}

enum NoiseSessionError: Error, Equatable {
    case invalidState
    case notEstablished
    case sessionNotFound
    case alreadyEstablished
    case peerIdentityMismatch
}

/// The manager owns the exact attempt's one bounded recovery. Packet handling
/// must not launch its historical second, immediate restart for this failure.
struct NoiseManagedHandshakeFailure: Error {
    let underlying: Error
}

class NoiseSession {
    let peerID: PeerID
    let role: NoiseRole
    private let keychain: KeychainManagerProtocol
    private var state: NoiseSessionState = .uninitialized
    private var handshakeState: NoiseHandshakeState?
    private var sendCipher: NoiseCipherState?
    private var receiveCipher: NoiseCipherState?

    // Lifecycle & security limits (confined to sessionQueue)
    private var messageCount: UInt64 = 0
    private var sessionStartTime = Date()
    private var lastActivityTime = Date()

    // Keys
    private let localStaticKey: Curve25519.KeyAgreement.PrivateKey
    private var remoteStaticPublicKey: Curve25519.KeyAgreement.PublicKey?

    // Thread safety
    private let sessionQueue = DispatchQueue(label: "chat.bitchat.noise.session", attributes: .concurrent)

    init(
        peerID: PeerID,
        role: NoiseRole,
        keychain: KeychainManagerProtocol,
        localStaticKey: Curve25519.KeyAgreement.PrivateKey,
        remoteStaticKey: Curve25519.KeyAgreement.PublicKey? = nil
    ) {
        self.peerID = peerID
        self.role = role
        self.keychain = keychain
        self.localStaticKey = localStaticKey
        self.remoteStaticPublicKey = remoteStaticKey
    }

    // MARK: - Handshake

    func startHandshake() throws -> Data {
        return try sessionQueue.sync(flags: .barrier) {
            guard case .uninitialized = state else {
                throw NoiseSessionError.invalidState
            }

            // For XX pattern, we don't need remote static key upfront
            handshakeState = NoiseHandshakeState(
                role: role,
                pattern: .XX,
                keychain: keychain,
                localStaticKey: localStaticKey,
                remoteStaticKey: nil
            )

            state = .handshaking

            // Only initiator writes the first message
            if role == .initiator {
                guard let handshake = handshakeState else {
                    throw NoiseSessionError.invalidState
                }
                let message = try handshake.writeMessage()
                return message
            } else {
                // Responder doesn't send first message in XX pattern
                return Data()
            }
        }
    }

    func processHandshakeMessage(_ message: Data) throws -> Data? {
        return try sessionQueue.sync(flags: .barrier) {
            SecureLogger.debug("NoiseSession[\(peerID)]: Processing handshake message, current state: \(state), role: \(role)")

            // Initialize handshake state if needed (for responders)
            if state == .uninitialized && role == .responder {
                handshakeState = NoiseHandshakeState(
                    role: role,
                    pattern: .XX,
                    keychain: keychain,
                    localStaticKey: localStaticKey,
                    remoteStaticKey: nil
                )
                state = .handshaking
                SecureLogger.debug("NoiseSession[\(peerID)]: Initialized handshake state for responder")
            }

            guard case .handshaking = state, let handshake = handshakeState else {
                throw NoiseSessionError.invalidState
            }

            // Process incoming message
            _ = try handshake.readMessage(message)
            SecureLogger.debug("NoiseSession[\(peerID)]: Read handshake message, checking if complete")

            // Check if handshake is complete
            if handshake.isHandshakeComplete() {
                try completeHandshake(handshake)
                return nil
            } else {
                // Generate response
                let response = try handshake.writeMessage()
                SecureLogger.debug("NoiseSession[\(peerID)]: Generated handshake response of size \(response.count)")

                // Check if handshake is complete after writing
                if handshake.isHandshakeComplete() {
                    try completeHandshake(handshake)
                }

                return response
            }
        }
    }

    private func completeHandshake(_ handshake: NoiseHandshakeState) throws {
        let (send, receive, _) = try handshake.getTransportCiphers(useExtractedNonce: true)
        sendCipher = send
        receiveCipher = receive
        remoteStaticPublicKey = handshake.getRemoteStaticPublicKey()
        state = .established
        handshakeState = nil
        SecureLogger.debug("NoiseSession[\(peerID)]: Handshake complete, transitioning to established")
        SecureLogger.info(.handshakeCompleted(peerID: peerID.id))
    }

    // MARK: - Transport

    func encrypt(_ plaintext: Data) throws -> Data {
        return try sessionQueue.sync(flags: .barrier) {
            let now = Date()
            if now.timeIntervalSince(sessionStartTime) > NoiseSecurityConstants.sessionTimeout {
                throw NoiseSecurityError.sessionExpired
            }
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

            guard case .established = state, let cipher = sendCipher else {
                throw NoiseSessionError.notEstablished
            }

            let encrypted = try cipher.encrypt(plaintext: plaintext)
            messageCount += 1
            lastActivityTime = now
            return encrypted
        }
    }

    func decrypt(_ ciphertext: Data) throws -> Data {
        return try sessionQueue.sync(flags: .barrier) {
            let now = Date()
            if now.timeIntervalSince(sessionStartTime) > NoiseSecurityConstants.sessionTimeout {
                throw NoiseSecurityError.sessionExpired
            }

            // The payload type is encrypted, so a large candidate can only be
            // bounded here; `NoiseEncryptionService.decrypt` authenticates it and
            // then requires the resulting type to be `.privateFile`.
            guard NoiseSecurityValidator.validateCiphertextSize(ciphertext)
                    || NoiseSecurityValidator.validatePrivateFileCiphertextSize(ciphertext) else {
                throw NoiseSecurityError.messageTooLarge
            }

            guard case .established = state, let cipher = receiveCipher else {
                throw NoiseSessionError.notEstablished
            }

            let decrypted = try cipher.decrypt(ciphertext: ciphertext)
            lastActivityTime = now
            return decrypted
        }
    }

    func needsRenegotiation() -> Bool {
        sessionQueue.sync {
            let messageThreshold = UInt64(Double(NoiseSecurityConstants.maxMessagesPerSession) * 0.9)
            if messageCount >= messageThreshold {
                return true
            }

            let now = Date()
            if now.timeIntervalSince(lastActivityTime) > NoiseSecurityConstants.sessionTimeout {
                return true
            }

            // A session that never goes idle keeps refreshing lastActivityTime forever,
            // so check sessionStartTime at 90% of sessionTimeout to give the periodic
            // rekey check room to rotate keys before encrypt/decrypt start throwing
            // sessionExpired.
            if now.timeIntervalSince(sessionStartTime) > NoiseSecurityConstants.sessionTimeout * 0.9 {
                return true
            }

            return false
        }
    }

    // MARK: - State Management

    func getState() -> NoiseSessionState {
        return sessionQueue.sync {
            return state
        }
    }

    func isEstablished() -> Bool {
        return sessionQueue.sync {
            if case .established = state {
                return true
            }
            return false
        }
    }

    func getRemoteStaticPublicKey() -> Curve25519.KeyAgreement.PublicKey? {
        return sessionQueue.sync {
            return remoteStaticPublicKey
        }
    }

    func reset() {
        sessionQueue.sync(flags: .barrier) {
            let wasEstablished = state == .established
            state = .uninitialized
            handshakeState = nil
            messageCount = 0
            let now = Date()
            sessionStartTime = now
            lastActivityTime = now

            // Clear sensitive cipher states
            sendCipher?.clearSensitiveData()
            receiveCipher?.clearSensitiveData()
            sendCipher = nil
            receiveCipher = nil

            if wasEstablished {
                SecureLogger.info(.sessionExpired(peerID: peerID.id))
            }
        }
    }

    // MARK: - Testing Support
    #if DEBUG
    func setLastActivityTimeForTesting(_ date: Date) {
        sessionQueue.sync(flags: .barrier) {
            lastActivityTime = date
        }
    }

    func setMessageCountForTesting(_ count: UInt64) {
        sessionQueue.sync(flags: .barrier) {
            messageCount = count
        }
    }

    func setSessionStartTimeForTesting(_ date: Date) {
        sessionQueue.sync(flags: .barrier) {
            sessionStartTime = date
        }
    }
    #endif
}
