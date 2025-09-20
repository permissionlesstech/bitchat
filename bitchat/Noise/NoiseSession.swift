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
    let peer: Peer
    let role: NoiseRole
    private let keychain: KeychainManagerProtocol
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
    
    init(
        peer: Peer,
        role: NoiseRole,
        keychain: KeychainManagerProtocol,
        localStaticKey: Curve25519.KeyAgreement.PrivateKey,
        remoteStaticKey: Curve25519.KeyAgreement.PublicKey? = nil
    ) {
        self.peer = peer
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
            SecureLogger.debug("NoiseSession[\(peer.id)]: Processing handshake message, current state: \(state), role: \(role)")
            
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
                SecureLogger.debug("NoiseSession[\(peer.id)]: Initialized handshake state for responder")
            }
            
            guard case .handshaking = state, let handshake = handshakeState else {
                throw NoiseSessionError.invalidState
            }
            
            // Process incoming message
            _ = try handshake.readMessage(message)
            SecureLogger.debug("NoiseSession[\(peer.id)]: Read handshake message, checking if complete")
            
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
                
                SecureLogger.debug("NoiseSession[\(peer.id)]: Handshake complete (no response needed), transitioning to established")
                SecureLogger.info(.handshakeCompleted(peerID: peer.id))
                
                return nil
            } else {
                // Generate response
                let response = try handshake.writeMessage()
                sentHandshakeMessages.append(response)
                SecureLogger.debug("NoiseSession[\(peer.id)]: Generated handshake response of size \(response.count)")
                
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
                    
                    SecureLogger.debug("NoiseSession[\(peer.id)]: Handshake complete after writing response, transitioning to established")
                    SecureLogger.info(.handshakeCompleted(peerID: peer.id))
                }
                
                return response
            }
        }
    }
    
    // MARK: - Transport
    
    func encrypt(_ plaintext: Data) throws -> Data {
        return try sessionQueue.sync(flags: .barrier) {
            guard case .established = state, let cipher = sendCipher else {
                throw NoiseSessionError.notEstablished
            }
            
            return try cipher.encrypt(plaintext: plaintext)
        }
    }
    
    func decrypt(_ ciphertext: Data) throws -> Data {
        return try sessionQueue.sync(flags: .barrier) {
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
            let wasEstablished = state == .established
            state = .uninitialized
            handshakeState = nil
            
            // Clear sensitive cipher states
            sendCipher?.clearSensitiveData()
            receiveCipher?.clearSensitiveData()
            sendCipher = nil
            receiveCipher = nil
            
            // Clear sent handshake messages
            for i in 0..<sentHandshakeMessages.count {
                var message = sentHandshakeMessages[i]
                keychain.secureClear(&message)
            }
            sentHandshakeMessages.removeAll()
            
            // Clear handshake hash
            if var hash = handshakeHash {
                keychain.secureClear(&hash)
            }
            handshakeHash = nil
            
            if wasEstablished {
                SecureLogger.info(.sessionExpired(peerID: peer.id))
            }
        }
    }
}

// MARK: - Session Manager

final class NoiseSessionManager {
    private var sessions: [Peer: NoiseSession] = [:]
    private let localStaticKey: Curve25519.KeyAgreement.PrivateKey
    private let keychain: KeychainManagerProtocol
    private let managerQueue = DispatchQueue(label: "chat.bitchat.noise.manager", attributes: .concurrent)
    
    // Callbacks
    var onSessionEstablished: ((Peer, Curve25519.KeyAgreement.PublicKey) -> Void)?
    var onSessionFailed: ((String, Error) -> Void)?
    
    init(localStaticKey: Curve25519.KeyAgreement.PrivateKey, keychain: KeychainManagerProtocol) {
        self.localStaticKey = localStaticKey
        self.keychain = keychain
    }
    
    // MARK: - Session Management
    
    func createSession(for peer: Peer, role: NoiseRole) -> NoiseSession {
        return managerQueue.sync(flags: .barrier) {
            let session = SecureNoiseSession(
                peer: peer,
                role: role,
                keychain: keychain,
                localStaticKey: localStaticKey
            )
            sessions[peer] = session
            return session
        }
    }
    
    func getSession(for peer: Peer) -> NoiseSession? {
        return managerQueue.sync {
            return sessions[peer]
        }
    }
    
    func removeSession(for peer: Peer) {
        managerQueue.sync(flags: .barrier) {
            if let session = sessions[peer] {
                if session.isEstablished() {
                    SecureLogger.info(.sessionExpired(peerID: peer.id))
                }
                // Clear sensitive data before removing
                session.reset()
            }
            _ = sessions.removeValue(forKey: peer)
        }
    }

    func removeAllSessions() {
        managerQueue.sync(flags: .barrier) {
            for (_, session) in sessions {
                session.reset()
            }
            sessions.removeAll()
        }
    }
    
    func getEstablishedSessions() -> [Peer: NoiseSession] {
        return managerQueue.sync {
            return sessions.filter { $0.value.isEstablished() }
        }
    }
    
    // MARK: - Handshake Helpers
    
    func initiateHandshake(with peer: Peer) throws -> Data {
        return try managerQueue.sync(flags: .barrier) {
            // Check if we already have an established session
            if let existingSession = sessions[peer], existingSession.isEstablished() {
                // Session already established, don't recreate
                throw NoiseSessionError.alreadyEstablished
            }
            
            // Remove any existing non-established session
            if let existingSession = sessions[peer], !existingSession.isEstablished() {
                _ = sessions.removeValue(forKey: peer)
            }
            
            // Create new initiator session
            let session = SecureNoiseSession(
                peer: peer,
                role: .initiator,
                keychain: keychain,
                localStaticKey: localStaticKey
            )
            sessions[peer] = session
            
            do {
                let handshakeData = try session.startHandshake()
                return handshakeData
            } catch {
                // Clean up failed session
                _ = sessions.removeValue(forKey: peer)
                SecureLogger.error(.handshakeFailed(peerID: peer.id, error: error.localizedDescription))
                throw error
            }
        }
    }
    
    func handleIncomingHandshake(from peer: Peer, message: Data) throws -> Data? {
        // Process everything within the synchronized block to prevent race conditions
        return try managerQueue.sync(flags: .barrier) {
            var shouldCreateNew = false
            var existingSession: NoiseSession? = nil
            
            if let existing = sessions[peer] {
                // If we have an established session, the peer must have cleared their session
                // for a good reason (e.g., decryption failure, restart, etc.)
                // We should accept the new handshake to re-establish encryption
                if existing.isEstablished() {
                    SecureLogger.info("Accepting handshake from \(peer.id) despite existing session - peer likely cleared their session", category: .session)
                    _ = sessions.removeValue(forKey: peer)
                    shouldCreateNew = true
                } else {
                    // If we're in the middle of a handshake and receive a new initiation,
                    // reset and start fresh (the other side may have restarted)
                    if existing.getState() == .handshaking && message.count == 32 {
                        _ = sessions.removeValue(forKey: peer)
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
                    peer: peer,
                    role: .responder,
                    keychain: keychain,
                    localStaticKey: localStaticKey
                )
                sessions[peer] = newSession
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
                            self?.onSessionEstablished?(peer, remoteKey)
                        }
                    }
                }
                
                return response
            } catch {
                // Reset the session on handshake failure so next attempt can start fresh
                _ = sessions.removeValue(forKey: peer)
                
                // Schedule callback outside the synchronized block to prevent deadlock
                DispatchQueue.global().async { [weak self] in
                    self?.onSessionFailed?(peer.id, error)
                }
                
                SecureLogger.error(.handshakeFailed(peerID: peer.id, error: error.localizedDescription))
                throw error
            }
        }
    }
    
    // MARK: - Encryption/Decryption
    
    func encrypt(_ plaintext: Data, for peer: Peer) throws -> Data {
        guard let session = getSession(for: peer) else {
            throw NoiseSessionError.sessionNotFound
        }
        
        return try session.encrypt(plaintext)
    }
    
    func decrypt(_ ciphertext: Data, from peer: Peer) throws -> Data {
        guard let session = getSession(for: peer) else {
            throw NoiseSessionError.sessionNotFound
        }
        
        return try session.decrypt(ciphertext)
    }
    
    // MARK: - Key Management
    
    func getRemoteStaticKey(for peer: Peer) -> Curve25519.KeyAgreement.PublicKey? {
        return getSession(for: peer)?.getRemoteStaticPublicKey()
    }
    
    func getHandshakeHash(for peer: Peer) -> Data? {
        return getSession(for: peer)?.getHandshakeHash()
    }
    
    // MARK: - Session Rekeying
    
    func getSessionsNeedingRekey() -> [(peer: Peer, needsRekey: Bool)] {
        return managerQueue.sync {
            var needingRekey: [(peer: Peer, needsRekey: Bool)] = []
            
            for (peer, session) in sessions {
                if let secureSession = session as? SecureNoiseSession,
                   secureSession.isEstablished(),
                   secureSession.needsRenegotiation() {
                    needingRekey.append((peer: peer, needsRekey: true))
                }
            }
            
            return needingRekey
        }
    }
    
    func initiateRekey(for peer: Peer) throws {
        // Remove old session
        removeSession(for: peer)
        
        // Initiate new handshake
        _ = try initiateHandshake(with: peer)
        
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
