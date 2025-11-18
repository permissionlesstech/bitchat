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

class NoiseSession {
    let peerID: PeerID
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
                // Get transport ciphers
                let (send, receive) = try handshake.getTransportCiphers(useExtractedNonce: true)
                sendCipher = send
                receiveCipher = receive
                
                // Store remote static key
                remoteStaticPublicKey = handshake.getRemoteStaticPublicKey()
                
                // Store handshake hash for channel binding
                handshakeHash = handshake.getHandshakeHash()
                
                state = .established
                handshakeState = nil // Clear handshake state
                
                SecureLogger.debug("NoiseSession[\(peerID)]: Handshake complete (no response needed), transitioning to established")
                SecureLogger.info(.handshakeCompleted(peerID: peerID.id))
                
                return nil
            } else {
                // Generate response
                let response = try handshake.writeMessage()
                sentHandshakeMessages.append(response)
                SecureLogger.debug("NoiseSession[\(peerID)]: Generated handshake response of size \(response.count)")
                
                // Check if handshake is complete after writing
                if handshake.isHandshakeComplete() {
                    // Get transport ciphers
                    let (send, receive) = try handshake.getTransportCiphers(useExtractedNonce: true)
                    sendCipher = send
                    receiveCipher = receive
                    
                    // Store remote static key
                    remoteStaticPublicKey = handshake.getRemoteStaticPublicKey()
                    
                    // Store handshake hash for channel binding
                    handshakeHash = handshake.getHandshakeHash()
                    
                    state = .established
                    handshakeState = nil // Clear handshake state
                    
                    SecureLogger.debug("NoiseSession[\(peerID)]: Handshake complete after writing response, transitioning to established")
                    SecureLogger.info(.handshakeCompleted(peerID: peerID.id))
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
                SecureLogger.info(.sessionExpired(peerID: peerID.id))
            }
        }
    }
}
