//
// NoiseSessionManager.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import CryptoKit
import Foundation

final class NoiseSessionManager {
    private var sessions: [PeerID: NoiseSession] = [:]
    private let localStaticKey: Curve25519.KeyAgreement.PrivateKey
    private let keychain: KeychainManagerProtocol
    private let managerQueue = DispatchQueue(label: "chat.bitchat.noise.manager", attributes: .concurrent)
    
    // Callbacks
    var onSessionEstablished: ((PeerID, Curve25519.KeyAgreement.PublicKey) -> Void)?
    var onSessionFailed: ((PeerID, Error) -> Void)?
    
    init(localStaticKey: Curve25519.KeyAgreement.PrivateKey, keychain: KeychainManagerProtocol) {
        self.localStaticKey = localStaticKey
        self.keychain = keychain
    }
    
    // MARK: - Session Management
    
    func getSession(for peerID: PeerID) -> NoiseSession? {
        return managerQueue.sync {
            return sessions[peerID]
        }
    }
    
    func removeSession(for peerID: PeerID) {
        managerQueue.sync(flags: .barrier) {
            if let session = sessions.removeValue(forKey: peerID) {
                session.reset() // Clear sensitive data before removing
            }
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
    
    // MARK: - Handshake Helpers
    
    func initiateHandshake(with peerID: PeerID) throws -> Data {
        return try managerQueue.sync(flags: .barrier) {
            // Check if we already have an established session
            if let existingSession = sessions[peerID], existingSession.isEstablished() {
                // Session already established, don't recreate
                throw NoiseSessionError.alreadyEstablished
            }
            
            // Remove any existing non-established session
            if let existingSession = sessions[peerID], !existingSession.isEstablished() {
                _ = sessions.removeValue(forKey: peerID)
            }
            
            // Create new initiator session
            let session = SecureNoiseSession(
                peerID: peerID,
                role: .initiator,
                keychain: keychain,
                localStaticKey: localStaticKey
            )
            sessions[peerID] = session
            
            do {
                let handshakeData = try session.startHandshake()
                return handshakeData
            } catch {
                // Clean up failed session
                _ = sessions.removeValue(forKey: peerID)
                SecureLogger.error(.handshakeFailed(peerID: peerID.id, error: error.localizedDescription))
                throw error
            }
        }
    }
    
    func handleIncomingHandshake(from peerID: PeerID, message: Data) throws -> Data? {
        // Process everything within the synchronized block to prevent race conditions
        return try managerQueue.sync(flags: .barrier) {
            var shouldCreateNew = false
            var existingSession: NoiseSession? = nil
            
            if let existing = sessions[peerID] {
                // If we have an established session, the peer must have cleared their session
                // for a good reason (e.g., decryption failure, restart, etc.)
                // We should accept the new handshake to re-establish encryption
                if existing.isEstablished() {
                    SecureLogger.info("Accepting handshake from \(peerID) despite existing session - peer likely cleared their session", category: .session)
                    _ = sessions.removeValue(forKey: peerID)
                    shouldCreateNew = true
                } else {
                    // If we're in the middle of a handshake and receive a new initiation,
                    // reset and start fresh (the other side may have restarted)
                    if existing.getState() == .handshaking && message.count == 32 {
                        _ = sessions.removeValue(forKey: peerID)
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
                    keychain: keychain,
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
                _ = sessions.removeValue(forKey: peerID)
                
                // Schedule callback outside the synchronized block to prevent deadlock
                DispatchQueue.global().async { [weak self] in
                    self?.onSessionFailed?(peerID, error)
                }
                
                SecureLogger.error(.handshakeFailed(peerID: peerID.id, error: error.localizedDescription))
                throw error
            }
        }
    }
    
    // MARK: - Encryption/Decryption
    
    func encrypt(_ plaintext: Data, for peerID: PeerID) throws -> Data {
        guard let session = getSession(for: peerID) else {
            throw NoiseSessionError.sessionNotFound
        }
        
        return try session.encrypt(plaintext)
    }
    
    func decrypt(_ ciphertext: Data, from peerID: PeerID) throws -> Data {
        guard let session = getSession(for: peerID) else {
            throw NoiseSessionError.sessionNotFound
        }
        
        return try session.decrypt(ciphertext)
    }
    
    // MARK: - Key Management
    
    func getRemoteStaticKey(for peerID: PeerID) -> Curve25519.KeyAgreement.PublicKey? {
        return getSession(for: peerID)?.getRemoteStaticPublicKey()
    }
    
    // MARK: - Session Rekeying
    
    func getSessionsNeedingRekey() -> [(peerID: PeerID, needsRekey: Bool)] {
        return managerQueue.sync {
            var needingRekey: [(peerID: PeerID, needsRekey: Bool)] = []
            
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
    
    func initiateRekey(for peerID: PeerID) throws {
        // Remove old session
        removeSession(for: peerID)
        
        // Initiate new handshake
        _ = try initiateHandshake(with: peerID)
    }
}
