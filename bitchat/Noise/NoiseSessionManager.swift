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

struct NoiseHandshakeProcessingResult {
    let response: Data?
    let didEstablishAuthenticatedSession: Bool
}

struct NoiseHandshakeInitiation: Equatable, Sendable {
    let payload: Data
    let attemptID: UUID
}

final class NoiseSessionManager {
    private var sessions: [PeerID: NoiseSession] = [:]
    /// Opaque identity for each exact entry in `sessions`. The generation is
    /// created and removed under the same barrier as the session itself, so a
    /// caller can never authenticate data with one session and lease another.
    private var sessionGenerations: [PeerID: UUID] = [:]
    /// One-time handoff tokens prevent a prepared XX message 1 from leaving
    /// after an inbound collision has already changed this peer's role.
    private var ordinaryInitiationIDs: [PeerID: UUID] = [:]
    private struct QuarantinedTransport {
        let session: NoiseSession
        let generation: UUID
        /// Duplicate message 1 packets replace the incomplete responder but
        /// never extend the original rollback window indefinitely.
        let rollbackDeadline: DispatchTime
    }
    /// An unauthenticated inbound message 1 cannot keep old sending keys live,
    /// but it also must not permanently destroy a victim session. The old
    /// transport remains receive-only while the ordinary responder proves the
    /// claimed static identity, then is discarded on success or restored on
    /// bounded failure.
    private var quarantinedTransports: [PeerID: QuarantinedTransport] = [:]
    private var quarantinedResponderTimeouts: [PeerID: DispatchWorkItem] = [:]
    private let sessionFactory: (PeerID, NoiseRole) -> NoiseSession
    private let ordinaryResponderHandshakeTimeout: TimeInterval
    private let managerQueue = DispatchQueue(label: "chat.bitchat.noise.manager", attributes: .concurrent)
    
    // Callbacks
    var onSessionEstablished: ((PeerID, Curve25519.KeyAgreement.PublicKey, UUID) -> Void)?
    var onSessionRestored: ((PeerID, UUID) -> Void)?
    var onSessionFailed: ((PeerID, Error) -> Void)?
    
    init(
        localStaticKey: Curve25519.KeyAgreement.PrivateKey,
        keychain: KeychainManagerProtocol,
        ordinaryResponderHandshakeTimeout: TimeInterval =
            NoiseSecurityConstants.ordinaryResponderHandshakeTimeout
    ) {
        self.ordinaryResponderHandshakeTimeout = ordinaryResponderHandshakeTimeout
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
        ordinaryResponderHandshakeTimeout: TimeInterval =
            NoiseSecurityConstants.ordinaryResponderHandshakeTimeout,
        sessionFactory: @escaping (PeerID, NoiseRole) -> NoiseSession
    ) {
        self.ordinaryResponderHandshakeTimeout = ordinaryResponderHandshakeTimeout
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
            removeSessionLocked(for: peerID)
        }
    }

    private func removeSessionLocked(for peerID: PeerID) {
        if let session = sessions.removeValue(forKey: peerID) {
            session.reset() // Clear sensitive data before removing
        }
        if let quarantined = quarantinedTransports.removeValue(forKey: peerID) {
            quarantined.session.reset()
        }
        quarantinedResponderTimeouts.removeValue(forKey: peerID)?.cancel()
        sessionGenerations.removeValue(forKey: peerID)
        ordinaryInitiationIDs.removeValue(forKey: peerID)
    }

    func removeAllSessions() {
        managerQueue.sync(flags: .barrier) {
            for (_, session) in sessions {
                session.reset()
            }
            for (_, quarantined) in quarantinedTransports {
                quarantined.session.reset()
            }
            for (_, timeout) in quarantinedResponderTimeouts {
                timeout.cancel()
            }
            sessions.removeAll()
            sessionGenerations.removeAll()
            ordinaryInitiationIDs.removeAll()
            quarantinedTransports.removeAll()
            quarantinedResponderTimeouts.removeAll()
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
                sessionGenerations.removeValue(forKey: peerID)
                ordinaryInitiationIDs.removeValue(forKey: peerID)
                existingSession.reset()
            }
            
            // Create new initiator session
            let session = sessionFactory(peerID, .initiator)
            sessions[peerID] = session
            sessionGenerations[peerID] = UUID()
            
            do {
                let handshakeData = try session.startHandshake()
                return handshakeData
            } catch {
                // Clean up failed session
                _ = sessions.removeValue(forKey: peerID)
                sessionGenerations.removeValue(forKey: peerID)
                ordinaryInitiationIDs.removeValue(forKey: peerID)
                session.reset()
                SecureLogger.error(.handshakeFailed(peerID: peerID.id, error: error.localizedDescription))
                throw error
            }
        }
    }

    /// Prepares an ordinary reconnect before atomically retiring the current
    /// transport. Authorization and handshake-start failure leave the working
    /// session untouched. Once this returns, encryption observes only the new
    /// handshaking session and must queue until it establishes.
    func initiateReconnectHandshake(
        with peerID: PeerID,
        authorize: () throws -> Void
    ) throws -> NoiseHandshakeInitiation {
        try managerQueue.sync(flags: .barrier) {
            guard let established = sessions[peerID],
                  established.isEstablished() else {
                throw NoiseSessionError.notEstablished
            }
            try authorize()

            let next = sessionFactory(peerID, .initiator)
            let payload: Data
            do {
                payload = try next.startHandshake()
            } catch {
                next.reset()
                SecureLogger.error(
                    .handshakeFailed(
                        peerID: peerID.id,
                        error: error.localizedDescription
                    )
                )
                throw error
            }

            removeSessionLocked(for: peerID)
            let attemptID = UUID()
            sessions[peerID] = next
            sessionGenerations[peerID] = UUID()
            ordinaryInitiationIDs[peerID] = attemptID
            return NoiseHandshakeInitiation(
                payload: payload,
                attemptID: attemptID
            )
        }
    }

    /// Claims a prepared message 1 exactly once. A crossed inbound initiation
    /// that already made this peer a responder invalidates the token.
    func claimHandshakeInitiation(
        _ initiation: NoiseHandshakeInitiation,
        for peerID: PeerID
    ) -> Data? {
        managerQueue.sync(flags: .barrier) {
            guard ordinaryInitiationIDs[peerID] == initiation.attemptID,
                  let session = sessions[peerID],
                  session.role == .initiator,
                  session.getState() == .handshaking else {
                return nil
            }
            ordinaryInitiationIDs.removeValue(forKey: peerID)
            return initiation.payload
        }
    }
    
    func handleIncomingHandshake(from peerID: PeerID, message: Data) throws -> Data? {
        try handleIncomingHandshakeWithResult(
            from: peerID,
            message: message
        ).response
    }

    /// Processes one exact handshake candidate and reports whether that
    /// candidate completed authenticated establishment. The peer's retained
    /// session may already be established while a replacement is only on
    /// message one, so callers must not infer candidate completion from the
    /// peer-level session table.
    func handleIncomingHandshakeWithResult(
        from peerID: PeerID,
        message: Data
    ) throws -> NoiseHandshakeProcessingResult {
        // Process everything within the synchronized block to prevent race conditions.
        // Return establishment metadata and publish the callback only after the
        // manager barrier is released, avoiding both a deadlock and a window in
        // which `processHandshakeMessage` returns before authentication state.
        let result: (
            response: Data?,
            establishedSession: (
                remoteKey: Curve25519.KeyAgreement.PublicKey,
                generation: UUID
            )?
        ) = try managerQueue.sync(flags: .barrier) {
            let session: NoiseSession

            if let existing = sessions[peerID],
               existing.isEstablished()
                    || message.count
                        == NoiseSecurityConstants.xxInitialMessageSize {
                if existing.isEstablished(),
                   let generation = sessionGenerations[peerID] {
                    // Message 1 cannot prove that the remote still owns its
                    // old keys. Remove them from every sending/generation API
                    // immediately, but retain the object solely for bounded
                    // rollback until the ordinary responder authenticates.
                    _ = sessions.removeValue(forKey: peerID)
                    sessionGenerations.removeValue(forKey: peerID)
                    ordinaryInitiationIDs.removeValue(forKey: peerID)
                    if let prior = quarantinedTransports.updateValue(
                        QuarantinedTransport(
                            session: existing,
                            generation: generation,
                            rollbackDeadline: .now()
                                + ordinaryResponderHandshakeTimeout
                        ),
                        forKey: peerID
                    ) {
                        prior.session.reset()
                    }
                } else {
                    _ = sessions.removeValue(forKey: peerID)
                    sessionGenerations.removeValue(forKey: peerID)
                    ordinaryInitiationIDs.removeValue(forKey: peerID)
                    existing.reset()
                }
                let replacement = sessionFactory(peerID, .responder)
                sessions[peerID] = replacement
                sessionGenerations[peerID] = UUID()
                session = replacement
                if quarantinedTransports[peerID] != nil {
                    scheduleQuarantinedResponderTimeoutLocked(
                        replacement,
                        for: peerID
                    )
                }
            } else if let existing = sessions[peerID] {
                session = existing
            } else {
                let newSession = sessionFactory(peerID, .responder)
                sessions[peerID] = newSession
                sessionGenerations[peerID] = UUID()
                session = newSession
            }
            
            // Process the handshake message within the synchronized block
            do {
                let response = try session.processHandshakeMessage(message)
                
                // Check the exact session that processed this message. A
                // preserved peer-level session can remain established while a
                // replacement candidate is still unauthenticated.
                var establishedSession: (
                    remoteKey: Curve25519.KeyAgreement.PublicKey,
                    generation: UUID
                )?
                if session.isEstablished() {
                    guard let remoteKey = session.getRemoteStaticPublicKey(),
                          authenticatedRemoteKey(remoteKey, matches: peerID) else {
                        throw NoiseSessionError.peerIdentityMismatch
                    }

                    if let quarantined = quarantinedTransports.removeValue(
                        forKey: peerID
                    ) {
                        quarantinedResponderTimeouts.removeValue(
                            forKey: peerID
                        )?.cancel()
                        quarantined.session.reset()
                    }
                    ordinaryInitiationIDs.removeValue(forKey: peerID)
                    guard let generation = sessionGenerations[peerID] else {
                        throw NoiseEncryptionError.sessionNotEstablished
                    }
                    establishedSession = (remoteKey, generation)
                }
                
                return (response, establishedSession)
            } catch {
                if let storedSession = sessions[peerID],
                   storedSession === session {
                    _ = sessions.removeValue(forKey: peerID)
                    sessionGenerations.removeValue(forKey: peerID)
                }
                ordinaryInitiationIDs.removeValue(forKey: peerID)
                session.reset()
                quarantinedResponderTimeouts.removeValue(forKey: peerID)?.cancel()
                let restoredGeneration: UUID?
                if let quarantined = quarantinedTransports.removeValue(forKey: peerID) {
                    sessions[peerID] = quarantined.session
                    sessionGenerations[peerID] = quarantined.generation
                    restoredGeneration = quarantined.generation
                } else {
                    restoredGeneration = nil
                }
                
                // Schedule callback outside the synchronized block to prevent deadlock
                DispatchQueue.global().async { [weak self] in
                    if let restoredGeneration {
                        self?.onSessionRestored?(peerID, restoredGeneration)
                    }
                    self?.onSessionFailed?(peerID, error)
                }
                
                SecureLogger.error(.handshakeFailed(peerID: peerID.id, error: error.localizedDescription))
                throw error
            }
        }

        if let established = result.establishedSession {
            onSessionEstablished?(peerID, established.remoteKey, established.generation)
        }
        return NoiseHandshakeProcessingResult(
            response: result.response,
            didEstablishAuthenticatedSession: result.establishedSession != nil
        )
    }

    private func scheduleQuarantinedResponderTimeoutLocked(
        _ responder: NoiseSession,
        for peerID: PeerID
    ) {
        quarantinedResponderTimeouts.removeValue(forKey: peerID)?.cancel()
        let timeout = DispatchWorkItem(flags: .barrier) { [weak self, weak responder] in
            guard let self,
                  let responder,
                  let current = self.sessions[peerID],
                  current === responder,
                  current.role == .responder,
                  current.getState() == .handshaking,
                  let quarantined = self.quarantinedTransports.removeValue(
                    forKey: peerID
                  ) else {
                return
            }

            _ = self.sessions.removeValue(forKey: peerID)
            self.sessionGenerations.removeValue(forKey: peerID)
            self.ordinaryInitiationIDs.removeValue(forKey: peerID)
            self.quarantinedResponderTimeouts.removeValue(forKey: peerID)
            responder.reset()
            self.sessions[peerID] = quarantined.session
            self.sessionGenerations[peerID] = quarantined.generation
            SecureLogger.debug(
                "Ordinary responder handshake with \(peerID) timed out; restored quarantined transport",
                category: .session
            )
            DispatchQueue.global().async { [weak self] in
                self?.onSessionRestored?(peerID, quarantined.generation)
            }
        }
        quarantinedResponderTimeouts[peerID] = timeout
        guard let deadline = quarantinedTransports[peerID]?.rollbackDeadline else {
            quarantinedResponderTimeouts.removeValue(forKey: peerID)
            return
        }
        managerQueue.asyncAfter(deadline: deadline, execute: timeout)
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
        try managerQueue.sync {
            guard let session = sessions[peerID] else {
                throw NoiseSessionError.sessionNotFound
            }
            return try session.encrypt(plaintext)
        }
    }

    /// Encrypts only if `expected` still names the current established entry.
    /// A rekey between capability proof and media encryption therefore fails
    /// closed instead of sending on an unproven reconnect session.
    func encrypt(
        _ plaintext: Data,
        for peerID: PeerID,
        expectedSessionGeneration expected: UUID
    ) throws -> Data {
        try managerQueue.sync {
            guard let session = sessions[peerID],
                  session.isEstablished(),
                  sessionGenerations[peerID] == expected else {
                throw NoiseEncryptionError.sessionNotEstablished
            }
            return try session.encrypt(plaintext)
        }
    }
    
    func decrypt(_ ciphertext: Data, from peerID: PeerID) throws -> Data {
        try decryptWithSessionGeneration(ciphertext, from: peerID).plaintext
    }

    func sessionGeneration(for peerID: PeerID) -> UUID? {
        managerQueue.sync {
            guard sessions[peerID]?.isEstablished() == true else { return nil }
            return sessionGenerations[peerID]
        }
    }

    /// Decrypts while holding the manager's read lease. Session promotion and
    /// removal require its barrier, so the returned generation always names
    /// the exact session object that authenticated these bytes.
    func decryptWithSessionGeneration(
        _ ciphertext: Data,
        from peerID: PeerID
    ) throws -> (plaintext: Data, sessionGeneration: UUID) {
        try managerQueue.sync {
            if let session = sessions[peerID],
               session.isEstablished(),
               let generation = sessionGenerations[peerID] {
                return (try session.decrypt(ciphertext), generation)
            }

            // Quarantine is receive-only: old keys cannot encrypt, advertise
            // an established generation, or authorize outbound state, but
            // legitimate in-flight ciphertext from the retained peer may
            // still advance and later resume on rollback.
            if let responder = sessions[peerID],
               responder.role == .responder,
               responder.getState() == .handshaking,
               let quarantined = quarantinedTransports[peerID] {
                return (
                    try quarantined.session.decrypt(ciphertext),
                    quarantined.generation
                )
            }

            if sessions[peerID] == nil, quarantinedTransports[peerID] == nil {
                throw NoiseSessionError.sessionNotFound
            }
            throw NoiseEncryptionError.sessionNotEstablished
        }
    }

    func hasReceiveSession(for peerID: PeerID) -> Bool {
        managerQueue.sync {
            if sessions[peerID]?.isEstablished() == true {
                return true
            }
            guard let responder = sessions[peerID],
                  responder.role == .responder,
                  responder.getState() == .handshaking else {
                return false
            }
            return quarantinedTransports[peerID]?.session.isEstablished() == true
        }
    }

    /// Runs a state commit under a read lease for the exact established
    /// session. Rekey, reconnect, and removal all need the same barrier.
    func withCurrentSessionGeneration<Result>(
        for peerID: PeerID,
        expected: UUID,
        _ body: () -> Result
    ) -> Result? {
        managerQueue.sync {
            guard sessions[peerID]?.isEstablished() == true,
                  sessionGenerations[peerID] == expected else { return nil }
            return body()
        }
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
    
    func initiateRekey(for peerID: PeerID) throws -> Data {
        let initiation = try initiateReconnectHandshake(
            with: peerID,
            authorize: {}
        )
        guard let payload = claimHandshakeInitiation(initiation, for: peerID) else {
            throw NoiseSessionError.invalidState
        }
        return payload
    }
}
