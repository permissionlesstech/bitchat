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
        private(set) var probeCount = 0

        var now: Date {
            lock.lock(); defer { lock.unlock() }; return _now
        }
        func advance(_ seconds: TimeInterval) {
            lock.lock(); _now = _now.addingTimeInterval(seconds); lock.unlock()
        }
        func setResult(_ r: TorEgressVerifier.ProbeResult) {
            lock.lock(); _result = r; lock.unlock()
        }
        func makeProbe() -> @Sendable () async -> TorEgressVerifier.ProbeResult {
            return { [self] in
                lock.lock(); probeCount += 1; let r = _result; lock.unlock()
                return r
            }
        }
        func nowProvider() -> @Sendable () -> Date {
            return { [self] in self.now }
        }
    }

    private func makeVerifier(_ h: Harness, ttl: TimeInterval = 300, minRetry: TimeInterval = 5) -> TorEgressVerifier {
        TorEgressVerifier(ttl: ttl, minRetryInterval: minRetry, now: h.nowProvider(), probe: h.makeProbe())
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
}
