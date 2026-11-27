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
    private struct QuarantinedTransport {
        let session: NoiseSession
        let generation: UUID
        /// Duplicate message 1 packets replace the incomplete responder but
        /// never extend the original rollback window indefinitely.
        let rollbackDeadline: DispatchTime
    }

    /// All per-peer session, timer, quarantine, and handshake-recovery state
    /// consolidated into one value so cleanup and teardown never leave
    /// orphaned entries across parallel tables.
    private struct PeerSessionSlot {
        var session: NoiseSession?
        /// Opaque identity for `session`, created and cleared under the same
        /// manager barrier so callers never authenticate data with one session
        /// and lease another.
        var generation: UUID?
        /// One-time handoff token preventing a prepared XX message 1 from
        /// leaving after an inbound collision changed this peer's role.
        var ordinaryInitiationID: UUID?
        var ordinaryInitiatorTimeout: DispatchWorkItem?
        var ordinaryInitiatorRetryNotification = false
        var ordinaryResponderTimeout: DispatchWorkItem?
        var ordinaryResponderDeadline: DispatchTime?
        var ordinaryResponderRetryNotification = false
        var ordinaryResponderCreatedByYield = false
        var recentOrdinaryInitiatorCompletion: Date?
        /// Receive-only rollback state while an unauthenticated inbound
        /// message 1 proves the claimed static identity.
        var quarantinedTransport: QuarantinedTransport?
        var quarantineRollbackCooldownUntil: Date?
        var suppressedInitiationRecoveryTimeout: DispatchWorkItem?
        var delayedHandshakeRecoveryWorkItem: DispatchWorkItem?
        var handshakeRecoveryCallbackID: UUID?
        var pendingHandshakeRecoveryID: UUID?

        var isEmpty: Bool {
            session == nil
                && generation == nil
                && ordinaryInitiationID == nil
                && ordinaryInitiatorTimeout == nil
                && !ordinaryInitiatorRetryNotification
                && ordinaryResponderTimeout == nil
                && ordinaryResponderDeadline == nil
                && !ordinaryResponderRetryNotification
                && !ordinaryResponderCreatedByYield
                && recentOrdinaryInitiatorCompletion == nil
                && quarantinedTransport == nil
                && quarantineRollbackCooldownUntil == nil
                && suppressedInitiationRecoveryTimeout == nil
                && delayedHandshakeRecoveryWorkItem == nil
                && handshakeRecoveryCallbackID == nil
                && pendingHandshakeRecoveryID == nil
        }

        mutating func cancelOrdinaryInitiatorTimeout() {
            ordinaryInitiatorTimeout?.cancel()
            ordinaryInitiatorTimeout = nil
            ordinaryInitiatorRetryNotification = false
        }

        mutating func cancelOrdinaryResponderTimeout(preserveDeadline: Bool = false) {
            ordinaryResponderTimeout?.cancel()
            ordinaryResponderTimeout = nil
            if !preserveDeadline {
                ordinaryResponderDeadline = nil
            }
            ordinaryResponderRetryNotification = false
            ordinaryResponderCreatedByYield = false
        }

        mutating func cancelSuppressedInitiationRecovery() {
            suppressedInitiationRecoveryTimeout?.cancel()
            suppressedInitiationRecoveryTimeout = nil
        }

        mutating func cancelDelayedHandshakeRecovery() {
            delayedHandshakeRecoveryWorkItem?.cancel()
            delayedHandshakeRecoveryWorkItem = nil
            handshakeRecoveryCallbackID = nil
            pendingHandshakeRecoveryID = nil
        }

        mutating func resetAll() {
            session?.reset()
            quarantinedTransport?.session.reset()
            cancelOrdinaryInitiatorTimeout()
            cancelOrdinaryResponderTimeout()
            cancelSuppressedInitiationRecovery()
            cancelDelayedHandshakeRecovery()
            self = PeerSessionSlot()
        }
    }

    private var slots: [PeerID: PeerSessionSlot] = [:]
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
            NoiseSession(
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

    // MARK: - Slot Helpers (must hold managerQueue barrier)

    @discardableResult
    private func mutateSlot<T>(for peerID: PeerID, _ body: (inout PeerSessionSlot) -> T) -> T {
        var slot = slots[peerID] ?? PeerSessionSlot()
        let result = body(&slot)
        if slot.isEmpty {
            slots.removeValue(forKey: peerID)
        } else {
            slots[peerID] = slot
        }
        return result
    }

    // MARK: - Session Management

    func getSession(for peerID: PeerID) -> NoiseSession? {
        return managerQueue.sync {
            return slots[peerID]?.session
        }
    }

    /// Whether this peer has an inbound ordinary XX responder that still
    /// needs message 3 before its receive keys can become authoritative.
    func isAwaitingResponderHandshakeCompletion(for peerID: PeerID) -> Bool {
        managerQueue.sync {
            guard let session = slots[peerID]?.session else { return false }
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
            guard slots[peerID]?.pendingHandshakeRecoveryID == request.recoveryID else {
                return nil
            }

            if let current = slots[peerID]?.session,
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
                        rearmDeadline: slots[peerID]?.quarantinedTransport == nil
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

            let attemptID = UUID()
            // Start before retiring a working transport. If preparation fails,
            // the established session and its generation are untouched.
            mutateSlot(for: peerID) { slot in
                slot.session?.reset()
                slot.quarantinedTransport?.session.reset()
                slot.quarantinedTransport = nil
                slot.cancelOrdinaryInitiatorTimeout()
                slot.cancelOrdinaryResponderTimeout()
                slot.cancelSuppressedInitiationRecovery()
                slot.recentOrdinaryInitiatorCompletion = nil
                slot.quarantineRollbackCooldownUntil = nil
                slot.session = next
                slot.generation = UUID()
                slot.ordinaryInitiationID = attemptID
            }
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
        if var slot = slots.removeValue(forKey: peerID) {
            slot.resetAll()
        }
    }

    func removeAllSessions() {
        managerQueue.sync(flags: .barrier) {
            for var slot in slots.values {
                slot.resetAll()
            }
            slots.removeAll()
        }
    }

    // MARK: - Handshake Helpers

    func initiateHandshake(with peerID: PeerID) throws -> Data {
        return try managerQueue.sync(flags: .barrier) {
            // Check if we already have an established session
            if let existingSession = slots[peerID]?.session, existingSession.isEstablished() {
                // Session already established, don't recreate
                throw NoiseSessionError.alreadyEstablished
            }

            // Remove any existing non-established session
            if let existingSession = slots[peerID]?.session, !existingSession.isEstablished() {
                removeSessionLocked(for: peerID)
            }

            // Create new initiator session
            let session = sessionFactory(peerID, .initiator)
            mutateSlot(for: peerID) { slot in
                slot.recentOrdinaryInitiatorCompletion = nil
                slot.session = session
                slot.generation = UUID()
            }

            do {
                let handshakeData = try session.startHandshake()
                scheduleOrdinaryInitiatorTimeoutLocked(
                    session,
                    for: peerID,
                    notifyOnTimeout: false
                )
                mutateSlot(for: peerID) { $0.cancelDelayedHandshakeRecovery() }
                return handshakeData
            } catch {
                // Clean up failed session
                mutateSlot(for: peerID) { slot in
                    slot.session = nil
                    slot.generation = nil
                    slot.ordinaryInitiationID = nil
                    slot.cancelOrdinaryInitiatorTimeout()
                }
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
            guard slots[peerID]?.session == nil,
                  slots[peerID]?.quarantinedTransport == nil else {
                return nil
            }
            try authorize()

            let session = sessionFactory(peerID, .initiator)
            do {
                let payload = try session.startHandshake()
                let attemptID = UUID()
                mutateSlot(for: peerID) { slot in
                    slot.session = session
                    slot.generation = UUID()
                    slot.ordinaryInitiationID = attemptID
                    slot.recentOrdinaryInitiatorCompletion = nil
                    slot.quarantineRollbackCooldownUntil = nil
                    slot.cancelDelayedHandshakeRecovery()
                }
                scheduleOrdinaryInitiatorTimeoutLocked(
                    session,
                    for: peerID,
                    notifyOnTimeout: notifyOnTimeout
                )
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
            guard let established = slots[peerID]?.session,
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

            let attemptID = UUID()
            // Retire only after the replacement initiator has successfully
            // produced message 1. Do not use the broad removal helper here:
            // this transition owns the exact new session installed below.
            mutateSlot(for: peerID) { slot in
                slot.cancelOrdinaryInitiatorTimeout()
                slot.cancelOrdinaryResponderTimeout()
                slot.cancelSuppressedInitiationRecovery()
                slot.cancelDelayedHandshakeRecovery()
                slot.recentOrdinaryInitiatorCompletion = nil
                slot.quarantineRollbackCooldownUntil = nil
                slot.session = next
                slot.generation = UUID()
                slot.ordinaryInitiationID = attemptID
            }
            established.reset()
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
            guard let slot = slots[peerID],
                  slot.ordinaryInitiationID == initiation.attemptID,
                  let session = slot.session,
                  session.role == .initiator,
                  session.getState() == .handshaking else {
                return nil
            }
            let notifyOnTimeout = slot.ordinaryInitiatorRetryNotification
            mutateSlot(for: peerID) { $0.ordinaryInitiationID = nil }
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
            let existingAtIngress = slots[peerID]?.session
            let isFreshInitiation =
                message.count == NoiseSecurityConstants.xxInitialMessageSize
                || existingAtIngress == nil
                || (
                    existingAtIngress?.isEstablished() == true
                    && message.count
                        > NoiseSecurityConstants.xxInitialMessageSize
                )

            if isFreshInitiation {
                if let cooldownUntil = slots[peerID]?.quarantineRollbackCooldownUntil {
                    if cooldownUntil > Date(),
                       slots[peerID]?.session?.isEstablished() == true {
                        SecureLogger.debug(
                            "Ignoring unauthenticated reconnect initiation during rollback cooldown for \(peerID)",
                            category: .session
                        )
                        return (nil, nil)
                    }
                    mutateSlot(for: peerID) { $0.quarantineRollbackCooldownUntil = nil }
                }

                if slots[peerID]?.suppressedInitiationRecoveryTimeout != nil,
                   localPeerID < peerID.toShort(),
                   slots[peerID]?.session?.isEstablished() == true {
                    SecureLogger.debug(
                        "Coalescing duplicate initiation while convergence recovery is pending for \(peerID)",
                        category: .session
                    )
                    return (nil, nil)
                }

                if let completedAt = slots[peerID]?.recentOrdinaryInitiatorCompletion {
                    let stillInGrace = Date().timeIntervalSince(completedAt)
                        < recentInitiatorCompletionGracePeriod
                    if stillInGrace,
                       localPeerID < peerID.toShort(),
                       let established = slots[peerID]?.session,
                       established.isEstablished() {
                        mutateSlot(for: peerID) { $0.recentOrdinaryInitiatorCompletion = nil }
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
                    mutateSlot(for: peerID) { $0.recentOrdinaryInitiatorCompletion = nil }
                }

                if let ordinaryInitiator = slots[peerID]?.session,
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
                        slots[peerID]?.ordinaryInitiatorRetryNotification ?? false
                    didYieldLocalInitiator = true
                    mutateSlot(for: peerID) { slot in
                        slot.session = nil
                        slot.generation = nil
                        slot.ordinaryInitiationID = nil
                        slot.cancelOrdinaryInitiatorTimeout()
                        slot.cancelOrdinaryResponderTimeout()
                    }
                    ordinaryInitiator.reset()
                }
            }

            let session: NoiseSession

            if let existing = slots[peerID]?.session {
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
                    let replacement = sessionFactory(peerID, .responder)
                    if existing.isEstablished(),
                       let generation = slots[peerID]?.generation {
                        // Message 1 is unauthenticated. Remove the old
                        // transport from every outbound/generation API now,
                        // retaining it only as receive-only rollback state.
                        let priorQuarantined = mutateSlot(for: peerID) { slot -> QuarantinedTransport? in
                            slot.ordinaryInitiationID = nil
                            slot.cancelOrdinaryInitiatorTimeout()
                            slot.cancelOrdinaryResponderTimeout()
                            let prior = slot.quarantinedTransport
                            slot.quarantinedTransport = QuarantinedTransport(
                                session: existing,
                                generation: generation,
                                rollbackDeadline: .now()
                                    + ordinaryResponderHandshakeTimeout
                            )
                            slot.session = replacement
                            slot.generation = UUID()
                            return prior
                        }
                        priorQuarantined?.session.reset()
                    } else {
                        inheritedResponderShouldRetry =
                            slots[peerID]?.ordinaryResponderRetryNotification ?? false
                        inheritedResponderWasCreatedByYield =
                            slots[peerID]?.ordinaryResponderCreatedByYield ?? false
                        mutateSlot(for: peerID) { slot in
                            slot.ordinaryInitiationID = nil
                            // Keep the first responder/quarantine deadline. A
                            // repeated message 1 may refresh message 2, but never
                            // refreshes the attacker's outbound-pause budget.
                            slot.cancelOrdinaryResponderTimeout(preserveDeadline: true)
                            slot.session = replacement
                            slot.generation = UUID()
                        }
                        existing.reset()
                    }
                    session = replacement
                } else {
                    session = existing
                }
            } else {
                let newSession = sessionFactory(peerID, .responder)
                mutateSlot(for: peerID) { slot in
                    slot.session = newSession
                    slot.generation = UUID()
                }
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

                    let (quarantined, generation) = mutateSlot(for: peerID) { slot -> (QuarantinedTransport?, UUID?) in
                        let quarantined = slot.quarantinedTransport
                        slot.quarantinedTransport = nil
                        slot.ordinaryInitiationID = nil
                        slot.cancelOrdinaryInitiatorTimeout()
                        slot.cancelOrdinaryResponderTimeout()
                        slot.quarantineRollbackCooldownUntil = nil
                        slot.recentOrdinaryInitiatorCompletion =
                            session.role == .initiator ? Date() : nil
                        slot.cancelSuppressedInitiationRecovery()
                        slot.cancelDelayedHandshakeRecovery()
                        return (quarantined, slot.generation)
                    }
                    quarantined?.session.reset()
                    guard let generation else {
                        throw NoiseEncryptionError.sessionNotEstablished
                    }
                    establishedSession = (remoteKey, generation)
                }

                return (response, establishedSession)
            } catch {
                let isIdentityMismatch =
                    (error as? NoiseSessionError) == .peerIdentityMismatch

                let (
                    shouldRequestRecovery,
                    initialSuppressRestart,
                    restoredGeneration,
                    pendingRecoveryID
                ) = mutateSlot(for: peerID) { slot -> (Bool, Bool, UUID?, UUID?) in
                    let shouldRetry: Bool
                    let suppressRestart: Bool
                    if session.role == .initiator {
                        shouldRetry = slot.ordinaryInitiatorRetryNotification
                        suppressRestart = true
                    } else {
                        shouldRetry = slot.ordinaryResponderRetryNotification
                        suppressRestart = slot.ordinaryResponderCreatedByYield
                    }

                    if let storedSession = slot.session,
                       storedSession === session {
                        slot.session = nil
                        slot.generation = nil
                    }
                    slot.ordinaryInitiationID = nil
                    slot.cancelOrdinaryInitiatorTimeout()
                    slot.cancelOrdinaryResponderTimeout()
                    slot.recentOrdinaryInitiatorCompletion = nil

                    let restoredGen: UUID?
                    if let quarantined = slot.quarantinedTransport {
                        slot.quarantinedTransport = nil
                        slot.session = quarantined.session
                        slot.generation = quarantined.generation
                        slot.quarantineRollbackCooldownUntil =
                            Date().addingTimeInterval(ordinaryReconnectRollbackCooldown)
                        restoredGen = quarantined.generation
                    } else {
                        restoredGen = nil
                    }
                    return (
                        shouldRetry,
                        suppressRestart,
                        restoredGen,
                        slot.pendingHandshakeRecoveryID
                    )
                }
                session.reset()

                let shouldSuppressImmediateHandlerRestart =
                    initialSuppressRestart || pendingRecoveryID != nil

                // An identity mismatch is terminal: the counterpart failed to
                // prove the claimed static key, so it never finished keys that
                // could have replaced the restored ones. Every other restore
                // that owns (or joins) a convergence retry must keep transport
                // queues parked until that retry concludes — the counterpart
                // may already have discarded the restored sending keys.
                let restoreReason: NoiseSessionRestoreReason =
                    !isIdentityMismatch
                        && (shouldRequestRecovery || pendingRecoveryID != nil)
                    ? .pendingConvergence
                    : .terminal

                // Schedule callback outside the synchronized block to prevent deadlock
                DispatchQueue.global().async { [weak self] in
                    if let restoredGeneration {
                        self?.onSessionRestored?(peerID, restoredGeneration, restoreReason)
                    }
                    self?.onSessionFailed?(peerID, error)
                }
                if shouldRequestRecovery, !isIdentityMismatch {
                    requestHandshakeRecovery(
                        for: peerID,
                        after: NoiseSecurityConstants
                            .handshakeCollisionRecoveryDelay
                    )
                } else if isIdentityMismatch,
                          let recoveryID = pendingRecoveryID {
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
        let timeout = DispatchWorkItem(flags: .barrier) { [weak self, weak session] in
            guard let self,
                  let session,
                  let current = self.slots[peerID]?.session,
                  current === session,
                  current.role == .initiator,
                  current.getState() == .handshaking else {
                return
            }

            self.mutateSlot(for: peerID) { slot in
                slot.session = nil
                slot.generation = nil
                slot.ordinaryInitiationID = nil
                slot.ordinaryInitiatorTimeout = nil
                slot.ordinaryInitiatorRetryNotification = false
                slot.recentOrdinaryInitiatorCompletion = nil
            }
            session.reset()
            SecureLogger.debug(
                "Ordinary initiator handshake with \(peerID) timed out",
                category: .session
            )

            if notifyOnTimeout {
                self.requestHandshakeRecovery(for: peerID)
            }
        }
        mutateSlot(for: peerID) { slot in
            slot.cancelOrdinaryInitiatorTimeout()
            slot.ordinaryInitiatorRetryNotification = notifyOnTimeout
            slot.ordinaryInitiatorTimeout = timeout
        }
        managerQueue.asyncAfter(
            deadline: .now() + ordinaryHandshakeTimeout,
            execute: timeout
        )
    }

    private func scheduleOrdinaryResponderTimeoutLocked(
        _ session: NoiseSession,
        for peerID: PeerID,
        notifyOnTimeout: Bool,
        createdByYield: Bool,
        rearmDeadline: Bool = false
    ) {
        let deadline: DispatchTime
        if let rollbackDeadline = slots[peerID]?.quarantinedTransport?.rollbackDeadline {
            deadline = rollbackDeadline
        } else if !rearmDeadline, let previousDeadline = slots[peerID]?.ordinaryResponderDeadline {
            deadline = previousDeadline
        } else {
            deadline = .now() + ordinaryResponderHandshakeTimeout
        }

        let timeout = DispatchWorkItem(flags: .barrier) { [weak self, weak session] in
            guard let self,
                  let session,
                  let current = self.slots[peerID]?.session,
                  current === session,
                  current.role == .responder,
                  current.getState() == .handshaking else {
                return
            }

            let restored: QuarantinedTransport? = self.mutateSlot(for: peerID) { slot in
                slot.session = nil
                slot.generation = nil
                slot.ordinaryInitiationID = nil
                slot.ordinaryResponderTimeout = nil
                slot.ordinaryResponderDeadline = nil
                slot.ordinaryResponderRetryNotification = false
                slot.ordinaryResponderCreatedByYield = false
                slot.recentOrdinaryInitiatorCompletion = nil

                if let quarantined = slot.quarantinedTransport {
                    slot.quarantinedTransport = nil
                    slot.session = quarantined.session
                    slot.generation = quarantined.generation
                    slot.quarantineRollbackCooldownUntil =
                        Date().addingTimeInterval(self.ordinaryReconnectRollbackCooldown)
                    return quarantined
                }
                return nil
            }
            session.reset()

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
        mutateSlot(for: peerID) { slot in
            slot.cancelOrdinaryResponderTimeout(preserveDeadline: true)
            slot.ordinaryResponderRetryNotification = notifyOnTimeout
            slot.ordinaryResponderCreatedByYield = createdByYield
            slot.ordinaryResponderDeadline = deadline
            slot.ordinaryResponderTimeout = timeout
        }
        managerQueue.asyncAfter(deadline: deadline, execute: timeout)
    }

    private func scheduleSuppressedInitiationRecoveryLocked(
        _ establishedSession: NoiseSession,
        completedAt: Date,
        for peerID: PeerID
    ) {
        let elapsed = max(0, Date().timeIntervalSince(completedAt))
        let remainingGrace = max(
            0,
            recentInitiatorCompletionGracePeriod - elapsed
        )
        let timeout = DispatchWorkItem(flags: .barrier) { [weak self, weak establishedSession] in
            guard let self,
                  let establishedSession,
                  let current = self.slots[peerID]?.session,
                  current === establishedSession,
                  current.isEstablished() else {
                return
            }

            self.mutateSlot(for: peerID) { $0.suppressedInitiationRecoveryTimeout = nil }
            self.requestHandshakeRecovery(for: peerID)
        }
        mutateSlot(for: peerID) { slot in
            slot.cancelSuppressedInitiationRecovery()
            slot.suppressedInitiationRecoveryTimeout = timeout
        }
        managerQueue.asyncAfter(
            deadline: .now() + remainingGrace,
            execute: timeout
        )
    }

    #if DEBUG
    /// Fires a pending suppressed-initiation recovery immediately instead of
    /// waiting out the completion-grace timer, so tests can inject a grace
    /// period too large to lose against a starved runner and still exercise
    /// the recovery path deterministically.
    func _test_fireSuppressedInitiationRecovery(for peerID: PeerID) {
        managerQueue.sync(flags: .barrier) {
            let pending = mutateSlot(for: peerID) { slot -> DispatchWorkItem? in
                let work = slot.suppressedInitiationRecoveryTimeout
                slot.suppressedInitiationRecoveryTimeout = nil
                return work
            }
            guard let pending else { return }
            pending.cancel()
            guard let current = slots[peerID]?.session,
                  current.isEstablished() else {
                return
            }
            requestHandshakeRecovery(for: peerID)
        }
    }
    #endif

    private func requestHandshakeRecovery(
        for peerID: PeerID,
        after delay: TimeInterval = 0
    ) {
        let request = NoiseHandshakeRecoveryRequest(
            peerID: peerID,
            recoveryID: UUID()
        )
        mutateSlot(for: peerID) { slot in
            slot.cancelDelayedHandshakeRecovery()
            slot.pendingHandshakeRecoveryID = request.recoveryID
        }
        scheduleHandshakeRecoveryCallbackLocked(request, after: delay)
    }

    private func redispatchHandshakeRecoveryLocked(
        _ request: NoiseHandshakeRecoveryRequest,
        after delay: TimeInterval
    ) {
        guard slots[request.peerID]?.pendingHandshakeRecoveryID
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
        guard slots[peerID]?.pendingHandshakeRecoveryID == request.recoveryID else {
            return
        }

        let callbackID = UUID()
        let callback = DispatchWorkItem(flags: .barrier) { [weak self] in
            guard let self,
                  self.slots[peerID]?.pendingHandshakeRecoveryID == request.recoveryID,
                  self.slots[peerID]?.handshakeRecoveryCallbackID == callbackID else {
                return
            }
            self.mutateSlot(for: peerID) { slot in
                slot.delayedHandshakeRecoveryWorkItem = nil
                slot.handshakeRecoveryCallbackID = nil
            }
            let handler = self.onHandshakeRecoveryRequired
            DispatchQueue.global().async {
                handler?(request)
            }
        }
        mutateSlot(for: peerID) { slot in
            slot.delayedHandshakeRecoveryWorkItem?.cancel()
            slot.handshakeRecoveryCallbackID = callbackID
            slot.delayedHandshakeRecoveryWorkItem = callback
        }
        managerQueue.asyncAfter(
            deadline: .now() + max(0, delay),
            execute: callback
        )
    }

    private func consumeHandshakeRecoveryLocked(
        _ request: NoiseHandshakeRecoveryRequest
    ) {
        let peerID = request.peerID
        guard slots[peerID]?.pendingHandshakeRecoveryID == request.recoveryID else {
            return
        }
        mutateSlot(for: peerID) { $0.cancelDelayedHandshakeRecovery() }
    }

    /// Mesh handshakes normally use a 16-hex wire ID. Full Noise-key IDs are
    /// also accepted by internal callers when they exactly match the static
    /// key. Anything else fails closed: an identifier that can't be checked
    /// against the remote static key must never complete a handshake.
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
        return false
    }

    // MARK: - Encryption/Decryption

    func encrypt(_ plaintext: Data, for peerID: PeerID) throws -> Data {
        try managerQueue.sync {
            guard let session = slots[peerID]?.session else {
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
            guard let slot = slots[peerID],
                  let session = slot.session,
                  session.isEstablished(),
                  slot.generation == expected else {
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
            guard let slot = slots[peerID],
                  slot.session?.isEstablished() == true else { return nil }
            return slot.generation
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
            let slot = slots[peerID]
            if let session = slot?.session,
               session.isEstablished(),
               let generation = slot?.generation {
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
            if let responder = slot?.session,
               responder.role == .responder,
               responder.getState() == .handshaking,
               let quarantined = slot?.quarantinedTransport {
                try authorizeDecrypt()
                return (
                    try quarantined.session.decrypt(ciphertext),
                    quarantined.generation
                )
            }

            if slot?.session == nil, slot?.quarantinedTransport == nil {
                throw NoiseSessionError.sessionNotFound
            }
            throw NoiseEncryptionError.sessionNotEstablished
        }
    }

    func hasReceiveSession(for peerID: PeerID) -> Bool {
        managerQueue.sync {
            guard let slot = slots[peerID] else { return false }
            if slot.session?.isEstablished() == true {
                return true
            }
            guard let responder = slot.session,
                  responder.role == .responder,
                  responder.getState() == .handshaking else {
                return false
            }
            return slot.quarantinedTransport?.session.isEstablished() == true
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
            guard let slot = slots[peerID],
                  slot.session?.isEstablished() == true,
                  slot.generation == expected else { return nil }
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

            for (peerID, slot) in slots {
                if let session = slot.session,
                   session.isEstablished(),
                   session.needsRenegotiation() {
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
