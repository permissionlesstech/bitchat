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

struct NoiseHandshakeRecoveryRequest: Equatable, Sendable {
    let peerID: PeerID
    fileprivate let recoveryID: UUID
}

enum NoiseHandshakeRecoveryPreparation {
    case ordinary(NoiseHandshakeInitiation)
    case transferred
}

/// Why a quarantined transport became the active session again.
enum NoiseSessionRestoreReason: Equatable, Sendable {
    /// The replacement attempt failed terminally (claimed-identity mismatch,
    /// or a failure that owns no convergence retry). The counterpart never
    /// finished replacement keys, so the restored generation is immediately
    /// valid for outbound traffic.
    case terminal
    /// The responder window expired — or a recoverable failure occurred —
    /// and this manager owns one mandatory convergence retry. The counterpart
    /// may already hold replacement keys that discarded the restored ones, so
    /// outbound queue drains must wait for the retry to conclude.
    case pendingConvergence
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
    private var ordinaryInitiatorTimeouts: [PeerID: DispatchWorkItem] = [:]
    private var ordinaryInitiatorRetryNotifications: [PeerID: Bool] = [:]
    private var ordinaryResponderTimeouts: [PeerID: DispatchWorkItem] = [:]
    private var ordinaryResponderDeadlines: [PeerID: DispatchTime] = [:]
    private var ordinaryResponderRetryNotifications: [PeerID: Bool] = [:]
    private var ordinaryRespondersCreatedByYield: Set<PeerID> = []
    private var recentOrdinaryInitiatorCompletions: [PeerID: Date] = [:]
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
    private var quarantineRollbackCooldownUntil: [PeerID: Date] = [:]
    private var suppressedInitiationRecoveryTimeouts: [PeerID: DispatchWorkItem] = [:]
    private var delayedHandshakeRecoveryWorkItems: [PeerID: DispatchWorkItem] = [:]
    private var handshakeRecoveryCallbackIDs: [PeerID: UUID] = [:]
    private var pendingHandshakeRecoveryIDs: [PeerID: UUID] = [:]
    private let sessionFactory: (PeerID, NoiseRole) -> NoiseSession
    private let localPeerID: PeerID
    private let ordinaryHandshakeTimeout: TimeInterval
    private let ordinaryResponderHandshakeTimeout: TimeInterval
    private let recentInitiatorCompletionGracePeriod: TimeInterval
    private let ordinaryReconnectRollbackCooldown: TimeInterval
    private let managerQueue = DispatchQueue(label: "chat.bitchat.noise.manager", attributes: .concurrent)
    
    // Callbacks
    var onSessionEstablished: ((PeerID, Curve25519.KeyAgreement.PublicKey, UUID) -> Void)?
    var onSessionRestored: ((PeerID, UUID, NoiseSessionRestoreReason) -> Void)?
    var onSessionFailed: ((PeerID, Error) -> Void)?
    var onHandshakeRecoveryRequired: ((NoiseHandshakeRecoveryRequest) -> Void)?
    
    init(
        localStaticKey: Curve25519.KeyAgreement.PrivateKey,
        keychain: KeychainManagerProtocol,
        ordinaryHandshakeTimeout: TimeInterval =
            NoiseSecurityConstants.ordinaryHandshakeTimeout,
        ordinaryResponderHandshakeTimeout: TimeInterval =
            NoiseSecurityConstants.ordinaryResponderHandshakeTimeout,
        recentInitiatorCompletionGracePeriod: TimeInterval =
            NoiseSecurityConstants.recentInitiatorCompletionGracePeriod,
        ordinaryReconnectRollbackCooldown: TimeInterval =
            NoiseSecurityConstants.ordinaryReconnectRollbackCooldown
    ) {
        self.localPeerID = PeerID(publicKey: localStaticKey.publicKey.rawRepresentation)
        self.ordinaryHandshakeTimeout = ordinaryHandshakeTimeout
        self.ordinaryResponderHandshakeTimeout = ordinaryResponderHandshakeTimeout
        self.recentInitiatorCompletionGracePeriod =
            recentInitiatorCompletionGracePeriod
        self.ordinaryReconnectRollbackCooldown =
            ordinaryReconnectRollbackCooldown
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
        localStaticKey: Curve25519.KeyAgreement.PrivateKey,
        keychain _: KeychainManagerProtocol,
        ordinaryHandshakeTimeout: TimeInterval =
            NoiseSecurityConstants.ordinaryHandshakeTimeout,
        ordinaryResponderHandshakeTimeout: TimeInterval =
            NoiseSecurityConstants.ordinaryResponderHandshakeTimeout,
        recentInitiatorCompletionGracePeriod: TimeInterval =
            NoiseSecurityConstants.recentInitiatorCompletionGracePeriod,
        ordinaryReconnectRollbackCooldown: TimeInterval =
            NoiseSecurityConstants.ordinaryReconnectRollbackCooldown,
        sessionFactory: @escaping (PeerID, NoiseRole) -> NoiseSession
    ) {
        self.localPeerID = PeerID(publicKey: localStaticKey.publicKey.rawRepresentation)
        self.ordinaryHandshakeTimeout = ordinaryHandshakeTimeout
        self.ordinaryResponderHandshakeTimeout = ordinaryResponderHandshakeTimeout
        self.recentInitiatorCompletionGracePeriod =
            recentInitiatorCompletionGracePeriod
        self.ordinaryReconnectRollbackCooldown =
            ordinaryReconnectRollbackCooldown
        self.sessionFactory = sessionFactory
    }
    #endif
    
    // MARK: - Session Management
    
    func getSession(for peerID: PeerID) -> NoiseSession? {
        return managerQueue.sync {
            return sessions[peerID]
        }
    }

    /// Whether this peer has an inbound ordinary XX responder that still
    /// needs message 3 before its receive keys can become authoritative.
    func isAwaitingResponderHandshakeCompletion(for peerID: PeerID) -> Bool {
        managerQueue.sync {
            guard let session = sessions[peerID] else { return false }
            return session.role == .responder
                && session.getState() == .handshaking
        }
    }

    /// Transfers one bounded recovery generation to whatever ordinary XX
    /// handshake currently owns the peer, or starts the generation's single
    /// retry. The request token prevents stale transport callbacks from
    /// creating additional attempts.
    func prepareHandshakeRecovery(
        _ request: NoiseHandshakeRecoveryRequest,
        authorizeAttempt: () throws -> Void
    ) throws -> NoiseHandshakeRecoveryPreparation? {
        try managerQueue.sync(flags: .barrier) {
            let peerID = request.peerID
            guard pendingHandshakeRecoveryIDs[peerID] == request.recoveryID else {
                return nil
            }

            if let current = sessions[peerID],
               current.getState() == .handshaking {
                if current.role == .initiator {
                    scheduleOrdinaryInitiatorTimeoutLocked(
                        current,
                        for: peerID,
                        notifyOnTimeout: true
                    )
                } else {
                    // A recovery may transfer to a responder that raced ahead
                    // of the callback. Preserve an existing quarantine deadline
                    // so duplicate unauthenticated message 1 packets cannot
                    // extend the outbound pause.
                    scheduleOrdinaryResponderTimeoutLocked(
                        current,
                        for: peerID,
                        notifyOnTimeout: true,
                        createdByYield: true,
                        rearmDeadline: quarantinedTransports[peerID] == nil
                    )
                }
                return .transferred
            }

            do {
                try authorizeAttempt()
            } catch {
                redispatchHandshakeRecoveryLocked(
                    request,
                    after: NoiseSecurityConstants.handshakeRateLimitRecoveryDelay
                )
                throw error
            }

            let next = sessionFactory(peerID, .initiator)
            let payload: Data
            do {
                payload = try next.startHandshake()
            } catch {
                next.reset()
                redispatchHandshakeRecoveryLocked(
                    request,
                    after: NoiseSecurityConstants.handshakeCollisionRecoveryDelay
                )
                throw error
            }

            // Start before retiring a working transport. If preparation fails,
            // the established session and its generation are untouched.
            if let current = sessions.removeValue(forKey: peerID) {
                current.reset()
            }
            if let quarantined = quarantinedTransports.removeValue(forKey: peerID) {
                quarantined.session.reset()
            }
            sessionGenerations.removeValue(forKey: peerID)
            ordinaryInitiationIDs.removeValue(forKey: peerID)
            cancelOrdinaryInitiatorTimeoutLocked(for: peerID)
            cancelOrdinaryResponderTimeoutLocked(for: peerID)
            cancelSuppressedInitiationRecoveryLocked(for: peerID)
            recentOrdinaryInitiatorCompletions.removeValue(forKey: peerID)
            quarantineRollbackCooldownUntil.removeValue(forKey: peerID)

            let attemptID = UUID()
            sessions[peerID] = next
            sessionGenerations[peerID] = UUID()
            ordinaryInitiationIDs[peerID] = attemptID
            // This is the one retry owned by `request`; it may time out but
            // must not recursively mint another generation.
            scheduleOrdinaryInitiatorTimeoutLocked(
                next,
                for: peerID,
                notifyOnTimeout: false
            )
            consumeHandshakeRecoveryLocked(request)
            return .ordinary(
                NoiseHandshakeInitiation(
                    payload: payload,
                    attemptID: attemptID
                )
            )
        }
    }

    func cancelHandshakeRecovery(_ request: NoiseHandshakeRecoveryRequest) {
        managerQueue.sync(flags: .barrier) {
            consumeHandshakeRecoveryLocked(request)
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
        sessionGenerations.removeValue(forKey: peerID)
        ordinaryInitiationIDs.removeValue(forKey: peerID)
        cancelOrdinaryInitiatorTimeoutLocked(for: peerID)
        cancelOrdinaryResponderTimeoutLocked(for: peerID)
        recentOrdinaryInitiatorCompletions.removeValue(forKey: peerID)
        quarantineRollbackCooldownUntil.removeValue(forKey: peerID)
        cancelSuppressedInitiationRecoveryLocked(for: peerID)
        cancelDelayedHandshakeRecoveryLocked(for: peerID)
    }

    func removeAllSessions() {
        managerQueue.sync(flags: .barrier) {
            for (_, session) in sessions {
                session.reset()
            }
            for (_, quarantined) in quarantinedTransports {
                quarantined.session.reset()
            }
            for (_, timeout) in ordinaryInitiatorTimeouts {
                timeout.cancel()
            }
            for (_, timeout) in ordinaryResponderTimeouts {
                timeout.cancel()
            }
            for (_, timeout) in suppressedInitiationRecoveryTimeouts {
                timeout.cancel()
            }
            for (_, timeout) in delayedHandshakeRecoveryWorkItems {
                timeout.cancel()
            }
            sessions.removeAll()
            sessionGenerations.removeAll()
            ordinaryInitiationIDs.removeAll()
            ordinaryInitiatorTimeouts.removeAll()
            ordinaryInitiatorRetryNotifications.removeAll()
            ordinaryResponderTimeouts.removeAll()
            ordinaryResponderDeadlines.removeAll()
            ordinaryResponderRetryNotifications.removeAll()
            ordinaryRespondersCreatedByYield.removeAll()
            recentOrdinaryInitiatorCompletions.removeAll()
            quarantinedTransports.removeAll()
            quarantineRollbackCooldownUntil.removeAll()
            suppressedInitiationRecoveryTimeouts.removeAll()
            delayedHandshakeRecoveryWorkItems.removeAll()
            handshakeRecoveryCallbackIDs.removeAll()
            pendingHandshakeRecoveryIDs.removeAll()
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
                removeSessionLocked(for: peerID)
            }
            recentOrdinaryInitiatorCompletions.removeValue(forKey: peerID)
            
            // Create new initiator session
            let session = sessionFactory(peerID, .initiator)
            sessions[peerID] = session
            sessionGenerations[peerID] = UUID()
            
            do {
                let handshakeData = try session.startHandshake()
                scheduleOrdinaryInitiatorTimeoutLocked(
                    session,
                    for: peerID,
                    notifyOnTimeout: false
                )
                cancelDelayedHandshakeRecoveryLocked(for: peerID)
                return handshakeData
            } catch {
                // Clean up failed session
                _ = sessions.removeValue(forKey: peerID)
                sessionGenerations.removeValue(forKey: peerID)
                ordinaryInitiationIDs.removeValue(forKey: peerID)
                cancelOrdinaryInitiatorTimeoutLocked(for: peerID)
                session.reset()
                SecureLogger.error(.handshakeFailed(peerID: peerID.id, error: error.localizedDescription))
                throw error
            }
        }
    }

    /// Atomically starts an ordinary initiator only when no other session
    /// already owns the peer. BLE discovery can report the same peer on
    /// multiple links; combining the absence check, authorization, creation,
    /// and handoff token prevents two different message 1 packets escaping.
    func initiateHandshakeIfAbsent(
        with peerID: PeerID,
        notifyOnTimeout: Bool,
        authorize: () throws -> Void
    ) throws -> NoiseHandshakeInitiation? {
        try managerQueue.sync(flags: .barrier) {
            guard sessions[peerID] == nil,
                  quarantinedTransports[peerID] == nil else {
                return nil
            }
            try authorize()

            let session = sessionFactory(peerID, .initiator)
            do {
                let payload = try session.startHandshake()
                let attemptID = UUID()
                sessions[peerID] = session
                sessionGenerations[peerID] = UUID()
                ordinaryInitiationIDs[peerID] = attemptID
                recentOrdinaryInitiatorCompletions.removeValue(forKey: peerID)
                quarantineRollbackCooldownUntil.removeValue(forKey: peerID)
                scheduleOrdinaryInitiatorTimeoutLocked(
                    session,
                    for: peerID,
                    notifyOnTimeout: notifyOnTimeout
                )
                cancelDelayedHandshakeRecoveryLocked(for: peerID)
                return NoiseHandshakeInitiation(
                    payload: payload,
                    attemptID: attemptID
                )
            } catch {
                session.reset()
                SecureLogger.error(
                    .handshakeFailed(
                        peerID: peerID.id,
                        error: error.localizedDescription
                    )
                )
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
        notifyOnTimeout: Bool,
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

            // Retire only after the replacement initiator has successfully
            // produced message 1. Do not use the broad removal helper here:
            // this transition owns the exact new session installed below.
            _ = sessions.removeValue(forKey: peerID)
            sessionGenerations.removeValue(forKey: peerID)
            ordinaryInitiationIDs.removeValue(forKey: peerID)
            cancelOrdinaryInitiatorTimeoutLocked(for: peerID)
            cancelOrdinaryResponderTimeoutLocked(for: peerID)
            cancelSuppressedInitiationRecoveryLocked(for: peerID)
            cancelDelayedHandshakeRecoveryLocked(for: peerID)
            recentOrdinaryInitiatorCompletions.removeValue(forKey: peerID)
            quarantineRollbackCooldownUntil.removeValue(forKey: peerID)
            established.reset()

            let attemptID = UUID()
            sessions[peerID] = next
            sessionGenerations[peerID] = UUID()
            ordinaryInitiationIDs[peerID] = attemptID
            scheduleOrdinaryInitiatorTimeoutLocked(
                next,
                for: peerID,
                notifyOnTimeout: notifyOnTimeout
            )
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
            let notifyOnTimeout =
                ordinaryInitiatorRetryNotifications[peerID] ?? false
            // Preparation and on-wire exchange have independent bounds. Once
            // BLE owns these exact bytes, give the peer the full response
            // window without changing retry ownership.
            scheduleOrdinaryInitiatorTimeoutLocked(
                session,
                for: peerID,
                notifyOnTimeout: notifyOnTimeout
            )
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
            var yieldedInitiatorShouldRetry = false
            var didYieldLocalInitiator = false
            var inheritedResponderShouldRetry = false
            var inheritedResponderWasCreatedByYield = false
            let existingAtIngress = sessions[peerID]
            let isFreshInitiation =
                message.count == NoiseSecurityConstants.xxInitialMessageSize
                || existingAtIngress == nil
                || (
                    existingAtIngress?.isEstablished() == true
                    && message.count
                        > NoiseSecurityConstants.xxInitialMessageSize
                )

            if isFreshInitiation {
                if let cooldownUntil = quarantineRollbackCooldownUntil[peerID] {
                    if cooldownUntil > Date(),
                       sessions[peerID]?.isEstablished() == true {
                        SecureLogger.debug(
                            "Ignoring unauthenticated reconnect initiation during rollback cooldown for \(peerID)",
                            category: .session
                        )
                        return (nil, nil)
                    }
                    quarantineRollbackCooldownUntil.removeValue(forKey: peerID)
                }

                if suppressedInitiationRecoveryTimeouts[peerID] != nil,
                   localPeerID < peerID.toShort(),
                   sessions[peerID]?.isEstablished() == true {
                    SecureLogger.debug(
                        "Coalescing duplicate initiation while convergence recovery is pending for \(peerID)",
                        category: .session
                    )
                    return (nil, nil)
                }

                if let completedAt = recentOrdinaryInitiatorCompletions[peerID] {
                    let stillInGrace = Date().timeIntervalSince(completedAt)
                        < recentInitiatorCompletionGracePeriod
                    if stillInGrace,
                       localPeerID < peerID.toShort(),
                       let established = sessions[peerID],
                       established.isEstablished() {
                        recentOrdinaryInitiatorCompletions.removeValue(forKey: peerID)
                        scheduleSuppressedInitiationRecoveryLocked(
                            established,
                            completedAt: completedAt,
                            for: peerID
                        )
                        SecureLogger.debug(
                            "Deferring delayed crossed initiation from \(peerID) after initiator completion",
                            category: .session
                        )
                        return (nil, nil)
                    }
                    recentOrdinaryInitiatorCompletions.removeValue(forKey: peerID)
                }

                if let ordinaryInitiator = sessions[peerID],
                   ordinaryInitiator.role == .initiator,
                   ordinaryInitiator.getState() == .handshaking {
                    if localPeerID < peerID.toShort() {
                        SecureLogger.debug(
                            "Ignoring crossed ordinary initiation from \(peerID); keeping deterministic initiator role",
                            category: .session
                        )
                        return (nil, nil)
                    }
                    yieldedInitiatorShouldRetry =
                        ordinaryInitiatorRetryNotifications[peerID] ?? false
                    didYieldLocalInitiator = true
                    _ = sessions.removeValue(forKey: peerID)
                    sessionGenerations.removeValue(forKey: peerID)
                    ordinaryInitiationIDs.removeValue(forKey: peerID)
                    cancelOrdinaryInitiatorTimeoutLocked(for: peerID)
                    cancelOrdinaryResponderTimeoutLocked(for: peerID)
                    ordinaryInitiator.reset()
                }
            }

            let session: NoiseSession

            if let existing = sessions[peerID] {
                if existing.isEstablished(),
                   !isFreshInitiation {
                    // An established ordinary XX transport has no remaining
                    // handshake messages to consume. Unauthenticated garbage
                    // must not tear down its working keys.
                    SecureLogger.debug(
                        "Ignoring non-initial handshake bytes for established peer \(peerID)",
                        category: .session
                    )
                    return (nil, nil)
                }
                if isFreshInitiation {
                    if existing.isEstablished(),
                       let generation = sessionGenerations[peerID] {
                        // Message 1 is unauthenticated. Remove the old
                        // transport from every outbound/generation API now,
                        // retaining it only as receive-only rollback state.
                        _ = sessions.removeValue(forKey: peerID)
                        sessionGenerations.removeValue(forKey: peerID)
                        ordinaryInitiationIDs.removeValue(forKey: peerID)
                        cancelOrdinaryInitiatorTimeoutLocked(for: peerID)
                        cancelOrdinaryResponderTimeoutLocked(for: peerID)
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
                        inheritedResponderShouldRetry =
                            ordinaryResponderRetryNotifications[peerID] ?? false
                        inheritedResponderWasCreatedByYield =
                            ordinaryRespondersCreatedByYield.contains(peerID)
                        _ = sessions.removeValue(forKey: peerID)
                        sessionGenerations.removeValue(forKey: peerID)
                        ordinaryInitiationIDs.removeValue(forKey: peerID)
                        // Keep the first responder/quarantine deadline. A
                        // repeated message 1 may refresh message 2, but never
                        // refreshes the attacker's outbound-pause budget.
                        cancelOrdinaryResponderTimeoutLocked(
                            for: peerID,
                            preserveDeadline: true
                        )
                        existing.reset()
                    }

                    let replacement = sessionFactory(peerID, .responder)
                    sessions[peerID] = replacement
                    sessionGenerations[peerID] = UUID()
                    session = replacement
                } else {
                    session = existing
                }
            } else {
                let newSession = sessionFactory(peerID, .responder)
                sessions[peerID] = newSession
                sessionGenerations[peerID] = UUID()
                session = newSession
            }

            do {
                if isFreshInitiation,
                   session.role == .responder {
                    scheduleOrdinaryResponderTimeoutLocked(
                        session,
                        for: peerID,
                        notifyOnTimeout:
                            yieldedInitiatorShouldRetry
                            || inheritedResponderShouldRetry,
                        createdByYield:
                            didYieldLocalInitiator
                            || inheritedResponderWasCreatedByYield
                    )
                }

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
                        quarantined.session.reset()
                    }
                    ordinaryInitiationIDs.removeValue(forKey: peerID)
                    cancelOrdinaryInitiatorTimeoutLocked(for: peerID)
                    cancelOrdinaryResponderTimeoutLocked(for: peerID)
                    quarantineRollbackCooldownUntil.removeValue(forKey: peerID)
                    if session.role == .initiator {
                        recentOrdinaryInitiatorCompletions[peerID] = Date()
                    } else {
                        recentOrdinaryInitiatorCompletions.removeValue(
                            forKey: peerID
                        )
                    }
                    cancelSuppressedInitiationRecoveryLocked(for: peerID)
                    cancelDelayedHandshakeRecoveryLocked(for: peerID)
                    guard let generation = sessionGenerations[peerID] else {
                        throw NoiseEncryptionError.sessionNotEstablished
                    }
                    establishedSession = (remoteKey, generation)
                }
                
                return (response, establishedSession)
            } catch {
                var shouldRequestRecovery = false
                var shouldSuppressImmediateHandlerRestart = false
                if session.role == .initiator {
                    shouldRequestRecovery =
                        ordinaryInitiatorRetryNotifications[peerID] ?? false
                    shouldSuppressImmediateHandlerRestart = true
                } else {
                    shouldRequestRecovery =
                        ordinaryResponderRetryNotifications[peerID] ?? false
                    shouldSuppressImmediateHandlerRestart =
                        ordinaryRespondersCreatedByYield.contains(peerID)
                }

                if let storedSession = sessions[peerID],
                   storedSession === session {
                    _ = sessions.removeValue(forKey: peerID)
                    sessionGenerations.removeValue(forKey: peerID)
                }
                ordinaryInitiationIDs.removeValue(forKey: peerID)
                cancelOrdinaryInitiatorTimeoutLocked(for: peerID)
                cancelOrdinaryResponderTimeoutLocked(for: peerID)
                recentOrdinaryInitiatorCompletions.removeValue(forKey: peerID)
                session.reset()

                let isIdentityMismatch =
                    (error as? NoiseSessionError) == .peerIdentityMismatch

                let restoredGeneration: UUID?
                if let quarantined = quarantinedTransports.removeValue(forKey: peerID) {
                    sessions[peerID] = quarantined.session
                    sessionGenerations[peerID] = quarantined.generation
                    restoredGeneration = quarantined.generation
                    markRollbackCooldownLocked(for: peerID)
                } else {
                    restoredGeneration = nil
                }

                // An identity mismatch is terminal: the counterpart failed to
                // prove the claimed static key, so it never finished keys that
                // could have replaced the restored ones. Every other restore
                // that owns (or joins) a convergence retry must keep transport
                // queues parked until that retry concludes — the counterpart
                // may already have discarded the restored sending keys.
                let restoreReason: NoiseSessionRestoreReason =
                    !isIdentityMismatch
                        && (shouldRequestRecovery
                            || pendingHandshakeRecoveryIDs[peerID] != nil)
                    ? .pendingConvergence
                    : .terminal

                // Schedule callback outside the synchronized block to prevent deadlock
                DispatchQueue.global().async { [weak self] in
                    if let restoredGeneration {
                        self?.onSessionRestored?(peerID, restoredGeneration, restoreReason)
                    }
                    self?.onSessionFailed?(peerID, error)
                }
                if pendingHandshakeRecoveryIDs[peerID] != nil {
                    shouldSuppressImmediateHandlerRestart = true
                }
                if shouldRequestRecovery, !isIdentityMismatch {
                    requestHandshakeRecovery(
                        for: peerID,
                        after: NoiseSecurityConstants
                            .handshakeCollisionRecoveryDelay
                    )
                } else if isIdentityMismatch,
                          let recoveryID = pendingHandshakeRecoveryIDs[peerID] {
                    redispatchHandshakeRecoveryLocked(
                        NoiseHandshakeRecoveryRequest(
                            peerID: peerID,
                            recoveryID: recoveryID
                        ),
                        after: NoiseSecurityConstants
                            .handshakeCollisionRecoveryDelay
                    )
                }
                
                SecureLogger.error(.handshakeFailed(peerID: peerID.id, error: error.localizedDescription))
                if shouldSuppressImmediateHandlerRestart, !isIdentityMismatch {
                    throw NoiseManagedHandshakeFailure(underlying: error)
                }
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

    private func scheduleOrdinaryInitiatorTimeoutLocked(
        _ session: NoiseSession,
        for peerID: PeerID,
        notifyOnTimeout: Bool
    ) {
        cancelOrdinaryInitiatorTimeoutLocked(for: peerID)
        ordinaryInitiatorRetryNotifications[peerID] = notifyOnTimeout
        let timeout = DispatchWorkItem(flags: .barrier) { [weak self, weak session] in
            guard let self,
                  let session,
                  let current = self.sessions[peerID],
                  current === session,
                  current.role == .initiator,
                  current.getState() == .handshaking else {
                return
            }

            _ = self.sessions.removeValue(forKey: peerID)
            self.sessionGenerations.removeValue(forKey: peerID)
            self.ordinaryInitiationIDs.removeValue(forKey: peerID)
            self.ordinaryInitiatorTimeouts.removeValue(forKey: peerID)
            self.ordinaryInitiatorRetryNotifications.removeValue(forKey: peerID)
            self.recentOrdinaryInitiatorCompletions.removeValue(forKey: peerID)
            session.reset()
            SecureLogger.debug(
                "Ordinary initiator handshake with \(peerID) timed out",
                category: .session
            )

            if notifyOnTimeout {
                self.requestHandshakeRecovery(for: peerID)
            }
        }
        ordinaryInitiatorTimeouts[peerID] = timeout
        managerQueue.asyncAfter(
            deadline: .now() + ordinaryHandshakeTimeout,
            execute: timeout
        )
    }

    private func cancelOrdinaryInitiatorTimeoutLocked(for peerID: PeerID) {
        ordinaryInitiatorTimeouts.removeValue(forKey: peerID)?.cancel()
        ordinaryInitiatorRetryNotifications.removeValue(forKey: peerID)
    }

    private func scheduleOrdinaryResponderTimeoutLocked(
        _ session: NoiseSession,
        for peerID: PeerID,
        notifyOnTimeout: Bool,
        createdByYield: Bool,
        rearmDeadline: Bool = false
    ) {
        let previousDeadline = ordinaryResponderDeadlines[peerID]
        cancelOrdinaryResponderTimeoutLocked(
            for: peerID,
            preserveDeadline: true
        )
        ordinaryResponderRetryNotifications[peerID] = notifyOnTimeout
        if createdByYield {
            ordinaryRespondersCreatedByYield.insert(peerID)
        }

        let deadline: DispatchTime
        if let rollbackDeadline =
            quarantinedTransports[peerID]?.rollbackDeadline {
            deadline = rollbackDeadline
        } else if !rearmDeadline, let previousDeadline {
            deadline = previousDeadline
        } else {
            deadline = .now() + ordinaryResponderHandshakeTimeout
        }
        ordinaryResponderDeadlines[peerID] = deadline

        let timeout = DispatchWorkItem(flags: .barrier) { [weak self, weak session] in
            guard let self,
                  let session,
                  let current = self.sessions[peerID],
                  current === session,
                  current.role == .responder,
                  current.getState() == .handshaking else {
                return
            }

            _ = self.sessions.removeValue(forKey: peerID)
            self.sessionGenerations.removeValue(forKey: peerID)
            self.ordinaryInitiationIDs.removeValue(forKey: peerID)
            self.ordinaryResponderTimeouts.removeValue(forKey: peerID)
            self.ordinaryResponderDeadlines.removeValue(forKey: peerID)
            self.ordinaryResponderRetryNotifications.removeValue(forKey: peerID)
            self.ordinaryRespondersCreatedByYield.remove(peerID)
            self.recentOrdinaryInitiatorCompletions.removeValue(forKey: peerID)
            session.reset()

            let restored: QuarantinedTransport?
            if let quarantined =
                self.quarantinedTransports.removeValue(forKey: peerID) {
                self.sessions[peerID] = quarantined.session
                self.sessionGenerations[peerID] = quarantined.generation
                self.markRollbackCooldownLocked(for: peerID)
                restored = quarantined
            } else {
                restored = nil
            }

            SecureLogger.debug(
                restored == nil
                    ? "Ordinary responder handshake with \(peerID) timed out"
                    : "Ordinary responder handshake with \(peerID) timed out; restored quarantined transport",
                category: .session
            )
            if let restored {
                // The mandatory convergence retry below owns the outbound
                // resume: the timed-out counterpart may hold replacement keys
                // that already discarded the restored generation's, so queue
                // drains under it would be silently undecryptable.
                DispatchQueue.global().async { [weak self] in
                    self?.onSessionRestored?(
                        peerID,
                        restored.generation,
                        .pendingConvergence
                    )
                }
            }

            // A rollback always owns one local convergence attempt. The retry
            // retires the restored session atomically, so an attacker cannot
            // pace unauthenticated message 1 packets to pause outbound forever.
            if notifyOnTimeout || restored != nil {
                self.requestHandshakeRecovery(for: peerID)
            }
        }
        ordinaryResponderTimeouts[peerID] = timeout
        managerQueue.asyncAfter(deadline: deadline, execute: timeout)
    }

    private func cancelOrdinaryResponderTimeoutLocked(
        for peerID: PeerID,
        preserveDeadline: Bool = false
    ) {
        ordinaryResponderTimeouts.removeValue(forKey: peerID)?.cancel()
        if !preserveDeadline {
            ordinaryResponderDeadlines.removeValue(forKey: peerID)
        }
        ordinaryResponderRetryNotifications.removeValue(forKey: peerID)
        ordinaryRespondersCreatedByYield.remove(peerID)
    }

    private func markRollbackCooldownLocked(for peerID: PeerID) {
        quarantineRollbackCooldownUntil[peerID] =
            Date().addingTimeInterval(ordinaryReconnectRollbackCooldown)
    }

    private func scheduleSuppressedInitiationRecoveryLocked(
        _ establishedSession: NoiseSession,
        completedAt: Date,
        for peerID: PeerID
    ) {
        cancelSuppressedInitiationRecoveryLocked(for: peerID)
        let elapsed = max(0, Date().timeIntervalSince(completedAt))
        let remainingGrace = max(
            0,
            recentInitiatorCompletionGracePeriod - elapsed
        )
        let timeout = DispatchWorkItem(flags: .barrier) {
            [weak self, weak establishedSession] in
            guard let self,
                  let establishedSession,
                  let current = self.sessions[peerID],
                  current === establishedSession,
                  current.isEstablished() else {
                return
            }

            self.suppressedInitiationRecoveryTimeouts.removeValue(
                forKey: peerID
            )
            self.requestHandshakeRecovery(for: peerID)
        }
        suppressedInitiationRecoveryTimeouts[peerID] = timeout
        managerQueue.asyncAfter(
            deadline: .now() + remainingGrace,
            execute: timeout
        )
    }

    private func cancelSuppressedInitiationRecoveryLocked(for peerID: PeerID) {
        suppressedInitiationRecoveryTimeouts.removeValue(forKey: peerID)?
            .cancel()
    }

    private func requestHandshakeRecovery(
        for peerID: PeerID,
        after delay: TimeInterval = 0
    ) {
        cancelDelayedHandshakeRecoveryLocked(for: peerID)
        let request = NoiseHandshakeRecoveryRequest(
            peerID: peerID,
            recoveryID: UUID()
        )
        pendingHandshakeRecoveryIDs[peerID] = request.recoveryID
        scheduleHandshakeRecoveryCallbackLocked(request, after: delay)
    }

    private func redispatchHandshakeRecoveryLocked(
        _ request: NoiseHandshakeRecoveryRequest,
        after delay: TimeInterval
    ) {
        guard pendingHandshakeRecoveryIDs[request.peerID]
                == request.recoveryID else {
            return
        }
        scheduleHandshakeRecoveryCallbackLocked(request, after: delay)
    }

    private func scheduleHandshakeRecoveryCallbackLocked(
        _ request: NoiseHandshakeRecoveryRequest,
        after delay: TimeInterval
    ) {
        let peerID = request.peerID
        guard pendingHandshakeRecoveryIDs[peerID] == request.recoveryID else {
            return
        }

        delayedHandshakeRecoveryWorkItems.removeValue(forKey: peerID)?.cancel()
        let callbackID = UUID()
        handshakeRecoveryCallbackIDs[peerID] = callbackID
        let callback = DispatchWorkItem(flags: .barrier) { [weak self] in
            guard let self,
                  self.pendingHandshakeRecoveryIDs[peerID]
                    == request.recoveryID,
                  self.handshakeRecoveryCallbackIDs[peerID] == callbackID else {
                return
            }
            self.delayedHandshakeRecoveryWorkItems.removeValue(forKey: peerID)
            self.handshakeRecoveryCallbackIDs.removeValue(forKey: peerID)
            let handler = self.onHandshakeRecoveryRequired
            DispatchQueue.global().async {
                handler?(request)
            }
        }
        delayedHandshakeRecoveryWorkItems[peerID] = callback
        managerQueue.asyncAfter(
            deadline: .now() + max(0, delay),
            execute: callback
        )
    }

    private func consumeHandshakeRecoveryLocked(
        _ request: NoiseHandshakeRecoveryRequest
    ) {
        let peerID = request.peerID
        guard pendingHandshakeRecoveryIDs[peerID] == request.recoveryID else {
            return
        }
        delayedHandshakeRecoveryWorkItems.removeValue(forKey: peerID)?.cancel()
        handshakeRecoveryCallbackIDs.removeValue(forKey: peerID)
        pendingHandshakeRecoveryIDs.removeValue(forKey: peerID)
    }

    private func cancelDelayedHandshakeRecoveryLocked(for peerID: PeerID) {
        delayedHandshakeRecoveryWorkItems.removeValue(forKey: peerID)?.cancel()
        handshakeRecoveryCallbackIDs.removeValue(forKey: peerID)
        pendingHandshakeRecoveryIDs.removeValue(forKey: peerID)
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
        from peerID: PeerID,
        establishedGenerationIsReady: (UUID) -> Bool = { _ in true },
        authorizeDecrypt: () throws -> Void = {}
    ) throws -> (plaintext: Data, sessionGeneration: UUID) {
        try managerQueue.sync {
            if let session = sessions[peerID],
               session.isEstablished(),
               let generation = sessionGenerations[peerID] {
                // Keep the generation lease across the transport-readiness
                // check and decrypt. Promotion/restoration needs this queue's
                // barrier, so no new receive nonce can be consumed before BLE
                // installs state for the exact generation.
                guard establishedGenerationIsReady(generation) else {
                    throw NoiseEncryptionError.transportGenerationNotReady
                }
                try authorizeDecrypt()
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
                try authorizeDecrypt()
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
    
    func initiateRekey(for peerID: PeerID) throws -> NoiseHandshakeInitiation {
        try initiateReconnectHandshake(
            with: peerID,
            notifyOnTimeout: true,
            authorize: {}
        )
    }
}
