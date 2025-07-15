//
// NoiseSession.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import CryptoKit
import os.log

// MARK: - Noise Session State

enum NoiseSessionState: Equatable {
    case uninitialized
    case handshaking
    case established
    case failed(Error)
    
    static func == (lhs: NoiseSessionState, rhs: NoiseSessionState) -> Bool {
        switch (lhs, rhs) {
        case (.uninitialized, .uninitialized),
             (.handshaking, .handshaking),
             (.established, .established):
            return true
        case (.failed, .failed):
            return true // We don't compare the errors
        default:
            return false
        }
    }
}

// MARK: - Noise Session

class NoiseSession {
    let peerID: String
    let role: NoiseRole
    private var state: NoiseSessionState = .uninitialized
    private var handshakeState: NoiseHandshakeState?
    private var sendCipher: NoiseCipherState?
    private var receiveCipher: NoiseCipherState?
    
    // Keys
    private let localStaticKey: Curve25519.KeyAgreement.PrivateKey
    private var remoteStaticPublicKey: Curve25519.KeyAgreement.PublicKey?
    
    // Handshake messages for retransmission
    private var sentHandshakeMessages: [Data] = []
    private var handshakeHash: Data?
    
    // Thread safety
    private let sessionQueue = DispatchQueue(label: "chat.bitchat.noise.session", attributes: .concurrent)
    
    init(peerID: String, role: NoiseRole, localStaticKey: Curve25519.KeyAgreement.PrivateKey, remoteStaticKey: Curve25519.KeyAgreement.PublicKey? = nil) {
        self.peerID = peerID
        self.role = role
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
                localStaticKey: localStaticKey,
                remoteStaticKey: nil
            )
            
            state = .handshaking
            
            // Only initiator writes the first message
            if role == .initiator {
                let message = try handshakeState!.writeMessage()
                sentHandshakeMessages.append(message)
                return message
            } else {
                // Responder doesn't send first message in XX pattern
                return Data()
            }
        }
    }
    
    func processHandshakeMessage(_ message: Data) throws -> Data? {
        return try sessionQueue.sync(flags: .barrier) {
            
            // Initialize handshake state if needed (for responders)
            if state == .uninitialized && role == .responder {
                handshakeState = NoiseHandshakeState(
                    role: role,
                    pattern: .XX,
                    localStaticKey: localStaticKey,
                    remoteStaticKey: nil
                )
                state = .handshaking
            }
            
            guard case .handshaking = state, let handshake = handshakeState else {
                throw NoiseSessionError.invalidState
            }
            
            // Process incoming message
            _ = try handshake.readMessage(message)
            
            // Check if handshake is complete
            if handshake.isHandshakeComplete() {
                // Get transport ciphers
                let (send, receive) = try handshake.getTransportCiphers()
                sendCipher = send
                receiveCipher = receive
                
                // Store remote static key
                remoteStaticPublicKey = handshake.getRemoteStaticPublicKey()
                
                // Store handshake hash for channel binding
                handshakeHash = handshake.getHandshakeHash()
                
                state = .established
                handshakeState = nil // Clear handshake state
                
                return nil
            } else {
                // Generate response
                let response = try handshake.writeMessage()
                sentHandshakeMessages.append(response)
                
                // Check if handshake is complete after writing
                if handshake.isHandshakeComplete() {
                    // Get transport ciphers
                    let (send, receive) = try handshake.getTransportCiphers()
                    sendCipher = send
                    receiveCipher = receive
                    
                    // Store remote static key
                    remoteStaticPublicKey = handshake.getRemoteStaticPublicKey()
                    
                    // Store handshake hash for channel binding
                    handshakeHash = handshake.getHandshakeHash()
                    
                    state = .established
                    handshakeState = nil // Clear handshake state
                }
                
                return response
            }
        }
    }
    
    // MARK: - Transport
    
    func encrypt(_ plaintext: Data) throws -> Data {
        return try sessionQueue.sync {
            guard case .established = state, let cipher = sendCipher else {
                throw NoiseSessionError.notEstablished
            }
            
            return try cipher.encrypt(plaintext: plaintext)
        }
    }
    
    func decrypt(_ ciphertext: Data) throws -> Data {
        return try sessionQueue.sync {
            guard case .established = state, let cipher = receiveCipher else {
                throw NoiseSessionError.notEstablished
            }
            
            return try cipher.decrypt(ciphertext: ciphertext)
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
    
    func getHandshakeHash() -> Data? {
        return sessionQueue.sync {
            return handshakeHash
        }
    }
    
    func reset() {
        sessionQueue.sync(flags: .barrier) {
            state = .uninitialized
            handshakeState = nil
            sendCipher = nil
            receiveCipher = nil
            sentHandshakeMessages.removeAll()
            handshakeHash = nil
        }
    }
}

// MARK: - Session Manager

class NoiseSessionManager {
    private var sessions: [String: NoiseSession] = [:]
    private let localStaticKey: Curve25519.KeyAgreement.PrivateKey
    private let managerQueue = DispatchQueue(label: "chat.bitchat.noise.manager", attributes: .concurrent)
    
    // Callbacks
    var onSessionEstablished: ((String, Curve25519.KeyAgreement.PublicKey) -> Void)?
    var onSessionFailed: ((String, Error) -> Void)?
    
    init(localStaticKey: Curve25519.KeyAgreement.PrivateKey) {
        self.localStaticKey = localStaticKey
    }
    
    // MARK: - Session Management
    
    func createSession(for peerID: String, role: NoiseRole) -> NoiseSession {
        return managerQueue.sync(flags: .barrier) {
            let session = SecureNoiseSession(
                peerID: peerID,
                role: role,
                localStaticKey: localStaticKey
            )
            sessions[peerID] = session
            return session
        }
    }
    
    func getSession(for peerID: String) -> NoiseSession? {
        return managerQueue.sync {
            return sessions[peerID]
        }
    }
    
    func removeSession(for peerID: String) {
        _ = managerQueue.sync(flags: .barrier) {
            sessions.removeValue(forKey: peerID)
        }
    }
    
    func getEstablishedSessions() -> [String: NoiseSession] {
        return managerQueue.sync {
            return sessions.filter { $0.value.isEstablished() }
        }
    }
    
    // MARK: - Handshake Helpers
    
    func initiateHandshake(with peerID: String) throws -> Data {
        return try managerQueue.sync(flags: .barrier) {
            // Check if we already have an established session
            if let existingSession = sessions[peerID], existingSession.isEstablished() {
                // Session already established, don't recreate
                throw NoiseSessionError.alreadyEstablished
            }
            
            // Remove any existing non-established session
            if let existingSession = sessions[peerID], !existingSession.isEstablished() {
                sessions.removeValue(forKey: peerID)
            }
            
            // Create new initiator session
            let session = SecureNoiseSession(
                peerID: peerID,
                role: .initiator,
                localStaticKey: localStaticKey
            )
            sessions[peerID] = session
            
            do {
                let handshakeData = try session.startHandshake()
                return handshakeData
            } catch {
                // Clean up failed session
                sessions.removeValue(forKey: peerID)
                throw error
            }
        }
    }
    
    func handleIncomingHandshake(from peerID: String, message: Data) throws -> Data? {
        // Process everything within the synchronized block to prevent race conditions
        return try managerQueue.sync(flags: .barrier) {
            var shouldCreateNew = false
            var existingSession: NoiseSession? = nil
            
            if let existing = sessions[peerID] {
                // If we have an established session, we might need to help the other side complete theirs
                if existing.isEstablished() {
                    // If this is a handshake initiation (32 bytes), the other side doesn't have a session
                    // We should complete the handshake to help them establish their session
                    if message.count == 32 {
                        // Remove existing session and create new one
                        sessions.removeValue(forKey: peerID)
                        shouldCreateNew = true
                    } else {
                        // For other handshake messages, ignore if already established
                        throw NoiseSessionError.alreadyEstablished
                    }
                } else {
                    // If we're in the middle of a handshake and receive a new initiation,
                    // reset and start fresh (the other side may have restarted)
                    if existing.getState() == .handshaking && message.count == 32 {
                        sessions.removeValue(forKey: peerID)
                        shouldCreateNew = true
                    } else {
                        existingSession = existing
                    }
                }
            } else {
                shouldCreateNew = true
            }
            
            // Get or create session
            let session: NoiseSession
            if shouldCreateNew {
                let newSession = SecureNoiseSession(
                    peerID: peerID,
                    role: .responder,
                    localStaticKey: localStaticKey
                )
                sessions[peerID] = newSession
                session = newSession
            } else {
                session = existingSession!
            }
            
            // Process the handshake message within the synchronized block
            do {
                let response = try session.processHandshakeMessage(message)
                
                // Check if session is established after processing
                if session.isEstablished() {
                    if let remoteKey = session.getRemoteStaticPublicKey() {
                        // Schedule callback outside the synchronized block to prevent deadlock
                        DispatchQueue.global().async { [weak self] in
                            self?.onSessionEstablished?(peerID, remoteKey)
                        }
                    }
                }
                
                return response
            } catch {
                // Reset the session on handshake failure so next attempt can start fresh
                sessions.removeValue(forKey: peerID)
                
                // Schedule callback outside the synchronized block to prevent deadlock
                DispatchQueue.global().async { [weak self] in
                    self?.onSessionFailed?(peerID, error)
                }
                
                throw error
            }
        }
    }
    
    // MARK: - Encryption/Decryption
    
    func encrypt(_ plaintext: Data, for peerID: String) throws -> Data {
        guard let session = getSession(for: peerID) else {
            throw NoiseSessionError.sessionNotFound
        }
        
        return try session.encrypt(plaintext)
    }
    
    func decrypt(_ ciphertext: Data, from peerID: String) throws -> Data {
        guard let session = getSession(for: peerID) else {
            throw NoiseSessionError.sessionNotFound
        }
        
        return try session.decrypt(ciphertext)
    }
    
    // MARK: - Key Management
    
    func getRemoteStaticKey(for peerID: String) -> Curve25519.KeyAgreement.PublicKey? {
        return getSession(for: peerID)?.getRemoteStaticPublicKey()
    }
    
    func getHandshakeHash(for peerID: String) -> Data? {
        return getSession(for: peerID)?.getHandshakeHash()
    }
    
    // MARK: - Session Rekeying
    
    func getSessionsNeedingRekey() -> [(peerID: String, needsRekey: Bool)] {
        return managerQueue.sync {
            var needingRekey: [(peerID: String, needsRekey: Bool)] = []
            
            for (peerID, session) in sessions {
                if let secureSession = session as? SecureNoiseSession,
                   secureSession.isEstablished(),
                   secureSession.needsRenegotiation() {
                    needingRekey.append((peerID: peerID, needsRekey: true))
                }
            }
            
            return needingRekey
        }
    }
    
    func initiateRekey(for peerID: String) throws {
        // Remove old session
        removeSession(for: peerID)
        
        // Initiate new handshake
        _ = try initiateHandshake(with: peerID)
        
    }
}

// MARK: - Errors

enum NoiseSessionError: Error {
    case invalidState
    case notEstablished
    case sessionNotFound
    case handshakeFailed(Error)
    case alreadyEstablished
}