import BitFoundation
import Foundation
import Testing
@testable import bitchat

struct BLEPrivateMediaSessionStoreTests {
    private let peer = PeerID(str: "aaaaaaaaaaaaaaaa")
    private let fingerprint = "ABCDEF0123456789"

    @Test func sameGenerationReconciliationDoesNotRearmProofMachinery() {
        let store = BLEPrivateMediaSessionStore()
        let generation = UUID()
        let fresh = store.beginAuthenticatedGeneration(
            for: peer, fingerprint: fingerprint, generation: generation
        )
        #expect(fresh != nil)
        // A quarantine-restore of the same generation is a reconciliation,
        // not a new session: no new watchdog, no waiter churn.
        let again = store.beginAuthenticatedGeneration(
            for: peer, fingerprint: fingerprint, generation: generation
        )
        #expect(again == nil)
        // The original watchdog identity survives.
        #expect(store.proofTimeoutTarget(for: peer)?.nonce == fresh?.watchdogNonce)
    }

    @Test func freshGenerationRejectsFingerprintMismatchedWaiters() {
        let store = BLEPrivateMediaSessionStore()
        var completed = 0
        _ = store.registerPolicyResolution(
            for: peer, fingerprint: fingerprint, requestID: UUID(),
            completion: { _ in completed += 1 }
        )
        // The replacement session authenticates a DIFFERENT identity: the
        // old waiters must come back for rejection instead of riding along.
        let fresh = store.beginAuthenticatedGeneration(
            for: peer, fingerprint: "FEDCBA9876543210", generation: UUID()
        )
        #expect(fresh?.rejected.count == 1)
        #expect(!store.hasPendingPolicyResolution(for: peer))
    }

    @Test func applyPeerStateRequiresTheCurrentGenerationAndReleasesWaiters() {
        let store = BLEPrivateMediaSessionStore()
        let generation = UUID()
        _ = store.beginAuthenticatedGeneration(
            for: peer, fingerprint: fingerprint, generation: generation
        )
        _ = store.registerPolicyResolution(
            for: peer, fingerprint: fingerprint, requestID: UUID(),
            completion: { _ in }
        )

        // A proof bound to a superseded generation must not classify the
        // replacement session.
        let stale = store.applyAuthenticatedPeerState(
            for: peer, fingerprint: fingerprint, generation: UUID(),
            capabilities: [.privateMedia]
        )
        #expect(stale == nil)

        let released = store.applyAuthenticatedPeerState(
            for: peer, fingerprint: fingerprint, generation: generation,
            capabilities: [.privateMedia]
        )
        #expect(released?.count == 1)
        // Proof landed: the watchdog is retired, so nothing can time out.
        #expect(store.proofTimeoutTarget(for: peer) == nil)
    }

    @Test func expiryRequiresTheLiveDeadlineIdentityAndPinsTheMarker() {
        let store = BLEPrivateMediaSessionStore()
        let generation = UUID()
        let fresh = store.beginAuthenticatedGeneration(
            for: peer, fingerprint: fingerprint, generation: generation
        )
        let nonce = fresh?.watchdogNonce ?? UUID()

        // A stale nonce (superseded deadline) must not expire anything.
        let stale = store.expireProofDeadline(
            for: peer, fingerprint: fingerprint,
            sessionGeneration: generation, nonce: UUID()
        )
        #expect(!stale.expired)

        let expired = store.expireProofDeadline(
            for: peer, fingerprint: fingerprint,
            sessionGeneration: generation, nonce: nonce
        )
        #expect(expired.expired)
        #expect(!expired.deferredOutbound)
        // The timeout marker now classifies this generation as unproven.
        #expect(store.policyInputs(for: peer).timedOut != nil)
    }

    @Test func expiryReportsTheConvergenceDeferralSoDrainsStayParked() {
        let store = BLEPrivateMediaSessionStore()
        let generation = UUID()
        let fresh = store.beginAuthenticatedGeneration(
            for: peer, fingerprint: fingerprint, generation: generation
        )
        store.setOutboundDeferredUntilConvergence(peer)

        let expired = store.expireProofDeadline(
            for: peer, fingerprint: fingerprint,
            sessionGeneration: generation, nonce: fresh?.watchdogNonce ?? UUID()
        )
        #expect(expired.expired)
        #expect(expired.deferredOutbound)

        store.clearOutboundDeferredUntilConvergence(peer)
        // Deferral is per-peer state, not per-deadline: once convergence
        // clears it, a later expiry may drain.
        _ = store.beginAuthenticatedGeneration(
            for: peer, fingerprint: fingerprint, generation: UUID()
        )
        let next = store.proofTimeoutTarget(for: peer)
        let afterClear = store.expireProofDeadline(
            for: peer, fingerprint: fingerprint,
            sessionGeneration: next?.generation ?? nil, nonce: next?.nonce ?? UUID()
        )
        #expect(afterClear.expired)
        #expect(!afterClear.deferredOutbound)
    }

    @Test func policyWaitersReuseTheLiveWatchdogDeadline() {
        let store = BLEPrivateMediaSessionStore()
        let generation = UUID()
        let fresh = store.beginAuthenticatedGeneration(
            for: peer, fingerprint: fingerprint, generation: generation
        )

        // First waiter piggybacks on the watchdog's deadline (case-insensitive
        // fingerprint match): no second timeout gets scheduled.
        let first = store.registerPolicyResolution(
            for: peer, fingerprint: fingerprint.lowercased(), requestID: UUID(),
            completion: { _ in }
        )
        #expect(first.registered)
        #expect(!first.shouldSchedule)
        #expect(first.nonce == fresh?.watchdogNonce)

        // Later waiters join the existing set.
        let second = store.registerPolicyResolution(
            for: peer, fingerprint: fingerprint, requestID: UUID(),
            completion: { _ in }
        )
        #expect(second.registered)
        #expect(!second.shouldSchedule)
    }

    @Test func clearSessionRebasesWaitersOntoANilGenerationDeadline() {
        let store = BLEPrivateMediaSessionStore()
        let generation = UUID()
        _ = store.beginAuthenticatedGeneration(
            for: peer, fingerprint: fingerprint, generation: generation
        )
        _ = store.registerPolicyResolution(
            for: peer, fingerprint: fingerprint, requestID: UUID(),
            completion: { _ in }
        )
        store.setOutboundDeferredUntilConvergence(peer)

        let rearm = store.clearSession(for: peer)

        // Waiters survive the clear but their deadline is rebased so the
        // old generation's timeout can no longer claim them.
        #expect(rearm != nil)
        #expect(store.currentGeneration(for: peer) == nil)
        #expect(store.hasPendingPolicyResolution(for: peer))
        let target = store.proofTimeoutTarget(for: peer)
        #expect(target?.generation == nil)
        #expect(target?.nonce == rearm?.nonce)
    }

    @Test func peerStateSendsAreOncePerGenerationPerKind() {
        let store = BLEPrivateMediaSessionStore()
        _ = store.beginAuthenticatedGeneration(
            for: peer, fingerprint: fingerprint, generation: UUID()
        )
        #expect(store.markPeerStateSend(for: peer, echo: false))
        #expect(!store.markPeerStateSend(for: peer, echo: false))
        #expect(store.markPeerStateSend(for: peer, echo: true))
        #expect(!store.markPeerStateSend(for: peer, echo: true))

        // A fresh generation resets both slots.
        _ = store.beginAuthenticatedGeneration(
            for: peer, fingerprint: fingerprint, generation: UUID()
        )
        #expect(store.markPeerStateSend(for: peer, echo: false))
    }
}
