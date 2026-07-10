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
import BitFoundation

final class NoiseSessionManager {
    private var sessions: [PeerID: NoiseSession] = [:]
    /// A responder rehandshake must not evict a working transport session
    /// before the candidate proves that its authenticated static key belongs
    /// to the claimed wire ID. Candidates therefore live outside `sessions`
    /// until the XX handshake completes and the binding is validated.
    private var responderCandidates: [PeerID: NoiseSession] = [:]
    private let sessionFactory: (PeerID, NoiseRole) -> NoiseSession
    private let managerQueue = DispatchQueue(label: "chat.bitchat.noise.manager", attributes: .concurrent)
    
    // Callbacks
    var onSessionEstablished: ((PeerID, Curve25519.KeyAgreement.PublicKey) -> Void)?
    var onSessionFailed: ((PeerID, Error) -> Void)?
    
    init(localStaticKey: Curve25519.KeyAgreement.PrivateKey, keychain: KeychainManagerProtocol) {
        self.sessionFactory = { peerID, role in
            SecureNoiseSession(
                peerID: peerID,
                role: role,
                keychain: keychain,
                localStaticKey: localStaticKey
            )
        }
    }

    #if DEBUG
    init(
        localStaticKey _: Curve25519.KeyAgreement.PrivateKey,
        keychain _: KeychainManagerProtocol,
        sessionFactory: @escaping (PeerID, NoiseRole) -> NoiseSession
    ) {
        self.sessionFactory = sessionFactory
    }
    #endif
    
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
            if let candidate = responderCandidates.removeValue(forKey: peerID) {
                candidate.reset()
            }
        }
    }

    func removeAllSessions() {
        managerQueue.sync(flags: .barrier) {
            for (_, session) in sessions {
                session.reset()
            }
            for (_, candidate) in responderCandidates {
                candidate.reset()
            }
            sessions.removeAll()
            responderCandidates.removeAll()
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
                existingSession.reset()
            }
            
            // Create new initiator session
            let session = sessionFactory(peerID, .initiator)
            sessions[peerID] = session
            
            do {
                let handshakeData = try session.startHandshake()
                return handshakeData
            } catch {
                // Clean up failed session
                _ = sessions.removeValue(forKey: peerID)
                session.reset()
                SecureLogger.error(.handshakeFailed(peerID: peerID.id, error: error.localizedDescription))
                throw error
            }
        }
    }
    
    func handleIncomingHandshake(from peerID: PeerID, message: Data) throws -> Data? {
        // Process everything within the synchronized block to prevent race conditions
        return try managerQueue.sync(flags: .barrier) {
            let session: NoiseSession
            let isReplacementCandidate: Bool

            if let candidate = responderCandidates[peerID] {
                // A fresh XX message 1 supersedes an incomplete candidate,
                // but never the established session it is trying to replace.
                if message.count == NoiseSecurityConstants.xxInitialMessageSize {
                    candidate.reset()
                    let replacement = sessionFactory(peerID, .responder)
                    responderCandidates[peerID] = replacement
                    session = replacement
                } else {
                    session = candidate
                }
                isReplacementCandidate = true
            } else if let existing = sessions[peerID] {
                if existing.isEstablished() {
                    SecureLogger.info(
                        "Validating replacement handshake from \(peerID) while preserving the established session",
                        category: .session
                    )
                    let candidate = sessionFactory(peerID, .responder)
                    responderCandidates[peerID] = candidate
                    session = candidate
                    isReplacementCandidate = true
                } else if existing.getState() == .handshaking,
                          message.count == NoiseSecurityConstants.xxInitialMessageSize {
                    // No established transport state exists to preserve. A
                    // fresh initiation replaces the incomplete handshake.
                    _ = sessions.removeValue(forKey: peerID)
                    existing.reset()
                    let replacement = sessionFactory(peerID, .responder)
                    sessions[peerID] = replacement
                    session = replacement
                    isReplacementCandidate = false
                } else {
                    session = existing
                    isReplacementCandidate = false
                }
            } else {
                let newSession = sessionFactory(peerID, .responder)
                sessions[peerID] = newSession
                session = newSession
                isReplacementCandidate = false
            }
            
            // Process the handshake message within the synchronized block
            do {
                let response = try session.processHandshakeMessage(message)
                
                // Check if session is established after processing
                if session.isEstablished() {
                    guard let remoteKey = session.getRemoteStaticPublicKey(),
                          authenticatedRemoteKey(remoteKey, matches: peerID) else {
                        throw NoiseSessionError.peerIdentityMismatch
                    }

                    if isReplacementCandidate {
                        _ = responderCandidates.removeValue(forKey: peerID)
                        let previous = sessions.updateValue(session, forKey: peerID)
                        if let previous, previous !== session {
                            previous.reset()
                        }
                    }

                    // Schedule callback outside the synchronized block to prevent deadlock
                    DispatchQueue.global().async { [weak self] in
                        self?.onSessionEstablished?(peerID, remoteKey)
                    }
                }
                
                return response
            } catch {
                // A failed candidate is discarded without touching the
                // established session. Ordinary failed handshakes retain the
                // historical cleanup behavior.
                if isReplacementCandidate {
                    if let storedCandidate = responderCandidates[peerID],
                       storedCandidate === session {
                        _ = responderCandidates.removeValue(forKey: peerID)
                    }
                } else if let storedSession = sessions[peerID],
                          storedSession === session {
                    _ = sessions.removeValue(forKey: peerID)
                }
                session.reset()
                
                // Schedule callback outside the synchronized block to prevent deadlock
                DispatchQueue.global().async { [weak self] in
                    self?.onSessionFailed?(peerID, error)
                }
                
                SecureLogger.error(.handshakeFailed(peerID: peerID.id, error: error.localizedDescription))
                throw error
            }
        }
    }

    /// Mesh handshakes normally use a 16-hex wire ID. Full Noise-key IDs are
    /// also accepted by internal callers when they exactly match the static
    /// key. Non-wire identifiers remain available to protocol test harnesses;
    /// BLE packet ingress always supplies a short hexadecimal ID.
    private func authenticatedRemoteKey(
        _ remoteKey: Curve25519.KeyAgreement.PublicKey,
        matches claimedPeerID: PeerID
    ) -> Bool {
        let rawKey = remoteKey.rawRepresentation
        if claimedPeerID.isShort {
            return PeerID(publicKey: rawKey) == claimedPeerID
        }
        if let claimedNoiseKey = claimedPeerID.noiseKey {
            return claimedNoiseKey == rawKey
        }
        return true
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
