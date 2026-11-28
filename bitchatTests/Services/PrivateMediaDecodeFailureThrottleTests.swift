//
// PrivateMediaDecodeFailureThrottleTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation
import Testing
@testable import bitchat

/// Media decode failures are attacker-triggerable: an authenticated peer can
/// send malformed payloads as fast as the link allows. Without a rate limit,
/// one system line per payload floods the DM thread (#1518).
struct PrivateMediaDecodeFailureThrottleTests {
    private let alice = PeerID(str: "aaaaaaaaaaaaaaaa")
    private let mallory = PeerID(str: "bbbbbbbbbbbbbbbb")
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func reason() -> PrivateMediaDecodeFailureReason { .malformedPayload }

    @Test("The first failure from a peer posts immediately")
    func firstFailurePosts() {
        var throttle = PrivateMediaDecodeFailureThrottle(window: 300)
        #expect(throttle.record(from: alice, reason: reason(), now: t0) == .post(.malformedPayload))
    }

    @Test("A flood inside one window posts exactly one line")
    func floodPostsOnlyOnce() {
        var throttle = PrivateMediaDecodeFailureThrottle(window: 300)
        var posted = 0
        for i in 0..<500 {
            let outcome = throttle.record(
                from: mallory,
                reason: reason(),
                now: t0.addingTimeInterval(Double(i) * 0.1)   // 500 payloads in 50s
            )
            if outcome != .suppress { posted += 1 }
        }
        #expect(posted == 1)
    }

    @Test("Suppressed failures are reported on the next line, not dropped")
    func suppressedCountSurfacesOnNextLine() {
        var throttle = PrivateMediaDecodeFailureThrottle(window: 300)
        _ = throttle.record(from: mallory, reason: reason(), now: t0)
        for i in 1...9 {
            _ = throttle.record(from: mallory, reason: reason(), now: t0.addingTimeInterval(Double(i)))
        }
        let afterWindow = throttle.record(
            from: mallory,
            reason: reason(),
            now: t0.addingTimeInterval(301)
        )
        #expect(afterWindow == .postWithSuppressed(.malformedPayload, suppressed: 9))
    }

    @Test("A quiet peer posts plainly, with no suppressed count")
    func quietPeerPostsWithoutCount() {
        var throttle = PrivateMediaDecodeFailureThrottle(window: 300)
        _ = throttle.record(from: alice, reason: reason(), now: t0)
        let next = throttle.record(from: alice, reason: reason(), now: t0.addingTimeInterval(600))
        #expect(next == .post(.malformedPayload))
    }

    @Test("Peers are throttled independently")
    func peersAreIndependent() {
        var throttle = PrivateMediaDecodeFailureThrottle(window: 300)
        #expect(throttle.record(from: alice, reason: reason(), now: t0) == .post(.malformedPayload))
        // Mallory flooding must not silence a genuine failure from Alice.
        #expect(throttle.record(from: mallory, reason: reason(), now: t0) == .post(.malformedPayload))
        #expect(throttle.record(from: alice, reason: reason(), now: t0.addingTimeInterval(1)) == .suppress)
        #expect(throttle.record(from: mallory, reason: reason(), now: t0.addingTimeInterval(1)) == .suppress)
    }

    @Test("The reason carried through is the one that surfaced")
    func outcomeCarriesTheReason() {
        var throttle = PrivateMediaDecodeFailureThrottle(window: 300)
        let tooLarge = PrivateMediaDecodeFailureReason.payloadTooLarge(bytes: 99)
        #expect(throttle.record(from: alice, reason: tooLarge, now: t0) == .post(tooLarge))
    }

    /// A hostile sender rotating peer IDs must not grow the throttle's state
    /// without bound.
    @Test("State does not accumulate across long-idle peers")
    func stalePeersArePruned() {
        var throttle = PrivateMediaDecodeFailureThrottle(window: 300)
        for i in 0..<1_000 {
            let rotating = PeerID(str: String(format: "%016x", i))
            _ = throttle.record(from: rotating, reason: reason(), now: t0)
        }
        // Long after every window closed, an old peer starts a fresh window
        // rather than reporting a stale suppressed count.
        let old = PeerID(str: String(format: "%016x", 0))
        let outcome = throttle.record(from: old, reason: reason(), now: t0.addingTimeInterval(10_000))
        #expect(outcome == .post(.malformedPayload))
    }
}
