import BitFoundation
import Foundation

struct BLEAuthenticatedPeerStateObservation {
    let fingerprint: String
    let sessionGeneration: UUID
    let capabilities: PeerCapabilities
}

struct BLEPrivateMediaProofTimeoutMarker {
    let fingerprint: String
    let sessionGeneration: UUID?
}

struct BLEPrivateMediaProofWatchdog {
    let fingerprint: String
    let sessionGeneration: UUID
    let timeoutNonce: UUID
}

struct BLEPendingPrivateMediaPolicyResolution {
    let fingerprint: String
    var sessionGeneration: UUID?
    var timeoutNonce: UUID
    var completions: [UUID: @MainActor (PrivateMediaSendPolicy) -> Void]
}

struct BLEAuthenticatedPeerStateSendProgress {
    let sessionGeneration: UUID
    var sentInitial = false
    var sentEcho = false
}

/// Lock-backed private-media session state: which Noise generation each
/// peer's capability proof, peer-state exchange, and policy waiters are
/// bound to. A fresh Noise authentication rotates the generation UUID, so
/// stale proof timers and proof packets cannot classify a replacement
/// session.
///
/// Lock-backed rather than engine-confined for two reasons: the send
/// policy is answered synchronously on the main actor, and several
/// transitions run inside noise-manager critical sections that the engine
/// is sync-waiting on (where re-entering the engine would self-deadlock,
/// but taking a leaf lock is safe). Every method is one whole transition
/// under the lock, so no caller can observe a torn intermediate state.
final class BLEPrivateMediaSessionStore: @unchecked Sendable {
    private let lock = NSLock()
    private var sessionGenerations: [PeerID: UUID] = [:]
    private var authenticatedStates: [PeerID: BLEAuthenticatedPeerStateObservation] = [:]
    private var proofTimeoutMarkers: [PeerID: BLEPrivateMediaProofTimeoutMarker] = [:]
    private var proofWatchdogs: [PeerID: BLEPrivateMediaProofWatchdog] = [:]
    private var pendingPolicyResolutions: [PeerID: BLEPendingPrivateMediaPolicyResolution] = [:]
    private var stateSendProgress: [PeerID: BLEAuthenticatedPeerStateSendProgress] = [:]
    /// Peers whose parked outbound queues must stay parked until the
    /// convergence retry re-authenticates: a timeout-restore brings back
    /// keys the counterpart may have already discarded, so nothing — not
    /// even the capability-proof watchdog — may drain the queues under
    /// them. Set on the deferred restore transition, cleared by any
    /// transition that is allowed to drain.
    private var outboundConvergenceDeferred: Set<PeerID> = []

    // MARK: Reads

    func currentGeneration(for peerID: PeerID) -> UUID? {
        lock.withLock { sessionGenerations[peerID] }
    }

    /// The exact current generation iff it authenticated both encrypted
    /// private media (bit 8) and durable receipts/retry (bit 9).
    func receiptSessionGeneration(for peerID: PeerID, currentNoiseGeneration: UUID?) -> UUID? {
        lock.withLock {
            guard let generation = sessionGenerations[peerID],
                  generation == currentNoiseGeneration,
                  let authenticated = authenticatedStates[peerID],
                  authenticated.sessionGeneration == generation,
                  authenticated.capabilities.contains(.privateMedia),
                  authenticated.capabilities.contains(.privateMediaReceipts) else {
                return nil
            }
            return generation
        }
    }

    /// One consistent view of the state the send-policy calculus needs.
    func policyInputs(for peerID: PeerID) -> (
        sessionGeneration: UUID?,
        authenticatedState: BLEAuthenticatedPeerStateObservation?,
        timedOut: BLEPrivateMediaProofTimeoutMarker?
    ) {
        lock.withLock {
            (
                sessionGenerations[peerID],
                authenticatedStates[peerID],
                proofTimeoutMarkers[peerID]
            )
        }
    }

    func hasPendingPolicyResolution(for peerID: PeerID) -> Bool {
        lock.withLock { pendingPolicyResolutions[peerID] != nil }
    }

    /// The live proof-timeout identity for a peer (watchdog first, then a
    /// registered waiter) — what a forced/expired timeout must present.
    func proofTimeoutTarget(for peerID: PeerID) -> (fingerprint: String, generation: UUID?, nonce: UUID)? {
        lock.withLock {
            if let watchdog = proofWatchdogs[peerID] {
                return (watchdog.fingerprint, watchdog.sessionGeneration, watchdog.timeoutNonce)
            }
            if let pending = pendingPolicyResolutions[peerID] {
                return (pending.fingerprint, pending.sessionGeneration, pending.timeoutNonce)
            }
            return nil
        }
    }

    // MARK: Generation transitions

    /// Installs a freshly authenticated generation: rotates the proof
    /// watchdog, resets peer-state send progress, and re-binds any pending
    /// policy waiters whose fingerprint still matches (mismatched waiters
    /// are rejected and returned for completion). Returns nil when the
    /// generation is already current — the same-generation reconciliation
    /// path, which must not re-arm proof machinery.
    func beginAuthenticatedGeneration(
        for peerID: PeerID,
        fingerprint: String,
        generation: UUID
    ) -> (watchdogNonce: UUID, rejected: [@MainActor (PrivateMediaSendPolicy) -> Void])? {
        lock.withLock {
            guard sessionGenerations[peerID] != generation else { return nil }
            let watchdogNonce = UUID()
            sessionGenerations[peerID] = generation
            authenticatedStates.removeValue(forKey: peerID)
            proofTimeoutMarkers.removeValue(forKey: peerID)
            proofWatchdogs[peerID] = BLEPrivateMediaProofWatchdog(
                fingerprint: fingerprint,
                sessionGeneration: generation,
                timeoutNonce: watchdogNonce
            )
            stateSendProgress[peerID] =
                BLEAuthenticatedPeerStateSendProgress(sessionGeneration: generation)

            guard var pending = pendingPolicyResolutions[peerID] else {
                return (watchdogNonce, [])
            }
            guard pending.fingerprint.caseInsensitiveCompare(fingerprint) == .orderedSame else {
                pendingPolicyResolutions.removeValue(forKey: peerID)
                return (watchdogNonce, Array(pending.completions.values))
            }
            pending.sessionGeneration = generation
            pending.timeoutNonce = watchdogNonce
            pendingPolicyResolutions[peerID] = pending
            return (watchdogNonce, [])
        }
    }

    /// Records a verified authenticated-peer-state packet for the current
    /// generation: pins the observation, retires proof timers, and releases
    /// matching policy waiters. Returns nil when the generation is no longer
    /// current (the caller's lease raced a replacement).
    func applyAuthenticatedPeerState(
        for peerID: PeerID,
        fingerprint: String,
        generation: UUID,
        capabilities: PeerCapabilities
    ) -> [@MainActor (PrivateMediaSendPolicy) -> Void]? {
        lock.withLock {
            guard sessionGenerations[peerID] == generation else { return nil }
            authenticatedStates[peerID] = BLEAuthenticatedPeerStateObservation(
                fingerprint: fingerprint,
                sessionGeneration: generation,
                capabilities: capabilities
            )
            proofTimeoutMarkers.removeValue(forKey: peerID)
            proofWatchdogs.removeValue(forKey: peerID)
            guard let pending = pendingPolicyResolutions.removeValue(forKey: peerID),
                  pending.fingerprint.caseInsensitiveCompare(fingerprint) == .orderedSame,
                  pending.sessionGeneration == generation else {
                return []
            }
            return Array(pending.completions.values)
        }
    }

    /// Consumes one peer-state send slot (initial or echo) for the current
    /// generation. Returns whether the packet should actually go out.
    func markPeerStateSend(for peerID: PeerID, echo: Bool) -> Bool {
        lock.withLock {
            guard let generation = sessionGenerations[peerID],
                  var progress = stateSendProgress[peerID],
                  progress.sessionGeneration == generation else { return false }
            if echo {
                guard !progress.sentEcho else { return false }
                progress.sentEcho = true
            } else {
                guard !progress.sentInitial else { return false }
                progress.sentInitial = true
            }
            stateSendProgress[peerID] = progress
            return true
        }
    }

    // MARK: Outbound convergence deferral

    func setOutboundDeferredUntilConvergence(_ peerID: PeerID) {
        lock.withLock { _ = outboundConvergenceDeferred.insert(peerID) }
    }

    func clearOutboundDeferredUntilConvergence(_ peerID: PeerID) {
        lock.withLock { _ = outboundConvergenceDeferred.remove(peerID) }
    }

    // MARK: Proof timeout

    /// Expires a proof deadline if its nonce/generation/fingerprint still
    /// identify the live watchdog or waiter set. On expiry the timeout
    /// marker is pinned and any waiters are returned for completion.
    /// `deferredOutbound` reports whether the peer's parked queues must
    /// stay parked (timeout-restore pending its convergence retry).
    func expireProofDeadline(
        for peerID: PeerID,
        fingerprint: String,
        sessionGeneration: UUID?,
        nonce: UUID
    ) -> (expired: Bool, deferredOutbound: Bool, completions: [@MainActor (PrivateMediaSendPolicy) -> Void]) {
        lock.withLock {
            let pending = pendingPolicyResolutions[peerID]
            let pendingMatches = pending?.timeoutNonce == nonce
                && pending?.sessionGeneration == sessionGeneration
                && pending?.fingerprint.caseInsensitiveCompare(fingerprint) == .orderedSame
            let watchdog = proofWatchdogs[peerID]
            let watchdogMatches = sessionGeneration != nil
                && watchdog?.timeoutNonce == nonce
                && watchdog?.sessionGeneration == sessionGeneration
                && watchdog?.fingerprint.caseInsensitiveCompare(fingerprint) == .orderedSame
            guard pendingMatches || watchdogMatches else {
                return (false, false, [])
            }
            var completions: [@MainActor (PrivateMediaSendPolicy) -> Void] = []
            if pendingMatches, let pending {
                completions = Array(pending.completions.values)
            }
            if pendingMatches {
                pendingPolicyResolutions.removeValue(forKey: peerID)
            }
            if watchdogMatches {
                proofWatchdogs.removeValue(forKey: peerID)
            }
            proofTimeoutMarkers[peerID] = BLEPrivateMediaProofTimeoutMarker(
                fingerprint: fingerprint,
                sessionGeneration: sessionGeneration
            )
            return (true, outboundConvergenceDeferred.contains(peerID), completions)
        }
    }

    /// Registers a policy-resolution waiter for a peer still awaiting its
    /// capability proof. Joins the existing waiter set when fingerprints
    /// match (bounded), otherwise starts one, reusing the live watchdog's
    /// deadline identity when it covers the same fingerprint/generation so
    /// only one timeout is ever in flight. `shouldSchedule` tells the
    /// caller to arm a fresh deadline.
    func registerPolicyResolution(
        for peerID: PeerID,
        fingerprint: String,
        requestID: UUID,
        completion: @escaping @MainActor (PrivateMediaSendPolicy) -> Void
    ) -> (registered: Bool, shouldSchedule: Bool, nonce: UUID, generation: UUID?) {
        lock.withLock {
            let generation = sessionGenerations[peerID]
            if var pending = pendingPolicyResolutions[peerID] {
                guard pending.fingerprint.caseInsensitiveCompare(fingerprint) == .orderedSame,
                      pending.completions.count
                        < TransportConfig.privateMediaCapabilityProofWaitersPerPeerCap else {
                    return (false, false, UUID(), generation)
                }
                pending.completions[requestID] = completion
                pendingPolicyResolutions[peerID] = pending
                return (true, false, pending.timeoutNonce, pending.sessionGeneration)
            }

            guard pendingPolicyResolutions.count
                    < TransportConfig.privateMediaCapabilityProofPendingPeerCap else {
                return (false, false, UUID(), generation)
            }
            let currentWatchdog = proofWatchdogs[peerID]
            let reusesWatchdog = currentWatchdog?.fingerprint
                .caseInsensitiveCompare(fingerprint) == .orderedSame
                && currentWatchdog?.sessionGeneration == generation
            let nonce: UUID
            if reusesWatchdog, let currentWatchdog {
                nonce = currentWatchdog.timeoutNonce
            } else {
                nonce = UUID()
            }
            pendingPolicyResolutions[peerID] =
                BLEPendingPrivateMediaPolicyResolution(
                    fingerprint: fingerprint,
                    sessionGeneration: generation,
                    timeoutNonce: nonce,
                    completions: [requestID: completion]
                )
            return (true, !reusesWatchdog, nonce, generation)
        }
    }

    // MARK: Teardown

    /// A session clear retires every generation-bound record. Waiters are
    /// kept but rebased onto a nil generation with a fresh deadline nonce,
    /// returned so the caller re-arms their timeout.
    func clearSession(for peerID: PeerID) -> (fingerprint: String, nonce: UUID)? {
        lock.withLock {
            sessionGenerations.removeValue(forKey: peerID)
            authenticatedStates.removeValue(forKey: peerID)
            proofTimeoutMarkers.removeValue(forKey: peerID)
            proofWatchdogs.removeValue(forKey: peerID)
            stateSendProgress.removeValue(forKey: peerID)
            outboundConvergenceDeferred.remove(peerID)
            guard var pending = pendingPolicyResolutions[peerID] else {
                return nil
            }
            let nonce = UUID()
            pending.sessionGeneration = nil
            pending.timeoutNonce = nonce
            pendingPolicyResolutions[peerID] = pending
            return (pending.fingerprint, nonce)
        }
    }

    /// Panic wipe: these records belong to pre-panic transfer state, and
    /// invoking their callbacks would let queued UI work recreate or resend
    /// wiped media — drop everything.
    func panicReset() {
        lock.withLock {
            sessionGenerations.removeAll()
            authenticatedStates.removeAll()
            proofTimeoutMarkers.removeAll()
            proofWatchdogs.removeAll()
            pendingPolicyResolutions.removeAll()
            stateSendProgress.removeAll()
            outboundConvergenceDeferred.removeAll()
        }
    }
}

extension BLEPrivateMediaSessionStore {
    /// The current generation iff its authenticated peer state proved the
    /// private-media capability (and, when required, durable receipts).
    func provenGeneration(for peerID: PeerID, requireReceipts: Bool) -> UUID? {
        let inputs = policyInputs(for: peerID)
        guard let generation = inputs.sessionGeneration,
              let authenticated = inputs.authenticatedState,
              authenticated.sessionGeneration == generation,
              authenticated.capabilities.contains(.privateMedia) else { return nil }
        if requireReceipts {
            guard authenticated.capabilities.contains(.privateMediaReceipts) else { return nil }
        }
        return generation
    }
}
