//
// RelayActivityAssertionTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

#if os(macOS)

import Foundation
import Testing
@testable import bitchat

/// macOS App Nap freezes Tor and BLE relay work once every window is minimized
/// or occluded (#1593). The fix holds a `ProcessInfo` activity — but only while
/// a transport is actually relaying, so an idle configuration does not pay for
/// an assertion it cannot use.
@MainActor
struct RelayActivityAssertionTests {

    /// Counts assertions so a leak (begin without end) or a double-begin is
    /// visible to the test rather than only to Instruments.
    private final class SpyAsserter: ProcessActivityAsserting {
        private(set) var beginCount = 0
        private(set) var endCount = 0
        private(set) var lastReason: String?
        var outstanding: Int { beginCount - endCount }

        func beginActivity(reason: String) -> NSObjectProtocol {
            beginCount += 1
            lastReason = reason
            return NSString(string: "activity-\(beginCount)")
        }

        func endActivity(_ token: NSObjectProtocol) {
            endCount += 1
        }
    }

    private typealias State = RelayActivityAssertion.TransportState

    private func state(tor: Bool = false, ready: Bool = false, ble: Bool = false) -> State {
        State(torDesired: tor, torReady: ready, bluetoothPoweredOn: ble)
    }

    // MARK: - Policy

    @Test("An idle configuration holds no assertion")
    func idleConfigurationHoldsNothing() {
        // Tor off and Bluetooth off: nothing to relay, so nothing to protect.
        #expect(!RelayActivityAssertion.shouldHold(state()))
    }

    @Test("BLE alone justifies the assertion")
    func bluetoothAloneJustifiesTheAssertion() {
        // Mesh-only, Tor deliberately off — the BLE relay is exactly what App
        // Nap would freeze on a minimized window.
        #expect(RelayActivityAssertion.shouldHold(state(ble: true)))
    }

    @Test("Tor bootstrap justifies the assertion before it reports ready")
    func torBootstrapJustifiesTheAssertion() {
        // Dropping the assertion here is what would leave a minimized window
        // stuck "starting tor…" indefinitely.
        #expect(RelayActivityAssertion.shouldHold(state(tor: true)))
    }

    @Test("Tor carrying traffic holds even if the policy flag lagged")
    func torReadyWithoutDesireStillHolds() {
        #expect(RelayActivityAssertion.shouldHold(state(ready: true)))
    }

    @Test("Every transport combination matches the documented policy")
    func everyTransportCombinationMatchesPolicy() {
        for tor in [false, true] {
            for ready in [false, true] {
                for ble in [false, true] {
                    #expect(
                        RelayActivityAssertion.shouldHold(state(tor: tor, ready: ready, ble: ble))
                            == (tor || ready || ble),
                        "tor=\(tor) ready=\(ready) ble=\(ble)"
                    )
                }
            }
        }
    }

    // MARK: - Assertion lifecycle

    @Test("Nothing is asserted before a transport comes up")
    func doesNotHoldOnCreation() {
        let spy = SpyAsserter()
        let assertion = RelayActivityAssertion(asserter: spy)

        #expect(!assertion.isHolding)
        #expect(spy.beginCount == 0)
    }

    @Test("The assertion begins once, with the documented reason")
    func beginsOnceWhenATransportComesUp() {
        let spy = SpyAsserter()
        let assertion = RelayActivityAssertion(asserter: spy)

        assertion.apply(state(ble: true))

        #expect(assertion.isHolding)
        #expect(spy.beginCount == 1)
        #expect(spy.lastReason == RelayActivityAssertion.activityReason)
    }

    @Test("Further active updates do not stack assertions")
    func repeatedActiveUpdatesDoNotStack() {
        // The three Combine sources fire independently; a second "still active"
        // update must not leak another ProcessInfo token.
        let spy = SpyAsserter()
        let assertion = RelayActivityAssertion(asserter: spy)

        assertion.apply(state(ble: true))
        assertion.apply(state(tor: true, ble: true))
        assertion.apply(state(tor: true, ready: true, ble: true))

        #expect(spy.beginCount == 1)
        #expect(spy.outstanding == 1)
    }

    @Test("The assertion survives losing one transport and drops with the last")
    func releasesOnlyWhenTheLastTransportGoesDown() {
        let spy = SpyAsserter()
        let assertion = RelayActivityAssertion(asserter: spy)

        assertion.apply(state(tor: true, ble: true))
        assertion.apply(state(tor: true))          // bluetooth off, Tor still up
        #expect(assertion.isHolding)
        #expect(spy.endCount == 0)

        assertion.apply(state())                   // everything off
        #expect(!assertion.isHolding)
        #expect(spy.outstanding == 0)
    }

    @Test("Repeated idle updates do not double-release")
    func repeatedIdleUpdatesDoNotDoubleRelease() {
        let spy = SpyAsserter()
        let assertion = RelayActivityAssertion(asserter: spy)

        assertion.apply(state(ble: true))
        assertion.apply(state())
        assertion.apply(state())

        #expect(spy.endCount == 1)
        #expect(spy.outstanding == 0)
    }

    @Test("A transport cycling off and on re-arms the exemption")
    func reacquiresAfterTransportsComeBack() {
        // e.g. the Bluetooth radio cycling — the relay must not stay throttled.
        let spy = SpyAsserter()
        let assertion = RelayActivityAssertion(asserter: spy)

        assertion.apply(state(ble: true))
        assertion.apply(state())
        assertion.apply(state(ble: true))

        #expect(assertion.isHolding)
        #expect(spy.beginCount == 2)
        #expect(spy.endCount == 1)
        #expect(spy.outstanding == 1)
    }

    // MARK: - update()

    @Test("A single-flag update drives the policy")
    func updateAppliesASingleFlag() {
        let spy = SpyAsserter()
        let assertion = RelayActivityAssertion(asserter: spy)

        assertion.update { $0.bluetoothPoweredOn = true }
        #expect(assertion.isHolding)
        #expect(spy.beginCount == 1)

        assertion.update { $0.bluetoothPoweredOn = false }
        #expect(!assertion.isHolding)
        #expect(spy.outstanding == 0)
    }

    @Test("A no-op update does not touch the assertion")
    func updateIgnoresUnchangedState() {
        // `removeDuplicates()` upstream should prevent this, but the sinks are
        // independent and the assertion must not depend on that.
        let spy = SpyAsserter()
        let assertion = RelayActivityAssertion(asserter: spy)

        assertion.update { $0.bluetoothPoweredOn = true }
        assertion.update { $0.bluetoothPoweredOn = true }

        #expect(spy.beginCount == 1)
    }

    // MARK: - Teardown

    @Test("Release hands the assertion back")
    func releaseHandsTheAssertionBack() {
        // applicationWillTerminate path.
        let spy = SpyAsserter()
        let assertion = RelayActivityAssertion(asserter: spy)

        assertion.apply(state(tor: true))
        assertion.release()

        #expect(!assertion.isHolding)
        #expect(spy.outstanding == 0)
    }

    @Test("Release is idempotent")
    func releaseIsIdempotent() {
        let spy = SpyAsserter()
        let assertion = RelayActivityAssertion(asserter: spy)

        assertion.apply(state(tor: true))
        assertion.release()
        assertion.release()

        #expect(spy.endCount == 1)
        #expect(spy.outstanding == 0)
    }

    @Test("Release without a held assertion is safe")
    func releaseWithoutActivityIsSafe() {
        let spy = SpyAsserter()
        let assertion = RelayActivityAssertion(asserter: spy)

        assertion.release()

        #expect(spy.beginCount == 0)
        #expect(spy.endCount == 0)
    }
}

#endif
