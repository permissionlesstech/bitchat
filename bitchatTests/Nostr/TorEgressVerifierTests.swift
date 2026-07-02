//
// TorEgressVerifierTests.swift
// bitchatTests
//
// Unit tests for the runtime Tor-egress self-check policy/caching. The network
// probe is injected, so these tests are deterministic and offline.
//

import Testing
import Foundation
@testable import bitchat
import Tor

@Suite(.serialized)
struct TorEgressVerifierTests {

    /// Deterministic, controllable clock + probe.
    private final class Harness: @unchecked Sendable {
        private let lock = NSLock()
        private var _now = Date(timeIntervalSince1970: 1_000_000)
        private var _result: TorEgressVerifier.ProbeResult = .verifiedTor
        private var _hanging = false
        private var _gated = false
        private var _released = false
        private var _probeCount = 0
        private var _cancelledCount = 0

        var now: Date {
            lock.lock(); defer { lock.unlock() }; return _now
        }
        var probeCount: Int {
            lock.lock(); defer { lock.unlock() }; return _probeCount
        }
        /// Number of hung probes that observed cooperative cancellation.
        var cancelledCount: Int {
            lock.lock(); defer { lock.unlock() }; return _cancelledCount
        }
        func advance(_ seconds: TimeInterval) {
            lock.lock(); _now = _now.addingTimeInterval(seconds); lock.unlock()
        }
        func setResult(_ r: TorEgressVerifier.ProbeResult) {
            lock.lock(); _result = r; lock.unlock()
        }
        /// When `true`, probes park forever and only exit via cooperative
        /// cancellation — models a canary request wedged by
        /// `waitsForConnectivity` deferring the request timer.
        func setHanging(_ hanging: Bool) {
            lock.lock(); _hanging = hanging; lock.unlock()
        }
        /// When `true`, probes wait for `release()` before returning — models
        /// a slow-but-completing canary for join-semantics tests.
        func setGated(_ gated: Bool) {
            lock.lock(); _gated = gated; lock.unlock()
        }
        func release() {
            lock.lock(); _released = true; lock.unlock()
        }
        /// Suspends until at least `n` probes have started.
        func waitUntilProbeCount(atLeast n: Int) async {
            while probeCount < n {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        func makeProbe() -> @Sendable () async -> TorEgressVerifier.ProbeResult {
            return { [self] in
                lock.lock()
                _probeCount += 1
                let r = _result
                let hang = _hanging
                let gated = _gated
                lock.unlock()
                if hang {
                    // Park until cancelled (verifier watchdog or invalidate());
                    // cancellation-responsive so no task outlives the test.
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 2_000_000)
                    }
                    lock.lock(); _cancelledCount += 1; lock.unlock()
                    return .unreachable("hung probe cancelled")
                }
                if gated {
                    while !Task.isCancelled {
                        lock.lock(); let released = _released; lock.unlock()
                        if released { break }
                        try? await Task.sleep(nanoseconds: 1_000_000)
                    }
                }
                return r
            }
        }
        func nowProvider() -> @Sendable () -> Date {
            return { [self] in self.now }
        }
    }

    private func makeVerifier(
        _ h: Harness,
        ttl: TimeInterval = 300,
        minRetry: TimeInterval = 5,
        probeTimeout: TimeInterval = TorEgressVerifier.defaultProbeTimeout
    ) -> TorEgressVerifier {
        TorEgressVerifier(
            ttl: ttl,
            minRetryInterval: minRetry,
            probeTimeout: probeTimeout,
            now: h.nowProvider(),
            probe: h.makeProbe()
        )
    }

    @Test("verifiedTor allows and is cached within TTL (single probe)")
    func verifiedIsCached() async {
        let h = Harness()
        h.setResult(.verifiedTor)
        let v = makeVerifier(h, ttl: 300)

        #expect(await v.verify() == true)
        // Second call within TTL must not re-probe.
        #expect(await v.verify() == true)
        #expect(h.probeCount == 1)
    }

    @Test("cache expires after TTL and re-probes")
    func cacheExpires() async {
        let h = Harness()
        h.setResult(.verifiedTor)
        let v = makeVerifier(h, ttl: 300)

        #expect(await v.verify() == true)
        #expect(h.probeCount == 1)

        h.advance(301)
        #expect(await v.verify() == true)
        #expect(h.probeCount == 2)
    }

    @Test("notTor refuses (leak detected) and is never cached as allowed")
    func notTorRefuses() async {
        let h = Harness()
        h.setResult(.notTor)
        let v = makeVerifier(h, ttl: 300, minRetry: 0)

        #expect(await v.verify() == false)
        // A subsequent success recovers.
        h.setResult(.verifiedTor)
        #expect(await v.verify() == true)
    }

    @Test("unreachable refuses: an unverified egress must not proceed (fail-closed)")
    func unreachableRefuses() async {
        let h = Harness()
        h.setResult(.unreachable("down"))
        let v = makeVerifier(h, ttl: 300, minRetry: 0)

        #expect(await v.verify() == false)
        #expect(v.hasFreshVerification == false)
    }

    @Test("unreachable-then-reachable recovers via retry")
    func unreachableRecoversWhenCanaryReturns() async {
        let h = Harness()
        h.setResult(.unreachable("down"))
        let v = makeVerifier(h, ttl: 300, minRetry: 5)

        #expect(await v.verify() == false)
        #expect(h.probeCount == 1)

        // Canary comes back; the next probe (after the retry throttle window)
        // verifies and allows again.
        h.setResult(.verifiedTor)
        h.advance(5)
        #expect(await v.verify() == true)
        #expect(h.probeCount == 2)
        #expect(v.hasFreshVerification == true)
    }

    @Test("cached verifiedTor within TTL allows during a canary blip without re-probing")
    func cachedVerifiedAllowsDuringCanaryBlip() async {
        let h = Harness()
        h.setResult(.verifiedTor)
        let v = makeVerifier(h, ttl: 300, minRetry: 0)

        #expect(await v.verify() == true)
        #expect(h.probeCount == 1)

        // The canary goes down inside the TTL window: the cached positive
        // verdict is authoritative, no probe runs, traffic stays allowed.
        h.setResult(.unreachable("down"))
        h.advance(100)
        #expect(await v.verify() == true)
        #expect(h.probeCount == 1)
        #expect(v.hasFreshVerification == true)
    }

    @Test("TTL expiry + unreachable refuses until a probe succeeds again")
    func expiredCacheWithUnreachableRefuses() async {
        let h = Harness()
        h.setResult(.verifiedTor)
        let v = makeVerifier(h, ttl: 300, minRetry: 0)

        #expect(await v.verify() == true)

        // Past the TTL the old verdict no longer stands: an unreachable canary
        // means unverified egress, so connection opens are refused.
        h.setResult(.unreachable("down"))
        h.advance(301)
        #expect(v.hasFreshVerification == false)
        #expect(await v.verify() == false)
        #expect(h.probeCount == 2)

        // A subsequent successful probe restores service.
        h.setResult(.verifiedTor)
        #expect(await v.verify() == true)
        #expect(v.hasFreshVerification == true)
    }

    @Test("minRetryInterval bounds re-probing while unverified (no canary hammering)")
    func throttleReprobe() async {
        let h = Harness()
        h.setResult(.unreachable("down"))
        let v = makeVerifier(h, ttl: 300, minRetry: 5)

        #expect(await v.verify() == false)
        #expect(h.probeCount == 1)
        // Within minRetry window: reuse last (refusing) decision, no new probe.
        h.advance(1)
        #expect(await v.verify() == false)
        #expect(h.probeCount == 1)
        // After the window: re-probe.
        h.advance(5)
        #expect(await v.verify() == false)
        #expect(h.probeCount == 2)
    }

    @Test("invalidate clears the synchronous cache snapshot")
    func invalidateClearsSnapshot() async {
        let h = Harness()
        h.setResult(.verifiedTor)
        let v = makeVerifier(h, ttl: 300)

        #expect(await v.verify() == true)
        #expect(v.hasFreshVerification == true)
        await v.invalidate()
        #expect(v.hasFreshVerification == false)
    }

    @Test("notTor drops any cached verification snapshot")
    func notTorClearsSnapshot() async {
        let h = Harness()
        h.setResult(.verifiedTor)
        let v = makeVerifier(h, ttl: 300, minRetry: 0)

        #expect(await v.verify() == true)
        #expect(v.hasFreshVerification == true)

        h.setResult(.notTor)
        h.advance(301)
        #expect(await v.verify() == false)
        #expect(v.hasFreshVerification == false)
    }

    @Test("invalidate forces a fresh probe")
    func invalidateForcesReprobe() async {
        let h = Harness()
        h.setResult(.verifiedTor)
        let v = makeVerifier(h, ttl: 300)

        #expect(await v.verify() == true)
        #expect(h.probeCount == 1)
        await v.invalidate()
        #expect(await v.verify() == true)
        #expect(h.probeCount == 2)
    }

    @Test("lastProbeResult reflects the most recent outcome")
    func lastResultTracked() async {
        let h = Harness()
        h.setResult(.notTor)
        let v = makeVerifier(h, ttl: 300, minRetry: 0)
        _ = await v.verify()
        #expect(await v.lastProbeResult() == .notTor)
    }

    // MARK: - Liveness (probe timeout watchdog + invalidate cancellation)

    @Test("a probe that never completes is bounded by probeTimeout and fails closed")
    func hungProbeIsBoundedByTimeout() async {
        let h = Harness()
        h.setHanging(true)
        let v = makeVerifier(h, ttl: 300, minRetry: 0, probeTimeout: 0.05)

        // Without the watchdog this would wedge: waitsForConnectivity can
        // defer the request timer, leaving the canary bounded only by the
        // 7-day resource timeout.
        #expect(await v.verify() == false)
        let last = await v.lastProbeResult()
        switch last {
        case .unreachable:
            break // fail-closed timeout verdict recorded
        default:
            Issue.record("expected .unreachable after probe timeout, got \(String(describing: last))")
        }
        #expect(v.hasFreshVerification == false)

        // The hung probe task itself was cancelled (URLSession task would be
        // torn down), not abandoned.
        while h.cancelledCount < 1 {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(h.cancelledCount == 1)

        // The in-flight slot was cleared: the next verify() starts a fresh
        // probe (does not join the hung one) and recovers.
        h.setHanging(false)
        h.setResult(.verifiedTor)
        #expect(await v.verify() == true)
        #expect(h.probeCount == 2)
        #expect(v.hasFreshVerification == true)
    }

    @Test("invalidate() cancels the in-flight probe and the awaiting caller fails closed")
    func invalidateCancelsInFlightProbe() async {
        let h = Harness()
        h.setHanging(true)
        // Long (real-time) timeout and throttle: only invalidate() can
        // unblock the caller, and only invalidate() clearing the throttle
        // lets the follow-up probe run without advancing the clock.
        let v = makeVerifier(h, ttl: 300, minRetry: 600, probeTimeout: 600)

        let first = Task { await v.verify() }
        await h.waitUntilProbeCount(atLeast: 1)
        await v.invalidate()

        // The awaiting caller resolves promptly (no 600s wait) and refuses.
        #expect(await first.value == false)
        #expect(v.hasFreshVerification == false)

        // The hung probe observed cancellation (a Tor restart genuinely
        // shakes the wedged canary request).
        while h.cancelledCount < 1 {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        // Recovery: a fresh verify() runs a NEW probe — it neither joins the
        // cancelled one nor inherits its throttle/last-result state.
        h.setHanging(false)
        h.setResult(.verifiedTor)
        #expect(await v.verify() == true)
        #expect(h.probeCount == 2)
        #expect(v.hasFreshVerification == true)
    }

    @Test("recovery after a hung probe survives invalidate + Tor restart cycle")
    func hungThenInvalidatedThenRecovers() async {
        let h = Harness()
        h.setHanging(true)
        let v = makeVerifier(h, ttl: 300, minRetry: 5, probeTimeout: 600)

        // Wedge one probe, then simulate a Tor restart mid-flight.
        let wedged = Task { await v.verify() }
        await h.waitUntilProbeCount(atLeast: 1)
        await v.invalidate()
        #expect(await wedged.value == false)

        // Canary still down right after restart: fresh probe, fail closed —
        // and the throttle applies to the FRESH result (bounded retry intact).
        h.setHanging(false)
        h.setResult(.unreachable("circuit not built"))
        #expect(await v.verify() == false)
        #expect(h.probeCount == 2)
        h.advance(1)
        #expect(await v.verify() == false)
        #expect(h.probeCount == 2) // throttled, no hammering

        // Canary returns after the retry window: verification recovers.
        h.setResult(.verifiedTor)
        h.advance(5)
        #expect(await v.verify() == true)
        #expect(v.hasFreshVerification == true)
    }

    @Test("concurrent verify() callers still share a single in-flight probe")
    func concurrentCallersShareOneProbe() async {
        let h = Harness()
        h.setResult(.verifiedTor)
        h.setGated(true)
        let v = makeVerifier(h, ttl: 300, minRetry: 0)

        let t1 = Task { await v.verify() }
        await h.waitUntilProbeCount(atLeast: 1)
        let t2 = Task { await v.verify() }
        // Give t2 a chance to join the in-flight probe before releasing it.
        // Either way the invariant holds: t2 joins the shared probe, or (if
        // scheduled after completion) hits the fresh TTL cache — exactly one
        // probe runs.
        try? await Task.sleep(nanoseconds: 20_000_000)
        h.release()

        #expect(await t1.value == true)
        #expect(await t2.value == true)
        #expect(h.probeCount == 1)
    }
}
